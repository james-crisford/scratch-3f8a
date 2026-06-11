import Foundation
import simd

/// Pure-roll putt simulator.
///
/// 2D semi-implicit Euler integrator on a flat green. Maps an `ImpactResult`
/// (peakVelocity, faceAngleRaw) through the per-user calibration factor to a
/// believable ball trajectory in the green-plane frame.
///
/// Frame (synthesis §1.1):
///   +x = target line (toward cup at address)
///   +y = left of the target line (CCW positive)
///   Angles measured CCW from +x, in radians.
///
/// Sign convention (synthesis §3.3, enforced at the producer since B80):
///   `faceAngleRaw < 0` = closed face = pull = ball left of the target line.
///   `FaceAngleComputer` now guarantees this convention (it negates the raw
///   CCW-positive IMU yaw delta — see its doc block), so the internal flip
///   `ψ_0 = -faceAngleRaw` is plain frame algebra (closed → `position.y > 0`
///   = left), no longer a right-handed-user HACK. Pull/push *wording* is
///   still right-handed golf language — a left-hander's "pull" goes right —
///   which lives in MarioKartAssist, not here.
///
/// Determinism: same inputs → byte-identical outputs. No RNG, no async work,
/// no global mutable state. Implemented as a caseless enum (no instances ever
/// constructed) to make the stateless contract explicit at the call site —
/// `BallPhysics.simulatePutt(...)` reads as "call the simulator", not
/// "I need to remember a model between strokes."
///
/// References:
/// - docs/ar-replay/research-synthesis.md (every equation + coefficient)
/// - Penner, A.R. (2002) Can. J. Phys. 80(2):83-96
/// - Hogan, S.J. & Antali, M. (2025) R. Soc. Open Sci. 12(11):250907
public enum BallPhysics {

    // MARK: - Coefficients (synthesis §5.3)

    /// Gravitational acceleration, m/s². Textbook.
    public static let g: Double = 9.81

    /// Solid-sphere rolling-inertia factor 5/7. Only applied to gravity along
    /// a slope (v1.2+) — NOT to friction, because the Stimpmeter calibration
    /// already absorbs it into μ_r (synthesis §2.4).
    public static let rollInertiaFactor: Double = 5.0 / 7.0

    /// Cup radius in metres (4.25 inch / 2). Rules of Golf.
    public static let cupRadius: Double = 0.054

    /// Maximum entry speed at which the ball can drop (Holmes 1991;
    /// Hogan & Antali 2025 re-derive "1.626 m/s" verbatim).
    public static let captureVelocity: Double = 1.626

    /// Hand-velocity → ball-velocity coefficient. COR(ball-on-putter)
    /// × face-strike efficiency at putting impact speeds (Quintic Hurrion,
    /// Wadden 2014).
    public static let launchCoefficient: Double = 0.90

    /// Energy retained after the launch skid phase. 5 % loss between
    /// kinetic and rolling regimes during the first ~20 % of path
    /// (Kolkowitz 2007 / Stanford; Quintic Hurrion 5–20 % skid range
    /// collapsed to a single-step energy proxy — synthesis §1.4).
    public static let skidEnergyRetention: Double = 0.95

    /// Default integration step: 16 ms (≈ 60 fps). Semi-implicit Euler is
    /// stable for this ODE down to ~1 ms (Lee 2025), so 16 ms is a comfortable
    /// default that aligns with the render frame budget. Configurable per call.
    public static let defaultIntegrationStep: Double = 1.0 / 60.0

    /// Roll stop threshold. Sub-perceptible — 5 cm/s.
    public static let stopVelocity: Double = 0.05

    /// Default Stimpmeter reading: 10 ft (well-prepared club green).
    public static let defaultStimp: Double = 10.0

    /// Stimp clamp range. Below 4 ft is "doesn't exist" greens; above 14 ft
    /// is "lightning, unplayable for 90 %" (synthesis §2.1).
    public static let minStimp: Double = 4.0
    public static let maxStimp: Double = 14.0

    /// Hard safety ceiling on integration steps. At 16 ms / step, 60 s of
    /// sim → 3750 steps. A real putt is < 8 s. 10 000 steps is "something
    /// is wrong, bail out." Prevents runaway loops on pathological inputs.
    public static let maxIntegrationSteps: Int = 10_000

