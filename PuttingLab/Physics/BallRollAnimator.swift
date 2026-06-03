import Foundation
import simd
import RealityKit
import QuartzCore

/// Ball-roll animator for Stage 3 Slice 3.4 (B49).
///
/// Drives the AR ball entity along a `BallPhysics.Result` path
/// at 60 Hz. Translates between the AR scene's world frame
/// (X/Y/Z, Y up) and `BallPhysics`'s green-plane 2D frame
/// (X = target line, Y = perpendicular to target, both in the
/// horizontal plane).
///
/// The animator is the SOLE driver of the ball entity's
/// `position` once `start` is called. The caller MUST disarm
/// the StrokeCapture before kicking this off so subsequent IMU
/// samples don't trigger a second roll while one is in flight.
///
/// On completion, the animator invokes `onComplete` with the
/// final `BallPhysics.Outcome` so the View can transition to
/// the result-panel state (B50).
@MainActor
final class BallRollAnimator {

    /// Ball-radius lift so the sphere centre sits ON the floor,
    /// not in it. Matches `ARPlacementScene.ballDiameter / 2`.
    private static let ballYLift: Float = 0.0427 / 2

    /// Render frame budget for the 60 Hz tick. CADisplayLink
    /// targets 60 fps; we drive the ball position from a fixed-
    /// step timer rather than per-sample so the animation is
    /// independent of `BallPhysics` integration step (which can
    /// be tuned lower for accuracy).
    private static let frameInterval: TimeInterval = 1.0 / 60.0

    private weak var ballEntity: Entity?
    private var path: [BallPhysics.PathSample] = []
    private var outcome: BallPhysics.Outcome = .rejected
    private var ballStart: SIMD3<Float> = .zero
    private var aimUnit: SIMD3<Float> = SIMD3<Float>(1, 0, 0)
    private var perpUnit: SIMD3<Float> = SIMD3<Float>(0, 0, 1)
    private var startWallClock: TimeInterval = 0
    private var totalDuration: TimeInterval = 0
    private var task: Task<Void, Never>?
    private var trailEmitter: ((SIMD3<Float>) -> Void)?
    private var onComplete: ((BallPhysics.Outcome, Double) -> Void)?

    init() {}

