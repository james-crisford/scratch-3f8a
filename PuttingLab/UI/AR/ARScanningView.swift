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

    /// HUD state. Updated from the ARSession delegate via main-actor
    /// dispatch. Throttled to ~10 Hz in the coordinator to stop the
    /// status string flickering at 60 fps.
    @State private var trackingState: String = "Starting…"
    @State private var planeCount: Int = 0
    @State private var sessionElapsedSeconds: Int = 0
    @State private var sessionStartedAt: Date = Date()

    var body: some View {
        ZStack {
            ARSceneRepresentable(
                trackingState: $trackingState,
                planeCount: $planeCount
            )
            .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                hud
                    .padding(.horizontal)
                    .padding(.bottom, 24)
            }
        }
        .statusBarHidden()
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            sessionElapsedSeconds = Int(Date().timeIntervalSince(sessionStartedAt))
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
            .padding(.leading, 16)
            .padding(.top, 12)

            Spacer()

            Text("AR scan · Slice 1")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(.trailing, 16)
                .padding(.top, 12)
        }
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
        // resume normal stroke-detection. Slice 2 fixes this with an
        // explicit pause/resume around the cover presentation.
        let arView = ARView(frame: .zero,
                            cameraMode: .ar,
                            automaticallyConfigureSession: false)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .none      // power saving — we don't render PBR yet
        config.frameSemantics = []               // no body / people-occlusion semantics yet
        // Pin the delegate queue to main so our delegate callbacks
        // happen on MainActor by default and the `detectedPlanes` set
        // is mutated serially. The Task { @MainActor in ... } wrappers
        // for the binding writes are belt-and-braces.
        arView.session.delegateQueue = .main
        arView.session.delegate = context.coordinator
        arView.session.run(config, options: [])
        // Visualize detected anchors during Slice 1 so we can SEE plane
        // detection working. We'll swap this for proper RealityKit
        // anchored content in Slice 2+.
        arView.debugOptions = [.showAnchorGeometry, .showAnchorOrigins]
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
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(trackingState: $trackingState, planeCount: $planeCount)
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        @Binding var trackingState: String
        @Binding var planeCount: Int

        /// Plane anchor IDs currently tracked. We hold the set so add /
        /// remove events keep `planeCount` correct without re-counting
        /// the entire ARSession.anchors array on every frame.
        private var detectedPlanes: Set<UUID> = []
        /// Last time we pushed a tracking-state update to the HUD.
        /// 10 Hz is enough for the user to see changes — full 60 Hz
        /// would flicker the string between frames mid-state-transition.
        private var lastHUDUpdate: Date = .distantPast

        init(trackingState: Binding<String>, planeCount: Binding<Int>) {
            _trackingState = trackingState
            _planeCount = planeCount
        }

        // MARK: ARSessionDelegate

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let now = Date()
            guard now.timeIntervalSince(lastHUDUpdate) > 0.1 else { return }
            lastHUDUpdate = now

            let status = Self.formatTrackingState(frame.camera.trackingState)
            Task { @MainActor [weak self] in
                self?.trackingState = status
            }
        }

        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            var added = 0
            for a in anchors where a is ARPlaneAnchor {
                if detectedPlanes.insert(a.identifier).inserted { added += 1 }
            }
            guard added > 0 else { return }
            let count = detectedPlanes.count
            Task { @MainActor [weak self] in
                self?.planeCount = count
            }
        }

        func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
            var removed = 0
            for a in anchors {
                if detectedPlanes.remove(a.identifier) != nil { removed += 1 }
            }
            guard removed > 0 else { return }
            let count = detectedPlanes.count
            Task { @MainActor [weak self] in
                self?.planeCount = count
            }
        }

        func sessionWasInterrupted(_ session: ARSession) {
            Task { @MainActor [weak self] in
                self?.trackingState = "Interrupted"
            }
        }

        func sessionInterruptionEnded(_ session: ARSession) {
            Task { @MainActor [weak self] in
                self?.trackingState = "Resuming…"
            }
        }

        func session(_ session: ARSession, didFailWithError error: Error) {
            let message = (error as NSError).localizedDescription
            Task { @MainActor [weak self] in
                self?.trackingState = "Failed: \(message)"
            }
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
