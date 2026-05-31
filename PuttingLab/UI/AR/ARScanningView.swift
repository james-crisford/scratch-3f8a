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
    @State private var sessionStartedAt: Date = Date()
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
                eventLog
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .statusBarHidden()
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            sessionElapsedSeconds = Int(Date().timeIntervalSince(sessionStartedAt))
        }
        .onAppear {
            logger.log(.sessionStart, "Slice 1 scanning view opened")
        }
        .onDisappear {
            logger.log(.sessionEnd, "Slice 1 scanning view dismissed")
            logger.saveSnapshot()
        }
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
                    logger.saveSnapshot()
                    logger.log(.note, "Snapshot saved manually")
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
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: d)
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
        if trackingState.hasPrefix("Limited") { return .yellow }
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
        uiView.session.pause()
        // Drop overlays + flush snapshot. Mirrors Slice 2's dismantle.
        coordinator.clearAllPlaneOverlays()
        coordinator.logger.saveSnapshot()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(trackingState: $trackingState,
                    planeCount: $planeCount,
                    logger: logger)
    }

    /// `@MainActor` so the delegate-callback bodies can talk to the
    /// MainActor-isolated `ARSessionLogger` + write SwiftUI Bindings
    /// without crossing actor boundaries. `arView.session.delegateQueue
    /// = .main` means ARKit will call us on MainActor at runtime; the
    /// annotation makes Swift 6 strict-concurrency aware.
    @MainActor
    final class Coordinator: NSObject, ARSessionDelegate {
        @Binding var trackingState: String
        @Binding var planeCount: Int
        let logger: ARSessionLogger
        weak var arView: ARView?

        /// Plane anchor IDs currently tracked. We hold the set so add /
        /// remove events keep `planeCount` correct without re-counting
        /// the entire ARSession.anchors array on every frame.
        private var detectedPlanes: Set<UUID> = []
        /// Last time we pushed a tracking-state update to the HUD.
        /// 10 Hz is enough for the user to see changes — full 60 Hz
        /// would flicker the string between frames mid-state-transition.
        private var lastHUDUpdate: Date = .distantPast
        /// Translucent green overlay per detected plane. Same approach
        /// as Slice 2 — see comments on the matching field there.
        private var planeOverlays: [UUID: AnchorEntity] = [:]
        /// Throttle for `.planeUpdated` log emission — see Slice 2 for
        /// the rationale (ARKit fires updates at ~10 Hz per plane).
        private var lastPlaneUpdateLog: [UUID: Date] = [:]

        init(trackingState: Binding<String>,
             planeCount: Binding<Int>,
             logger: ARSessionLogger) {
            _trackingState = trackingState
            _planeCount = planeCount
            self.logger = logger
        }

        // MARK: ARSessionDelegate

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let now = Date()
            guard now.timeIntervalSince(lastHUDUpdate) > 0.1 else { return }
            lastHUDUpdate = now

            let status = Self.formatTrackingState(frame.camera.trackingState)
            if status != _trackingState.wrappedValue {
                logger.log(.trackingState, status)
            }
            _trackingState.wrappedValue = status
        }

        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
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

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
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

        func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
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

        func sessionWasInterrupted(_ session: ARSession) {
            logger.log(.interruption, "session interrupted")
            _trackingState.wrappedValue = "Interrupted"
        }

        func sessionInterruptionEnded(_ session: ARSession) {
            logger.log(.interruptionEnded, "session resumed")
            _trackingState.wrappedValue = "Resuming…"
        }

        func session(_ session: ARSession, didFailWithError error: Error) {
            let nsErr = error as NSError
            let message: String
            if nsErr.domain == ARError.errorDomain,
               nsErr.code == ARError.Code.cameraUnauthorized.rawValue {
                message = "Camera denied. Settings → PuttingLab → Camera."
            } else {
                message = "Failed: \(nsErr.localizedDescription)"
            }
            logger.log(.failed, message,
                       payload: ["domain": nsErr.domain, "code": "\(nsErr.code)"])
            _trackingState.wrappedValue = message
        }

        // MARK: Translucent plane visualization (matches Slice 2)

        private func addOrUpdatePlaneOverlay(_ plane: ARPlaneAnchor) {
            guard let arView else { return }
            let width = plane.planeExtent.width
            let depth = plane.planeExtent.height
            guard width > 0.01, depth > 0.01 else { return }

            let mesh = MeshResource.generatePlane(width: width, depth: depth)
            let material = SimpleMaterial(
                color: UIColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 0.25),
                roughness: 0.5, isMetallic: false
            )
            let model = ModelEntity(mesh: mesh, materials: [material])
            model.position = SIMD3<Float>(plane.center.x, 0, plane.center.z)

            if let existing = planeOverlays[plane.identifier] {
                existing.children.removeAll()
                existing.addChild(model)
                existing.transform = Transform(matrix: plane.transform)
            } else {
                let anchor = AnchorEntity(world: plane.transform)
                anchor.addChild(model)
                arView.scene.addAnchor(anchor)
                planeOverlays[plane.identifier] = anchor
            }
        }

        private func removePlaneOverlay(id: UUID) {
            planeOverlays[id]?.removeFromParent()
            planeOverlays.removeValue(forKey: id)
        }

        func clearAllPlaneOverlays() {
            for (_, anchor) in planeOverlays {
                anchor.removeFromParent()
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
