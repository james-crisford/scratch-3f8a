import SwiftUI
import ARKit
import RealityKit
import simd

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
    /// Drives the export Share Sheet over the full ARSessionLogs JSON
    /// set so James can AirDrop / Mail / Files-out everything in one tap.
    @State private var showShareSheet: Bool = false
    /// URLs handed to the Share Sheet — populated asynchronously from
    /// a background scan so the main thread doesn't block on the
    /// filesystem walk (Gemini B21 finding #2).
    @State private var shareSheetURLs: [URL] = []
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
                hud
                if showStillnessHint && planeCount == 0 {
                    stillnessHint
                }
                groundTruthMarkerRow
                eventLog
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
        HStack {
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
            Text("AR place · Slice 2")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
                .accessibilityIdentifier("ar.titleBadge")
        }
        .padding(.top, 12)
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
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("LIVE EVENTS  (last \(min(5, logger.events.count)) of \(logger.events.count))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
                Button {
                    toggleRecording()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isRecording ? "stop.circle.fill" : "record.circle")
                        Text(isRecording ? "Stop" : "Record")
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
                    // Log first, THEN snapshot — otherwise the saved JSON
                    // doesn't contain the very note it's supposed to tag
                    // (L16 in the audit).
                    logger.log(.note, "Snapshot saved manually")
                    logger.saveSnapshot()
                } label: {
                    Text("Save")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.6), in: Capsule())
                }
                .accessibilityIdentifier("ar.saveButton")
                Button {
                    // Flush the current session FIRST so the share
                    // sheet pickup includes everything up to right now.
                    // Both saveSnapshot + collect happen off-main; we
                    // await the save so the just-written JSON is on
                    // disk before the directory scan runs.
                    logger.log(.note, "Export triggered")
                    Task {
                        await logger.saveSnapshotAndWait()
                        shareSheetURLs = await ARLogExport.collectAllLogURLs()
                        showShareSheet = true
                    }
                } label: {
                    Text("Export all")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.75), in: Capsule())
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
    func placeBall(at worldPosition: SIMD3<Float>) {
        guard let arView else { return }
        ballAnchor?.removeFromParent()

        let radius = Self.ballDiameter / 2
        let mesh = MeshResource.generateSphere(radius: radius)
        let material = SimpleMaterial(color: .white, roughness: 0.4, isMetallic: false)
        let model = ModelEntity(mesh: mesh, materials: [material])
        // Lift the sphere by its radius so it sits ON the plane, not into it.
        model.position = SIMD3<Float>(0, radius, 0)

        let anchor = AnchorEntity(world: worldPosition)
        anchor.addChild(model)
        arView.scene.addAnchor(anchor)
        ballAnchor = anchor
        ballWorldPosition = worldPosition  // cache for the aim-line draw
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

        let dia = Self.holeDiameter
        let depth = Self.holeDepth
        let mesh = MeshResource.generateBox(width: dia,
                                             height: depth,
                                             depth: dia,
                                             cornerRadius: dia / 2)
        // Near-black, low specular reflection so it visually "absorbs"
        // light the way the inside of a real cup does. Slightly above
        // pure black so the well isn't a void on bright floors.
        let material = SimpleMaterial(
            color: UIColor(white: 0.04, alpha: 1.0),
            roughness: 0.95,
            isMetallic: false
        )
        let model = ModelEntity(mesh: mesh, materials: [material])
        // The box's local origin is its centre. To put the TOP face at
        // the plane (anchor) level, shift the model DOWN by half the
        // box height. The result: body extends from y=−depth up to y=0
        // in anchor-local frame, i.e. fully embedded in the floor with
        // its rim flush at the detected plane.
        model.position = SIMD3<Float>(0, -depth / 2, 0)

        let anchor = AnchorEntity(world: worldPosition)
        anchor.addChild(model)
        arView.scene.addAnchor(anchor)
        holeAnchor = anchor

        if let ballWorldPosition {
            drawAimLine(from: ballWorldPosition, to: worldPosition)
        }
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
        guard let query = arView.makeRaycastQuery(
                from: center,
                allowing: .existingPlaneGeometry,
                alignment: .horizontal
              ),
              let result = arView.session.raycast(query).first else {
            return nil
        }
        let t = result.worldTransform
        return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
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
                for a in anchors {
                    guard let plane = a as? ARPlaneAnchor else { continue }
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
                }
                guard added > 0 else { return }
                _planeCount.wrappedValue = detectedPlanes.count
            }
        }

        nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            MainActor.assumeIsolated {
                let now = Date()
                for a in anchors {
                    guard let plane = a as? ARPlaneAnchor,
                          detectedPlanes.contains(a.identifier) else { continue }
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
                }
            }
        }

        nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
            MainActor.assumeIsolated {
                var removed = 0
                for a in anchors {
                    if detectedPlanes.remove(a.identifier) != nil {
                        removed += 1
                        removePlaneOverlay(id: a.identifier)
                        lastPlaneUpdateLog.removeValue(forKey: a.identifier)
                        logger.log(.planeRemoved,
                                   "plane \(a.identifier.uuidString.prefix(6))")
                    }
                }
                guard removed > 0 else { return }
                _planeCount.wrappedValue = detectedPlanes.count
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
        /// explicit cleanup is cheap insurance).
        func clearAllPlaneOverlays() {
            for (_, overlay) in planeOverlays {
                overlay.anchor.removeFromParent()
            }
            planeOverlays.removeAll()
            lastPlaneUpdateLog.removeAll()
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

                // Raycast against existing detected horizontal planes only.
                // `.existingPlaneGeometry` ensures we hit a confirmed plane,
                // not an estimated one — important during verification.
                guard let query = arView.makeRaycastQuery(
                    from: point,
                    allowing: .existingPlaneGeometry,
                    alignment: .horizontal
                ),
                let result = arView.session.raycast(query).first
                else {
                    logger.log(.raycastMiss, "no horizontal plane under tap")
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