    /// Run a simulated putt. Translates the impact result + ball
    /// world coord + hole world coord into the `BallPhysics`
    /// 2D frame, calls `BallPhysics.simulatePutt`, then drives
    /// the ball entity at 60 Hz.
    ///
    /// - Parameters:
    ///   - ballEntity: The RealityKit entity wrapping the ball
    ///     sphere; its parent transform stays anchored to the
    ///     world via `AnchorEntity(world:)`, so we mutate the
    ///     entity's local `.position` which is then world-space.
    ///   - ballWorld: Ball world coord at swing time.
    ///   - holeWorld: Hole world coord at swing time.
    ///   - impact: `ImpactResult` from the just-detected stroke.
    ///   - speedCalibration: Per-user factor; 1.0 if uncalibrated.
    ///   - stimpFeet: Green speed. Default 10 ft.
    ///   - trailEmitter: Optional closure invoked once per frame
    ///     with the current world position — caller can drop
    ///     fading trail markers for the Stage 3 spec's "trail of
    ///     fading translucent yellow markers" effect.
    ///   - onComplete: Fired when the ball stops. Passes the
    ///     `BallPhysics.Outcome` + total duration in seconds.
    func start(ballEntity: Entity,
                ballWorld: SIMD3<Float>,
                holeWorld: SIMD3<Float>,
                impact: ImpactResult,
                speedCalibration: Double = 1.0,
                stimpFeet: Double = BallPhysics.defaultStimp,
                trailEmitter: ((SIMD3<Float>) -> Void)? = nil,
                onComplete: @escaping (BallPhysics.Outcome, Double) -> Void) {
        cancel()

        // Compute aim direction in the horizontal plane.
        let aimVec = SIMD3<Float>(holeWorld.x - ballWorld.x, 0,
                                   holeWorld.z - ballWorld.z)
        let aimLen = simd_length(aimVec)
        guard aimLen > 0.01 else {
            onComplete(.rejected, 0)
            return
        }
        let aim = aimVec / aimLen
        let perp = SIMD3<Float>(-aim.z, 0, aim.x)

        // Run the simulator. Target line distance = aimLen.
        // Cup at (aimLen, 0) in the 2D frame; ball starts at origin.
        let cup2D = SIMD2<Double>(Double(aimLen), 0)
        let result = BallPhysics.simulatePutt(
            peakVelocity: impact.peakVelocity,
            faceAngleRaw: impact.faceAngleRaw,
            speedCalibration: speedCalibration,
            stimpFeet: stimpFeet,
            startPosition: .zero,
            cupPosition: cup2D
        )

        guard !result.path.isEmpty else {
            onComplete(result.outcome, 0)
            return
        }

        // Cache state for the animation loop.
        self.ballEntity = ballEntity
        self.path = result.path
        self.outcome = result.outcome
        self.ballStart = ballWorld
        self.aimUnit = aim
        self.perpUnit = perp
        self.totalDuration = result.totalDuration
        self.trailEmitter = trailEmitter
        self.onComplete = onComplete
        self.startWallClock = CACurrentMediaTime()

        // 60 Hz animation task.
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Cancel the in-flight roll. Resets internal state; the
    /// ball entity is left at whatever position the loop last
    /// wrote. Caller should re-position if needed.
    func cancel() {
        task?.cancel()
        task = nil
        path.removeAll()
        trailEmitter = nil
        onComplete = nil
    }

    private func runLoop() async {
        guard let ballEntity else { return }
        while !Task.isCancelled {
            let now = CACurrentMediaTime()
            let t = now - startWallClock

            // Find the path sample bracketing time `t` and lerp
            // between them. PathSample.time is seconds since
            // launch.
            if t >= totalDuration {
                // Snap to final sample and end.
                if let last = path.last {
                    let world = worldPos(from: last.position)
                    ballEntity.position = world
                    trailEmitter?(world)
                    // B63 — when the ball is CAPTURED, animate it
                    // descending into the cup over ~350ms. Workflow
                    // audit flagged that on outcome=.captured the
                    // ball stayed at floor-level Y, so "drained" felt
                    // identical to "stopped right next to the cup".
                    if outcome == .captured {
                        await dropBallIntoCup(ballEntity: ballEntity,
                                                startY: world.y,
                                                trailEmitter: trailEmitter)
                    }
                }
                onComplete?(outcome, totalDuration)
                onComplete = nil
                return
            }

            // Binary search the bracketing samples. Path is
            // already time-ordered with monotonic `time`.
            let (lo, hi) = bracketingIndices(at: t)
            let pLo = path[lo]
            let pHi = path[hi]
            let span = pHi.time - pLo.time
            let alpha = span > 1e-9 ? (t - pLo.time) / span : 0
            let interp = pLo.position + (pHi.position - pLo.position) * alpha
            let world = worldPos(from: interp)
            ballEntity.position = world
            trailEmitter?(world)

            try? await Task.sleep(nanoseconds: UInt64(Self.frameInterval * 1_000_000_000))
        }
    }

    /// B64 — cup depth used to derive the drop target. Was hardcoded
    /// as -0.04 (literally `-0.08 / 2` accidentally correct against
    /// ARPlacementView.holeDepth = 0.08). Workflow audit flagged the
    /// magic number as a maintenance trap if cup depth ever tunes.
    private static let cupDepth: Float = 0.08

    /// B63 — drop the captured ball into the cup over ~350ms.
    /// Animates Y from the floor-lifted position down to roughly the
    /// middle of the regulation 8cm cup, so "drained" has a satisfying
    /// visual landing. Includes a slight ease-out (cube of progress)
    /// so the ball decelerates as it settles.
    ///
    /// B64 — accepts ballEntity as non-optional + guards inside, so
    /// even if the caller deallocates the wrapping weak ref during
    /// the 350ms drop the loop can no-op cleanly.
    private func dropBallIntoCup(ballEntity: Entity,
                                  startY: Float,
                                  trailEmitter: ((SIMD3<Float>) -> Void)?) async {
        let dropDurationS: Double = 0.35
        let targetY: Float = -Self.cupDepth / 2  // ~half-way into the cup
        let frames = Int(dropDurationS / Self.frameInterval)
        let startWall = CACurrentMediaTime()
        for _ in 0..<frames {
            if Task.isCancelled { return }
            // B64 — defensive: if the entity's parent (anchor) was
            // deallocated mid-drop, abort early. Entity itself is a
            // class but its scene attachment could become invalid.
            guard ballEntity.parent != nil else { return }
            let t = CACurrentMediaTime() - startWall
            let raw = Float(min(1.0, t / dropDurationS))
            let eased = 1 - pow(1 - raw, 3)  // ease-out cubic
            var p = ballEntity.position
            p.y = startY + (targetY - startY) * eased
            ballEntity.position = p
            trailEmitter?(p)
            try? await Task.sleep(nanoseconds: UInt64(Self.frameInterval * 1_000_000_000))
            if raw >= 1.0 { break }
        }
        // Snap final position so float-drift doesn't leave us slightly
        // off-centre.
        guard ballEntity.parent != nil else { return }
        var p = ballEntity.position
        p.y = targetY
        ballEntity.position = p
    }

    /// Convert a 2D green-frame position into AR world coords.
    /// In the green frame: x = along target line (toward cup),
    /// y = perpendicular (left). World mapping uses the cached
    /// `aimUnit` + `perpUnit` orthonormal pair.
    private func worldPos(from p: SIMD2<Double>) -> SIMD3<Float> {
        let along = aimUnit * Float(p.x)
        let across = perpUnit * Float(p.y)
        var world = ballStart + along + across
        world.y = Self.ballYLift
        return world
    }

    /// Binary search for two adjacent path samples that bracket
    /// time `t`. Assumes `path` is non-empty and sorted by time.
    private func bracketingIndices(at t: Double) -> (Int, Int) {
        if t <= path[0].time { return (0, min(1, path.count - 1)) }
        if t >= path.last!.time {
            let last = path.count - 1
            return (last, last)
        }
        var lo = 0, hi = path.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if path[mid].time <= t {
                lo = mid
            } else {
                hi = mid
            }
        }
        return (lo, hi)
    }
}
