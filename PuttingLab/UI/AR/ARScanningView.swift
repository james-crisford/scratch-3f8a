import SwiftUI
import ARKit
import RealityKit

/// AR Slice 1 — pure verification of the ARKit foundation.
///
/// Opens a fullscreen camera view with horizontal plane detection running,
/// surfaces world-tracking quality + plane count via a HUD, and provides a
/// "Done" button to dismiss. No ball, no hole, no stroke integration yet —
/// the point is to validate the single biggest unknown from the overnight
/// architecture review:
///   • does ARKit world-tracking survive the phone going from
///     reading-pose → stroke-pose → reading-pose without losing the
///     floor anchor?
///   • does horizontal plane detection actually fire on a carpet / wooden
///     floor / desktop surface within a sensible time?
/// If those work, Slices 2-4 layer on top (ball placement, hole placement,
/// trajectory replay). If they don't, we know before investing 8-10 days
/// in UI work.
///
/// **DEBUG-only entry point.** The button that opens this view is labelled
/// as such on the result panel; this isn't user-facing yet.
struct ARScanningView: View {
    @Environment(\.dismiss) private var dismiss

    /// HUD state. Updated from the ARSession delegate. The Coordinator is
    /// `@MainActor`, so binding writes happen on the main thread directly
    /// (no `Task { @MainActor in ... }` hop needed). Throttled to ~10 Hz
    /// in the coordinator to stop the status string flickering at 60 fps.
    @State private var trackingState: String = "Starting…"
    @State private var planeCount: Int = 0
    @State private var sessionElapsedSeconds: Int = 0
    /// Anchored to the actual view-appear (not the View struct init) so
    /// the Elapsed counter starts when the user actually sees the
    /// camera (M9 in the audit). Set in onAppear.
    @State private var sessionStartedAt: Date?
    @State private var firstStillAt: Date?
    @State private var showStillnessHint: Bool = false
    /// Live AR session event log — observed by the HUD for real-time
    /// visibility, persisted to Documents/ARSessionLogs/<id>.json on
    /// dismantle. Same logger type as Slice 2 so the JSON shape is
    /// identical across both slices.
    @State private var logger: ARSessionLogger = ARSessionLogger(slice: "slice1-scan")

    var body: some View {
        ZStack {
            ARSceneRepresentable(
                logger: logger,
                trackingState: $trackingState,
                planeCount: $planeCount
            )
            .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                hud
                if showStillnessHint && planeCount == 0 {
                    stillnessHint
                }
                eventLog
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .statusBarHidden()
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            // Elapsed is anchored to onAppear, not view-struct init.
            // Without this fix the counter included pre-camera time and
            // also jumped on background+foreground (M9).
            if let start = sessionStartedAt {
                sessionElapsedSeconds = Int(Date().timeIntervalSince(start))
            }
            // Silent-wait coaching nudge after 2 s of no plane (M12).
            if planeCount == 0, let firstStillAt {
                if !showStillnessHint && Date().timeIntervalSince(firstStillAt) > 2.0 {
                    showStillnessHint = true
                }
            }
        }
        .onChange(of: planeCount) { _, newValue in
            // Roll back the silent-wait hint as soon as a plane appears.
            if newValue > 0 {
                showStillnessHint = false
                firstStillAt = nil
            }
        }
        .onAppear {
            sessionStartedAt = Date()
            firstStillAt = Date()
            logger.log(.sessionStart, "Slice 1 scanning view opened")
        }
        .onDisappear {
            logger.log(.sessionEnd, "Slice 1 scanning view dismissed")
            logger.saveSnapshot()
        }
    }

    /// Silent-wait nudge after 2 s of no plane (M12 fix).
    private var stillnessHint: some View {
        Text("Try slowly panning the phone — ARKit needs motion to detect surfaces")
            .font(.caption2.italic())
            .foregroundStyle(.white)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 6)
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
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

            Spacer()