    /// Penner 2002 reference μ_r = 0.131 for the Stimpmeter "average green"
    /// of the late 1990s. Kept as documentation only — modern Stimp-10 greens
    /// use the S-dependent form below ("Penner 2002 μ_r = 0.131 for a
    /// ~4.7-ft Stimp green; NOT the right constant for Stimp 10").
    public static let pennerReferenceFriction: Double = 0.131

    // MARK: - Public types

    public struct PathSample: Sendable, Equatable {
        /// Position in metres, green-plane frame (+x = target, +y = left).
        public let position: SIMD2<Double>
        /// Velocity in m/s, same frame.
        public let velocity: SIMD2<Double>
        /// Time since launch, seconds.
        public let time: Double

        public init(position: SIMD2<Double>, velocity: SIMD2<Double>, time: Double) {
            self.position = position
            self.velocity = velocity
            self.time = time
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// Ball passed within `cupRadius` of cup centre at `≤ captureVelocity`.
        case captured
        /// Ball passed within `cupRadius` at too high a speed — kicked
        /// radially outward at `0.6 · v_entry` and continued rolling.
        case lipOut
        /// Friction brought the ball to rest below `stopVelocity`.
        case stopped
        /// Inputs rejected (non-finite, negative velocity) — empty path.
        case rejected
    }

    public struct Result: Sendable, Equatable {
        public let path: [PathSample]
        public let outcome: Outcome
        public let endPosition: SIMD2<Double>
        public let endVelocity: SIMD2<Double>
        public let totalDuration: Double

        public init(
            path: [PathSample],
            outcome: Outcome,
            endPosition: SIMD2<Double>,
            endVelocity: SIMD2<Double>,
            totalDuration: Double
        ) {
            self.path = path
            self.outcome = outcome
            self.endPosition = endPosition
            self.endVelocity = endVelocity
            self.totalDuration = totalDuration
        }

        /// Empty trajectory used for rejected / pathological inputs.
        public static let empty = Result(
            path: [],
            outcome: .rejected,
            endPosition: .zero,
            endVelocity: .zero,
            totalDuration: 0
        )
    }

    // MARK: - μ_r(S)

    /// Rolling-friction coefficient from Stimpmeter reading.
    ///
    /// `μ_r = v_stimp² / (2gS) ≈ 0.611 / S_feet` (Penner 2002, Lee 2025,
    /// Kolkowitz 2007 — three derivations agree to within 4 %). The 5/7
    /// solid-sphere factor is already absorbed (synthesis §2.4) — do NOT
    /// multiply it again on friction.
    public static func rollingFriction(stimpFeet: Double) -> Double {
        let clamped = max(minStimp, min(maxStimp, stimpFeet))
        return 0.611 / clamped
    }

    // MARK: - Simulation

