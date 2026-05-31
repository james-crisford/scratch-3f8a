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
                placementState: $placementState
            )
            .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                hud
                eventLog
                actionRow
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .statusBarHidden()
        .onChange(of: planeCount) { _, newValue in
            // Auto-advance "waitingForPlane" → "readyToPlaceBall" once any
            // horizontal plane is found.
            if newValue > 0, case .waitingForPlane = placementState {
                placementState = .readyToPlaceBall
            }
        }
        .onAppear {
            logger.log(.sessionStart, "Slice 2 placement view opened")
        }
        .onDisappear {
            logger.log(.sessionEnd, "Slice 2 placement view dismissed")
            logger.saveSnapshot()
        }
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
            Spacer()
            Text("AR place · Slice 2")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
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
        if trackingState.hasPrefix("Limited") { return .yellow }
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
    func placeHole(at worldPosition: SIMD3<Float>) {
        guard let arView else { return }
        holeAnchor?.removeFromParent()

        // Use a flat plane mesh instead of a 1 mm cylinder — RealityKit
        // cylinders include top/bottom caps + a (sub-pixel at 1 mm) side
        // wall that z-fights with detected plane geometry. A single quad
        // sized to the hole diameter is cleaner and cheaper. Corner
        // radius = half the side gives a perfect disc.
        let dia = Self.holeDiameter
        let mesh = MeshResource.generatePlane(width: dia, depth: dia, cornerRadius: dia / 2)
        let material = SimpleMaterial(color: .black, roughness: 0.8, isMetallic: false)
        let model = ModelEntity(mesh: mesh, materials: [material])

        // Lift the anchor (not the model) 1 mm above the plane. Lifting
        // the model after rotation would push it sideways in the model's
        // local frame, not vertically in world space.
        let anchor = AnchorEntity(world: worldPosition + SIMD3<Float>(0, 0.001, 0))
        anchor.addChild(model)
        arView.scene.addAnchor(anchor)
        holeAnchor = anchor

        if let ballWorldPosition {
            drawAimLine(from: ballWorldPosition, to: worldPosition)
        }
    }

    /// Draw a thin cylinder between ball and hole as an aim guide.
    private func drawAimLine(from: SIMD3<Float>, to: SIMD3<Float>) {
        guard let arView else { return }
        lineAnchor?.removeFromParent()

        let mid = (from + to) * 0.5
        let length = simd_distance(from, to)
        guard length > 0.001 else { return }  // skip degenerate zero-length

        let mesh = MeshResource.generateCylinder(height: length,
                                                  radius: Self.aimLineThickness)
        let material = SimpleMaterial(color: .yellow.withAlphaComponent(0.75),
                                       roughness: 0.5, isMetallic: false)
        let model = ModelEntity(mesh: mesh, materials: [material])

        // Cylinder's default axis is Y. Rotate so it points from ball→hole
        // along the horizontal direction.
        let direction = simd_normalize(to - from)
        let yAxis = SIMD3<Float>(0, 1, 0)
        let rotation: simd_quatf
        let dot = simd_dot(yAxis, direction)
        if dot > 0.9999 {
            rotation = simd_quatf(angle: 0, axis: yAxis)
        } else if dot < -0.9999 {
            rotation = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
        } else {
            let axis = simd_normalize(simd_cross(yAxis, direction))
            let angle = acos(dot)
            rotation = simd_quatf(angle: angle, axis: axis)
        }
        model.transform.rotation = rotation

        // Lift the ANCHOR by 2 mm (in world space), not the model. After
        // the rotation above, the model's local Y axis points horizontally
        // along the ball→hole direction — so a local (0, 0.002, 0) offset
        // would push the line sideways. Lifting the anchor keeps the 2 mm
        // offset truly vertical regardless of orientation.
        let anchor = AnchorEntity(world: mid + SIMD3<Float>(0, 0.002, 0))
        anchor.addChild(model)
        arView.scene.addAnchor(anchor)
        lineAnchor = anchor
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
        context.coordinator.placementState = placementState
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        // Pause the AR session so the camera + IMU stop. ARTrackingManager
        // will need to be restarted on the practice screen — that's
        // Slice 3's wiring job.
        uiView.session.pause()
        // Drop our translucent plane overlays + flush the session log to
        // disk. The view's `onDisappear` also calls saveSnapshot, but
        // doing it here too means a snapshot exists even if the SwiftUI
        // lifecycle skips onDisappear (rare, but happens with fast cover
        // dismissals during interactive transitions).
        coordinator.clearAllPlaneOverlays()
        coordinator.logger.saveSnapshot()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(trackingState: $trackingState,
                    planeCount: $planeCount,
                    placementState: $placementState,
                    logger: logger)
    }

    /// `@MainActor` so the delegate-callback bodies + handleTap can talk
    /// to the MainActor-isolated `ARPlacementScene` and read SwiftUI
    /// Bindings without crossing actor boundaries. `arView.session.
    /// delegateQueue = .main` means ARKit will call us on MainActor at
    /// runtime; the annotation makes Swift 6 strict-concurrency aware.
    @MainActor
    final class Coordinator: NSObject, ARSessionDelegate {
        @Binding var trackingState: String
        @Binding var planeCount: Int
        @Binding var placementState: ARPlacementView.PlacementState
        weak var arView: ARView?
        weak var scene: ARPlacementScene?
        let logger: ARSessionLogger

        private var detectedPlanes: Set<UUID> = []
        private var lastHUDUpdate: Date = .distantPast
        /// Race guard against rapid double-tap. The state-binding write
        /// inside `handleTap` is async (via `Task { @MainActor in ... }`),
        /// so two taps fired within the same runloop tick could both read
        /// `.readyToPlaceBall` and place a ball + a stray "hole" at the
        /// second tap's spot. The flag flips synchronously on tap entry
        /// and clears after the binding write completes.
        private var isProcessingTap: Bool = false

        /// Translucent green overlay rectangles, one per detected plane.
        /// Replaces ARKit's built-in `debugOptions = .showAnchorGeometry`
        /// which paints solid-green wireframe over every surface and made
        /// it impossible to see the floor underneath. James's exact words:
        /// "translucent so i can see how close you are to mapping the
        /// floor". Map key is the plane's anchor UUID so we can update /
        /// remove individually as ARKit grows the mesh.
        private var planeOverlays: [UUID: AnchorEntity] = [:]
        /// Throttle for `.planeUpdated` log emission. ARKit fires anchor
        /// updates at ~10 Hz per plane, which would spam the event log.
        /// We only log if 1 s has passed since the last update event for
        /// that specific plane.
        private var lastPlaneUpdateLog: [UUID: Date] = [:]

        init(trackingState: Binding<String>,
             planeCount: Binding<Int>,
             placementState: Binding<ARPlacementView.PlacementState>,
             logger: ARSessionLogger) {
            _trackingState = trackingState
            _planeCount = planeCount
            _placementState = placementState
            self.logger = logger
        }

        // MARK: ARSessionDelegate

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let now = Date()
            guard now.timeIntervalSince(lastHUDUpdate) > 0.1 else { return }
            lastHUDUpdate = now
            let status = Self.formatTrackingState(frame.camera.trackingState)
            // Log tracking-state CHANGES only (not every 100 ms tick) so
            // the event log isn't dominated by "Normal → Normal" noise.
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
                    // Log each plane add with its extent + center so the
                    // event log + JSON snapshot record what we detected.
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
            let count = detectedPlanes.count
            _planeCount.wrappedValue = count
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            // ARKit grows + refines plane meshes over time as the user
            // moves the phone. Resize our translucent overlay to track,
            // and log a throttled `.planeUpdated` event so the user can
            // SEE that mapping is still improving (not just sitting at
            // the initial detection size).
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
            let count = detectedPlanes.count
            _planeCount.wrappedValue = count
        }

        // MARK: Translucent plane visualization

        /// Create or refresh a translucent green rectangle aligned with
        /// the detected plane. Sized to `planeExtent` so the user can SEE
        /// how big the detected mesh is + how it grows over time as
        /// ARKit refines it. The rectangle is parented to an AnchorEntity
        /// at the plane's WORLD transform, with the model entity offset
        /// to the plane's local-frame center.
        private func addOrUpdatePlaneOverlay(_ plane: ARPlaneAnchor) {
            guard let arView else { return }
            let width = plane.planeExtent.width
            let depth = plane.planeExtent.height  // ARKit calls Z-extent "height"
            // Skip near-zero-extent planes — ARKit briefly emits these
            // while initialising and generatePlane(0, 0) crashes RealityKit.
            guard width > 0.01, depth > 0.01 else { return }

            let mesh = MeshResource.generatePlane(width: width, depth: depth)
            // Soft translucent green. Alpha 0.25 lets the camera feed
            // show through clearly — verified at 0.4 it looked solid in
            // the Slice 1 build that James complained about.
            let material = SimpleMaterial(
                color: UIColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 0.25),
                roughness: 0.5, isMetallic: false
            )
            let model = ModelEntity(mesh: mesh, materials: [material])
            // ARPlaneAnchor.center is in the anchor's local frame; the
            // plane lies in local XZ with Y=0, so this offset keeps the
            // overlay exactly on the detected surface.
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

        /// Called from `dismantleUIView` so we don't leak overlays after
        /// the cover is dismissed (the ARView itself is released, but
        /// explicit cleanup is cheap insurance).
        func clearAllPlaneOverlays() {
            for (_, anchor) in planeOverlays {
                anchor.removeFromParent()
            }
            planeOverlays.removeAll()
            lastPlaneUpdateLog.removeAll()
        }

        func session(_ session: ARSession, didFailWithError error: Error) {
            // Friendly handling for the common case: user denied camera
            // permission on first launch. ARError code 103 =
            // .cameraUnauthorized. Anything else surfaces the raw error.
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

        func sessionWasInterrupted(_ session: ARSession) {
            // Backgrounding mid-AR (incoming call, app switcher) fires
            // this. Surface to the HUD so the user sees the freeze isn't
            // a bug. Slice 1 has the same delegate; Slice 2 was missing
            // it on the first draft.
            logger.log(.interruption, "session interrupted")
            _trackingState.wrappedValue = "Interrupted"
        }

        func sessionInterruptionEnded(_ session: ARSession) {
            logger.log(.interruptionEnded, "session resumed")
            _trackingState.wrappedValue = "Resuming…"
        }

        // MARK: Tap → raycast → place

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            // Race guard against rapid double-tap. Set BEFORE we read
            // placementState so two near-simultaneous taps don't both
            // see .readyToPlaceBall. The bug-hunt audit flagged this
            // explicitly.
            guard !isProcessingTap else { return }
            guard let arView, let scene else { return }
            isProcessingTap = true
            defer { isProcessingTap = false }

            let point = recognizer.location(in: arView)
            logger.log(.tap, "screen \(String(format: "(%.0f, %.0f)", point.x, point.y))")

            // Raycast against existing detected horizontal planes only.
            // `.existingPlaneGeometry` ensures we hit a confirmed plane,
            // not an estimated one — important during Slice 2 verification.
            guard let query = arView.makeRaycastQuery(
                from: point,
                allowing: .existingPlaneGeometry,
                alignment: .horizontal
            ),
            let result = arView.session.raycast(query).first
            else {
                logger.log(.raycastMiss, "no horizontal plane under tap")
                // Raycast missed — tap went off-plane (ceiling, wall,
                // outside the detected mesh). Surface a HUD hint so the
                // user knows the tap WAS registered but rejected, not
                // ignored. The UX audit flagged the silent-failure case.
                let binding = _trackingState
                Task { @MainActor in
                    let current = binding.wrappedValue
                    binding.wrappedValue = "Aim at the floor"
                    // Restore the original tracking line after 1.5 s.
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if binding.wrappedValue == "Aim at the floor" {
                        binding.wrappedValue = current
                    }
                }
                return
            }

            let t = result.worldTransform
            let world = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            logger.log(.raycastHit, "hit \(ARLogFmt.vec(world))",
                       payload: ["x": String(format: "%.4f", world.x),
                                 "y": String(format: "%.4f", world.y),
                                 "z": String(format: "%.4f", world.z)])

            // Mutate the scene + the placement state based on which step
            // we're on. Direct read of `placementState` is fine because
            // the Coordinator is @MainActor and so is the Binding.
            let stateBinding = _placementState
            switch placementState {
            case .waitingForPlane:
                // Shouldn't happen because the view auto-advances once
                // planeCount > 0, but defensive: a tap before plane is
                // detected does nothing.
                logger.log(.note, "tap ignored — no plane yet")
                return
            case .readyToPlaceBall:
                scene.placeBall(at: world)
                logger.log(.ballPlaced, "ball \(ARLogFmt.vec(world))",
                           payload: ["x": String(format: "%.4f", world.x),
                                     "y": String(format: "%.4f", world.y),
                                     "z": String(format: "%.4f", world.z)])
                stateBinding.wrappedValue = .readyToPlaceHole(world)
            case .readyToPlaceHole(let ballWorld):
                scene.placeHole(at: world)
                let dist = simd_distance(ballWorld, world)
                logger.log(.holePlaced, "hole \(ARLogFmt.vec(world)) · \(ARLogFmt.meters(dist))",
                           payload: ["x": String(format: "%.4f", world.x),
                                     "y": String(format: "%.4f", world.y),
                                     "z": String(format: "%.4f", world.z),
                                     "distance_m": String(format: "%.4f", dist)])
                stateBinding.wrappedValue = .complete(ball: ballWorld, hole: world)
            case .complete:
                // Once both are placed, taps are a no-op. User must Reset
                // before placing again. Avoids accidentally moving an
                // entity by tapping the floor again.
                logger.log(.note, "tap ignored — placement complete")
                return
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
