import SwiftUI
import ARKit
import RealityKit
import simd
import UIKit
import Darwin

/// AR Slice 2 — tap-to-place ball + hole on a detected horizontal plane.
///
/// Builds on Slice 1's plumbing (camera + horizontal plane detection) and
/// adds:
///   • Tap recognition that raycasts against detected planes
///   • A golf ball (4.27 cm white sphere) at the first tap location
///   • A golf hole (10.8 cm black disc, the regulation 4.25") at the
///     second tap location
///   • An aim line connecting the two
///   • A distance readout (metres)
///   • Reset + Done buttons
///
/// Still no stroke integration — Slice 3 wires the stroke result into the
/// ball position so the user sees their actual just-taken putt visualised
/// in the AR scene. Slice 4 adds ball-roll physics via `BallPhysics.swift`.
///
/// **DEBUG-only entry point.** A small text link "DEBUG · AR placement
/// test (Slice 2)" sits next to Slice 1's link below the result panel's
/// Done button.
struct ARPlacementView: View {
    @Environment(\.dismiss) private var dismiss

    /// Drives the HUD copy + the action button row at the bottom.
    /// Sendable because Slice 2's `handleTap` writes this from the
    /// gesture coordinator via a `Task { @MainActor in ... }`, and Swift
    /// 6 strict-concurrency requires types crossing actor boundaries to
    /// be Sendable. SIMD3<Float> is Sendable; the enum auto-conforms.
    enum PlacementState: Equatable, Sendable {
        case waitingForPlane             // No horizontal plane found yet.
        case readyToPlaceBall            // Plane found, waiting for first tap.
        case readyToPlaceHole(SIMD3<Float>)  // Ball placed, waiting for hole tap.
        case complete(ball: SIMD3<Float>, hole: SIMD3<Float>)
    }

    /// Pre-share confirmation summary. Built by scanning
    /// Documents/ARSessionLogs + Documents/ARSessionRecordings before
    /// the Share Sheet opens. Surfaces count + per-session breakdown
    /// + total size so James knows exactly what he's about to send.
    struct SendPreflight: Equatable, Sendable {
        enum Scope: String, Sendable { case thisOnly, all }
        struct Item: Identifiable, Equatable, Sendable {
            var id: String { sessionId }
            let sessionId: String
            let timestamp: String         // human "21:17:00" extracted from filename
            let hasJSON: Bool
            let hasMP4: Bool
            let frameCount: Int           // B32 extracted JPG frames
            let bytes: Int64
        }
        let scope: Scope
        let items: [Item]
        let totalBytes: Int64
        var totalFiles: Int {
            items.reduce(0) {
                $0 + ($1.hasJSON ? 1 : 0) + ($1.hasMP4 ? 1 : 0) + $1.frameCount
            }
        }
    }

    @State private var placementState: PlacementState = .waitingForPlane
    @State private var trackingState: String = "Starting…"
    @State private var planeCount: Int = 0
    /// Transient hint surfaced as a separate overlay (e.g. "Aim at the
    /// floor"). Lives on its own @State so the 10 Hz didUpdate(frame:)
    /// writes to trackingState don't overwrite it within ~100 ms (C2 in
    /// the 2026-05-31 audit — the toast was previously invisible).
    @State private var transientHint: String?
    /// First time we noticed planeCount stuck at 0 with normal tracking.
    /// Drives the silent-wait hint after 2 s (M12 in the audit).
    @State private var firstStillAt: Date?
    @State private var showStillnessHint: Bool = false
    /// Compact-view toggle. Default OFF for first-time users so they
    /// see the full setup HUD (state, instructions, markers, event
    /// log). Tap the eye icon in the top bar to collapse the chrome
    /// to just the crosshair + Place button + transient hints +
    /// recording dot. Gemini video analysis is materially better
    /// when the camera feed isn't obscured — and the user can flip
    /// back any time. Persists for the duration of the cover.
    @State private var hudCompact: Bool = false
    /// Drives the export Share Sheet over the full ARSessionLogs JSON
    /// set so James can AirDrop / Mail / Files-out everything in one tap.
    @State private var showShareSheet: Bool = false
    /// URLs handed to the Share Sheet — populated asynchronously from
    /// a background scan so the main thread doesn't block on the
    /// filesystem walk (Gemini B21 finding #2).
    @State private var shareSheetURLs: [URL] = []
    /// Pre-share preflight confirmation. James asked for an explicit
    /// "what am I sending" view because Send all silently bundles
    /// every historical session and the iOS Share Sheet shows opaque
    /// sessionId hashes. We show this BEFORE the Share Sheet so the
    /// user can see count + total size + per-session breakdown.
    @State private var showSendPreflight: Bool = false
    @State private var sendPreflight: SendPreflight = SendPreflight(scope: .thisOnly, items: [], totalBytes: 0)
    /// Free-form note input modal for ground-truth tagging (e.g. "phone
    /// slipped here", "plane overlay landed on table not floor").
    @State private var showNoteInput: Bool = false
    @State private var noteText: String = ""
    /// Screen recorder controls. James asked for video of what's
    /// happening on screen alongside the JSON so we can correlate
    /// visuals to sensors. Toggle via the Record button.
    @State private var recorder: ARScreenRecorder = ARScreenRecorder()
    @State private var isRecording: Bool = false

    /// The scene-graph "controller" we expose to the UIViewRepresentable.
    /// Lives as a single instance bound to the view so tap callbacks +
    /// state changes share one source of truth.
    @State private var scene: ARPlacementScene = ARPlacementScene()
    /// Live AR session event log — observed by the HUD for real-time
    /// visibility, persisted to Documents/ARSessionLogs/<id>.json on
    /// dismantle. Files-app + History → Export All picks up these JSONs
    /// alongside stroke replays.
    @State private var logger: ARSessionLogger = ARSessionLogger(slice: "slice2-placement")