    /// Simulate a flat-green putt roll.
    ///
    /// - Parameters:
    ///   - peakVelocity: Peak forward hand-velocity from `ImpactResult`, m/s.
    ///     Must be `>= 0` and finite.
    ///   - faceAngleRaw: Phone yaw delta from `ImpactResult`, signed radians.
    ///     Negative = closed face = pull left (RH user).
    ///   - speedCalibration: Per-user factor from
    ///     `CalibrationProfile.speedToDistanceFactor` that maps hand-peak
    ///     to ball-equivalent velocity. Pass 1.0 only if uncalibrated.
    ///   - stimpFeet: Green speed in feet. Clamped to `[4, 14]`. Default 10.
    ///   - startPosition: Ball start in green frame, metres. Default origin.
    ///   - cupPosition: Cup centre in green frame, metres.
    ///   - integrationStep: Δt in seconds. Default 16 ms (60 fps).
    /// - Returns: Trajectory + outcome. Pathological inputs (NaN, Inf, negative
    ///   velocity, non-positive Δt) → `.rejected` with empty path.
    public static func simulatePutt(
        peakVelocity: Double,
        faceAngleRaw: Double,
        speedCalibration: Double,
        stimpFeet: Double = defaultStimp,
        startPosition: SIMD2<Double> = .zero,
        cupPosition: SIMD2<Double>,
        integrationStep: Double = defaultIntegrationStep
    ) -> Result {

        // 1. Reject non-finite inputs. Pull peakVelocity through a separate
        //    sign check so negative-but-finite (an upstream bug, not a real
        //    putt) still returns an empty trajectory rather than rolling
        //    backwards. NaN compares false against any threshold, so the
        //    `.isFinite` gate must come first.
        guard
            peakVelocity.isFinite,
            faceAngleRaw.isFinite,
            speedCalibration.isFinite,
            stimpFeet.isFinite,
            startPosition.x.isFinite, startPosition.y.isFinite,
            cupPosition.x.isFinite, cupPosition.y.isFinite,
            integrationStep.isFinite,
            integrationStep > 0
        else {
            return .empty
        }
        guard peakVelocity >= 0 else {
            return .empty
        }

        // 2. Launch magnitude. `peakVelocity * speedCalibration` is the
        //    ball-equivalent velocity per `DistanceModel`'s calibration chain
        //    (synthesis §3.1, §8). 0.90 = COR + face efficiency, √0.95 =
        //    skid energy proxy (one-shot, not simulated).
        let v0Magnitude = peakVelocity
            * speedCalibration
            * launchCoefficient
            * sqrt(skidEnergyRetention)

        // 3. Zero-velocity short-circuit: never enter the loop with a stationary
        //    ball. Emit a single starting sample so the caller can still render
        //    "ball at rest" without a special case.
        if v0Magnitude < stopVelocity {
            let stationarySample = PathSample(
                position: startPosition,
                velocity: .zero,
                time: 0
            )
            return Result(
                path: [stationarySample],
                outcome: .stopped,
                endPosition: startPosition,
                endVelocity: .zero,
                totalDuration: 0
            )
        }

        // 4. Sign flip: face angle → green-frame azimuth (synthesis §3.3).
        //    B80: producer-enforced convention (negative = closed = pull =
        //    left), so closed → psi0 > 0 → +y = left. Pure frame algebra.
        let psi0 = -faceAngleRaw
        var velocity = SIMD2<Double>(
            v0Magnitude * cos(psi0),
            v0Magnitude * sin(psi0)
        )
        var position = startPosition

        // 5. Friction term. μ_r encodes the 5/7 factor already (synthesis §2.4).
        let mu = rollingFriction(stimpFeet: stimpFeet)
        let frictionDecel = mu * g

        // 6. Pre-size to spare the array reallocation. A typical 3-m putt at
        //    Stimp 10 lasts ~3 s ⇒ ~180 samples at 16 ms.
        var path: [PathSample] = []
        path.reserveCapacity(256)
        path.append(PathSample(position: position, velocity: velocity, time: 0))

        let dt = integrationStep
        var time: Double = 0
        var outcome: Outcome = .stopped
        // Once a lip-out occurs the final outcome stays `.lipOut` even after
        // friction subsequently brings the kicked ball to rest — the
        // interesting event is the near-miss, not where it eventually parks.
        var lipOutSeen = false
        var stepCount = 0

        // 7. Semi-implicit Euler: update velocity from current state, then
        //    advance position with the new velocity. More stable than
        //    explicit Euler for friction-dominated systems (Lee 2025) and
        //    keeps determinism trivial — pure arithmetic, no transcendentals
        //    that vary across builds.
        while stepCount < maxIntegrationSteps {
            let speed = simd_length(velocity)

            // Stop condition: rolled below the perception threshold.
            if speed < stopVelocity {
                outcome = lipOutSeen ? .lipOut : .stopped
                break
            }

            // WHY: friction always opposes the instantaneous velocity vector.
            // Curved trajectories on slopes (v1.2) emerge from this naturally
            // because the friction direction changes with v. On a flat green
            // the velocity direction is constant, so this reduces to scalar
            // deceleration along v_0.
            let frictionDir = velocity / speed
            let acceleration = -frictionDecel * frictionDir

            // Semi-implicit Euler step.
            let nextVelocity = velocity + acceleration * dt
            let nextSpeed = simd_length(nextVelocity)

            // Guard: friction overshoots stationary in one step → snap to
            // rest. Prevents the ball from reversing direction at the
            // tail of the roll (a classic semi-implicit Euler artefact for
            // damping-only systems).
            let velocityAfterStep: SIMD2<Double>
            if simd_dot(nextVelocity, velocity) < 0 || nextSpeed < stopVelocity {
                velocityAfterStep = .zero
            } else {
                velocityAfterStep = nextVelocity
            }

            let nextPosition = position + velocityAfterStep * dt

            // 8. Cup intersection: does the segment `position → nextPosition`
            //    pass within `cupRadius` of `cupPosition`? Use closest-point-
            //    on-segment to avoid missing fast passes where the segment
            //    spans more than the cup diameter in a single step.
            if let entrySpeed = segmentCupEntrySpeed(
                from: position,
                to: nextPosition,
                cup: cupPosition,
                velocityIn: velocity,
                velocityOut: velocityAfterStep
            ) {
                time += dt
                if entrySpeed <= captureVelocity {
                    // Capture: snap to cup centre at rest.
                    path.append(PathSample(
                        position: cupPosition,
                        velocity: .zero,
                        time: time
                    ))
                    outcome = .captured
                    position = cupPosition
                    velocity = .zero
                    break
                } else {
                    // Lip-out (synthesis §1.7 v1 engineering fit): kick the
                    // ball radially outward at 0.6 · v_entry and keep rolling.
                    // Snap the position fully clear of the cup disc so the
                    // segment check on the next step doesn't re-trigger
                    // lip-out forever (the kick keeps the ball moving but
                    // a single dt may not carry it clear of the 5.4 cm disc).
                    let delta = nextPosition - cupPosition
                    let deltaLen = simd_length(delta)
                    let outward: SIMD2<Double>
                    if deltaLen > 1e-9 {
                        outward = delta / deltaLen
                    } else {
                        // Direct centre hit: kick back along the inbound axis.
                        let inSpeed = simd_length(velocity)
                        outward = inSpeed > 1e-9 ? -velocity / inSpeed : SIMD2<Double>(1, 0)
                    }
                    velocity = outward * (entrySpeed * 0.6)
                    // Push position 1 cm clear of the disc edge so the next
                    // segment check starts outside.
                    position = cupPosition + outward * (cupRadius + 0.01)
                    path.append(PathSample(
                        position: position,
                        velocity: velocity,
                        time: time
                    ))
                    outcome = .lipOut
                    lipOutSeen = true
                    stepCount += 1
                    continue
                }
            }

            position = nextPosition
            velocity = velocityAfterStep
            time += dt
            stepCount += 1
            path.append(PathSample(position: position, velocity: velocity, time: time))
        }

        // If the integration ran out of steps (pathological input), still
        // surface a lip-out we saw before timing out — it remains the most
        // informative outcome.
        if outcome == .stopped, lipOutSeen {
            outcome = .lipOut
        }

        return Result(
            path: path,
            outcome: outcome,
            endPosition: position,
            endVelocity: velocity,
            totalDuration: time
        )
    }

