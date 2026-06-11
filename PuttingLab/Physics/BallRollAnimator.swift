import Foundation
import simd
import RealityKit
import QuartzCore

/// B67 — events emitted while the .captured drop animation runs. Plumbed
/// through BallRollAnimator.start so the AR view can route them into
/// ARSessionLogger as JSON events (ballDropTriggered / ballDropCompleted).
/// Without this, Wave 1 found, the pre-B67 logs had no signal for whether
/// the drop ran — only the final outcome.
enum BallDropEvent {
    case triggered(targetY: Float, startY: Float)
    case completed
}

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
    /// B67 — cache hole world-frame Y captured at start() so the drop
    /// animation targets the actual cup's vertical position. Pre-B67
    /// dropBallIntoCup hardcoded targetY = -cupDepth/2 in absolute world
    /// Y, which only happens to land in the cup when ARKit's world frame
    /// origin coincides with the floor. If the user re-localised or the
    /// world Y drifted, the ball would "drop" to a Y that no longer sits
    /// inside the cup geometry. AR7 stroke 5 (.captured outcome) showed
    /// the ball reach the cup mouth and then "disappear" rather than
    /// visibly drop — Wave 1+4 traced it to this mismatch.
    private var holeWorldY: Float = 0
    /// B67 — observer for drop-animation events (triggered/completed).
    /// Plain closure so this stays free of higher-level types; the caller
    /// (ARPlacementView) routes the call into ARSessionLogger.
    private var dropObserver: ((BallDropEvent) -> Void)?

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
                dropObserver: ((BallDropEvent) -> Void)? = nil,
                onComplete: @escaping (BallPhysics.Outcome, Double) -> Void) {
        cancel()
        // B67 — store hole world Y so dropBallIntoCup lands inside the
        // cup regardless of world-frame Y drift / re-localisation.
        self.holeWorldY = holeWorld.y
        self.dropObserver = dropObserver

        // Compute aim direction in the horizontal plane.
        let aimVec = SIMD3<Float>(holeWorld.x - ballWorld.x, 0,
                                   holeWorld.z - ballWorld.z)
        let aimLen = simd_length(aimVec)
        guard aimLen > 0.01 else {
            onComplete(.rejected, 0)
            return
        }
        let aim = aimVec / aimLen
        // B80 — TRUE left of the aim line via the shared GreenFrame helper.
        // The pre-B80 hand-rolled (-aim.z, 0, aim.x) was aim × up = RIGHT of
        // aim in ARKit's +Y-up frame, mirroring every roll across the target
        // line (b79 video: 3/3 putts rendered right while labelled "pull").
        let perp = GreenFrame.leftPerp(of: aim)

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
        dropObserver = nil
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
                    let local = localPos(from: last.position)
                    let world = worldPos(from: last.position)
                    ballEntity.position = local
                    trailEmitter?(world)
                    // B63 — when the ball is CAPTURED, animate it
                    // descending into the cup over ~350ms. Workflow
                    // audit flagged that on outcome=.captured the
                    // ball stayed at floor-level Y, so "drained" felt
                    // identical to "stopped right next to the cup".
                    if outcome == .captured {
                        // B67 — emit a trigger event so ARSessionLogger
                        // can confirm in JSON whether the drop animation
                        // actually ran. Pre-B67 AR7 stroke 5 was tagged
                        // .captured but Gemini saw the ball "disappear"
                        // at the cup mouth — without observability we
                        // couldn't tell whether dropBallIntoCup was even
                        // invoked or only the math was wrong.
                        // B76 — startY is now the LOCAL ball-entity Y
                        // (`local.y`), matching the frame `ballEntity.position`
                        // lives in. The drop animation mutates that
                        // local Y down toward `targetY` (also local).
                        let dropTargetLocal = (holeWorldY - ballStart.y) - Self.cupDepth / 2
                        dropObserver?(.triggered(targetY: dropTargetLocal,
                                                  startY: local.y))
                        await dropBallIntoCup(ballEntity: ballEntity,
                                                startY: local.y,
                                                trailEmitter: trailEmitter)
                        dropObserver?(.completed)
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
            ballEntity.position = localPos(from: interp)
            trailEmitter?(worldPos(from: interp))

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
        // B67 — target derived from the captured holeWorldY so the descent
        // lands inside the cup geometry even when the world-Y origin does
        // not coincide with floor=0. B80 — converted to the BALL ANCHOR'S
        // LOCAL frame: `ballEntity.position` is local to its anchor (B76),
        // so the pre-B80 world-frame value (holeWorldY − cupDepth/2)
        // would have dropped the ball ~0.85 m BELOW the floor in the b79
        // session's frame (floor at world −0.853). Gemini review caught
        // this; the .triggered observer event already computed the local
        // form — the animation now matches it.
        let targetY: Float = (holeWorldY - ballStart.y) - Self.cupDepth / 2
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
            // B80 — the emitter contract is WORLD coords (the roll loop
            // passes worldPos(from:)); `p` is anchor-local, so convert.
            // Pre-B80 this passed `p` raw — trail dots during the drop
            // phase rendered at wrong x/z whenever the anchor wasn't at
            // the world origin.
            trailEmitter?(ballStart + p)
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
    /// Roll position in the BALL ANCHOR'S LOCAL FRAME.
    ///
    /// B76 fix — `ballEntity` is `ballAnchor.children.first`; its
    /// `.position` is local to the anchor, not world. The pre-B76 code
    /// computed `ballStart + along + across` (a WORLD-frame coordinate)
    /// and assigned it to the local `.position`, which RealityKit then
    /// added to the anchor's already-world position. Net: X and Z were
    /// doubled (ball "rolled" 2x its real distance), and Y was pinned to
    /// `Self.ballYLift` absolute regardless of where the anchor sat
    /// (this is the "ball into the ground" James saw on AR8 — ballStart.y
    /// was non-zero, but `world.y = ballYLift` forced the ball to drop
    /// to that absolute height the instant the roll started).
    ///
    /// Returns just `along + across` plus the local Y lift. The anchor
    /// already sits at the placement point — we only need to express
    /// movement RELATIVE TO IT.
    private func localPos(from p: SIMD2<Double>) -> SIMD3<Float> {
        let along = aimUnit * Float(p.x)
        let across = perpUnit * Float(p.y)
        var local = along + across
        local.y = Self.ballYLift
        return local
    }

    /// The same point in WORLD coordinates — used for the trail emitter
    /// + the captured-drop animation, both of which place entities in
    /// scene space (not anchor space). `ballStart` is the anchor's
    /// world position, captured at `start()`.
    private func worldPos(from p: SIMD2<Double>) -> SIMD3<Float> {
        var w = ballStart + localPos(from: p)
        // ballStart.y is the raycast hit (i.e., the actual AR plane Y),
        // and `localPos` returned just `ballYLift` on Y. So the world Y
        // here is `ballStart.y + ballYLift` — the ball's centre sits one
        // radius above the detected floor, anywhere the anchor was placed.
        w.y = ballStart.y + Self.ballYLift
        return w
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