            Text("AR scan · Slice 1")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
        }
        .padding(.top, 12)
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Tracking", trackingState, tint: trackingTint)
            row("Planes", "\(planeCount)", tint: planeCount > 0 ? .green : .yellow)
            row("Elapsed", "\(sessionElapsedSeconds) s", tint: .white)

            Divider()
                .background(.white.opacity(0.25))
                .padding(.vertical, 2)

            Text(instructionText)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
                .lineSpacing(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    }

    /// Live AR event log shown below the HUD. Same layout as Slice 2 so
    /// James can use the two slices interchangeably for verification —
    /// "what's happening live" with a Save button that flushes to disk
    /// without waiting for dismantle.
    private var eventLog: some View {
        let recent = logger.events.suffix(5)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("LIVE EVENTS  (last \(min(5, logger.events.count)) of \(logger.events.count))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
                Button {
                    // Log first then save — otherwise the saved JSON
                    // lacks the very marker it's supposed to tag (L16).
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

    private func timeShort(_ d: Date) -> String {
        Self.shortTimeFormatter.string(from: d)
    }

    /// Static DateFormatter — reuse across every row render instead of
    /// reallocating per call (L27).
    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

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

    private var instructionText: String {
        if planeCount == 0 {
            return "Slowly move your phone so the camera sees the floor / table. A horizontal plane should appear within a few seconds."
        }
        return "Plane detected. Move around to verify tracking stays in 'Normal' state."
    }
}

// MARK: - UIViewRepresentable bridge

/// Bridges the UIKit ARView (the iOS 17 path for iPhone AR) into SwiftUI.
/// iOS 18 introduces a cleaner ARKitSession + RealityView path, but we
/// deploy to iOS 17.0 so this is the supported route today.
private struct ARSceneRepresentable: UIViewRepresentable {
    let logger: ARSessionLogger
    @Binding var trackingState: String
    @Binding var planeCount: Int

    func makeUIView(context: Context) -> ARView {
        // KNOWN-RISK FOR SLICE 1: this spins up a SECOND ARSession on top
        // of the one ARTrackingManager already owns for stillness-lock /
        // pose tracking during practice. iOS doesn't formally support
        // two concurrent ARSessions; in practice the more recent .run()
        // tends to win and the other quietly stops emitting frames. For
        // Slice 1 verification we accept this — when James dismisses
        // the view, ARTrackingManager will need to be restarted to
        // resume normal stroke-detection. Slice 3 will fix this with an
        // explicit pause/resume around the cover presentation.
        let arView = ARView(frame: .zero,
                            cameraMode: .ar,
                            automaticallyConfigureSession: false)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .none      // power saving — we don't render PBR yet
        config.frameSemantics = []               // no body / people-occlusion semantics yet
        arView.session.delegateQueue = .main
        arView.session.delegate = context.coordinator
        arView.session.run(config, options: [])
        // No `debugOptions = .showAnchorGeometry` here. The solid green
        // wireframe overlay was confusing during the first Slice 1 test
        // — James's words: "paints the whole room in green basically".
        // We add our own translucent green ModelEntity over each detected
        // plane in the Coordinator (`addOrUpdatePlaneOverlay`) so the user
        // can SEE how well the floor is mapped without losing the camera
        // feed underneath.
        context.coordinator.arView = arView
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // No-op: all state lives in the coordinator + the ARSession.
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        // Stop the AR session when SwiftUI tears the view down. ARSession
        // holds the camera + sensor subscriptions; without explicit
        // pause() they can linger and burn battery between presentations.
        // ARTrackingManager restart is handled by PracticeSessionView's
        // onDismiss closure (H4 fix) — nothing for us to do here.
        uiView.session.pause()
        // Drop overlays only. Static dismantleUIView isn't @MainActor-
        // isolated at the type level even though SwiftUI calls it on
        // the main thread, so we hop via assumeIsolated under Swift 6
        // strict mode. saveSnapshot is NOT called here — the View's
        // onDisappear already does it; doing it twice is wasted I/O
        // and can race with the first write (M14 fix).
        MainActor.assumeIsolated {
            coordinator.clearAllPlaneOverlays()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(trackingState: $trackingState,
                    planeCount: $planeCount,
                    logger: logger)
    }

    /// `@MainActor` on the class for its own state; every delegate
    /// method is `nonisolated` and bridges via MainActor.assumeIsolated
    /// (C1 fix — Swift 6 strict-concurrency rejects @MainActor methods
    /// satisfying nonisolated @objc protocol requirements otherwise).
    /// `arView.session.delegateQueue = .main` guarantees ARKit calls us
    /// on the main thread, so the runtime assertion always holds.
    @MainActor
    final class Coordinator: NSObject, ARSessionDelegate {
        @Binding var trackingState: String
        @Binding var planeCount: Int
        let logger: ARSessionLogger
        weak var arView: ARView?

        private var detectedPlanes: Set<UUID> = []
        private var lastHUDUpdate: Date = .distantPast
        private var planeOverlays: [UUID: PlaneOverlay] = [:]
        private var lastPlaneUpdateLog: [UUID: Date] = [:]

        /// Cached overlay record — mirrors Slice 2's PlaneOverlay struct.
        /// Re-uses the ModelEntity across 10 Hz ticks and only rebuilds
        /// the mesh when the extent changes by more than 5 cm (M7).
        private struct PlaneOverlay {
            let anchor: AnchorEntity
            let model: ModelEntity
            var lastWidth: Float
            var lastDepth: Float
        }

        init(trackingState: Binding<String>,
             planeCount: Binding<Int>,
             logger: ARSessionLogger) {
            _trackingState = trackingState
            _planeCount = planeCount
            self.logger = logger
        }

        // MARK: ARSessionDelegate

        nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
            MainActor.assumeIsolated {
                let now = Date()
                guard now.timeIntervalSince(lastHUDUpdate) > 0.1 else { return }
                lastHUDUpdate = now
                let status = Self.formatTrackingState(frame.camera.trackingState)
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

        nonisolated func sessionWasInterrupted(_ session: ARSession) {
            MainActor.assumeIsolated {
                logger.log(.interruption, "session interrupted")
                _trackingState.wrappedValue = "Interrupted"
            }
        }

        nonisolated func sessionInterruptionEnded(_ session: ARSession) {
            MainActor.assumeIsolated {
                logger.log(.interruptionEnded, "session resumed")
                _trackingState.wrappedValue = "Resuming…"
            }
        }

        nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
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

        // MARK: Translucent plane visualization (matches Slice 2)

        private func addOrUpdatePlaneOverlay(_ plane: ARPlaneAnchor) {
            guard let arView else { return }
            let width = plane.planeExtent.width
            let depth = plane.planeExtent.height
            guard width.isFinite, depth.isFinite, width > 0.01, depth > 0.01 else { return }

            let rotation = simd_quatf(angle: plane.planeExtent.rotationOnYAxis,
                                       axis: SIMD3<Float>(0, 1, 0))
            let translation = SIMD3<Float>(plane.center.x, 0, plane.center.z)
            let localTransform = Transform(scale: .one, rotation: rotation, translation: translation)

            if var existing = planeOverlays[plane.identifier] {
                existing.model.transform = localTransform
                existing.anchor.transform = Transform(matrix: plane.transform)
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

        private static let overlayMaterial: SimpleMaterial = SimpleMaterial(
            color: UIColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 0.25),
            roughness: 0.5, isMetallic: false
        )

        private func removePlaneOverlay(id: UUID) {
            planeOverlays[id]?.anchor.removeFromParent()
            planeOverlays.removeValue(forKey: id)
        }

        func clearAllPlaneOverlays() {
            for (_, overlay) in planeOverlays {
                overlay.anchor.removeFromParent()
            }
            planeOverlays.removeAll()
            lastPlaneUpdateLog.removeAll()
        }

        // MARK: Helpers

        private static func formatTrackingState(_ state: ARCamera.TrackingState) -> String {
            switch state {
            case .normal:
                return "Normal"
            case .limited(let reason):
                return "Limited (\(reasonString(reason)))"
            case .notAvailable:
                return "Unavailable"
            @unknown default:
                return "Unknown"
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