    // MARK: - Geometry helpers

    /// Closest distance from the cup centre to the segment `from → to`,
    /// and if that distance is `<= cupRadius`, the ball's speed at the
    /// moment of closest approach (linearly interpolated between
    /// `velocityIn` and `velocityOut`). Returns nil if the segment does
    /// not enter the cup disc.
    private static func segmentCupEntrySpeed(
        from: SIMD2<Double>,
        to: SIMD2<Double>,
        cup: SIMD2<Double>,
        velocityIn: SIMD2<Double>,
        velocityOut: SIMD2<Double>
    ) -> Double? {
        let segment = to - from
        let segLenSq = simd_dot(segment, segment)
        guard segLenSq > 1e-12 else {
            // Degenerate segment — treat as point.
            let dist = simd_length(from - cup)
            return dist <= cupRadius ? simd_length(velocityIn) : nil
        }
        // Parametric closest approach: t in [0, 1].
        let toCup = cup - from
        let tRaw = simd_dot(toCup, segment) / segLenSq
        let t = max(0.0, min(1.0, tRaw))
        let closest = from + segment * t
        let dist = simd_length(closest - cup)
        guard dist <= cupRadius else { return nil }
        // Linearly interpolate the velocity vector at parameter t.
        let velocityAtClosest = velocityIn + (velocityOut - velocityIn) * t
        return simd_length(velocityAtClosest)
    }
}