    var body: some View {
        ZStack {
            ARPlacementSceneRepresentable(
                scene: scene,
                logger: logger,
                trackingState: $trackingState,
                planeCount: $planeCount,
                placementState: $placementState,
                onTransientHint: { msg in showTransientHint(msg) },
                onResetAfterInterruption: { resetAfterInterruption() }
            )
            .ignoresSafeArea()

            // Centre crosshair so the user can SEE the exact world
            // point they're aiming at before committing — pairs with
            // the Place button. No tap needed; the placement happens
            // wherever this reticle is when the button is pressed.
            crosshair
                .allowsHitTesting(false)

            VStack {
                topBar
                Spacer()
                // In compact mode only the bare-essentials chrome
                // remains visible: a tiny tracking pill, the place
                // button, transient hints. The HUD blocks, GT
                // markers and event log all collapse away so the
                // camera feed + crosshair + AR entities own the
                // whole frame. Material UX win + helps the Gemini
                // video reviewer see the actual scene without HUD
                // chrome dominating every frame.
                if hudCompact {
                    compactStatusPill
                    // GT markers stay reachable even in compact mode
                    // so the user can tag what they just saw without
                    // expanding the HUD again. Smaller, emoji-only,
                    // no labels — just the icon glyphs.
                    compactMarkerRow
                } else {
                    hud
                    if showStillnessHint && planeCount == 0 {
                        stillnessHint
                    }
                    groundTruthMarkerRow
                    eventLog
                }
                placeActionButton
                actionRow
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)

            // Transient hint rendered as its OWN overlay (C2 fix). The
            // 10 Hz didUpdate(frame:) loop overwrites trackingState every
            // ~100 ms, so we route ephemeral feedback through a separate
            // state slot instead. Auto-dismisses 1.5 s after it is set.
            if let hint = transientHint {
                VStack {
                    Spacer()
                    Text(hint)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.78), in: Capsule())
                        .padding(.bottom, 220)
                        .transition(.opacity)
                }
                .allowsHitTesting(false)
            }
        }
        .statusBarHidden()
        .onChange(of: planeCount) { _, newValue in
            // Auto-advance "waitingForPlane" → "readyToPlaceBall" once any
            // horizontal plane is found.
            if newValue > 0, case .waitingForPlane = placementState {
                placementState = .readyToPlaceBall
            }
            // Roll back the silent-wait stillness hint once any plane is
            // detected — and reset the still-since timer so a later loss
            // of planes can re-trigger the hint cleanly.
            if newValue > 0 {
                showStillnessHint = false
                firstStillAt = nil
            }
        }
        .onAppear {
            firstStillAt = Date()
            logger.log(.sessionStart, "Slice 2 placement view opened")
            scene.logger = logger
            scene.logDeviceInfo()
            // CI / XCUITest hook: simulator never detects a plane, so
            // the Place buttons would otherwise be unreachable. The
            // -uiTestMode launch argument fakes the readyToPlaceBall
            // state so button-presence tests can find the controls.
            if CommandLine.arguments.contains("-uiTestMode") {
                planeCount = 1
                placementState = .readyToPlaceBall
                logger.log(.note, "UI test mode: forcing .readyToPlaceBall")
            } else {
                // Auto-start screen recording so every AR session
                // captures video alongside the JSON. James does not
                // have to remember to tap Record — the data is
                // always there for cross-reference. Skipped under
                // -uiTestMode to avoid ReplayKit's permission prompt
                // breaking the XCUITest run.
                logger.log(.note, "Auto-recording on session open")
                if recorder.start(sessionId: logger.sessionId) != nil {
                    isRecording = true
                } else {
                    // ReplayKit unavailable (rare — Mac Catalyst,
                    // tvOS, restricted mode). Don't block the AR
                    // flow; just surface a hint.
                    if let err = recorder.lastError {
                        logger.log(.failed, "Auto-record unavailable: \(err)")
                        showTransientHint("Recording unavailable: \(err)")
                    }
                }
            }
        }
        .onDisappear {
            // Stop any in-flight recording so the MP4 finalises and
            // gets bundled in the next Export All. If recording wasn't
            // active, stop() is a no-op.
            if isRecording {
                recorder.stop { url in
                    if let url {
                        logger.log(.note, "Recording auto-stopped on dismiss: \(url.lastPathComponent)")
                    }
                    logger.saveSnapshot()
                }
            }
            logger.log(.sessionEnd, "Slice 2 placement view dismissed")
            logger.saveSnapshot()
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            // 0.5 s tick is fine for this — we only need a coarse 2-second
            // threshold for the silent-wait hint.
            guard planeCount == 0, let firstStillAt else { return }
            if !showStillnessHint && Date().timeIntervalSince(firstStillAt) > 2.0 {
                showStillnessHint = true
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ARLogShareSheet(urls: shareSheetURLs)
        }
        .sheet(isPresented: $showSendPreflight) {
            preflightSheet
        }
        .alert("Add a ground-truth note", isPresented: $showNoteInput) {
            TextField("e.g. plane landed on table not floor", text: $noteText)
            Button("Cancel", role: .cancel) { noteText = "" }
            Button("Tag") {
                let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    logger.log(.note, "GT: \(trimmed)", payload: ["source": "user_note"])
                }
                noteText = ""
            }
        } message: {
            Text("Logged into the session JSON with a 'GT:' prefix so we can correlate what you saw to what the sensors recorded.")
        }
    }

    /// Show a 1.5 s transient overlay; auto-clears via a task so the
    /// state slot returns to nil and the overlay disappears. Called by
    /// the Coordinator via the `onTransientHint` closure (e.g. from the
    /// raycast-miss branch in handleTap).
    private func showTransientHint(_ message: String) {
        transientHint = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // Only clear if it's STILL the same message — another hint
            // could have replaced it and we don't want to dismiss early.
            if transientHint == message {
                transientHint = nil
            }
        }
    }

    /// Pre-share preview. Lists every session about to be shared
    /// with its timestamp, file types present (JSON / MP4), per-item
    /// size, and a total. James can scroll, confirm, or cancel
    /// before the iOS Share Sheet opens. Avoids accidentally
    /// re-sending the same historical sessions on every Send all.
    private var preflightSheet: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: sendPreflight.scope == .all ? "tray.full.fill" : "doc.fill")
                            .foregroundStyle(sendPreflight.scope == .all ? .indigo : .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sendPreflight.scope == .all ? "Sending ALL sessions" : "Sending THIS session only")
                                .font(.headline)
                            Text("\(sendPreflight.items.count) session" + (sendPreflight.items.count == 1 ? "" : "s") +
                                 " · \(sendPreflight.totalFiles) file" + (sendPreflight.totalFiles == 1 ? "" : "s") +
                                 " · \(formatBytes(sendPreflight.totalBytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if sendPreflight.items.isEmpty {
                    Text("No files to send. Save the snapshot or record a session first.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Section("Sessions (newest first)") {
                        ForEach(sendPreflight.items) { item in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.timestamp).font(.callout.monospaced())
                                    Text(String(item.sessionId.suffix(6)))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if item.hasJSON {
                                    Label("JSON", systemImage: "doc.text")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                                if item.hasMP4 {
                                    Label("MP4", systemImage: "video")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                                if item.frameCount > 0 {
                                    Label("\(item.frameCount) frames",
                                           systemImage: "photo.stack")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                                Text(formatBytes(item.bytes))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 70, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Confirm send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showSendPreflight = false
                        logger.log(.note, "Send cancelled at preflight")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showSendPreflight = false
                        // Open the actual iOS Share Sheet on the next
                        // runloop so the dismiss animation completes
                        // first — otherwise iOS races them and the
                        // share sheet flicks open behind the preflight.
                        DispatchQueue.main.async {
                            showShareSheet = true
                            logger.log(.note, "Send confirmed at preflight, opening share sheet")
                        }
                    } label: {
                        Text("Send")
                            .bold()
                    }
                    .disabled(sendPreflight.items.isEmpty)
                    .accessibilityIdentifier("ar.preflightSendButton")
                }
            }
        }
    }

    /// Walk the URL list (already populated by collectCurrentSessionURLs
    /// or ARLogExport.collectAllLogURLs) and group by sessionId stem so
    /// the preflight sheet can show JSON+MP4 pairs as one row.
    private func buildPreflight(scope: SendPreflight.Scope, urls: [URL]) -> SendPreflight {
        var grouped: [String: (hasJSON: Bool, hasMP4: Bool, frames: Int, bytes: Int64)] = [:]
        for url in urls {
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            // Frame JPGs have shape `<stem>-frame-NNN-<kind>-<HHMMSS>.jpg`.
            // We need to peel the suffix off so they group under the
            // parent sessionId row instead of inventing N siblings.
            let stem: String
            if ext == "jpg",
               let frameIdx = name.range(of: "-frame-", options: .backwards) {
                stem = String(name[..<frameIdx.lowerBound])
            } else {
                stem = url.deletingPathExtension().lastPathComponent
            }
            var entry = grouped[stem] ?? (false, false, 0, 0)
            if ext == "json" { entry.hasJSON = true }
            if ext == "mp4"  { entry.hasMP4 = true }
            if ext == "jpg"  { entry.frames += 1 }
            entry.bytes += size
            grouped[stem] = entry
        }
        let items: [SendPreflight.Item] = grouped
            .map { stem, info in
                SendPreflight.Item(
                    sessionId: stem,
                    timestamp: extractTimestamp(from: stem),
                    hasJSON: info.hasJSON,
                    hasMP4: info.hasMP4,
                    frameCount: info.frames,
                    bytes: info.bytes
                )
            }
            .sorted { $0.timestamp > $1.timestamp }
        let total = items.reduce(Int64(0)) { $0 + $1.bytes }
        return SendPreflight(scope: scope, items: items, totalBytes: total)
    }

    /// Pull a human-readable HH:mm:ss out of an `ar-slice2-placement-
    /// 2026-06-01T21-17-00.123Z-27E805` sessionId stem. Fallback to
    /// the full stem if parsing fails.
    private func extractTimestamp(from stem: String) -> String {
        // Stem shape: ar-slice2-placement-YYYY-MM-DDTHH-MM-SS.MMMZ-XXXXXX
        // We want "HH:MM:SS" of the second-to-last "-" segment cluster.
        let parts = stem.split(separator: "-")
        guard parts.count >= 7 else { return stem }
        // Layout: ar slice2 placement YYYY MM DDTHH MM SS.MMMZ XXXXXX
        let hourPart = parts[5]  // e.g. "01T21" — last two chars are hour
        let minute   = parts[6]
        let secMs    = parts[7]  // "00.123Z"
        let hour     = String(hourPart.suffix(2))
        let sec      = String(secMs.prefix(2))
        return "\(hour):\(minute):\(sec)"
    }

    /// Format bytes as KB / MB to one decimal place for the preflight.
    private func formatBytes(_ b: Int64) -> String {
        let kb = Double(b) / 1024.0
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024.0
        return String(format: "%.1f MB", mb)
    }

    /// Collect ONLY the current session's JSON + MP4 — the pair
    /// keyed by logger.sessionId. Used by the "Send this" button so
    /// James doesn't re-send historical sessions every time.
    private func collectCurrentSessionURLs() -> [URL] {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        let stem = logger.sessionId
        var urls: [URL] = []
        let jsonURL = docs
            .appendingPathComponent("ARSessionLogs", isDirectory: true)
            .appendingPathComponent("\(stem).json")
        if FileManager.default.fileExists(atPath: jsonURL.path) {
            urls.append(jsonURL)
        }
        let recordingsDir = docs.appendingPathComponent("ARSessionRecordings", isDirectory: true)
        let mp4URL = recordingsDir.appendingPathComponent("\(stem).mp4")
        if FileManager.default.fileExists(atPath: mp4URL.path) {
            urls.append(mp4URL)
        }
        // B39 dropped JPG bundling — Gemini reads the MP4 directly,
        // no need for the snapshot bundle. See ARLogShareSheet.swift
        // for the reasoning.
        return urls
    }

    /// Stop the recorder and await the MP4 write so the file exists
    /// before the Share Sheet's directory scan runs.
    ///
    /// B39 removes the on-device key-frame extraction that B32
    /// added. The reasoning: the offline-reviewer pipeline now uses
    /// Gemini 2.5 Pro's native video understanding (gemini_video.py)
    /// which reads the MP4 at 30-60 fps directly — strictly better
    /// than the 1 Hz JPG snapshots the extractor was producing.
    /// Keeping the extractor was just wasting battery + storage and
    /// bloating the Send bundle with redundant frames. The
    /// `extractKeyFrames(...)` static function stays in the
    /// ARScreenRecorder source in case a future offline-without-API
    /// flow needs it; we just don't call it from the live Send path.
    private func stopRecordingAsync() async {
        let savedURL: URL? = await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            recorder.stop { url in
                isRecording = false
                if let url {
                    logger.log(.note, "Recording stopped for send: \(url.lastPathComponent)")
                }
                cont.resume(returning: url)
            }
        }
        guard savedURL != nil else { return }
        await logger.saveSnapshotAndWait()
    }

    /// Start or stop the ReplayKit screen recording. The MP4 lands at
    /// Documents/ARSessionRecordings/<sessionId>.mp4 so the JSON and
    /// the video pair by filename. Export All bundles both.
    private func toggleRecording() {
        if isRecording {
            logger.log(.note, "Recording stop requested")
            recorder.stop { url in
                isRecording = false
                if let url {
                    logger.log(.note, "Recording saved: \(url.lastPathComponent)",
                               payload: ["filename": url.lastPathComponent])
                } else {
                    logger.log(.failed, "Recording save failed: \(recorder.lastError ?? "unknown")")
                    showTransientHint("Recording failed")
                }
            }
        } else {
            logger.log(.note, "Recording start requested")
            if recorder.start(sessionId: logger.sessionId) != nil {
                // start() is asynchronous — ReplayKit will prompt for
                // permission on first ever run. Mark isRecording true
                // optimistically; the callback inside the recorder
                // will flip it back on failure.
                isRecording = true
            } else {
                logger.log(.failed, "Recorder unavailable: \(recorder.lastError ?? "unknown")")
                showTransientHint(recorder.lastError ?? "Recording unavailable")
            }
        }
    }

    /// Force the placement state back to waiting after ARKit relocalises
    /// from an interruption (H5 fix). Without this, the cached ball /
    /// hole world coordinates may have shifted under the user and the
    /// distance readout becomes wrong-but-confident.
    private func resetAfterInterruption() {
        let hadPlacedEntities: Bool
        switch placementState {
        case .readyToPlaceHole, .complete: hadPlacedEntities = true
        default: hadPlacedEntities = false
        }
        guard hadPlacedEntities else { return }
        scene.clearPlacedEntities()
        placementState = planeCount > 0 ? .readyToPlaceBall : .waitingForPlane
        showTransientHint("Tracking recovered — place again")
        logger.log(.reset, "auto-reset after interruption recovery")
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text("Done")
                }
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.55), in: Capsule())
            }
            .accessibilityIdentifier("ar.doneButton")
            Spacer()
            // Clean-view toggle. SF Symbol "eye" / "eye.slash" pair
            // is universally read as "hide / show overlays". Logs to
            // .note so the AR session JSON records which mode the
            // user was in at every video timestamp — important when
            // the Gemini video reviewer is correlating events to
            // frames.
            Button {
                let was = hudCompact
                hudCompact.toggle()
                logger.log(.note, was ? "HUD expanded" : "HUD collapsed (compact view)",
                            payload: ["hud_compact": String(!was)])
            } label: {
                Image(systemName: hudCompact ? "eye.slash" : "eye")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .accessibilityIdentifier("ar.hudCompactToggle")
            Text(hudCompact ? "Slice 2" : "AR place · Slice 2")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
                .accessibilityIdentifier("ar.titleBadge")
        }
        .padding(.top, 12)
    }

    /// Minimal status pill shown ONLY in compact mode. Replaces the
    /// full HUD block with a single line: tracking colour-coded dot
    /// + state label + recording dot if active. Roughly 1/8 the
    /// vertical footprint of the full HUD so the camera frame is
    /// uncluttered for video review.
    private var compactStatusPill: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(trackingTint)
                .frame(width: 8, height: 8)
            Text(stateLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
            if isRecording {
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                    Text("REC")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.black.opacity(0.55), in: Capsule())
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("State", stateLabel, tint: .white)
            row("Tracking", trackingState, tint: trackingTint)
            row("Planes", "\(planeCount)", tint: planeCount > 0 ? .green : .yellow)
            if case let .complete(ball, hole) = placementState {
                row("Distance", String(format: "%.2f m  (%.1f ft)",
                                       simd_distance(ball, hole),
                                       simd_distance(ball, hole) * 3.281),
                    tint: .green)
            }
            Divider().background(.white.opacity(0.25)).padding(.vertical, 2)
            Text(instructionText)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
                .lineSpacing(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    }

    /// Live AR event log shown above the action row. Last 5 events,
    /// newest at the bottom (matches console reading direction). Updated
    /// in real time as ARKit fires delegate callbacks → the user can SEE
    /// what's happening without needing a Mac console.
    private var eventLog: some View {
        let recent = logger.events.suffix(5)
        return VStack(alignment: .leading, spacing: 4) {
            // Title on its own row so the 4 action buttons below have
            // full width — on SE-class iPhones the previous single-row
            // layout overflowed and clipped the Send buttons.
            Text("LIVE EVENTS  (last \(min(5, logger.events.count)) of \(logger.events.count))")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.65))
            HStack(spacing: 6) {
                Button {
                    toggleRecording()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isRecording ? "stop.circle.fill" : "record.circle")
                        Text(isRecording ? "Stop rec" : "Record")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background((isRecording ? Color.red : Color.red.opacity(0.6)),
                                 in: Capsule())
                }
                .accessibilityIdentifier("ar.recordButton")
                Button {
                    // Mid-session snapshot of just THIS session's
                    // events. Useful for tagging "look at this point".
                    // Distinct from Send below — does NOT open a share
                    // sheet; just flushes JSON to disk.
                    logger.log(.note, "Snapshot saved manually")
                    logger.saveSnapshot()
                } label: {
                    Text("Save now")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.6), in: Capsule())
                }
                .accessibilityIdentifier("ar.saveButton")
                Button {
                    // SEND THIS ONLY: just the current sessionId's
                    // JSON + MP4 pair. Now goes through the preflight
                    // confirmation sheet first so James can see exactly
                    // what's about to land in the Share Sheet.
                    logger.log(.note, "Send-this-only requested")
                    Task {
                        if isRecording { await stopRecordingAsync() }
                        await logger.saveSnapshotAndWait()
                        let urls = collectCurrentSessionURLs()
                        sendPreflight = buildPreflight(scope: .thisOnly, urls: urls)
                        shareSheetURLs = urls
                        showSendPreflight = true
                    }
                } label: {
                    Text("Send this")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.85), in: Capsule())
                }
                .accessibilityIdentifier("ar.sendThisButton")
                Button {
                    // SEND ALL: every JSON + MP4 in Documents/. James
                    // explicitly asked for clarity here — the previous
                    // version silently bundled all historical sessions
                    // so the same data got resent on every export. The
                    // preflight sheet lists every session by timestamp
                    // before the Share Sheet opens.
                    logger.log(.note, "Send-all requested")
                    Task {
                        if isRecording { await stopRecordingAsync() }
                        await logger.saveSnapshotAndWait()
                        let urls = await ARLogExport.collectAllLogURLs()
                        sendPreflight = buildPreflight(scope: .all, urls: urls)
                        shareSheetURLs = urls
                        showSendPreflight = true
                    }
                } label: {
                    Text("Send all")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.indigo.opacity(0.85), in: Capsule())
                }
                .accessibilityIdentifier("ar.exportButton")
            }
            ForEach(Array(recent.enumerated()), id: \.element.id) { _, ev in
                HStack(alignment: .top, spacing: 6) {
                    Text(timeShort(ev.timestamp))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.6))
                    Text(ev.kind.rawValue)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.cyan)
                    Text(ev.message)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
            if logger.events.isEmpty {
                Text("(no events yet — move the phone to start scanning)")
                    .font(.caption2.italic())
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 6)
    }

    /// Tiny silent-wait coaching nudge after 2 s of no detected planes
    /// (M12). ARKit needs parallax to bootstrap and a still phone gives
    /// `Tracking=Limited(initializing), Planes=0` indefinitely — which
    /// reads as "the slice is broken" unless we say what to do.
    private var stillnessHint: some View {
        Text("Try slowly panning the phone — ARKit needs motion to detect surfaces")
            .font(.caption2.italic())
            .foregroundStyle(.white)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 6)
    }

    /// Crosshair reticle in the centre of the screen. The Place
    /// button raycasts from this exact point, so what you aim at is
    /// what you get — way more accurate than tap-to-place because the
    /// crosshair gives you a target preview AND the button press
    /// doesn't move the phone the way a tap on the floor would.
    private var crosshair: some View {
        ZStack {
            Circle()
                .stroke(.white, lineWidth: 2)
                .frame(width: 56, height: 56)
                .shadow(color: .black.opacity(0.6), radius: 2)
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2)
        }
        .opacity(crosshairOpacity)
        .accessibilityIdentifier("ar.crosshair")
    }

    /// Dim the crosshair after placement is complete so it doesn't
    /// distract from the result; hide entirely if no plane yet.
    private var crosshairOpacity: Double {
        switch placementState {
        case .waitingForPlane:  return 0.25
        case .readyToPlaceBall, .readyToPlaceHole: return 0.95
        case .complete:         return 0.35
        }
    }

    /// Explicit placement button — appears below the event log only in
    /// states where placement is the next action. The crosshair shows
    /// where the entity will land; pressing this button does the raycast
    /// and commits. Tap-on-floor still works as a fallback.
    @ViewBuilder
    private var placeActionButton: some View {
        switch placementState {
        case .readyToPlaceBall:
            bigPlaceButton(label: "Place ball at crosshair",
                            icon: "circle.fill",
                            tint: .white,
                            id: "ar.placeBallButton") {
                placeAtCenter()
            }
        case .readyToPlaceHole:
            bigPlaceButton(label: "Place hole at crosshair",
                            icon: "scope",
                            tint: .yellow,
                            id: "ar.placeHoleButton") {
                placeAtCenter()
            }
        default:
            EmptyView()
        }
    }

    private func bigPlaceButton(label: String,
                                 icon: String,
                                 tint: Color,
                                 id: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.callout.weight(.bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(tint, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(.top, 8)
        .accessibilityIdentifier(id)
    }

    /// Centre-of-screen raycast + place (mirrors handleTap's flow but
    /// uses the crosshair point instead of a gesture location).
    private func placeAtCenter() {
        guard let world = scene.raycastScreenCenter() else {
            logger.log(.raycastMiss, "place button: screen-centre raycast missed")
            showTransientHint("Aim the crosshair at the floor")
            return
        }
        logger.log(.raycastHit, "place button hit \(ARLogFmt.vec(world))",
                   payload: ["x": String(format: "%.4f", world.x),
                             "y": String(format: "%.4f", world.y),
                             "z": String(format: "%.4f", world.z),
                             "source": "crosshair"])
        switch placementState {
        case .waitingForPlane:
            logger.log(.note, "place button — no plane yet")
        case .readyToPlaceBall:
            scene.placeBall(at: world)
            // Crosshair-path ballPlaced/holePlaced events were missing
            // x/y/z in payload (vs tap-path events which had them) —
            // discovered when analysing first user data dump. Downstream
            // analysers parsing payload only got the source tag; the
            // position was buried in the message string. Now identical
            // shape to the tap path so we can JSON-parse both.
            logger.log(.ballPlaced, "ball via crosshair \(ARLogFmt.vec(world))",
                       payload: ["source": "crosshair",
                                 "x": String(format: "%.4f", world.x),
                                 "y": String(format: "%.4f", world.y),
                                 "z": String(format: "%.4f", world.z)])
            placementState = .readyToPlaceHole(world)
        case .readyToPlaceHole(let ballWorld):
            scene.placeHole(at: world)
            let dist = simd_distance(ballWorld, world)
            logger.log(.holePlaced, "hole via crosshair \(ARLogFmt.vec(world)) · \(ARLogFmt.meters(dist))",
                       payload: ["source": "crosshair",
                                 "x": String(format: "%.4f", world.x),
                                 "y": String(format: "%.4f", world.y),
                                 "z": String(format: "%.4f", world.z),
                                 "distance_m": String(format: "%.4f", dist),
                                 "ball_x": String(format: "%.4f", ballWorld.x),
                                 "ball_y": String(format: "%.4f", ballWorld.y),
                                 "ball_z": String(format: "%.4f", ballWorld.z)])
            placementState = .complete(ball: ballWorld, hole: world)
        case .complete:
            break
        }
    }

    /// Ground-truth markers — quick-tap buttons that let James label
    /// what HE saw at a moment in time, so when we read the JSON back
    /// later we can correlate sensor data to actual observed events.
    /// Each tap logs a `.note` event with a `GT:` prefix.
    private var groundTruthMarkerRow: some View {
        HStack(spacing: 6) {
            markerButton(label: "👍 Good", id: "ar.markerGood") { logger.log(.note, "GT: looks good", payload: ["source": "user_marker", "tag": "good"]) }
            markerButton(label: "📐 Plane wrong", id: "ar.markerPlaneWrong") { logger.log(.note, "GT: plane overlay wrong", payload: ["source": "user_marker", "tag": "plane_wrong"]) }
            markerButton(label: "🎯 Drifted", id: "ar.markerDrifted") { logger.log(.note, "GT: ball/hole drifted", payload: ["source": "user_marker", "tag": "drifted"]) }
            markerButton(label: "❌ Lost", id: "ar.markerLost") { logger.log(.note, "GT: tracking lost", payload: ["source": "user_marker", "tag": "lost_tracking"]) }
            markerButton(label: "📝 Note…", id: "ar.markerNote") { showNoteInput = true }
        }
        .padding(.top, 6)
    }

    private func markerButton(label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.white.opacity(0.18), in: Capsule())
        }
        .accessibilityIdentifier(id)
    }

    /// Compact-mode marker strip. Same tag emit, no text labels —
    /// emoji only, tight circular buttons so 5 of them fit in a
    /// single thin strip. Still logs the same payload.tag values
    /// the analyser uses for correlation.
    private var compactMarkerRow: some View {
        HStack(spacing: 6) {
            compactMarkerButton("👍",   tag: "good")           { logger.log(.note, "GT: looks good",        payload: ["source": "user_marker", "tag": "good"]) }
            compactMarkerButton("📐", tag: "plane_wrong")    { logger.log(.note, "GT: plane overlay wrong", payload: ["source": "user_marker", "tag": "plane_wrong"]) }
            compactMarkerButton("🎯", tag: "drifted")        { logger.log(.note, "GT: ball/hole drifted",   payload: ["source": "user_marker", "tag": "drifted"]) }
            compactMarkerButton("❌", tag: "lost_tracking")  { logger.log(.note, "GT: tracking lost",       payload: ["source": "user_marker", "tag": "lost_tracking"]) }
            compactMarkerButton("📝", tag: "note")           { showNoteInput = true }
            Spacer()
        }
        .padding(.top, 4)
    }

    private func compactMarkerButton(_ glyph: String, tag: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(.callout)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.55), in: Circle())
        }
        .accessibilityIdentifier("ar.compactMarker.\(tag)")
    }

    private func timeShort(_ d: Date) -> String {
        Self.shortTimeFormatter.string(from: d)
    }

    /// Static DateFormatter — reuse across every event-log row render
    /// instead of reallocating per call (L27 in the audit).
    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private var actionRow: some View {
        HStack(spacing: 10) {
            if case .complete = placementState {
                Button { reset() } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            if case .readyToPlaceHole = placementState {
                // UX audit flagged the previous "Re-place ball" label as
                // misleading — it sounded like "drag the existing ball",
                // but the implementation calls `reset()` which wipes
                // everything. "Start over" matches the actual behaviour.
                Button { reset() } label: {
                    Label("Start over", systemImage: "arrow.counterclockwise")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private func row(_ label: String, _ value: String, tint: Color) -> some View {
        HStack {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
                .foregroundStyle(tint)
        }
    }

    private var trackingTint: Color {
        if trackingState.hasPrefix("Normal") { return .green }
        if trackingState.hasPrefix("Limited") || trackingState.hasPrefix("Starting") { return .yellow }
        return .red
    }

    private var stateLabel: String {
        switch placementState {
        case .waitingForPlane:  return "Scanning for floor"
        case .readyToPlaceBall: return "Tap to place ball"
        case .readyToPlaceHole: return "Tap to place hole"
        case .complete:         return "Placement complete"
        }
    }

    private var instructionText: String {
        switch placementState {
        case .waitingForPlane:
            return "Slowly move your phone so the camera sees the floor / table. A horizontal plane should appear within a few seconds."
        case .readyToPlaceBall:
            return "Tap a spot on the floor where you'd address the ball."
        case .readyToPlaceHole:
            return "Tap another spot where the hole should be. Aim line will appear."
        case .complete:
            return "Ball + hole placed. Reset to start over, or tap Done to leave."
        }
    }

    private func reset() {
        logger.log(.reset, "user tapped Start over / Reset")
        scene.clearPlacedEntities()
        placementState = planeCount > 0 ? .readyToPlaceBall : .waitingForPlane
    }
}

// MARK: - Scene controller (shared between SwiftUI + UIViewRepresentable)

/// Holds the RealityKit entities + provides the tap-handling API.
/// Lives as a single instance owned by `ARPlacementView` so the SwiftUI
/// view can call `clearPlacedEntities()` and the UIView coordinator can
/// react to taps that mutate the same scene.
@MainActor
final class ARPlacementScene {
    weak var arView: ARView?
    /// Optional logger reference so scene-side render operations
    /// (placeBall / placeHole / logDeviceInfo) can emit
    /// `materialApplied` / `deviceInfo` events. Set by the View
    /// after the scene is created (the View owns the @State
    /// logger). Optional + weak so the scene works in test
    /// contexts where no logger is attached.
    weak var logger: ARSessionLogger?
    private var ballAnchor: AnchorEntity?
    private var holeAnchor: AnchorEntity?
    private var lineAnchor: AnchorEntity?
    /// Cached world-frame position of the placed ball. The ball's
    /// AnchorEntity sits at this position, but reading
    /// `ballAnchor.position(relativeTo: nil)` is fragile if the entity
    /// is ever re-parented (it would return its position relative to the
    /// new parent, not world). Caching the world position at placement
    /// time avoids that surprise.
    private var ballWorldPosition: SIMD3<Float>?

    /// `@State` of a reference type requires that init can be called from
    /// the property initializer's context — which Swift 6 treats as
    /// nonisolated even though the enclosing `View` is `@MainActor`.
    /// This init sets nothing isolated, so `nonisolated` is sound.
    nonisolated init() {}

    /// Real golf-ball diameter: 4.27 cm regulation minimum (USGA).
    static let ballDiameter: Float = 0.0427
    /// Real golf-hole diameter: 4.25 in = 10.795 cm (R&A / USGA rules).
    static let holeDiameter: Float = 0.10795
    /// Real golf-hole depth: minimum 4 in / 10.16 cm per R&A. We use
    /// 8 cm so the bottom of the well stays visually well below the
    /// detected plane even on lightly-textured floors where ARKit
    /// might place the plane slightly off.
    static let holeDepth: Float = 0.08
    /// Aim-line thickness — slim enough to feel like a laser line, thick
    /// enough to read at 3+ m of distance.
    static let aimLineThickness: Float = 0.006

    /// Place the ball at a world-frame position. Replaces any prior ball.
    ///
    /// B40: switched from `SimpleMaterial(color: .white)` to
    /// `UnlitMaterial(color: .white)` so the ball isn't darkened by
    /// ARKit's lighting estimation — Gemini's CAC00F analysis flagged
    /// the white ball as rendering matte-gray in indoor conditions.
    /// Unlit pins the colour at the declared value regardless of scene
    /// lighting, which is exactly what we want for a high-visibility
    /// golf ball.
    func placeBall(at worldPosition: SIMD3<Float>) {
        guard let arView else { return }
        ballAnchor?.removeFromParent()

        let radius = Self.ballDiameter / 2
        let mesh = MeshResource.generateSphere(radius: radius)
        let material = UnlitMaterial(color: .white)
        let model = ModelEntity(mesh: mesh, materials: [material])
        // Lift the sphere by its radius so it sits ON the plane, not into it.
        model.position = SIMD3<Float>(0, radius, 0)

        let anchor = AnchorEntity(world: worldPosition)
        anchor.addChild(model)
        arView.scene.addAnchor(anchor)
        ballAnchor = anchor
        ballWorldPosition = worldPosition  // cache for the aim-line draw

        logger?.log(.materialApplied, "ball material applied",
                    payload: ["entity": "ball",
                              "material": "UnlitMaterial",
                              "color": "white",
                              "radius_m": String(format: "%.4f", radius)])
    }

    /// Place the hole at a world-frame position. Replaces any prior hole.
    /// Also draws / refreshes the aim line if a ball is already placed.
    ///
    /// The hole is rendered as a regulation 4.25" (10.8 cm) wide × 8 cm
    /// deep dark well, with the TOP RIM flush against the detected
    /// plane and the body extending DOWNWARD INTO the floor — exactly
    /// like a real golf hole, per James's B22 feedback. We can't carve
    /// a real hole into the camera feed (the floor isn't our mesh) but
    /// a black-interior sunken well reads correctly from any camera
    /// angle: directly above you see a dark disc; from an angle you
    /// see depth into the well.
    ///
    /// `MeshResource.generateCylinder(height:radius:)` is iOS 18+, so
    /// we use a corner-rounded `generateBox` whose width == depth ==
    /// diameter and `cornerRadius == diameter / 2` — geometrically
    /// indistinguishable from a cylinder at this size.
    func placeHole(at worldPosition: SIMD3<Float>) {
        guard let arView else { return }
        holeAnchor?.removeFromParent()

        // B40 hole rebuild — addresses Gemini's CAC00F findings:
        //
        //   * White SimpleMaterials were rendering as gray under
        //     ARKit lighting estimation. → switch to UnlitMaterial
        //     for all white parts (rim, wall, flagstick) so colour
        //     is pinned to declared value.
        //   * The disc-stack (rim + liner + shadow + bottom) read
        //     as a flat 2D decal because every layer sits at
        //     approximately plane height. → replace with a TRUE
        //     3D recess: white cylindrical wall going DOWN 8 cm
        //     into the floor, with a dark bottom at the base. From
        //     above this reads as a regulation white-rimmed cup
        //     with a shadowed interior; from an angle it reads
        //     as actual depth.
        //   * Flag was a rigid 2D rectangle. → custom triangle
        //     mesh via MeshDescriptor (iOS 13+).
        //
        // Layer list:
        //   [1] White rim disc — flush at plane (the halo).
        //   [2] White cylinder wall — 8 cm deep, descends into
        //       floor. Inner faces visible from above through the
        //       rim opening; reads as cup-interior plastic.
        //   [3] Dark bottom disc — at -8 cm, the cup floor.
        //   [4] White flagstick — 70 cm tall pole.
        //   [5] Red triangle flag — vertex mesh, looks like a
        //       real flag.

        let dia = Self.holeDiameter           // 10.8 cm — regulation cup
        let depth = Self.holeDepth            // 8 cm — regulation depth
        let rimOuter = dia * 1.20             // ≈ 12.9 cm — white halo

        let anchor = AnchorEntity(world: worldPosition)

        // [1] WHITE RIM — flat disc at plane level. UnlitMaterial
        //     pins it visibly white regardless of lighting.
        let rimMesh = MeshResource.generatePlane(width: rimOuter,
                                                  depth: rimOuter,
                                                  cornerRadius: rimOuter / 2)
        let rimMaterial = UnlitMaterial(color: .white)
        let rimModel = ModelEntity(mesh: rimMesh, materials: [rimMaterial])
        rimModel.position = SIMD3<Float>(0, 0.0005, 0)
        anchor.addChild(rimModel)

        // [2] CYLINDER WALL — corner-rounded box at the cup's
        //     diameter, height = depth, dropped 1/2 depth so the
        //     top sits at plane height and the bottom at -depth.
        //     White UnlitMaterial = plastic cup liner.
        //     iOS 17 lacks MeshResource.generateCylinder so we use
        //     the corner-radius-as-half-side trick.
        let wallMesh = MeshResource.generateBox(width: dia,
                                                 height: depth,
                                                 depth: dia,
                                                 cornerRadius: dia / 2)
        let wallMaterial = UnlitMaterial(color: .white)
        let wallModel = ModelEntity(mesh: wallMesh, materials: [wallMaterial])
        wallModel.position = SIMD3<Float>(0, -depth / 2, 0)
        anchor.addChild(wallModel)

        // [3] DARK BOTTOM — disc at the base of the cup. Warm
        //     dark gray (not pure black) to avoid uncanny look.
        //     SimpleMaterial fine here — we WANT it shaded /
        //     darker, that's the whole point.
        let bottomDia = dia * 0.95
        let bottomMesh = MeshResource.generatePlane(width: bottomDia,
                                                     depth: bottomDia,
                                                     cornerRadius: bottomDia / 2)
        let bottomMaterial = SimpleMaterial(
            color: UIColor(red: 0.10, green: 0.08, blue: 0.06, alpha: 1.0),
            roughness: 1.0,
            isMetallic: false
        )
        let bottomModel = ModelEntity(mesh: bottomMesh, materials: [bottomMaterial])
        // Sits 1 mm above the wall's bottom face so it shows.
        bottomModel.position = SIMD3<Float>(0, -depth + 0.001, 0)
        anchor.addChild(bottomModel)

        // [4] FLAGSTICK — 70 cm white pole, UnlitMaterial white.
        let poleSide: Float = 0.015
        let poleHeight: Float = 0.70
        let poleMesh = MeshResource.generateBox(width: poleSide,
                                                  height: poleHeight,
                                                  depth: poleSide,
                                                  cornerRadius: poleSide / 2)
        let poleMaterial = UnlitMaterial(color: .white)
        let poleModel = ModelEntity(mesh: poleMesh, materials: [poleMaterial])
        poleModel.position = SIMD3<Float>(0, poleHeight / 2, 0)
        anchor.addChild(poleModel)

        // [5] TRIANGLE FLAG — custom MeshDescriptor. Right-angle
        //     triangle with the vertical edge attached to the
        //     pole and the tip extending out +X. 15 cm long × 10
        //     cm tall.
        let flagW: Float = 0.15
        let flagH: Float = 0.10
        let flagMesh = Self.makeTriangleFlagMesh(width: flagW, height: flagH)
        let flagMaterial = UnlitMaterial(color: UIColor(red: 0.90,
                                                         green: 0.10,
                                                         blue: 0.10,
                                                         alpha: 1.0))
        let flagModel = ModelEntity(mesh: flagMesh, materials: [flagMaterial])
        flagModel.position = SIMD3<Float>(poleSide / 2,
                                            poleHeight - flagH - 0.02,
                                            0)
        anchor.addChild(flagModel)

        arView.scene.addAnchor(anchor)
        holeAnchor = anchor

        logger?.log(.materialApplied, "hole materials applied",
                    payload: ["entity": "hole",
                              "rim": "UnlitMaterial.white",
                              "wall": "UnlitMaterial.white",
                              "bottom": "SimpleMaterial.dark",
                              "flagstick": "UnlitMaterial.white",
                              "flag": "UnlitMaterial.red.triangle",
                              "depth_m": String(format: "%.3f", depth),
                              "diameter_m": String(format: "%.4f", dia)])

        if let ballWorldPosition {
            drawAimLine(from: ballWorldPosition, to: worldPosition)
        }
    }

    /// Build a flat triangle mesh for the flag. iOS 13+ via
    /// `MeshDescriptor` + `MeshResource.generate(from:)`.
    /// Triangle has vertices at pole (top + bottom) and tip (+X,
    /// mid-height). Renders single-sided; the unlit material on
    /// both faces means orientation doesn't matter for legibility.
    private static func makeTriangleFlagMesh(width: Float, height: Float) -> MeshResource {
        var descriptor = MeshDescriptor(name: "flag")
        descriptor.positions = MeshBuffer([
            SIMD3<Float>(0, 0, 0),              // pole bottom of flag
            SIMD3<Float>(0, height, 0),         // pole top of flag
            SIMD3<Float>(width, height / 2, 0), // tip
        ])
        // Two triangles (front + back) so it shows from either side.
        descriptor.primitives = .triangles([
            0, 2, 1,   // front-facing (CCW)
            0, 1, 2,   // back-facing (CW)
        ])
        return (try? MeshResource.generate(from: [descriptor]))
            ?? MeshResource.generateBox(width: width, height: height, depth: 0.001)
    }

    /// Log a one-shot deviceInfo event at session start. Captures
    /// the iPhone model, iOS version, and AR capabilities so we can
    /// tailor render fidelity per device. Surfaced by Gemini's
    /// CAC00F review as a logger gap (couldn't identify the iPhone
    /// from the JSON alone).
    func logDeviceInfo() {
        let device = UIDevice.current
        var hwModel = "unknown"
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.compactMap { element -> String? in
            guard let value = element.value as? Int8, value != 0 else { return nil }
            return String(UnicodeScalar(UInt8(value)))
        }.joined()
        if !identifier.isEmpty { hwModel = identifier }

        let supportsMesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        let supportsPersonSegmentation = ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentation)

        logger?.log(.deviceInfo, "device info",
                    payload: ["device_model": hwModel,
                              "device_name": device.name,
                              "ios_version": device.systemVersion,
                              "lidar_mesh_supported": supportsMesh ? "true" : "false",
                              "person_segmentation_supported": supportsPersonSegmentation ? "true" : "false",
                              "user_interface_idiom": device.userInterfaceIdiom == .phone ? "phone" : "other"])
    }

    /// Draw a thin box between ball and hole as an aim guide. Was a
    /// cylinder originally but `MeshResource.generateCylinder` is iOS
    /// 18+ only and PuttingLab targets iOS 17. A 12 mm-square box at
    /// 1-3 m viewing distance is visually indistinguishable from a
    /// cylinder for this purpose.
    private func drawAimLine(from: SIMD3<Float>, to: SIMD3<Float>) {
        guard let arView else { return }
        lineAnchor?.removeFromParent()

        let mid = (from + to) * 0.5
        let length = simd_distance(from, to)
        guard length > 0.001 else { return }  // skip degenerate zero-length

        let side = Self.aimLineThickness * 2  // diameter ≈ side length
        let mesh = MeshResource.generateBox(width: length,
                                             height: side,
                                             depth: side,
                                             cornerRadius: side / 2)
        let material = SimpleMaterial(color: .yellow.withAlphaComponent(0.75),
                                       roughness: 0.5, isMetallic: false)
        let model = ModelEntity(mesh: mesh, materials: [material])

        // Box's long axis is X. Rotate so +X points from ball→hole
        // along the horizontal direction. `direction` lives between two
        // points on a (roughly) horizontal plane — by construction it
        // should not be near anti-parallel to +X. The anti-parallel
        // branch is defensive only (M15 in the 2026-05-31 audit).
        let direction = simd_normalize(to - from)
        let xAxis = SIMD3<Float>(1, 0, 0)
        let rotation: simd_quatf
        let dot = simd_dot(xAxis, direction)
        if dot > 0.9999 {
            rotation = simd_quatf(angle: 0, axis: xAxis)
        } else if dot < -0.9999 {
            // Anti-parallel: rotate 180° around Y to flip +X → -X.
            rotation = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        } else {
            let axis = simd_normalize(simd_cross(xAxis, direction))
            let angle = acos(dot)
            rotation = simd_quatf(angle: angle, axis: axis)
        }
        model.transform.rotation = rotation

        // Lift the ANCHOR by 2 mm (in world space), not the model. Local
        // offsets get rotated; world offsets stay vertical regardless of
        // the model's orientation.
        let anchor = AnchorEntity(world: mid + SIMD3<Float>(0, 0.002, 0))
        anchor.addChild(model)
        arView.scene.addAnchor(anchor)
        lineAnchor = anchor
    }

    /// Raycast from the centre of the ARView (where the crosshair sits)
    /// against detected horizontal planes. Returns the world-space hit
    /// or nil on miss. Used by the explicit Place buttons — strictly
    /// more accurate than tap-to-place because the crosshair shows
    /// exactly where the entity will land BEFORE you commit, and the
    /// button press doesn't shake the phone.
    func raycastScreenCenter() -> SIMD3<Float>? {
        guard let arView else { return nil }
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)

        // B41: prefer the LiDAR mesh when available — placements snap
        // to the actual scanned floor, not an inferred rectangular
        // plane. Fall back to plane geometry, then to .estimatedPlane
        // for the first 5 s of any session before either has
        // populated.
        let priorities: [ARRaycastQuery.Target] = [
            .existingMeshGeometry,
            .existingPlaneGeometry,
            .estimatedPlane,
        ]
        for target in priorities {
            guard let query = arView.makeRaycastQuery(
                    from: center,
                    allowing: target,
                    alignment: .horizontal
                  ),
                  let result = arView.session.raycast(query).first else {
                continue
            }
            let t = result.worldTransform
            return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        }
        return nil
    }

    func clearPlacedEntities() {
        ballAnchor?.removeFromParent()
        holeAnchor?.removeFromParent()
        lineAnchor?.removeFromParent()
        ballAnchor = nil
        holeAnchor = nil
        lineAnchor = nil
        ballWorldPosition = nil
    }
}

// MARK: - UIViewRepresentable

private struct ARPlacementSceneRepresentable: UIViewRepresentable {
    let scene: ARPlacementScene
    let logger: ARSessionLogger
    @Binding var trackingState: String
    @Binding var planeCount: Int
    @Binding var placementState: ARPlacementView.PlacementState
    /// Callback fired when the Coordinator wants to surface a 1.5 s
    /// transient hint (e.g. "Aim at the floor"). Goes to a separate
    /// @State on the parent — see ARPlacementView.transientHint — so
    /// the live trackingState writes from didUpdate(frame:) don't
    /// overwrite it within 100 ms (C2 fix).
    let onTransientHint: (String) -> Void
    /// Callback fired on sessionInterruptionEnded so the parent view
    /// can force a reset of any placed entities — anchors are
    /// `AnchorEntity(world:)` and may now point to stale coordinates
    /// after ARKit relocalisation (H5 fix).
    let onResetAfterInterruption: () -> Void

    func makeUIView(context: Context) -> ARView {
        // KNOWN-RISK FOR SLICE 2 (same as Slice 1, restored from earlier
        // drop): this spins up a SECOND ARSession on top of the one
        // ARTrackingManager already owns for stillness-lock / pose
        // tracking during practice. iOS doesn't formally support two
        // concurrent ARSessions; in practice the more recent .run()
        // tends to win and the other quietly stops emitting frames.
        // When James dismisses the view, ARTrackingManager will need to
        // be restarted to resume normal stroke-detection. Slice 3 fixes
        // this with an explicit pause/resume around the cover
        // presentation.
        let arView = ARView(frame: .zero,
                            cameraMode: .ar,
                            automaticallyConfigureSession: false)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .none

        // B41 — LiDAR mesh as primary surface tracker.
        // `.meshWithClassification` gives a real triangle mesh of
        // every surface plus a per-face label (floor / wall /
        // ceiling / …) that we filter to floor-only for the green
        // overlay. Killed the rectangle-plane jitter Gemini surfaced
        // in CAC00F. Plane detection is kept ON in parallel as a
        // raycast fallback for the first ~5 s before the mesh
        // populates. Non-LiDAR phones fall back to plane detection
        // plus `.smoothedSceneDepth` for tighter inferred-depth
        // raycasts.
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
            context.coordinator.lidarActive = true
            logger.log(.note, "LiDAR scene reconstruction enabled (meshWithClassification)")
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            // Older LiDAR-equipped devices that don't support the
            // classification variant — we still get raw mesh.
            config.sceneReconstruction = .mesh
            context.coordinator.lidarActive = true
            logger.log(.note, "LiDAR mesh enabled (no classification)")
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics = [.smoothedSceneDepth]
            context.coordinator.lidarActive = false
            logger.log(.note, "LiDAR unavailable, plane+depth fallback (smoothedSceneDepth)")
        } else {
            context.coordinator.lidarActive = false
            logger.log(.note, "LiDAR unavailable, plane-only fallback")
        }

        arView.session.delegateQueue = .main
        arView.session.delegate = context.coordinator
        arView.session.run(config, options: [])
        // No `debugOptions = .showAnchorGeometry` here — that solid green
        // wireframe overlay was confusing during Slice 1 testing ("paints
        // the whole room green"). Instead we add our own translucent
        // green ModelEntity over each detected plane via the coordinator
        // (see `addOrUpdatePlaneOverlay`), so the user sees how well the
        // floor is mapped without losing the camera feed underneath.

        // Tap recognition.
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                          action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tap)

        scene.arView = arView
        context.coordinator.arView = arView
        context.coordinator.scene = scene
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // Coordinator already reads placementState live through its
        // @Binding — the old self-write here was a structural no-op
        // (L19 in the audit). Intentionally empty.
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        // Pause the AR session so the camera + IMU stop. ARTrackingManager
        // restart is handled by PracticeSessionView's onDismiss closure
        // (H4 fix) so we don't need to touch it here.
        uiView.session.pause()
        // Drop our translucent plane overlays + placed entities. SwiftUI
        // calls dismantleUIView on the main thread but the static method
        // isn't @MainActor-isolated at the type level, so we hop
        // explicitly via assumeIsolated to satisfy Swift 6 strict mode.
        // saveSnapshot is NOT called here — onDisappear on the View
        // already does it, and doing it twice produces wasted I/O + the
        // second write may race with the first (M14 fix).
        MainActor.assumeIsolated {
            coordinator.clearAllPlaneOverlays()
            coordinator.scene?.clearPlacedEntities()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(trackingState: $trackingState,
                    planeCount: $planeCount,
                    placementState: $placementState,
                    logger: logger,
                    onTransientHint: onTransientHint,
                    onResetAfterInterruption: onResetAfterInterruption)
    }

    /// `@MainActor` on the class so its own state stays main-isolated,
    /// but every ARSessionDelegate method + the @objc tap selector is
    /// marked `nonisolated` and bridges to MainActor via
    /// `MainActor.assumeIsolated`. The Obj-C protocol requirements
    /// cannot express actor isolation, so Swift 6 strict-concurrency
    /// otherwise rejects @MainActor-isolated methods satisfying them
    /// (C1 in the 2026-05-31 audit). `arView.session.delegateQueue =
    /// .main` guarantees ARKit calls us on the main thread at runtime,
    /// so the assumeIsolated check holds; UITapGestureRecognizer
    /// likewise dispatches on the main thread.
    @MainActor
    final class Coordinator: NSObject, ARSessionDelegate {
        @Binding var trackingState: String
        @Binding var planeCount: Int
        @Binding var placementState: ARPlacementView.PlacementState
        weak var arView: ARView?
        weak var scene: ARPlacementScene?
        let logger: ARSessionLogger
        let onTransientHint: (String) -> Void
        let onResetAfterInterruption: () -> Void

        private var detectedPlanes: Set<UUID> = []
        private var lastHUDUpdate: Date = .distantPast
        /// Real timestamp-based debounce for tap placement. Replaces the
        /// previous `isProcessingTap` defer pattern which was dead code
        /// for sequential gesture dispatches (handleTap is synchronous
        /// on MainActor; defer cleared the flag before the next tap
        /// could even arrive). 300 ms keeps fast deliberate taps usable
        /// while killing the common iOS double-tap reflex that
        /// otherwise places ball + hole in the same spot (H6 fix).
        private var lastPlacementAt: Date?

        /// Translucent green overlay rectangles, one per detected plane.
        /// Replaces ARKit's built-in `debugOptions = .showAnchorGeometry`
        /// which paints solid-green wireframe over every surface. Map
        /// key is the plane's anchor UUID so we can update / remove
        /// individually as ARKit grows the mesh.
        private var planeOverlays: [UUID: PlaneOverlay] = [:]
        /// Throttle for `.planeUpdated` log emission. ARKit fires anchor
        /// updates at ~10 Hz per plane, which would spam the event log.
        /// We only log if 1 s has passed since the last update event for
        /// that specific plane.
        private var lastPlaneUpdateLog: [UUID: Date] = [:]
        /// Set of plane IDs whose classification has already been
        /// logged via `.planeClassification`. We emit one event per
        /// plane the first time it passes through the overlay path,
        /// so the JSON records ARKit's verdict (floor / table / wall /
        /// none / …) per plane without churn.
        private var loggedClassifications: Set<UUID> = []

        // MARK: B41 LiDAR scene reconstruction

        /// Mesh manager that owns every cached `ARMeshAnchor` and
        /// rebuilds the floor-only triangle list. Optional only for
        /// init ordering — wired immediately in init body.
        let meshManager = ARMeshManager()
        /// True if `ARWorldTrackingConfiguration.sceneReconstruction
        /// = .meshWithClassification` was enabled this session. False
        /// on non-LiDAR devices (regular iPhones).
        var lidarActive: Bool = false
        /// Single anchor + entity carrying the live LiDAR floor
        /// overlay. Rebuilt whenever the mesh manager reports a
        /// change in floor-triangle count.
        private var meshOverlayAnchor: AnchorEntity?
        private var meshOverlayEntity: ModelEntity?
        /// Throttle for `.meshUpdated` log emission. ARKit updates
        /// mesh anchors at ~1-2 Hz; we log at most every 2 s per
        /// anchor.
        private var lastMeshUpdateLog: [UUID: Date] = [:]
        /// Throttle for the global `.meshStats` event. Emit at most
        /// every 5 s so we get one stats sample per pan-and-scan
        /// burst without polluting the log.
        private var lastMeshStatsAt: Date = .distantPast

        /// Cached overlay record. Re-uses the same ModelEntity across
        /// the 10 Hz didUpdate ticks instead of allocating a fresh
        /// MeshResource + SimpleMaterial + ModelEntity every time (M7
        /// fix). We rebuild the mesh only when the plane extent changes
        /// by more than 5 cm; otherwise we just update the transform.
        private struct PlaneOverlay {
            let anchor: AnchorEntity
            let model: ModelEntity
            var lastWidth: Float
            var lastDepth: Float
        }

        init(trackingState: Binding<String>,
             planeCount: Binding<Int>,
             placementState: Binding<ARPlacementView.PlacementState>,
             logger: ARSessionLogger,
             onTransientHint: @escaping (String) -> Void,
             onResetAfterInterruption: @escaping () -> Void) {
            _trackingState = trackingState
            _planeCount = planeCount
            _placementState = placementState
            self.logger = logger
            self.onTransientHint = onTransientHint
            self.onResetAfterInterruption = onResetAfterInterruption
        }

        // MARK: ARSessionDelegate
        //
        // Every delegate method is declared `nonisolated` so the
        // @MainActor Coordinator class satisfies the @objc protocol
        // requirements (which can't carry isolation). The body hops
        // back to MainActor via assumeIsolated, which is a runtime
        // assertion that holds because `arView.session.delegateQueue =
        // .main` guarantees ARKit dispatches on the main thread. C1
        // in the 2026-05-31 audit.

        nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
            MainActor.assumeIsolated {
                let now = Date()
                guard now.timeIntervalSince(lastHUDUpdate) > 0.1 else { return }
                lastHUDUpdate = now
                let status = Self.formatTrackingState(frame.camera.trackingState)
                // Log tracking-state CHANGES only (not every 100 ms tick).
                if status != _trackingState.wrappedValue {
                    logger.log(.trackingState, status)
                }
                _trackingState.wrappedValue = status
            }
        }

        nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            MainActor.assumeIsolated {
                var added = 0
                var meshDirty = false
                for a in anchors {
                    if let plane = a as? ARPlaneAnchor {
                        if detectedPlanes.insert(a.identifier).inserted {
                            added += 1
                            addOrUpdatePlaneOverlay(plane)
                            logger.log(.planeAdded,
                                       "plane \(plane.identifier.uuidString.prefix(6)) " +
                                       "ext=\(String(format: "%.2f×%.2f", plane.planeExtent.width, plane.planeExtent.height))m",
                                       payload: [
                                           "id": plane.identifier.uuidString,
                                           "width": String(format: "%.3f", plane.planeExtent.width),
                                           "height": String(format: "%.3f", plane.planeExtent.height),
                                           "alignment": plane.alignment == .horizontal ? "horizontal" : "vertical",
                                       ])
                        }
                    } else if let meshAnchor = a as? ARMeshAnchor {
                        if meshManager.updateAnchor(meshAnchor) {
                            meshDirty = true
                        }
                        logger.log(.meshAdded,
                                   "mesh \(meshAnchor.identifier.uuidString.prefix(6)) faces=\(meshAnchor.geometry.faces.count)",
                                   payload: [
                                       "id": meshAnchor.identifier.uuidString,
                                       "face_count": "\(meshAnchor.geometry.faces.count)",
                                   ])
                    }
                }
                if meshDirty { rebuildMeshOverlay() }
                if added > 0 { _planeCount.wrappedValue = detectedPlanes.count }
                emitMeshStatsIfDue()
            }
        }

        nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            MainActor.assumeIsolated {
                let now = Date()
                var meshDirty = false
                for a in anchors {
                    if let plane = a as? ARPlaneAnchor,
                       detectedPlanes.contains(a.identifier) {
                        addOrUpdatePlaneOverlay(plane)
                        let last = lastPlaneUpdateLog[a.identifier] ?? .distantPast
                        if now.timeIntervalSince(last) > 1.0 {
                            lastPlaneUpdateLog[a.identifier] = now
                            logger.log(.planeUpdated,
                                       "plane \(plane.identifier.uuidString.prefix(6)) " +
                                       "ext=\(String(format: "%.2f×%.2f", plane.planeExtent.width, plane.planeExtent.height))m",
                                       payload: [
                                           "id": plane.identifier.uuidString,
                                           "width": String(format: "%.3f", plane.planeExtent.width),
                                           "height": String(format: "%.3f", plane.planeExtent.height),
                                       ])
                        }
                    } else if let meshAnchor = a as? ARMeshAnchor {
                        if meshManager.updateAnchor(meshAnchor) {
                            meshDirty = true
                        }
                        let last = lastMeshUpdateLog[meshAnchor.identifier] ?? .distantPast
                        if now.timeIntervalSince(last) > 2.0 {
                            lastMeshUpdateLog[meshAnchor.identifier] = now
                            logger.log(.meshUpdated,
                                       "mesh \(meshAnchor.identifier.uuidString.prefix(6)) faces=\(meshAnchor.geometry.faces.count)",
                                       payload: [
                                           "id": meshAnchor.identifier.uuidString,
                                           "face_count": "\(meshAnchor.geometry.faces.count)",
                                       ])
                        }
                    }
                }
                if meshDirty { rebuildMeshOverlay() }
                emitMeshStatsIfDue()
            }
        }

        nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
            MainActor.assumeIsolated {
                var removed = 0
                var meshDirty = false
                for a in anchors {
                    if detectedPlanes.remove(a.identifier) != nil {
                        removed += 1
                        removePlaneOverlay(id: a.identifier)
                        lastPlaneUpdateLog.removeValue(forKey: a.identifier)
                        logger.log(.planeRemoved,
                                   "plane \(a.identifier.uuidString.prefix(6))")
                    } else if a is ARMeshAnchor {
                        if meshManager.removeAnchor(a.identifier) {
                            meshDirty = true
                            lastMeshUpdateLog.removeValue(forKey: a.identifier)
                            logger.log(.meshRemoved,
                                       "mesh \(a.identifier.uuidString.prefix(6))")
                        }
                    }
                }
                if meshDirty { rebuildMeshOverlay() }
                if removed > 0 { _planeCount.wrappedValue = detectedPlanes.count }
            }
        }

        /// Emit a `meshStats` event at most once every 5 s. Called
        /// from didAdd / didUpdate so we always get a stats sample
        /// soon after a mesh change without scheduling a timer.
        private func emitMeshStatsIfDue() {
            let now = Date()
            guard now.timeIntervalSince(lastMeshStatsAt) > 5.0 else { return }
            // Skip emission if mesh hasn't been touched at all this
            // session (non-LiDAR phones never get any meshAnchors).
            guard meshManager.anchorCount > 0 || lidarActive else { return }
            lastMeshStatsAt = now
            logger.log(.meshStats,
                       "mesh stats — floor=\(String(format: "%.2f", meshManager.floorAreaM2)) m² triangles=\(meshManager.floorTriangleCount)",
                       payload: meshManager.currentStats(lidarActive: lidarActive))
        }

        /// Rebuild the single green floor-overlay entity from the
        /// mesh manager's current floor-triangle list. Called only
        /// when the triangle count actually changed (not on every
        /// throttled didUpdate tick).
        private func rebuildMeshOverlay() {
            guard let arView else { return }
            guard let resource = meshManager.buildFloorMesh() else {
                // No floor triangles yet — leave any existing
                // overlay in place (better to keep stale than to
                // flicker an empty state).
                return
            }
            // Translucent green, UnlitMaterial so the colour stays
            // green regardless of ARKit lighting. Same material
            // recipe the rim/wall use, but green with 35% alpha.
            let overlayColor = UIColor(red: 0.20, green: 0.95,
                                        blue: 0.40, alpha: 0.35)
            var material = UnlitMaterial(color: overlayColor)
            material.blending = .transparent(opacity: .init(floatLiteral: 0.35))

            if let entity = meshOverlayEntity {
                entity.model?.mesh = resource
                entity.model?.materials = [material]
            } else {
                let entity = ModelEntity(mesh: resource, materials: [material])
                let anchor = AnchorEntity(world: .zero)
                anchor.addChild(entity)
                arView.scene.addAnchor(anchor)
                meshOverlayAnchor = anchor
                meshOverlayEntity = entity
            }
        }

        // MARK: Translucent plane visualization

        /// Create or refresh a translucent green rectangle aligned with
        /// the detected plane. Caches one ModelEntity per plane and
        /// only rebuilds the mesh when extent changes by more than 5 cm
        /// (M7 fix — was reallocating mesh+material+entity at 10 Hz per
        /// plane). Also applies `planeExtent.rotationOnYAxis` so the
        /// rectangle stays aligned with the oriented bounding box once
        /// ARKit refines a non-axis-aligned plane (H3 fix).
        private func addOrUpdatePlaneOverlay(_ plane: ARPlaneAnchor) {
            guard let arView else { return }
            let width = plane.planeExtent.width
            let depth = plane.planeExtent.height  // ARKit calls Z-extent "height"
            // Drop malformed / sub-epsilon extents — ARKit briefly emits
            // these while initialising and generatePlane crashes on
            // non-finite or zero/negative inputs (L26).
            guard width.isFinite, depth.isFinite, width > 0.01, depth > 0.01 else { return }

            // B40 gating — Gemini's CAC00F review flagged 2 extra small
            // planes (7BD084 = 0.39 m², 809333 = 0.30 m²) as visual
            // distractions next to the primary floor plane (20.88 m²).
            // Only show overlay for planes that are:
            //   - horizontal (vertical planes can't be putted on)
            //   - area >= 1.0 m² (filters table-top sized noise)
            //   - not explicitly classified as wall/ceiling/door/window
            // ARKit detection itself continues for all planes — this
            // only affects the visible green overlay. Raycasts still
            // hit any plane regardless. Log classification once per
            // plane so we can review filter decisions in the JSON.
            let area = width * depth
            let classification = plane.classification
            if !loggedClassifications.contains(plane.identifier) {
                loggedClassifications.insert(plane.identifier)
                logger.log(.planeClassification,
                           "plane \(plane.identifier.uuidString.prefix(6)) class=\(classification)",
                           payload: [
                               "id": plane.identifier.uuidString,
                               "classification": "\(classification)",
                               "area_m2": String(format: "%.3f", area),
                               "alignment": plane.alignment == .horizontal ? "horizontal" : "vertical",
                           ])
            }
            let rejected: Bool = {
                if plane.alignment != .horizontal { return true }
                if area < 1.0 { return true }
                switch classification {
                case .wall, .ceiling, .door, .window: return true
                default: return false
                }
            }()
            if rejected {
                // Remove any pre-existing overlay for this plane if it
                // previously qualified and now doesn't (rare — a plane
                // can be reclassified by ARKit as more data accrues).
                if planeOverlays[plane.identifier] != nil {
                    removePlaneOverlay(id: plane.identifier)
                }
                return
            }

            let rotation = simd_quatf(angle: plane.planeExtent.rotationOnYAxis,
                                       axis: SIMD3<Float>(0, 1, 0))
            let translation = SIMD3<Float>(plane.center.x, 0, plane.center.z)
            let localTransform = Transform(scale: .one, rotation: rotation, translation: translation)

            if var existing = planeOverlays[plane.identifier] {
                // Update local transform every tick — extent rotation
                // and center may shift as ARKit refines.
                existing.model.transform = localTransform
                existing.anchor.transform = Transform(matrix: plane.transform)
                // Only rebuild mesh when extent changes meaningfully.
                let dW = abs(existing.lastWidth - width)
                let dD = abs(existing.lastDepth - depth)
                if dW > 0.05 || dD > 0.05 {
                    existing.model.model = ModelComponent(
                        mesh: MeshResource.generatePlane(width: width, depth: depth),
                        materials: [Self.overlayMaterial]
                    )
                    existing.lastWidth = width
                    existing.lastDepth = depth
                }
                planeOverlays[plane.identifier] = existing
            } else {
                let mesh = MeshResource.generatePlane(width: width, depth: depth)
                let model = ModelEntity(mesh: mesh, materials: [Self.overlayMaterial])
                model.transform = localTransform
                let anchor = AnchorEntity(world: plane.transform)
                anchor.addChild(model)
                arView.scene.addAnchor(anchor)
                planeOverlays[plane.identifier] = PlaneOverlay(
                    anchor: anchor, model: model,
                    lastWidth: width, lastDepth: depth
                )
            }
        }

        /// Shared translucent material for every plane overlay. Stored
        /// statically so we don't allocate a fresh `SimpleMaterial` on
        /// each plane add/update.
        private static let overlayMaterial: SimpleMaterial = SimpleMaterial(
            color: UIColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 0.25),
            roughness: 0.5, isMetallic: false
        )

        private func removePlaneOverlay(id: UUID) {
            planeOverlays[id]?.anchor.removeFromParent()
            planeOverlays.removeValue(forKey: id)
        }

        /// Called from `dismantleUIView` so we don't leak overlays after
        /// the cover is dismissed (the ARView itself is released, but
        /// explicit cleanup is cheap insurance). B41: also tears
        /// down the LiDAR mesh overlay.
        func clearAllPlaneOverlays() {
            for (_, overlay) in planeOverlays {
                overlay.anchor.removeFromParent()
            }
            planeOverlays.removeAll()
            lastPlaneUpdateLog.removeAll()
            meshOverlayAnchor?.removeFromParent()
            meshOverlayAnchor = nil
            meshOverlayEntity = nil
            meshManager.clear()
            lastMeshUpdateLog.removeAll()
        }

        nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
            // Friendly handling for the common case: user denied camera
            // permission on first launch. ARError code 103 =
            // .cameraUnauthorized. Anything else surfaces the raw error.
            //
            // NOTE: for any user-facing AR flow (Slice 3+), upgrade this
            // to a modal alert with a UIApplication.openSettingsURLString
            // button (M11 in the audit). Acceptable for DEBUG-only.
            let nsErr = error as NSError
            let message: String
            if nsErr.domain == ARError.errorDomain,
               nsErr.code == ARError.Code.cameraUnauthorized.rawValue {
                message = "Camera denied. Settings → PuttingLab → Camera."
            } else {
                message = "Failed: \(nsErr.localizedDescription)"
            }
            MainActor.assumeIsolated {
                logger.log(.failed, message,
                           payload: ["domain": nsErr.domain, "code": "\(nsErr.code)"])
                _trackingState.wrappedValue = message
            }
        }

        nonisolated func sessionWasInterrupted(_ session: ARSession) {
            MainActor.assumeIsolated {
                // Backgrounding mid-AR (incoming call, app switcher)
                // fires this. Surface to the HUD so the user sees the
                // freeze isn't a bug.
                logger.log(.interruption, "session interrupted")
                _trackingState.wrappedValue = "Interrupted"
            }
        }

        nonisolated func sessionInterruptionEnded(_ session: ARSession) {
            MainActor.assumeIsolated {
                // ARKit will try to relocalise — but the cached world
                // coordinates we used for AnchorEntity(world:) may now
                // point at a stale location. Push the recovery decision
                // up to the parent View (H5 fix) which will clear any
                // placed entities, reset state, and surface a hint.
                logger.log(.interruptionEnded, "session resumed")
                _trackingState.wrappedValue = "Resuming…"
                onResetAfterInterruption()
            }
        }

        // MARK: Tap → raycast → place

        @objc nonisolated func handleTap(_ recognizer: UITapGestureRecognizer) {
            MainActor.assumeIsolated {
                guard let arView, let scene else { return }

                // Real timestamp-based debounce (H6). UITapGestureRecognizer
                // dispatches on the main thread, so handleTap is serial;
                // the previous `isProcessingTap` defer pattern was dead
                // code for the rapid double-tap case. 300 ms is a snug
                // gate — fast enough for deliberate retries, slow enough
                // to swallow the iOS reflex double-tap that otherwise
                // placed ball + hole in the same spot.
                if let last = lastPlacementAt, Date().timeIntervalSince(last) < 0.3 {
                    logger.log(.note, "tap ignored — debounce <300ms")
                    return
                }

                let point = recognizer.location(in: arView)
                logger.log(.tap, "screen \(String(format: "(%.0f, %.0f)", point.x, point.y))")

                // B41: prefer LiDAR mesh, then plane geometry, then
                // estimated plane. Same priority chain as the
                // crosshair raycast so tap-to-place and Place-button
                // give identical results.
                let tapTargets: [ARRaycastQuery.Target] = [
                    .existingMeshGeometry,
                    .existingPlaneGeometry,
                    .estimatedPlane,
                ]
                var raycastResult: ARRaycastResult?
                for target in tapTargets {
                    if let query = arView.makeRaycastQuery(
                            from: point,
                            allowing: target,
                            alignment: .horizontal),
                       let r = arView.session.raycast(query).first {
                        raycastResult = r
                        break
                    }
                }
                guard let result = raycastResult else {
                    logger.log(.raycastMiss, "no horizontal surface under tap")
                    // Route the rejected-tap feedback to the parent
                    // view's transientHint overlay (C2). The previous
                    // path wrote to trackingState directly and was
                    // overwritten ~100 ms later by didUpdate(frame:).
                    onTransientHint("Aim at the floor")
                    return
                }

                let t = result.worldTransform
                let world = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
                logger.log(.raycastHit, "hit \(ARLogFmt.vec(world))",
                           payload: ["x": String(format: "%.4f", world.x),
                                     "y": String(format: "%.4f", world.y),
                                     "z": String(format: "%.4f", world.z)])

                switch placementState {
                case .waitingForPlane:
                    logger.log(.note, "tap ignored — no plane yet")
                case .readyToPlaceBall:
                    scene.placeBall(at: world)
                    logger.log(.ballPlaced, "ball \(ARLogFmt.vec(world))",
                               payload: ["x": String(format: "%.4f", world.x),
                                         "y": String(format: "%.4f", world.y),
                                         "z": String(format: "%.4f", world.z)])
                    _placementState.wrappedValue = .readyToPlaceHole(world)
                    lastPlacementAt = Date()
                case .readyToPlaceHole(let ballWorld):
                    scene.placeHole(at: world)
                    let dist = simd_distance(ballWorld, world)
                    logger.log(.holePlaced, "hole \(ARLogFmt.vec(world)) · \(ARLogFmt.meters(dist))",
                               payload: ["x": String(format: "%.4f", world.x),
                                         "y": String(format: "%.4f", world.y),
                                         "z": String(format: "%.4f", world.z),
                                         "distance_m": String(format: "%.4f", dist)])
                    _placementState.wrappedValue = .complete(ball: ballWorld, hole: world)
                    lastPlacementAt = Date()
                case .complete:
                    logger.log(.note, "tap ignored — placement complete")
                }
            }
        }

        // MARK: Helpers

        private static func formatTrackingState(_ state: ARCamera.TrackingState) -> String {
            switch state {
            case .normal: return "Normal"
            case .limited(let reason): return "Limited (\(reasonString(reason)))"
            case .notAvailable: return "Unavailable"
            @unknown default: return "Unknown"
            }
        }

        private static func reasonString(_ reason: ARCamera.TrackingState.Reason) -> String {
            switch reason {
            case .initializing: return "initializing"
            case .relocalizing: return "relocalizing"
            case .excessiveMotion: return "moving too fast"
            case .insufficientFeatures: return "low features"
            @unknown default: return "unknown reason"
            }
        }
    }
}
