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
        // B42: Move-ball / Move-hole UX. User has placed both
        // entities and wants to nudge ONE without wiping the
        // other. We preserve the kept entity's world coord in
        // the associated value so the place action can rebuild
        // the .complete tuple cleanly.
        case replacingBall(hole: SIMD3<Float>)
        case replacingHole(ball: SIMD3<Float>)
        // B52 — the four address-flow states (.calibratingAddress,
        // .addressReady, .readyForStroke, .strokeInProgress) were
        // removed in B52. The press-and-unpress gesture replaces
        // them: press snapshots the address pose inline + arms
        // StrokeCapture; UI stays at .complete with @State
        // pressActive tracking the press; the stroke detection
        // window opens on press and closes on swing peak.
        case rolling(ball: SIMD3<Float>,
                     hole: SIMD3<Float>,
                     pose: AddressPose,
                     impact: ImpactResult)
        // Stage 3 Slice 3.4 / B49 — ball has come to rest.
        // outcome + duration retained for the result panel.
        case rolled(ball: SIMD3<Float>,
                    hole: SIMD3<Float>,
                    pose: AddressPose,
                    impact: ImpactResult,
                    outcome: BallPhysics.Outcome,
                    durationS: Double)
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
    /// B42: live LiDAR mesh stats string for the expanded HUD row.
    /// Refreshed by the 0.5 s tick from `scene.meshSummary()`. Reads
    /// "—" on non-LiDAR devices.
    @State private var lidarHUD: String = "—"
    /// B42: drives the crosshair shrink + fade when the raycast is
    /// confidently hitting a surface, so the cup isn't obscured at
    /// close range. Polled at 0.5 Hz from the same tick.
    @State private var raycastConfident: Bool = false
    /// B42: tag of the currently-pulsing GT marker button (one at
    /// a time is enough — taps are serial). Cleared 500 ms after
    /// it's set via a Task.sleep. SwiftUI's `.animation(value:)`
    /// interpolates the background between green ↔ default on
    /// every change.
    @State private var activeMarkerPulse: String? = nil
    /// B45 — once-per-session flag so the "scan more of the floor"
    /// transient hint doesn't re-fire every 0.5 s tick.
    @State private var scanMoreHintShown: Bool = false
    /// B48 Slice 3.3 — stroke capture runner. Recreated on each
    /// `armStrokeCapture` so the IMU stream + StrokeDetector
    /// reset cleanly between strokes.
    @State private var strokeCapture: StrokeCapture? = nil
    /// B52 — tracks whether the StrokeDetector has fired its
    /// onStarted callback yet for the current press. Used by
    /// handlePressEnded to distinguish "user pressed but never
    /// swung" (cancel) from "user pressed and swung" (let detector
    /// close naturally).
    @State private var strokeInFlight: Bool = false
    /// B53 — result chip visibility. False during the 500ms quiet
    /// window after .rolled so the user gets an unobstructed AR
    /// view of where the ball ended up, then fades in.
    @State private var resultChipVisible: Bool = false
    /// B53 — true when the user has tapped the chip to expand the
    /// full StrokeResultPanel. The slide-up panel is now opt-in
    /// rather than automatic (it covered too much of the AR scene
    /// per James's 2026-06-03 feedback + the roleplay walkthrough).
    @State private var resultPanelExpanded: Bool = false
    /// B49 Slice 3.4 — putt-roll animator. Holds the 60 Hz tick
    /// task that drives the ball entity along the
    /// `BallPhysics.simulatePutt` trajectory.
    @State private var ballRollAnimator: BallRollAnimator? = nil

    /// B51 — press-and-unpress gesture state. True from the
    /// instant the user presses on the AR view at `.complete`
    /// until they release. Used by the gesture overlay to avoid
    /// re-firing handlePressBegan on every DragGesture .onChanged
    /// event (a single press emits many onChanged calls).
    @State private var pressActive: Bool = false

    /// B50 Slice 3.5 — Mario Kart bucketer. Stateless, reused
    /// across strokes. `Sendable` per the type declaration.
    private static let marioKart = MarioKartAssist()

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

            // B51 — press-and-unpress gesture catcher. Sits
            // immediately above the AR scene but below all UI
            // chrome (HUD / buttons / event log) so the chrome
            // still receives its own taps. Active only at
            // .complete — the user presses anywhere on the AR
            // view to lock the address pose and arm StrokeCapture,
            // then releases when their swing is done. Buttons
            // higher up in the ZStack still steal taps that hit
            // their hit-test regions; this only catches presses
            // on the empty AR area where the user actually grips.
            if case .complete(let ball, let hole) = placementState {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in handlePressBegan(ball: ball, hole: hole) }
                            .onEnded { _ in handlePressEnded(ball: ball, hole: hole) }
                    )
                    .accessibilityIdentifier("ar.pressGesture")
            }

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
            // B42: spring animation on placementState changes so the
            // HUD / button rows slide rather than snap when entering
            // the Move-ball / Move-hole flow + when completing
            // placement.
            .animation(.spring(response: 0.4, dampingFraction: 0.85),
                        value: placementState)

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

            // B53 — result UX overhaul per the 2026-06-03 roleplay.
            // The B50 full slide-up panel covered ~half the screen
            // exactly when the user wanted to look at where the ball
            // ended up. Replaced with:
            //   1. 500ms quiet window after .rolled fires — nothing
            //      covering the AR view. The visual IS the data.
            //   2. Top-anchored result chip fades in at 500ms with
            //      bucket-led copy: "Drained · Square · 1.48m".
            //   3. Bottom-right Putt again capsule for the loop.
            //   4. Tap chip → full StrokeResultPanel slides up
            //      (B50 design retained, now opt-in).
            //   5. Auto-dismiss chip → .complete after 10s of idle.
            if case .rolled(let ball, let hole, let pose, let impact,
                             let outcome, let duration) = placementState {
                // Top chip (bucket + distance + face). Hidden during
                // the 500ms quiet window; fades in after.
                if resultChipVisible {
                    VStack {
                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                resultPanelExpanded = true
                            }
                        } label: {
                            resultChip(impact: impact, outcome: outcome)
                        }
                        .accessibilityIdentifier("ar.resultChip")
                        Spacer()
                    }
                    .padding(.top, 8)
                    .transition(.opacity)
                }

                // Bottom-right Putt again button. Always visible while
                // .rolled — one tap loops back to .complete.
                if resultChipVisible {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button {
                                if let ballEntity = scene.ballModelEntity() {
                                    ballEntity.position = SIMD3<Float>(0, 0.0427/2, 0)
                                }
                                scene.clearRollTrail()
                                resultChipVisible = false
                                resultPanelExpanded = false
                                placementState = .complete(ball: ball, hole: hole)
                                _ = pose
                            } label: {
                                Label("Putt again", systemImage: "figure.golf")
                                    .font(.callout.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(.green.opacity(0.95), in: Capsule())
                                    .foregroundStyle(.white)
                            }
                            .accessibilityIdentifier("ar.puttAgainButton")
                        }
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 32)
                    .transition(.opacity)
                }

                // Opt-in full result panel (B50 design, only shown
                // when user taps the chip).
                if resultPanelExpanded {
                    VStack {
                        Spacer()
                        StrokeResultPanel(
                            viewModel: makeStrokeResultVM(ball: ball, hole: hole,
                                                           impact: impact,
                                                           outcome: outcome,
                                                           duration: duration),
                            onPuttAgain: {
                                if let ballEntity = scene.ballModelEntity() {
                                    ballEntity.position = SIMD3<Float>(0, 0.0427/2, 0)
                                }
                                scene.clearRollTrail()
                                resultChipVisible = false
                                resultPanelExpanded = false
                                placementState = .complete(ball: ball, hole: hole)
                                _ = pose
                            },
                            onResetAll: { reset() },
                            onDismiss: {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    resultPanelExpanded = false
                                }
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
        .statusBarHidden()
        .onChange(of: placementState) { _, newValue in
            // B53 — 500ms quiet window after .rolled before the
            // result chip fades in. Lets the user look at where the
            // ball ended up unobstructed.
            if case .rolled = newValue {
                resultChipVisible = false
                resultPanelExpanded = false
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if case .rolled = placementState {
                        withAnimation(.easeIn(duration: 0.25)) {
                            resultChipVisible = true
                        }
                    }
                }
            } else {
                resultChipVisible = false
                resultPanelExpanded = false
            }
        }
        .onChange(of: planeCount) { _, newValue in
            // Auto-advance "waitingForPlane" → "readyToPlaceBall" once any
            // horizontal surface is found.
            //
            // B42: surface = plane OR LiDAR mesh anchor. On LiDAR
            // devices a mesh anchor may exist before any plane is
            // surfaced.
            let hasSurface = newValue > 0 || scene.meshAnchorCount() > 0
            if hasSurface, case .waitingForPlane = placementState {
                placementState = .readyToPlaceBall
            }
            if hasSurface {
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
                    // B42: auto-compact HUD when we're recording for
                    // Gemini review. Every session is recorded since
                    // B25 auto-recording, so the camera feed +
                    // crosshair + AR entities own the frame by
                    // default. User can flip back via the eye icon.
                    hudCompact = true
                    logger.log(.note, "auto-compact HUD on (recording active)",
                               payload: ["hud_compact": "true",
                                         "trigger": "auto_record_start"])
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
                    // B42: ReplayKit's completion handler is @Sendable
                    // and its dispatch queue isn't guaranteed to be
                    // main, so hop explicitly. Mirrors the pattern at
                    // `showTransientHint` (L291).
                    Task { @MainActor in
                        if let url {
                            logger.log(.note, "Recording auto-stopped on dismiss: \(url.lastPathComponent)")
                        }
                        logger.saveSnapshot()
                    }
                }
            }
            logger.log(.sessionEnd, "Slice 2 placement view dismissed")
            logger.saveSnapshot()
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            // 0.5 s tick — drives both the silent-wait hint AND the
            // live LiDAR HUD row + adaptive crosshair fade.
            //
            // B42: stillness hint must consider LiDAR mesh anchors, not
            // just ARPlaneAnchors. On iPhone 13 Pro Max, the LiDAR
            // mesh can populate without any planes being detected
            // (LiDAR's first; planes are a derived layer). Previous
            // gate falsely fired "Try slowly panning" even though the
            // mesh was clearly working.
            let hasSurface = planeCount > 0 || scene.meshAnchorCount() > 0
            if !hasSurface, let firstStillAt {
                if !showStillnessHint && Date().timeIntervalSince(firstStillAt) > 2.0 {
                    showStillnessHint = true
                }
            } else if showStillnessHint {
                showStillnessHint = false
            }
            // Live mesh HUD row + crosshair adaptive opacity.
            lidarHUD = scene.meshSummary()
            raycastConfident = scene.raycastScreenCenter() != nil

            // B45 — "scan more of the floor" hint. After 5s, if LiDAR
            // is active but we still have < 2 m² of floor mapped,
            // surface a transient suggesting the user keep panning.
            // Suppressed if the user already has a placement in
            // progress (don't interrupt mid-flow).
            if let firstStillAt,
               Date().timeIntervalSince(firstStillAt) > 5.0,
               !scanMoreHintShown,
               scene.meshAnchorCount() > 0,
               scene.lidarFloorAreaM2() > 0,
               scene.lidarFloorAreaM2() < 2.0,
               case .waitingForPlane = placementState {
                scanMoreHintShown = true
                showTransientHint("Slowly pan around — more floor → better tracking")
                logger.log(.note,
                           "B45 scan-more hint shown",
                           payload: ["floor_area_m2": String(format: "%.2f", scene.lidarFloorAreaM2())])
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
                // B42: hop to MainActor before touching @State + logger.
                // The continuation must resume exactly once — calling
                // it inside the Task is safe because the Task body
                // runs to completion serially before the next
                // dispatch step.
                Task { @MainActor in
                    isRecording = false
                    if let url {
                        logger.log(.note, "Recording stopped for send: \(url.lastPathComponent)")
                    }
                    cont.resume(returning: url)
                }
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
            logger.log(.recordingStateChanged, "Recording stop requested",
                       payload: ["state": "stop_requested"])
            recorder.stop { url in
                // B42: MainActor hop + replace twin `.note` events with
                // a single structured `.recordingStateChanged` event
                // (Event.Kind already defined in B40, never wired).
                Task { @MainActor in
                    isRecording = false
                    if let url {
                        logger.log(.recordingStateChanged, "Recording saved: \(url.lastPathComponent)",
                                   payload: ["state": "stopped",
                                             "filename": url.lastPathComponent])
                    } else {
                        logger.log(.failed, "Recording save failed: \(recorder.lastError ?? "unknown")")
                        showTransientHint("Recording failed")
                    }
                }
            }
        } else {
            logger.log(.recordingStateChanged, "Recording start requested",
                       payload: ["state": "start_requested"])
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
        case .readyToPlaceHole, .complete, .replacingBall, .replacingHole,
             .rolling, .rolled:
            hadPlacedEntities = true
        case .waitingForPlane, .readyToPlaceBall:
            hadPlacedEntities = false
        }
        guard hadPlacedEntities else { return }
        scene.clearPlacedEntities()
        let hasSurface = planeCount > 0 || scene.meshAnchorCount() > 0
        placementState = hasSurface ? .readyToPlaceBall : .waitingForPlane
        showTransientHint("Tracking recovered — place again")
        logger.log(.reset, "auto-reset after interruption recovery")
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            // B42: Done button uses native iOS chevron + "Done" label,
            // consistent 38pt capsule chrome (was mixed heights).
            Button { dismiss() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text("Done")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(.black.opacity(0.55), in: Capsule())
            }
            .accessibilityIdentifier("ar.doneButton")
            Spacer()
            // B42: HUD toggle — swapped the misleading eye/eye.slash
            // glyph (read as "hide content" not "hide chrome") for
            // rectangle.dashed / rectangle, which reads as "wireframe
            // layer on/off". Also gets a tiny pulse animation when
            // tapped so the state change is visually confirmed.
            Button {
                let was = hudCompact
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    hudCompact.toggle()
                }
                logger.log(.note, was ? "HUD expanded" : "HUD collapsed (compact view)",
                            payload: ["hud_compact": String(!was)])
            } label: {
                Image(systemName: hudCompact ? "rectangle.dashed" : "rectangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .accessibilityIdentifier("ar.hudCompactToggle")
            // B42: title badge — quieter caption2 weight, version stamp
            // visible at a glance so any future Gemini frame can be
            // tied back to the exact build that produced it.
            Text(hudCompact ? "v0.4.8" : "PuttingLab · v0.4.8")
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12)
                .frame(height: 38)
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
                    // B42: recording dot pulses at 1 Hz for "this is
                    // live" affordance. SF Symbol effect handles the
                    // animation without timer state.
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, options: .repeating)
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
            // B42: live LiDAR mesh stats. "—" when LiDAR is inactive
            // or no mesh anchors yet (non-Pro devices, first second
            // of cold start). Updates every 0.5 s from the .onReceive
            // timer.
            row("LiDAR", lidarHUD, tint: lidarHUD == "—" ? .white.opacity(0.5) : .green)
            if case let .complete(ball, hole) = placementState {
                let d = simd_distance(ball, hole)
                // B42: distance gets a larger headline weight + colour-
                // coded bucket so the metric reads at a glance, and a
                // one-word judgement label ("short" / "lag" / "long")
                // makes the number actionable instead of abstract.
                HStack {
                    Text("DISTANCE")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 80, alignment: .leading)
                    Text(String(format: "%.2f m", d))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Self.distanceTint(d))
                    Text("· \(Self.distanceWord(d))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Self.distanceTint(d).opacity(0.85))
                    Spacer()
                    Text(String(format: "%.1f ft", d * 3.281))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.55))
                }
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

    /// B42 distance bucket → tint. 0.5-3 m = drainable putts (green),
    /// 3-6 m = lag putts (orange), 6 m+ = long / unusual (red).
    private static func distanceTint(_ d: Float) -> Color {
        switch d {
        case ..<3.0:  return .green
        case ..<6.0:  return .orange
        default:      return .red
        }
    }

    /// B42 distance bucket → one-word judgement label.
    private static func distanceWord(_ d: Float) -> String {
        switch d {
        case ..<3.0:  return "short"
        case ..<6.0:  return "lag"
        default:      return "long"
        }
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
        // B42: shrink + fade the crosshair when the raycast is
        // confidently hitting a surface — at that point the user
        // doesn't need a big ring to know "you'll hit something".
        // Keeps the cup visible underneath at close range. Smooth
        // spring transition. Falls back to the 56pt / 0.95 opacity
        // search state when the raycast is missing.
        let confident = raycastConfident && (placementState != .waitingForPlane)
        let size: CGFloat = confident ? 32 : 56
        let opacity = confident ? min(0.45, crosshairOpacity) : crosshairOpacity
        return ZStack {
            Circle()
                .stroke(.white, lineWidth: confident ? 1.5 : 2)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.6), radius: 2)
            Image(systemName: "plus")
                .font(.system(size: confident ? 14 : 22, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2)
        }
        .opacity(opacity)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: confident)
        .accessibilityIdentifier("ar.crosshair")
    }

    /// Dim the crosshair after placement is complete so it doesn't
    /// distract from the result; hide entirely if no plane yet.
    private var crosshairOpacity: Double {
        switch placementState {
        case .waitingForPlane:  return 0.25
        case .readyToPlaceBall, .readyToPlaceHole: return 0.95
        // B42: the Move-ball / Move-hole flows are placement-active
        // (user is aiming at the new spot), so full visibility.
        case .replacingBall, .replacingHole: return 0.95
        // B47/B48/B49: address + stroke + roll states — crosshair
        // isn't being used (no placement happening), dim it out.
        case .rolling, .rolled: return 0.15
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
        // B42: Move-ball / Move-hole flows mirror the first-place
        // buttons; same crosshair raycast, just resolves back into
        // .complete with the preserved entity.
        case .replacingBall:
            bigPlaceButton(label: "Re-place ball at crosshair",
                            icon: "circle.fill",
                            tint: .white,
                            id: "ar.replaceBallButton") {
                placeAtCenter()
            }
        case .replacingHole:
            bigPlaceButton(label: "Re-place hole at crosshair",
                            icon: "scope",
                            tint: .yellow,
                            id: "ar.replaceHoleButton") {
                placeAtCenter()
            }
        case .waitingForPlane, .complete, .rolling, .rolled:
            // B47/B48/B49 address + stroke + roll states don't
            // use the crosshair Place button — they're driven by
            // the explicit action row + IMU stream + physics
            // animator.
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
            // B42: error haptic — tells the user "the press registered
            // but the raycast missed" without needing eyes on the
            // toast. Existing pattern from SessionCoordinator etc.
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        // B42: solid medium impact haptic on a successful raycast hit.
        // Fires before the entity actually drops so it pairs with the
        // tap, not the visual.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
            // B46 Slice 3.1: drop foot markers at the address
            // position behind the ball — shows the user where to
            // stand for the putt.
            scene.placeAddressMarkers(ball: ballWorld, hole: world)
        // B42: Move-ball UX — preserved hole stays, new ball drops.
        case .replacingBall(let preservedHole):
            scene.placeBall(at: world)
            let dist = simd_distance(world, preservedHole)
            logger.log(.ballPlaced, "ball re-placed via crosshair \(ARLogFmt.vec(world))",
                       payload: ["source": "replace",
                                 "x": String(format: "%.4f", world.x),
                                 "y": String(format: "%.4f", world.y),
                                 "z": String(format: "%.4f", world.z),
                                 "distance_m": String(format: "%.4f", dist),
                                 "hole_x": String(format: "%.4f", preservedHole.x),
                                 "hole_y": String(format: "%.4f", preservedHole.y),
                                 "hole_z": String(format: "%.4f", preservedHole.z)])
            // B42 safety net fix: redraw the aim line via the
            // dedicated helper rather than rebuilding the entire
            // hole entity. Avoids the visible flicker + double
            // `materialApplied` event that the placeHole-replay
            // approach caused.
            scene.refreshAimLine(from: world, to: preservedHole)
            placementState = .complete(ball: world, hole: preservedHole)
            scene.placeAddressMarkers(ball: world, hole: preservedHole)
        // B42: Move-hole UX — preserved ball stays, new hole drops.
        case .replacingHole(let preservedBall):
            scene.placeHole(at: world)
            let dist = simd_distance(preservedBall, world)
            logger.log(.holePlaced, "hole re-placed via crosshair \(ARLogFmt.vec(world)) · \(ARLogFmt.meters(dist))",
                       payload: ["source": "replace",
                                 "x": String(format: "%.4f", world.x),
                                 "y": String(format: "%.4f", world.y),
                                 "z": String(format: "%.4f", world.z),
                                 "distance_m": String(format: "%.4f", dist),
                                 "ball_x": String(format: "%.4f", preservedBall.x),
                                 "ball_y": String(format: "%.4f", preservedBall.y),
                                 "ball_z": String(format: "%.4f", preservedBall.z)])
            placementState = .complete(ball: preservedBall, hole: world)
            scene.placeAddressMarkers(ball: preservedBall, hole: world)
        case .complete, .rolling, .rolled:
            // No placement action during the post-placement flows.
            break
        }
    }

    /// Ground-truth markers — quick-tap buttons that let James label
    /// what HE saw at a moment in time, so when we read the JSON back
    /// later we can correlate sensor data to actual observed events.
    /// Each tap logs a `.note` event with a `GT:` prefix.
    private var groundTruthMarkerRow: some View {
        HStack(spacing: 6) {
            markerButton(label: "👍 Good",         tag: "good",          id: "ar.markerGood") { logger.log(.note, "GT: looks good", payload: ["source": "user_marker", "tag": "good"]) }
            markerButton(label: "📐 Plane wrong",  tag: "plane_wrong",   id: "ar.markerPlaneWrong") { logger.log(.note, "GT: plane overlay wrong", payload: ["source": "user_marker", "tag": "plane_wrong"]) }
            markerButton(label: "🎯 Drifted",      tag: "drifted",       id: "ar.markerDrifted") { logger.log(.note, "GT: ball/hole drifted", payload: ["source": "user_marker", "tag": "drifted"]) }
            markerButton(label: "❌ Lost",          tag: "lost_tracking", id: "ar.markerLost") { logger.log(.note, "GT: tracking lost", payload: ["source": "user_marker", "tag": "lost_tracking"]) }
            markerButton(label: "📝 Note…",        tag: "note",          id: "ar.markerNote") { showNoteInput = true }
        }
        .padding(.top, 6)
    }

    private func markerButton(label: String, tag: String, id: String, action: @escaping () -> Void) -> some View {
        // B42: green pulse confirmation on tap. Set activeMarkerPulse
        // = tag, sleep 400 ms, clear. SwiftUI animates the
        // background colour change via `.animation(value:)`.
        Button {
            withAnimation(.easeOut(duration: 0.18)) { activeMarkerPulse = tag }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                if activeMarkerPulse == tag {
                    withAnimation(.easeIn(duration: 0.25)) { activeMarkerPulse = nil }
                }
            }
            action()
        } label: {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    (activeMarkerPulse == tag
                        ? Color(red: 0.20, green: 0.85, blue: 0.40)
                        : Color.white.opacity(0.18)),
                    in: Capsule()
                )
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
        // B42: same activeMarkerPulse-driven green flash as the full
        // HUD marker buttons, sized to the compact circle.
        Button {
            withAnimation(.easeOut(duration: 0.18)) { activeMarkerPulse = tag }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                if activeMarkerPulse == tag {
                    withAnimation(.easeIn(duration: 0.25)) { activeMarkerPulse = nil }
                }
            }
            action()
        } label: {
            Text(glyph)
                .font(.callout)
                .frame(width: 36, height: 36)
                .background(
                    (activeMarkerPulse == tag
                        ? Color(red: 0.20, green: 0.85, blue: 0.40)
                        : Color.black.opacity(0.55)),
                    in: Circle()
                )
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
        HStack(spacing: 8) {
            switch placementState {
            case .complete(let ball, let hole):
                // B42: at .complete, three capsule buttons.
                // Reset = destructive-all (wipe both).
                // Move ball / Move hole = constructive-replace-one,
                // preserves the OTHER entity's world coord.
                Button { reset() } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                }
                .accessibilityIdentifier("ar.resetButton")
                Button {
                    scene.clearBall()
                    placementState = .replacingBall(hole: hole)
                    logger.log(.note, "Move ball tapped",
                               payload: ["preserved_hole_x": String(format: "%.4f", hole.x),
                                         "preserved_hole_y": String(format: "%.4f", hole.y),
                                         "preserved_hole_z": String(format: "%.4f", hole.z)])
                } label: {
                    Label("Move ball", systemImage: "circle.dashed")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(.white.opacity(0.85), in: Capsule())
                        .foregroundStyle(.black)
                }
                .accessibilityIdentifier("ar.moveBallButton")
                Button {
                    scene.clearHole()
                    placementState = .replacingHole(ball: ball)
                    logger.log(.note, "Move hole tapped",
                               payload: ["preserved_ball_x": String(format: "%.4f", ball.x),
                                         "preserved_ball_y": String(format: "%.4f", ball.y),
                                         "preserved_ball_z": String(format: "%.4f", ball.z)])
                } label: {
                    Label("Move hole", systemImage: "scope")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(.yellow.opacity(0.95), in: Capsule())
                        .foregroundStyle(.black)
                }
                .accessibilityIdentifier("ar.moveHoleButton")
                // B52 — no "Set address" / "Ready" buttons at
                // .complete. The press-anywhere gesture (DragGesture
                // overlay on the AR view) IS the address-lock +
                // stroke-arm trigger. UI prompt at the bottom of
                // the AR view tells the user.
            case .rolling:
                // B49 — only Cancel during the roll; no replay
                // until the ball stops.
                EmptyView()
            case .rolled(let ball, let hole, let pose, let impact, _, _):
                // B49 — three buttons: Reset / Replay last putt /
                // Putt again. "Putt again" preserves ball + hole +
                // calibration (the user is still standing in the
                // same spot, just wants another swing). "Replay
                // last putt" re-runs the same simulation against
                // the same impact for visual review. Reset wipes.
                Button { reset() } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                }
                .accessibilityIdentifier("ar.resetButton")
                Button {
                    // Re-position the ball back to start and
                    // re-run the same simulation.
                    if let ballEntity = scene.ballModelEntity() {
                        ballEntity.position = SIMD3<Float>(0, 0.0427/2, 0)
                    }
                    scene.clearRollTrail()
                    startRoll(ball: ball, hole: hole, pose: pose, impact: impact)
                } label: {
                    Label("Replay last putt", systemImage: "play.circle")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(.white.opacity(0.85), in: Capsule())
                        .foregroundStyle(.black)
                }
                .accessibilityIdentifier("ar.replayLastPutt")
                Button {
                    // Re-position the ball back to start so the
                    // user can swing again.
                    if let ballEntity = scene.ballModelEntity() {
                        ballEntity.position = SIMD3<Float>(0, 0.0427/2, 0)
                    }
                    scene.clearRollTrail()
                    armStrokeCapture(ball: ball, hole: hole, pose: pose)
                } label: {
                    Label("Putt again", systemImage: "figure.golf")
                        .font(.callout.weight(.bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.green.opacity(0.95), in: Capsule())
                        .foregroundStyle(.white)
                }
                .accessibilityIdentifier("ar.puttAgain")
            case .replacingBall(let preservedHole):
                // B42: Cancel returns to .complete with the cached
                // ball/hole pair. Restore the ball entity by calling
                // placeBall at the LAST cached world coord — but we
                // don't have it; the user just tapped Move ball
                // which cleared the ball. So Cancel here means
                // "restore the ball at the same spot it was". Since
                // the View doesn't cache the previous ball coord,
                // Cancel is best-effort: we re-enter .readyToPlaceBall
                // with the hole still there, asking the user to
                // place the ball again.
                Button {
                    placementState = .readyToPlaceHole(preservedHole)
                    logger.log(.note, "Move ball cancelled — back to hole-preserved state")
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                }
                .accessibilityIdentifier("ar.cancelMoveBall")
            case .replacingHole(let preservedBall):
                Button {
                    // Cancel from replacingHole: restore the ball + go
                    // back to readyToPlaceHole so user can re-place
                    // hole. The ball entity is still on screen since
                    // clearHole() left it alone.
                    placementState = .readyToPlaceHole(preservedBall)
                    logger.log(.note, "Move hole cancelled — back to ball-preserved state")
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                }
                .accessibilityIdentifier("ar.cancelMoveHole")
            case .readyToPlaceHole:
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
            case .waitingForPlane, .readyToPlaceBall:
                EmptyView()
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
        case .complete:         return pressActive ? "Now swing" : "Press anywhere to putt"
        case .replacingBall:    return "Re-place ball"
        case .replacingHole:    return "Re-place hole"
        case .rolling:          return "Rolling…"
        case .rolled:           return "Result"
        }
    }

    /// B54 — top result chip. Per James's 2026-06-03 feedback the
    /// chip no longer shows outcome data inline. It's a simple
    /// prompt: tap to open the full StrokeResultPanel. The user has
    /// already physically observed the result via the AR scene; the
    /// chip just asks "do you want to see the stats?".
    private func resultChip(impact: ImpactResult,
                             outcome: BallPhysics.Outcome) -> some View {
        _ = impact
        _ = outcome
        return HStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("View result")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
            Image(systemName: "chevron.up")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.leading, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.black.opacity(0.78), in: Capsule())
    }

    private var instructionText: String {
        switch placementState {
        case .waitingForPlane:
            return "Slowly pan the phone — the green floor will appear"
        case .readyToPlaceBall:
            return "Tap where you'll address the ball"
        case .readyToPlaceHole:
            return "Tap where the hole goes"
        case .complete:
            return pressActive
                ? "Make your putting motion now"
                : "Press + hold the screen, swing, release"
        case .replacingBall:
            return "Aim the crosshair at the new ball spot"
        case .replacingHole:
            return "Aim the crosshair at the new hole spot"
        case .rolling:
            return "Ball rolling — watch the trail"
        case .rolled(_, _, _, _, let outcome, _):
            switch outcome {
            case .captured: return "Drained!"
            case .lipOut:   return "Lipped out"
            case .stopped:  return "Stopped — tap Putt again"
            case .rejected: return "Stroke too soft — try again"
            }
        }
    }

    private func reset() {
        logger.log(.reset, "user tapped Start over / Reset")
        cancelStrokeCapture()
        pressActive = false
        ballRollAnimator?.cancel()
        ballRollAnimator = nil
        scene.clearPlacedEntities()
        let hasSurface = planeCount > 0 || scene.meshAnchorCount() > 0
        placementState = hasSurface ? .readyToPlaceBall : .waitingForPlane
    }

    /// B52 — arm the StrokeCapture runner. Called from
    /// `handlePressBegan` (press flow). Stays at `.complete`
    /// throughout (UI tracks press via `@State pressActive`).
    /// The IMU stream + StrokeDetector run in the background;
    /// `handleStrokeStarted` / `handleStrokeCompleted` fire as
    /// the detector phase changes.
    private func armStrokeCapture(ball: SIMD3<Float>,
                                   hole: SIMD3<Float>,
                                   pose: AddressPose) {
        strokeCapture?.disarm()
        let capture = StrokeCapture()
        strokeCapture = capture
        strokeInFlight = false
        logger.log(.note, "Stroke capture armed",
                   payload: ["phone_to_ball_m": String(format: "%.4f", pose.phoneToBallM)])

        capture.arm(with: pose,
                     onStarted: {
            handleStrokeStarted(ball: ball, hole: hole, pose: pose)
        }, onCompleted: { impact, window in
            handleStrokeCompleted(ball: ball, hole: hole, pose: pose,
                                   impact: impact, window: window)
        }, onFailure: { msg in
            logger.log(.failed, "Stroke capture failed: \(msg)")
            showTransientHint("Stroke detection failed")
            cancelStrokeCapture()
            strokeInFlight = false
            placementState = .complete(ball: ball, hole: hole)
        })
    }

    /// Cancel the stroke capture. Used by Cancel button + Reset
    /// paths. Doesn't tear down the address pose.
    private func cancelStrokeCapture() {
        strokeCapture?.disarm()
        strokeCapture = nil
    }

    // MARK: - B51 press-and-unpress flow

    /// B51 — snapshot an AddressPose directly from the current
    /// AR frame + latest IMU sample. Replaces the 1.5 s stillness
    /// loop in `AddressPoseCapture` — the press itself is the
    /// deliberate stillness signal. Returns nil if the AR session
    /// has no current frame yet (extremely rare race at press
    /// instant).
    private func snapshotAddressPoseInline(ball: SIMD3<Float>) -> AddressPose? {
        guard let arView = scene.arView,
              let frame = arView.session.currentFrame else { return nil }
        let phoneTransform = frame.camera.transform
        let phonePos = SIMD3<Float>(phoneTransform.columns.3.x,
                                     phoneTransform.columns.3.y,
                                     phoneTransform.columns.3.z)
        let distance = simd_distance(phonePos, ball)
        // Compass yaw + gravity: read from the AR camera's Euler
        // angles since we're not running the dedicated IMU stream
        // until StrokeCapture arms it. RealityKit gives us
        // gravity-aligned yaw via the camera's eulerAngles.
        let euler = frame.camera.eulerAngles
        return AddressPose(
            phoneWorldTransform: phoneTransform,
            phoneToBallM: distance,
            compassYaw: Double(euler.y),
            gravity: SIMD3<Double>(0, -1, 0),  // ARKit world-Y is up
            lockedAt: frame.timestamp
        )
    }

    /// B52 — user pressed the AR view at `.complete`. Snapshot the
    /// address pose inline + arm StrokeCapture immediately. Stays
    /// at `.complete` throughout (UI tracks press via pressActive).
    /// The user holds the press through the swing; releasing
    /// before a stroke is detected cancels the capture.
    private func handlePressBegan(ball: SIMD3<Float>, hole: SIMD3<Float>) {
        guard pressActive == false else { return }
        guard let pose = snapshotAddressPoseInline(ball: ball) else {
            showTransientHint("Couldn't lock address — try again")
            return
        }
        pressActive = true
        logger.log(.note, "Press flow: address snapshot at press",
                   payload: ["phone_to_ball_m": String(format: "%.4f", pose.phoneToBallM),
                             "yaw_rad": String(format: "%.4f", pose.compassYaw)])
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        armStrokeCapture(ball: ball, hole: hole, pose: pose)
    }

    /// B51 — user released the press. If a stroke was already
    /// detected and is in flight, the unpress is informational
    /// (the StrokeDetector's own end-of-swing logic will close
    /// the window). If no stroke yet, treat the release as
    /// abandonment and disarm.
    private func handlePressEnded(ball: SIMD3<Float>, hole: SIMD3<Float>) {
        guard pressActive else { return }
        pressActive = false
        logger.log(.note, "Press flow: release",
                   payload: ["stroke_in_flight": strokeInFlight ? "true" : "false"])
        // If stroke not yet started → abandon. If stroke is in
        // flight, the StrokeDetector closes its window naturally
        // when the swing finishes.
        _ = hole
        if !strokeInFlight, strokeCapture != nil {
            cancelStrokeCapture()
            showTransientHint("No swing — try again")
            placementState = .complete(ball: ball, hole: hole)
        }
    }

    /// StrokeDetector phase has transitioned out of `.armed` —
    /// emit the `strokeStarted` event. Stays at `.complete`; the
    /// `strokeInFlight` flag tells handlePressEnded not to cancel.
    private func handleStrokeStarted(ball: SIMD3<Float>,
                                       hole: SIMD3<Float>,
                                       pose: AddressPose) {
        logger.log(.strokeStarted, "Stroke detected",
                   payload: ["ball_x": String(format: "%.4f", ball.x),
                             "ball_y": String(format: "%.4f", ball.y),
                             "ball_z": String(format: "%.4f", ball.z),
                             "hole_x": String(format: "%.4f", hole.x),
                             "hole_y": String(format: "%.4f", hole.y),
                             "hole_z": String(format: "%.4f", hole.z),
                             "phone_to_ball_m": String(format: "%.4f", pose.phoneToBallM)])
        strokeInFlight = true
        // B46 hint: hide address foot markers during the stroke
        // (they're stance affordances, not stroke affordances).
        scene.setAddressMarkersVisible(false)
    }

    /// StrokeDetector returned a closed window + ImpactDetector
    /// computed a result. Log `peakImpact` + `strokeEnded`,
    /// disarm the capture, return to `.addressReady` ready for
    /// the next swing. Slice 3.4 will wire the BallRollAnimator
    /// off of this hook.
    private func handleStrokeCompleted(ball: SIMD3<Float>,
                                         hole: SIMD3<Float>,
                                         pose: AddressPose,
                                         impact: ImpactResult,
                                         window: StrokeWindow) {
        logger.log(.peakImpact, "Peak impact computed",
                   payload: [
                       "timestamp": String(format: "%.4f", impact.timestamp),
                       "velocity_mps": String(format: "%.4f", impact.peakVelocity),
                       "face_angle_deg": String(format: "%.2f", impact.faceAngleDegrees),
                       "confidence": String(format: "%.3f", impact.confidence),
                       "snapped_to_square": impact.snappedToSquare ? "true" : "false",
                       "snap_reason": impact.snapReason?.rawValue ?? "",
                       "samples": "\(window.samples.count)",
                       "window_duration_s": String(format: "%.4f", window.duration)
                   ])
        logger.log(.strokeEnded, "Stroke window closed",
                   payload: ["window_start": String(format: "%.4f", window.start),
                             "window_end": String(format: "%.4f", window.end),
                             "window_duration_s": String(format: "%.4f", window.duration)])
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        // B54 — no impact-time stat hint. User physically observes
        // the roll first; stats come later via the opt-in "View
        // result" chip after ball comes to rest.
        cancelStrokeCapture()
        // B49 — transition to .rolling and start the roll animator.
        startRoll(ball: ball, hole: hole, pose: pose, impact: impact)
    }

    /// B49 Slice 3.4 — kick off the BallRollAnimator. Transitions
    /// to `.rolling` and starts the 60 Hz tick. When the ball
    /// stops, transitions to `.rolled(outcome:duration:)` ready
    /// for the result panel in B50.
    private func startRoll(ball: SIMD3<Float>,
                            hole: SIMD3<Float>,
                            pose: AddressPose,
                            impact: ImpactResult) {
        guard let ballEntity = scene.ballModelEntity() else {
            // No ball entity (rare race) — go straight back to
            // .complete so user can retry.
            _ = pose
            placementState = .complete(ball: ball, hole: hole)
            return
        }
        let animator = BallRollAnimator()
        ballRollAnimator = animator
        scene.clearRollTrail()
        placementState = .rolling(ball: ball, hole: hole,
                                   pose: pose, impact: impact)
        animator.start(
            ballEntity: ballEntity,
            ballWorld: ball,
            holeWorld: hole,
            impact: impact,
            speedCalibration: 1.0,
            stimpFeet: BallPhysics.defaultStimp,
            trailEmitter: { world in
                scene.dropRollTrailMarker(at: world)
            },
            onComplete: { outcome, duration in
                handleRollComplete(ball: ball, hole: hole,
                                    pose: pose, impact: impact,
                                    outcome: outcome,
                                    duration: duration)
            })
    }

    /// B49/B50 — fired when the ball stops. Logs the full
    /// `strokeResult` chain with Mario Kart bucket + outcome,
    /// fires appropriate haptic, transitions to `.rolled`.
    private func handleRollComplete(ball: SIMD3<Float>,
                                      hole: SIMD3<Float>,
                                      pose: AddressPose,
                                      impact: ImpactResult,
                                      outcome: BallPhysics.Outcome,
                                      duration: Double) {
        let bucket = Self.marioKart.bucket(from: impact)
        logger.log(.strokeResult,
                   "Ball stopped — outcome=\(outcome) bucket=\(bucket.bucket.rawValue)",
                   payload: [
                       "outcome": String(describing: outcome),
                       "duration_s": String(format: "%.3f", duration),
                       "velocity_mps": String(format: "%.4f", impact.peakVelocity),
                       "face_angle_deg": String(format: "%.2f", impact.faceAngleDegrees),
                       "bucket": bucket.bucket.rawValue,
                       "bucket_label": bucket.label,
                       "bucket_display_deg": String(format: "%.2f", bucket.displayDegrees),
                       "bucket_snapped_to_square": bucket.snappedToSquare ? "true" : "false",
                       "bucket_cause": bucket.cause
                   ])
        switch outcome {
        case .captured:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .lipOut, .stopped:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .rejected:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        // Restore address markers so the user can putt again.
        scene.setAddressMarkersVisible(true)
        placementState = .rolled(ball: ball, hole: hole, pose: pose,
                                   impact: impact, outcome: outcome,
                                   durationS: duration)
        ballRollAnimator = nil
    }

    /// B50 — build the result-panel view model from the rolled
    /// stroke chain. Distance is the simulated travel distance
    /// from the BallPhysics path (cached via the impact +
    /// outcome, recomputed deterministically here for display).
    /// We re-simulate to get the distance instead of caching
    /// because the impact + outcome + duration alone don't
    /// carry the path; the sim is fast (<1ms) and idempotent.
    private func makeStrokeResultVM(ball: SIMD3<Float>,
                                      hole: SIMD3<Float>,
                                      impact: ImpactResult,
                                      outcome: BallPhysics.Outcome,
                                      duration: Double) -> StrokeResultViewModel {
        let aimVec = SIMD3<Float>(hole.x - ball.x, 0, hole.z - ball.z)
        let aimLen = simd_length(aimVec)
        let sim = BallPhysics.simulatePutt(
            peakVelocity: impact.peakVelocity,
            faceAngleRaw: impact.faceAngleRaw,
            speedCalibration: 1.0,
            stimpFeet: BallPhysics.defaultStimp,
            startPosition: .zero,
            cupPosition: SIMD2<Double>(Double(aimLen), 0)
        )
        let distanceMetres = sqrt(sim.endPosition.x * sim.endPosition.x
                                   + sim.endPosition.y * sim.endPosition.y)
        let distanceFeet = distanceMetres * 3.28084
        let bucket = Self.marioKart.bucket(from: impact)

        let outcomeHeadline: String
        let outcomeTint: Color
        switch outcome {
        case .captured:
            outcomeHeadline = "Drained"
            outcomeTint = .green
        case .lipOut:
            outcomeHeadline = "Lipped out"
            outcomeTint = .orange
        case .stopped:
            let shortBy = Double(aimLen) - distanceMetres
            if shortBy > 0.3 {
                outcomeHeadline = "Short"
            } else if shortBy < -0.3 {
                outcomeHeadline = "Long"
            } else {
                outcomeHeadline = "Stopped"
            }
            outcomeTint = .white
        case .rejected:
            outcomeHeadline = "Too soft to read"
            outcomeTint = .yellow
        }

        // `duration` currently unused in the panel — kept in the
        // function signature so B51 can wire roll-time display
        // without a signature break.
        _ = duration
        return StrokeResultViewModel(
            distanceMetres: distanceMetres,
            distanceFeet: distanceFeet,
            faceAngleDeg: impact.faceAngleDegrees,
            peakVelocityMps: impact.peakVelocity,
            bucketLabel: bucket.label,
            bucketTint: bucketColor(for: bucket.bucket),
            causeLine: bucket.cause,
            outcomeHeadline: outcomeHeadline,
            outcomeTint: outcomeTint,
            autoDismissAfter: 6.0
        )
    }

    /// Tint for the Mario Kart bucket pill.
    private func bucketColor(for bucket: DirectionBucket) -> Color {
        switch bucket {
        case .square:                       return .green
        case .slightPull, .slightPush:      return .yellow
        case .pull, .push:                  return .orange
        case .miss:                         return .red
        }
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
    /// Weak reference to the Coordinator's LiDAR mesh manager so the
    /// View-side HUD (LiDAR row, stillness-hint gate) can read mesh
    /// stats without threading another binding through the
    /// UIViewRepresentable. Set by the Coordinator at init time.
    weak var meshManager: ARMeshManager?
    private var ballAnchor: AnchorEntity?
    private var holeAnchor: AnchorEntity?
    private var lineAnchor: AnchorEntity?
    /// B46 (Slice 3.1) — address-pose foot markers. Two
    /// translucent yellow rectangles rendered on the AR floor
    /// behind the ball, showing the user where to stand for the
    /// putt. Hidden when stroke begins (B48 hides via setIsActive
    /// on the underlying entities).
    private var addressMarkersAnchor: AnchorEntity?
    /// B53 — local env probe dropped at the ball position for sharper
    /// IBL. Retained so the next `placeBall` (or `clearBall`) can
    /// remove the previous probe before adding a new one. Without
    /// this, every placement leaks a probe to the ARSession.
    private var ballLocalProbe: AREnvironmentProbeAnchor?
    /// B49 Slice 3.4 — anchor + retained list for the roll-trail
    /// markers. Kept as a flat list so we can FIFO-cap at ~200
    /// markers (one per 60Hz frame, ~3 s of roll without growth).
    private var rollTrailAnchor: AnchorEntity?
    private var rollTrailMarkers: [ModelEntity] = []
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

        // B45 dimpled tour ball — Gemini-validated 10/10 in mockup v5.
        // PhysicallyBasedMaterial with polyurethane clearcoat sheen +
        // procedural concave dimple normal map. Requires
        // environmentTexturing = .automatic + AREnvironmentProbeAnchor
        // (both wired in makeUIView); without those the PBR shading is
        // flat and the dimples won't read.
        // B53 — PBR polish per Gemini B51 6/10 read: stronger clearcoat
        // sheen + lower roughness so the IBL probe's reflection is more
        // visible. Dimple normal-map amplitude bumped to 0.32 (was 0.18)
        // in makeDimpleNormalTexture() — on device the IBL contrast is
        // weaker than the Three.js mockup so the dimples need more
        // depth to read.
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(red: 0.998, green: 0.998,
                                                  blue: 1.0, alpha: 1.0))
        material.roughness = .init(floatLiteral: 0.18)
        material.metallic = .init(floatLiteral: 0.0)
        material.clearcoat = .init(floatLiteral: 0.7)
        material.clearcoatRoughness = .init(floatLiteral: 0.12)
        if let resource = Self.cachedDimpleNormalTexture {
            material.normal = .init(texture: .init(resource))
        }

        let model = ModelEntity(mesh: mesh, materials: [material])
        // Lift the sphere by its radius so it sits ON the plane.
        model.position = SIMD3<Float>(0, radius, 0)
        // Tilt the ball ~32° about X so the SphereGeometry UV pole
        // singularity isn't facing typical camera angles — hides the
        // dimple-pattern pinching. Gemini's v3 → v5 iteration showed
        // this lifted the mockup score from 9.5 → 10.
        model.orientation = simd_quatf(angle: -.pi * 0.18,
                                        axis: SIMD3<Float>(1, 0, 0))

        let anchor = AnchorEntity(world: worldPosition)
        anchor.addChild(model)
        arView.scene.addAnchor(anchor)
        ballAnchor = anchor
        ballWorldPosition = worldPosition

        // B53 — drop a small local environment probe at the ball
        // position. The world-origin 4m³ probe (added in makeUIView)
        // provides scene-wide IBL but its sampling at the ball's
        // actual position can be muted. A tight 0.6m³ probe centred
        // on the ball gives sharper local reflections — the gold
        // floor/wall around it actually shows up in the clearcoat
        // sheen. Gemini B51 ball score 6/10 cited weak IBL.
        // B53/B54-fix — drop the previous probe before adding a new
        // one. Without this every placeBall accumulates a probe on
        // the ARSession (caught in pre-ship audit 2026-06-03).
        if let old = ballLocalProbe {
            arView.session.remove(anchor: old)
        }
        var probeTransform = matrix_identity_float4x4
        probeTransform.columns.3 = SIMD4<Float>(worldPosition.x,
                                                  worldPosition.y + 0.1,
                                                  worldPosition.z, 1)
        let localProbe = AREnvironmentProbeAnchor(
            transform: probeTransform,
            extent: SIMD3<Float>(0.6, 0.6, 0.6)
        )
        arView.session.add(anchor: localProbe)
        ballLocalProbe = localProbe

        logger?.log(.materialApplied, "B53 ball material applied",
                    payload: ["entity": "ball",
                              "design": "b53_dimpled_tour_ball_v2",
                              "material": "PhysicallyBasedMaterial",
                              "clearcoat": "0.7",
                              "roughness": "0.18",
                              "metallic": "0.0",
                              "normal_map": "procedural_dimples_32x32_deep",
                              "local_probe_extent_m": "0.6",
                              "radius_m": String(format: "%.4f", radius)])
    }

    /// B51 — lazy-built TextureResource of the dimple normal map.
    /// Computed once on first access and reused for every subsequent
    /// `placeBall` call. Was previously regenerated each placement,
    /// causing a visible 80-120 ms hitch when the user replaced the
    /// ball or the "Putt again" handler reset it.
    private static let cachedDimpleNormalTexture: TextureResource? = {
        guard let cg = makeDimpleNormalTexture() else { return nil }
        return try? TextureResource.generate(from: cg,
                                              options: .init(semantic: .normal))
    }()

    /// Build a procedural dimple normal-map texture for the tour
    /// ball's surface detail. 1024×1024 canvas, 32×32 staggered grid
    /// (≈ regulation 336-pattern density). Each dimple is a concave
    /// bowl with normals pointing radially outward at the rim and
    /// flat at the centre — catches light realistically rather than
    /// reading as flat painted dots (Gemini's v1 → v2 fix).
    private static func makeDimpleNormalTexture() -> CGImage? {
        let size = 1024
        let bytesPerRow = size * 4
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        // Neutral normal background = "no tilt, +Z out of surface".
        context.setFillColor(UIColor(red: 0.5, green: 0.5,
                                      blue: 1.0, alpha: 1.0).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        let cols = 32
        let rows = 32
        let cellW = CGFloat(size) / CGFloat(cols)
        let dimpleR = cellW / 2 * 0.85
        let steps = 16

        for row in 0..<rows {
            let xOff: CGFloat = (row % 2 == 0) ? 0 : cellW / 2
            for col in 0..<cols {
                let cx = (CGFloat(col) + 0.5) * cellW + xOff
                let cy = (CGFloat(row) + 0.5) * cellW
                // Concentric rings rim → centre. Outer rim has the
                // steepest tilt outward; the centre is flat. This
                // mimics a real dimple's concave bowl shape.
                for i in 0..<steps {
                    let ringR = dimpleR * (1.0 - CGFloat(i) / CGFloat(steps))
                    let slopeT = CGFloat(i) / CGFloat(steps)
                    // B53 — bump tilt 0.43 → 0.62 (≈45% deeper) so the
                    // dimples have stronger normal contrast. On device
                    // the IBL contrast is weaker than the Three.js
                    // mockup, so dimples need more depth to read.
                    // Gemini B51 ball score 6/10 cited weak dimple read.
                    let tilt = (1.0 - slopeT) * 0.62
                    var angle: CGFloat = 0
                    while angle < .pi * 2 {
                        let dx = cos(angle)
                        let dy = sin(angle)
                        let px = cx + dx * ringR
                        let py = cy + dy * ringR
                        context.setFillColor(UIColor(
                            red: 0.5 + dx * tilt,
                            green: 0.5 + dy * tilt,
                            blue: 0.78,
                            alpha: 1.0
                        ).cgColor)
                        context.fillEllipse(in: CGRect(
                            x: px - 3, y: py - 3,
                            width: 6, height: 6))
                        angle += .pi / 12
                    }
                }
            }
        }
        return context.makeImage()
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

        // B44 hole rebuild — Gemini-validated 10/10 design after 7
        // iterations of Three.js mockups. Key changes vs B40:
        //
        //   * Cup WALL switches from UnlitMaterial(white) to a lit
        //     PhysicallyBasedMaterial — the directional component of
        //     ARKit's lighting estimate then naturally shades the
        //     curved inside surface, creating the bright-side /
        //     shadow-side asymmetry that sells 3D recess. Without
        //     this the cup reads as a flat decal (Gemini scored the
        //     B40 cup 2/10 in CAC00F, and 3/10 in the mockup).
        //   * RIM switches from a solid white disc to an ANNULUS
        //     (ring) so the cup mouth isn't visually covered by the
        //     rim from above. Gold metallic material — looks like
        //     a real golf-course brass collar.
        //   * NEW inner BEVEL ring (antique gold) inside the gold
        //     rim — reads as the chamfered metal edge meeting the
        //     cup. Pushes the rim from "printed gold ring" to
        //     "physical machined metal".
        //   * NEW soft CONTACT SHADOW ring outside the rim — gentle
        //     transparent dark ring that "seats" the cup into the
        //     floor instead of looking like it's stickered on top.
        //   * FLAGSTICK switches from UnlitMaterial(white) to a lit
        //     PhysicallyBasedMaterial (matte black). Gemini's final
        //     note: absolute black absorbs all light and reads as a
        //     2D element; matte black with a tiny specular response
        //     catches the key light and grounds the pole in the
        //     scene's lighting.
        //   * NEW gold FERRULE wrapping the pole base — small metal
        //     bracket around the flagstick where it emerges from the
        //     cup. Real flagsticks have these.
        //
        // Geometry stays at B40 — 10.8 cm × 8 cm regulation cup +
        // 70 cm pole. All changes are materials + a few new entities.

        let dia = Self.holeDiameter           // 10.8 cm
        let depth = Self.holeDepth            // 8 cm
        let rimOuter = dia * 1.20             // 12.9 cm

        let anchor = AnchorEntity(world: worldPosition)

        // [1] CONTACT SHADOW — translucent dark annulus just outside
        //     the rim. Wider than the rim by ~18% so it fades into
        //     the floor naturally. Sits LOWEST so the rim draws on
        //     top of it. Sells the rim as physically embedded.
        let contactInner = rimOuter / 2
        let contactOuter = rimOuter / 2 * 1.18
        let contactMesh = Self.makeAnnulusMesh(innerRadius: contactInner,
                                                outerRadius: contactOuter)
        var contactMaterial = UnlitMaterial(
            color: UIColor.black.withAlphaComponent(0.18)
        )
        contactMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.18))
        let contactModel = ModelEntity(mesh: contactMesh, materials: [contactMaterial])
        contactModel.position = SIMD3<Float>(0, 0.0008, 0)
        anchor.addChild(contactModel)

        // [2] GOLD RIM — B52 fix: 3D extruded ring (6mm tall) instead
        //     of a flat annulus. Flat annuli have no surface curvature
        //     for PBR specular to play on — Gemini's B51 read scored
        //     the gold "flat yellow" with zero metallic reflection.
        //     Extruding gives the rim side-faces that catch the
        //     environment probe properly. Built as a corner-rounded
        //     box matching rimOuter, with the cup-mouth carved out
        //     by the wall geometry below.
        let rimMesh = MeshResource.generateBox(width: rimOuter,
                                                height: 0.006,
                                                depth: rimOuter,
                                                cornerRadius: rimOuter / 2)
        var rimMaterial = PhysicallyBasedMaterial()
        rimMaterial.baseColor = .init(tint: UIColor(red: 0.83, green: 0.66,
                                                     blue: 0.28, alpha: 1.0))
        rimMaterial.roughness = .init(floatLiteral: 0.25)
        rimMaterial.metallic = .init(floatLiteral: 0.95)
        let rimModel = ModelEntity(mesh: rimMesh, materials: [rimMaterial])
        rimModel.position = SIMD3<Float>(0, 0.003, 0)
        anchor.addChild(rimModel)

        // [3] INNER BEVEL — thin antique-gold annulus at the rim's
        //     inner edge. Darker (lower brightness) so it reads as
        //     the chamfered transition between rim and cup interior.
        let bevelMesh = Self.makeAnnulusMesh(innerRadius: dia / 2,
                                              outerRadius: dia / 2 * 1.04)
        var bevelMaterial = PhysicallyBasedMaterial()
        bevelMaterial.baseColor = .init(tint: UIColor(red: 0.54, green: 0.38,
                                                       blue: 0.13, alpha: 1.0))
        bevelMaterial.roughness = .init(floatLiteral: 0.45)
        bevelMaterial.metallic = .init(floatLiteral: 0.9)
        let bevelModel = ModelEntity(mesh: bevelMesh, materials: [bevelMaterial])
        bevelModel.position = SIMD3<Float>(0, 0.0010, 0)
        anchor.addChild(bevelModel)

        // [4] CYLINDER WALL — lit white plastic. THIS is the
        //     headline material change: PhysicallyBasedMaterial
        //     receives ARKit's directional light, so the curved
        //     inside surface is bright on the lit side and dark
        //     on the shadow side — which Gemini called out as the
        //     critical depth cue. White declared, but ARKit's
        //     shading + the rim's own cast shadow create the
        //     natural top-to-bottom darkening that mimics a real
        //     plastic cup liner.
        // B52 — render the cup wall with FRONT-face culling so only
        // the INSIDE surfaces of the box are drawn. From above
        // looking down at the cup, the user now sees the inside
        // walls + the dark bottom, which reads as a real recessed
        // cup. Without this, RealityKit's default back-face culling
        // shows only the box's TOP face = a flat dark disc, which
        // is what Gemini scored 1/10 in B51.
        let wallMesh = MeshResource.generateBox(width: dia,
                                                 height: depth,
                                                 depth: dia,
                                                 cornerRadius: dia / 2)
        var wallMaterial = PhysicallyBasedMaterial()
        wallMaterial.baseColor = .init(tint: UIColor(white: 0.96, alpha: 1.0))
        wallMaterial.roughness = .init(floatLiteral: 0.85)
        wallMaterial.metallic = .init(floatLiteral: 0.0)
        wallMaterial.faceCulling = .front
        let wallModel = ModelEntity(mesh: wallMesh, materials: [wallMaterial])
        wallModel.position = SIMD3<Float>(0, -depth / 2, 0)
        anchor.addChild(wallModel)

        // [5] DARK BOTTOM — at -depth. Stays SimpleMaterial dark;
        //     we WANT it to stay dark regardless of lighting since
        //     it's the deepest point of the recess.
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
        bottomModel.position = SIMD3<Float>(0, -depth + 0.001, 0)
        anchor.addChild(bottomModel)

        // [6] FLAGSTICK — matte black PhysicallyBasedMaterial.
        //     Slightly off-pure-black so it catches a subtle key-
        //     light highlight on the lit side, giving the pole 3D
        //     volume. Final 10/10 fix per Gemini's last note.
        let poleSide: Float = 0.015
        let poleHeight: Float = 0.70
        let poleMesh = MeshResource.generateBox(width: poleSide,
                                                  height: poleHeight,
                                                  depth: poleSide,
                                                  cornerRadius: poleSide / 2)
        var poleMaterial = PhysicallyBasedMaterial()
        poleMaterial.baseColor = .init(tint: UIColor(red: 0.12, green: 0.10,
                                                      blue: 0.10, alpha: 1.0))
        poleMaterial.roughness = .init(floatLiteral: 0.55)
        poleMaterial.metallic = .init(floatLiteral: 0.25)
        let poleModel = ModelEntity(mesh: poleMesh, materials: [poleMaterial])
        poleModel.position = SIMD3<Float>(0, poleHeight / 2, 0)
        anchor.addChild(poleModel)

        // [7] GOLD FERRULE — small metal ring wrapping the pole
        //     base where it emerges from the cup floor. Real
        //     flagsticks have this bracket. PhysicallyBasedMaterial
        //     matching the rim's gold.
        let ferruleSide: Float = poleSide * 1.65
        let ferruleMesh = MeshResource.generateBox(width: ferruleSide,
                                                    height: 0.022,
                                                    depth: ferruleSide,
                                                    cornerRadius: ferruleSide / 2)
        var ferruleMaterial = PhysicallyBasedMaterial()
        ferruleMaterial.baseColor = .init(tint: UIColor(red: 0.83, green: 0.66,
                                                         blue: 0.28, alpha: 1.0))
        ferruleMaterial.roughness = .init(floatLiteral: 0.30)
        ferruleMaterial.metallic = .init(floatLiteral: 0.95)
        let ferruleModel = ModelEntity(mesh: ferruleMesh, materials: [ferruleMaterial])
        ferruleModel.position = SIMD3<Float>(0, 0.014, 0)
        anchor.addChild(ferruleModel)

        // [8] TRIANGLE FLAG — unchanged from B40. UnlitMaterial red
        //     so the colour stays bright regardless of lighting.
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

        logger?.log(.materialApplied, "B44 hole materials applied",
                    payload: ["entity": "hole",
                              "design": "b44_gold_rim_lit_white_wall",
                              "rim": "PBR.gold.metallic95",
                              "bevel": "PBR.antique_gold.metallic90",
                              "contact_shadow": "Unlit.black.alpha18",
                              "wall": "PBR.white.lit",
                              "bottom": "SimpleMaterial.dark",
                              "flagstick": "PBR.matte_black",
                              "ferrule": "PBR.gold.metallic95",
                              "flag": "UnlitMaterial.red.triangle",
                              "depth_m": String(format: "%.3f", depth),
                              "diameter_m": String(format: "%.4f", dia)])

        if let ballWorldPosition {
            drawAimLine(from: ballWorldPosition, to: worldPosition)
        }
    }

    /// Build a flat ring (annulus) mesh on the XZ plane (Y=0).
    /// Used by the B44 hole render for the gold rim + inner bevel +
    /// contact shadow — none of which can be done with the built-in
    /// `MeshResource.generatePlane` since that's a solid disc.
    /// iOS 17 has no `MeshResource.generateRing`, so we build a
    /// triangle strip via MeshDescriptor.
    ///
    /// Both faces are emitted so the ring is visible from above and
    /// below — useful for the contact shadow which the camera may
    /// see from a near-grazing angle.
    private static func makeAnnulusMesh(innerRadius: Float,
                                         outerRadius: Float,
                                         segments: Int = 96) -> MeshResource {
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity((segments + 1) * 2)
        for i in 0...segments {
            let a = Float(i) / Float(segments) * 2 * .pi
            let cosA = cos(a)
            let sinA = sin(a)
            positions.append(SIMD3<Float>(innerRadius * cosA, 0, innerRadius * sinA))
            positions.append(SIMD3<Float>(outerRadius * cosA, 0, outerRadius * sinA))
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(segments * 12)
        for i in 0..<segments {
            let i0 = UInt32(i * 2)
            let i1 = UInt32(i * 2 + 1)
            let i2 = UInt32(i * 2 + 2)
            let i3 = UInt32(i * 2 + 3)
            // Front face (visible from above, +Y)
            indices.append(i0); indices.append(i2); indices.append(i1)
            indices.append(i1); indices.append(i2); indices.append(i3)
            // Back face (visible from below, -Y) — reversed winding
            indices.append(i0); indices.append(i1); indices.append(i2)
            indices.append(i1); indices.append(i3); indices.append(i2)
        }
        var descriptor = MeshDescriptor(name: "annulus")
        descriptor.positions = MeshBuffer(positions)
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor]))
            ?? MeshResource.generatePlane(width: outerRadius * 2,
                                            depth: outerRadius * 2,
                                            cornerRadius: outerRadius)
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

        // B41: LiDAR scene reconstruction makes the underlying
        // plane-detection significantly more accurate (ARKit uses
        // LiDAR depth to fit plane geometry tightly to the real
        // surface), so we still raycast against planes — there is
        // no `.existingMeshGeometry` target in ARRaycastQuery
        // (mesh hits would require an arView.scene.raycast with
        // sceneUnderstanding collision shapes, which is heavier).
        // Plane + estimated-plane fallback delivers the placement
        // accuracy improvement; the headline B41 visual win is the
        // mesh-based green overlay following the actual floor.
        let priorities: [ARRaycastQuery.Target] = [
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
        // B53/B54-fix — remove local env probe on full reset
        if let probe = ballLocalProbe {
            arView?.session.remove(anchor: probe)
            ballLocalProbe = nil
        }
        clearAddressMarkers()
        clearRollTrail()
        rollTrailAnchor?.removeFromParent()
        rollTrailAnchor = nil
    }

    /// B46 (Slice 3.1) — drop the address-pose foot markers.
    /// Called by Move ball / Move hole / Reset paths so the
    /// markers don't linger over stale ball/hole coords.
    func clearAddressMarkers() {
        addressMarkersAnchor?.removeFromParent()
        addressMarkersAnchor = nil
    }

    /// B46 (Slice 3.1) — render two translucent yellow foot
    /// markers on the AR floor showing the user where to stand
    /// for the putt. Position computed from the ball + hole
    /// world coords:
    ///   * 60 cm behind the ball along the negative aim direction
    ///   * markers spread 26 cm apart, perpendicular to aim line
    ///   * 24 cm long × 10 cm wide each
    ///
    /// Materials use `PhysicallyBasedMaterial` (matches B45
    /// `environmentTexturing = .automatic` so they shade with the
    /// ARKit-estimated ambient light). Markers are visually below
    /// the floor (lifted 1 mm only) so the user can see they're
    /// affordances, not physical objects.
    ///
    /// Hidden — but the entities stay in the scene graph for the
    /// future stroke-detection path (B48) to flip via `isEnabled`.
    func placeAddressMarkers(ball: SIMD3<Float>, hole: SIMD3<Float>) {
        guard let arView else { return }
        clearAddressMarkers()

        // Aim direction in the XZ plane (horizontal). If ball and
        // hole are co-located, skip — no meaningful aim direction.
        let aimVec = SIMD3<Float>(hole.x - ball.x, 0, hole.z - ball.z)
        let aimLen = simd_length(aimVec)
        guard aimLen > 0.01 else { return }
        let aim = aimVec / aimLen
        // Perpendicular in the floor plane (rotate 90° about Y).
        let perp = SIMD3<Float>(-aim.z, 0, aim.x)

        // Marker geometry — 24 cm long × 10 cm wide, 1 mm thick
        // disc. Lift 1 mm above the floor to avoid z-fighting with
        // the LiDAR mesh overlay.
        let footLen: Float = 0.24
        let footWid: Float = 0.10
        let footMesh = MeshResource.generatePlane(width: footLen,
                                                   depth: footWid,
                                                   cornerRadius: 0.02)

        var footMaterial = PhysicallyBasedMaterial()
        footMaterial.baseColor = .init(tint: UIColor(red: 1.0,
                                                       green: 0.92,
                                                       blue: 0.20,
                                                       alpha: 0.78))
        footMaterial.roughness = .init(floatLiteral: 0.7)
        footMaterial.metallic = .init(floatLiteral: 0.0)
        footMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.78))

        // Stance position: 60 cm behind the ball along -aim. Foot
        // markers spread 26 cm apart sideways via ±perp.
        let stanceCenter = ball - aim * 0.60
        let footOffset = perp * 0.13   // ±13 cm = 26 cm spread

        // Yaw the foot rectangle so its long axis aligns with the
        // aim direction (foot points TOWARD the ball).
        let yaw = atan2(aim.x, aim.z)
        let footRot = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))

        let anchor = AnchorEntity(world: .zero)

        let leftFoot = ModelEntity(mesh: footMesh, materials: [footMaterial])
        leftFoot.position = stanceCenter - footOffset
        leftFoot.position.y = 0.001
        leftFoot.orientation = footRot
        anchor.addChild(leftFoot)

        let rightFoot = ModelEntity(mesh: footMesh, materials: [footMaterial])
        rightFoot.position = stanceCenter + footOffset
        rightFoot.position.y = 0.001
        rightFoot.orientation = footRot
        anchor.addChild(rightFoot)

        arView.scene.addAnchor(anchor)
        addressMarkersAnchor = anchor

        logger?.log(.materialApplied,
                    "B46 address markers applied",
                    payload: ["entity": "address_markers",
                              "design": "b46_foot_markers",
                              "material": "PhysicallyBasedMaterial.yellow_translucent",
                              "stance_x": String(format: "%.4f", stanceCenter.x),
                              "stance_y": String(format: "%.4f", stanceCenter.y),
                              "stance_z": String(format: "%.4f", stanceCenter.z),
                              "aim_yaw_deg": String(format: "%.2f", yaw * 180 / .pi),
                              "foot_offset_m": "0.13"])
    }

    /// B46 — toggle address-marker visibility. Called by the
    /// stroke-detection path in B48 to hide markers during the
    /// stroke without tearing them down.
    func setAddressMarkersVisible(_ visible: Bool) {
        addressMarkersAnchor?.isEnabled = visible
    }

    /// B49 Slice 3.4 — expose the ball ModelEntity so the
    /// BallRollAnimator can mutate its position at 60 Hz. The
    /// entity sits as the first child of `ballAnchor`. Returns
    /// nil if the ball hasn't been placed (animator caller
    /// should guard).
    func ballModelEntity() -> Entity? {
        ballAnchor?.children.first
    }

    /// B49 — drop a small translucent yellow trail marker at the
    /// ball's current world position. Called once per 60 Hz tick
    /// by the BallRollAnimator's trailEmitter. Markers fade
    /// visually via their stored opacity decay (handled at
    /// render time by RealityKit's blending).
    func dropRollTrailMarker(at world: SIMD3<Float>) {
        guard let arView else { return }
        if rollTrailAnchor == nil {
            let anchor = AnchorEntity(world: .zero)
            arView.scene.addAnchor(anchor)
            rollTrailAnchor = anchor
        }
        // Cap the trail at ~200 markers so memory doesn't grow.
        if rollTrailMarkers.count > 200 {
            rollTrailMarkers.first?.removeFromParent()
            rollTrailMarkers.removeFirst()
        }
        let mesh = MeshResource.generatePlane(width: 0.018, depth: 0.018,
                                                cornerRadius: 0.009)
        var material = UnlitMaterial(
            color: UIColor(red: 1.0, green: 0.94, blue: 0.20, alpha: 0.65)
        )
        material.blending = .transparent(opacity: .init(floatLiteral: 0.65))
        let marker = ModelEntity(mesh: mesh, materials: [material])
        marker.position = SIMD3<Float>(world.x, 0.0008, world.z)
        rollTrailAnchor?.addChild(marker)
        rollTrailMarkers.append(marker)
    }

    /// B49 — wipe the trail (called at the start of a new roll
    /// + on Reset). Keeps the anchor for re-use.
    func clearRollTrail() {
        rollTrailMarkers.forEach { $0.removeFromParent() }
        rollTrailMarkers.removeAll(keepingCapacity: true)
    }

    /// B42: drop ONLY the ball entity (Move-ball UX). Leaves the
    /// hole + aim line in place. The aim line is intentionally
    /// kept rendered (anchored to the hole) — it'll get redrawn
    /// against the new ball position when placement completes.
    /// `ballWorldPosition` is cleared so the next `placeHole` /
    /// `placeBall` call doesn't try to draw an aim line to the
    /// stale ball coord.
    func clearBall() {
        ballAnchor?.removeFromParent()
        lineAnchor?.removeFromParent()
        ballAnchor = nil
        lineAnchor = nil
        ballWorldPosition = nil
        // B53/B54-fix — remove local env probe when ball is cleared
        if let probe = ballLocalProbe {
            arView?.session.remove(anchor: probe)
            ballLocalProbe = nil
        }
        clearAddressMarkers()
    }

    /// B42: drop ONLY the hole entity (Move-hole UX). The aim
    /// line is anchored to the hole world coord so it dies with
    /// the hole. Ball stays placed + the cached
    /// `ballWorldPosition` survives so the next `placeHole` can
    /// redraw the aim line to the kept ball.
    func clearHole() {
        holeAnchor?.removeFromParent()
        lineAnchor?.removeFromParent()
        holeAnchor = nil
        lineAnchor = nil
        clearAddressMarkers()
    }

    /// B42 safety net: redraw the aim line between an existing ball
    /// and hole without touching either entity. Used by the
    /// Move-ball completion path so we don't have to rebuild the
    /// hole just to get the aim line back. Public wrapper around
    /// the private drawAimLine — keeps the hole + ball untouched
    /// while still anchoring the aim line geometry.
    func refreshAimLine(from ball: SIMD3<Float>, to hole: SIMD3<Float>) {
        drawAimLine(from: ball, to: hole)
        ballWorldPosition = ball
    }

    /// Live LiDAR mesh anchor count — proxied to `meshManager`
    /// when wired by the Coordinator. Returns 0 on non-LiDAR
    /// devices (no manager attached at init time). Used by the
    /// View's stillness-hint gate (B42 — was checking only
    /// planeCount, which falsely triggered on LiDAR-only scans).
    func meshAnchorCount() -> Int {
        meshManager?.anchorCount ?? 0
    }

    /// B45 — total floor area scanned by LiDAR, in m². Used by the
    /// "scan more of the floor" hint in the View when the area is
    /// still small after 5 s of session time.
    func lidarFloorAreaM2() -> Double {
        meshManager?.floorAreaM2 ?? 0
    }

    /// One-line HUD summary of the LiDAR mesh state for the
    /// expanded HUD row. Returns "—" when LiDAR is inactive.
    func meshSummary() -> String {
        guard let mgr = meshManager, mgr.anchorCount > 0 else { return "—" }
        return String(format: "%.1f m² · %d anchors · %d tris",
                       mgr.floorAreaM2, mgr.anchorCount, mgr.floorTriangleCount)
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

        // B45 — environment texturing + light estimation. Gemini
        // audit of CAC00F-style B44 recording 52C831 scored the
        // hole 3/10 because PhysicallyBasedMaterial declarations
        // weren't being lit — root cause was environmentTexturing
        // = .none. With .automatic, ARKit continuously captures
        // the room as an IBL probe, so PBR metallics reflect
        // properly and lit white walls darken on the shadow side.
        config.environmentTexturing = .automatic
        config.isLightEstimationEnabled = true   // explicit (default is true, but be sure)

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
            // B45 — also enable per-pixel depth semantics on LiDAR
            // devices. Tighter raycast accuracy at object edges +
            // better depth occlusion. Was previously only on the
            // non-LiDAR fallback path.
            var semantics: ARConfiguration.FrameSemantics = []
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                semantics.insert(.sceneDepth)
            }
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                semantics.insert(.smoothedSceneDepth)
            }
            if !semantics.isEmpty {
                config.frameSemantics = semantics
            }
            logger.log(.note,
                       "LiDAR scene reconstruction enabled (meshWithClassification, depth semantics)")
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

        // B45 — drop an `AREnvironmentProbeAnchor` at world origin
        // covering a 4 m³ region. RealityKit's PBR shader queries
        // this anchor for the local lighting environment when
        // shading metallic / clearcoat materials. Without it, even
        // with environmentTexturing = .automatic, materials at
        // placement positions get a generic ambient. Probe is
        // re-centred at session start; subsequent placements
        // automatically use it because it covers the whole scan
        // volume.
        let probe = AREnvironmentProbeAnchor(
            transform: matrix_identity_float4x4,
            extent: SIMD3<Float>(4, 4, 4)
        )
        arView.session.add(anchor: probe)
        logger.log(.note, "B45 environment probe anchor added (4m³)")
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
        // B42: wire the scene to the Coordinator's mesh manager so
        // the View-side HUD (LiDAR row, stillness gate) can read
        // mesh stats without threading another binding.
        scene.meshManager = context.coordinator.meshManager
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
        /// B53 — wall-clock timestamp of the last `rebuildMeshOverlay`
        /// call. Used to throttle rebuilds to 2Hz so the green floor
        /// mesh stops jittering on every ARKit anchor update.
        private var lastMeshRebuildAt: TimeInterval = 0
        private var meshOverlayEntity: ModelEntity?
        /// Throttle for `.meshUpdated` log emission. ARKit updates
        /// mesh anchors at ~1-2 Hz; we log at most every 2 s per
        /// anchor.
        private var lastMeshUpdateLog: [UUID: Date] = [:]
        /// Throttle for the global `.meshStats` event. Emit at most
        /// every 5 s so we get one stats sample per pan-and-scan
        /// burst without polluting the log.
        private var lastMeshStatsAt: Date = .distantPast
        /// B42: throttle for the periodic `.lightEstimate` event. Fires
        /// once every 5 s out of `session(_:didUpdate frame:)` so we
        /// can correlate "white renders gray" regressions to ARKit's
        /// ambient light estimate without per-frame spam.
        private var lastLightEstimateLog: Date = .distantPast

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

                // B42: periodic ambient-light estimate so we can
                // correlate render bugs (e.g. white-renders-gray
                // from CAC00F) to the actual ARKit lighting
                // estimate. Throttled to one event per 5 s.
                if now.timeIntervalSince(lastLightEstimateLog) > 5.0,
                   let light = frame.lightEstimate {
                    lastLightEstimateLog = now
                    logger.log(.lightEstimate,
                               String(format: "light intensity=%.0f temp=%.0fK",
                                       light.ambientIntensity,
                                       light.ambientColorTemperature),
                               payload: [
                                   "ambient_intensity": String(format: "%.2f", light.ambientIntensity),
                                   "ambient_color_temperature": String(format: "%.2f", light.ambientColorTemperature),
                               ])
                }
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
                        // B42: one-shot note when the classification
                        // buffer is absent — distinguishes "LiDAR
                        // silently broken" from "mesh detected,
                        // classification still warming up".
                        if meshAnchor.geometry.classification == nil,
                           meshManager.didSeeAnchorWithoutClassification(meshAnchor.identifier) {
                            logger.log(.note,
                                       "LiDAR mesh detected, awaiting classification",
                                       payload: ["id": meshAnchor.identifier.uuidString])
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
            // B53 — throttle rebuilds to 2Hz (was every anchor update,
            // i.e. up to 60Hz). Halves the edge-jitter Gemini scored
            // 7/10 in B51 — the overlay was re-tessellating faster
            // than the user could focus on a single triangle. Next
            // ARKit anchor update naturally retries within 50ms so
            // we don't need an explicit re-queue.
            let now = CACurrentMediaTime()
            if now - lastMeshRebuildAt < 0.5 { return }
            lastMeshRebuildAt = now
            guard let resource = meshManager.buildFloorMesh() else {
                // No floor triangles yet — leave any existing
                // overlay in place (better to keep stale than to
                // flicker an empty state).
                return
            }
            // B53 — drop overlay opacity from 35% to 22%. Lower
            // opacity hides the mesh-edge jitter that's intrinsic to
            // ARKit's tessellation. Still readable as "there's a
            // mesh here" but no longer attention-grabbing.
            let overlayColor = UIColor(red: 0.20, green: 0.95,
                                        blue: 0.40, alpha: 0.22)
            var material = UnlitMaterial(color: overlayColor)
            material.blending = .transparent(opacity: .init(floatLiteral: 0.22))

            if let entity = meshOverlayEntity {
                entity.model?.mesh = resource
                entity.model?.materials = [material]
            } else {
                let entity = ModelEntity(mesh: resource, materials: [material])
                // B42: lift the overlay 2 mm above the LiDAR floor to
                // avoid z-fighting with the camera-feed pixels at
                // exactly floor-Y (visible as patchy flicker /
                // shimmer along triangle edges when the camera
                // moves). If this introduces visible parallax when
                // the phone is held very low to the floor, drop to
                // 1 mm in B43.
                let entityAnchor = AnchorEntity(world: SIMD3<Float>(0, 0.002, 0))
                entityAnchor.addChild(entity)
                arView.scene.addAnchor(entityAnchor)
                meshOverlayAnchor = entityAnchor
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

            // B42: when LiDAR scene reconstruction is active, the
            // rectangular plane overlay is strictly worse than the
            // LiDAR triangle-mesh overlay and stacks visually on top
            // of it (Gemini would see two greens). Drop the
            // rectangle but KEEP the plane anchor registered (the
            // raycast fallback chain still hits .existingPlaneGeometry
            // as a safety net before the mesh populates).
            if lidarActive {
                // If we previously created an overlay before lidarActive
                // became true (race during cold start), tear it down.
                if planeOverlays[plane.identifier] != nil {
                    removePlaneOverlay(id: plane.identifier)
                }
                return
            }

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

                // B41: plane + estimated-plane fallback. ARKit's
                // plane geometry is significantly tighter on LiDAR
                // devices because the LiDAR depth fits the plane
                // to the real surface; `.existingMeshGeometry`
                // isn't a real raycast target (mesh hits go via
                // arView.scene.raycast, not ARSession.raycast).
                let tapTargets: [ARRaycastQuery.Target] = [
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
                               payload: ["source": "tap",
                                         "x": String(format: "%.4f", world.x),
                                         "y": String(format: "%.4f", world.y),
                                         "z": String(format: "%.4f", world.z)])
                    _placementState.wrappedValue = .readyToPlaceHole(world)
                    lastPlacementAt = Date()
                case .readyToPlaceHole(let ballWorld):
                    scene.placeHole(at: world)
                    let dist = simd_distance(ballWorld, world)
                    logger.log(.holePlaced, "hole \(ARLogFmt.vec(world)) · \(ARLogFmt.meters(dist))",
                               payload: ["source": "tap",
                                         "x": String(format: "%.4f", world.x),
                                         "y": String(format: "%.4f", world.y),
                                         "z": String(format: "%.4f", world.z),
                                         "distance_m": String(format: "%.4f", dist)])
                    _placementState.wrappedValue = .complete(ball: ballWorld, hole: world)
                    // B46 Slice 3.1: drop foot markers behind the ball.
                    scene.placeAddressMarkers(ball: ballWorld, hole: world)
                    lastPlacementAt = Date()
                // B42: tap-to-place mirrors the crosshair Move-ball /
                // Move-hole flow when the user is in a replacing state.
                case .replacingBall(let preservedHole):
                    scene.placeBall(at: world)
                    let dist = simd_distance(world, preservedHole)
                    logger.log(.ballPlaced, "ball re-placed via tap \(ARLogFmt.vec(world))",
                               payload: ["source": "replace_tap",
                                         "x": String(format: "%.4f", world.x),
                                         "y": String(format: "%.4f", world.y),
                                         "z": String(format: "%.4f", world.z),
                                         "distance_m": String(format: "%.4f", dist)])
                    // B42: refresh aim line without rebuilding the
                    // hole entity (avoids flicker + duplicate
                    // materialApplied event).
                    scene.refreshAimLine(from: world, to: preservedHole)
                    _placementState.wrappedValue = .complete(ball: world, hole: preservedHole)
                    scene.placeAddressMarkers(ball: world, hole: preservedHole)
                    lastPlacementAt = Date()
                case .replacingHole(let preservedBall):
                    scene.placeHole(at: world)
                    let dist = simd_distance(preservedBall, world)
                    logger.log(.holePlaced, "hole re-placed via tap \(ARLogFmt.vec(world))",
                               payload: ["source": "replace_tap",
                                         "x": String(format: "%.4f", world.x),
                                         "y": String(format: "%.4f", world.y),
                                         "z": String(format: "%.4f", world.z),
                                         "distance_m": String(format: "%.4f", dist)])
                    _placementState.wrappedValue = .complete(ball: preservedBall, hole: world)
                    scene.placeAddressMarkers(ball: preservedBall, hole: world)
                    lastPlacementAt = Date()
                case .complete, .rolling, .rolled:
                    // B47/B48/B49: tap is ignored in the
                    // post-placement flows — they're driven by
                    // explicit buttons + the IMU stream + the
                    // physics animator.
                    logger.log(.note, "tap ignored — placement complete or stroke/roll flow active")
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
