import Foundation
import simd
@testable import PuttingLab

// Data-driven experiments over the 192 recorded strokes + deterministic
// fuzzing of the pure mechanics. All conclusions must trace to the REAL
// compiled production code — no ports, no reimplementations.

// MARK: - live: LiveImpactDetector replay vs stored user judgments

@MainActor
func cmdLive(_ paths: [String]) {
    let (ok, failed) = replayAll(collectJSONs(paths))
    print("=== plab live — production LiveImpactDetector replayed over recorded strokes ===")
    print("mode A: session-latched (forceWarmUp once, reset per stroke — mirrors AR flow)")
    print("mode B: cold detector per stroke (no forceWarmUp — natural warm-up only)")
    print("")
    print("file,judgment,windowMs,A_fires,A_firstMs,B_fires,B_firstMs")

    let sessionDetector = LiveImpactDetector()
    sessionDetector.forceWarmUp()

    struct Row {
        let judgment: String
        let aFires: Int
        let aFirst: Double
        let bFires: Int
    }
    var rows: [Row] = []

    for r in ok {
        let samples = r.replay.toStrokeWindow().samples
        guard let t0 = samples.first?.timestamp else { continue }
        let windowMs = (samples[samples.count - 1].timestamp - t0) * 1000

        sessionDetector.reset()
        var aFireTimes: [Double] = []
        for s in samples where sessionDetector.consume(s) {
            aFireTimes.append((s.timestamp - t0) * 1000)
        }

        let cold = LiveImpactDetector()
        var bFireTimes: [Double] = []
        for s in samples where cold.consume(s) {
            bFireTimes.append((s.timestamp - t0) * 1000)
        }

        let judgment = r.replay.userImpactJudgment ?? "-"
        rows.append(Row(
            judgment: judgment,
            aFires: aFireTimes.count,
            aFirst: aFireTimes.first ?? .nan,
            bFires: bFireTimes.count
        ))
        print("\(r.url.lastPathComponent),\(judgment),\(f(windowMs, 0)),\(aFireTimes.count),\(aFireTimes.first.map { f($0, 0) } ?? "-"),\(bFireTimes.count),\(bFireTimes.first.map { f($0, 0) } ?? "-")")
    }

    print("")
    print("--- summary: fires per stroke (mode A, session-latched) x stored judgment ---")
    let judgments = Set(rows.map { $0.judgment }).sorted()
    for j in judgments {
        let sub = rows.filter { $0.judgment == j }
        let byFires = Dictionary(grouping: sub, by: { $0.aFires })
            .map { "\($0.key) fires: \($0.value.count)" }
            .sorted()
            .joined(separator: ", ")
        let firsts = sub.filter { $0.aFires > 0 }.map { $0.aFirst }.sorted()
        let med = firsts.isEmpty ? Double.nan : firsts[firsts.count / 2]
        print("\(j) (n=\(sub.count)): \(byFires); median first-fire \(f(med, 0)) ms")
    }
    let coldMisses = rows.filter { $0.bFires == 0 && $0.aFires > 0 }.count
    print("cold-per-stroke (mode B) misses that session-latch (mode A) catches: \(coldMisses)")
    if failed.count > 0 { print("decode failures: \(failed.count)") }
}

// MARK: - fuzz: deterministic invariant fuzzing of the pure mechanics

struct LCG {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 2862933555777941757 &+ 3037000493 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + next() * (hi - lo) }
}

func cmdFuzz(_ opts: [String: String]) {
    let n = Int(opts["--n"] ?? "") ?? 20_000
    var rng = LCG(seed: UInt64(opts["--seed"].flatMap { UInt64($0) } ?? 42))
    var violations: [String] = []

    print("=== plab fuzz — invariant fuzzing of HEAD-compiled mechanics (seed deterministic, n=\(n)) ===")

    // --- BallPhysics invariants ---
    var outcomes: [String: Int] = [:]
    for i in 0..<n {
        let v = rng.range(0, 5.4)                       // crosses the 5.0 spike gate
        let face = rng.range(-0.6, 0.6)
        let cal = rng.range(0.5, 40)
        let stimp = rng.range(3, 15)                    // crosses the 4...14 clamp
        let cupX = rng.next() < 0.02 ? 0.0 : rng.range(0.15, 6)  // 2%: cup at start
        // Alternate every other iteration between the legacy hole model
        // and the shipped HoleModel v1.1 candidates so invariants hold
        // under BOTH parameterisations.
        let useV11 = i % 2 == 1
        let sim = BallPhysics.simulatePutt(
            peakVelocity: v, faceAngleRaw: face, speedCalibration: cal,
            stimpFeet: stimp, cupPosition: SIMD2<Double>(cupX, 0),
            captureShrink: useV11 ? BallPhysics.HoleModel.captureShrink : 1.0,
            lipOutForwardBias: useV11 ? BallPhysics.HoleModel.lipOutForwardBias : 0.0,
            lipOutSpeedRetention: useV11 ? BallPhysics.HoleModel.lipOutSpeedRetention : 0.6)
        let tag = String(describing: sim.outcome)
        outcomes[tag, default: 0] += 1

        func flag(_ msg: String) {
            if violations.count < 25 {
                violations.append("[ball #\(i)] v=\(v) face=\(face) cal=\(cal) stimp=\(stimp) cupX=\(cupX): \(msg)")
            } else if violations.count == 25 {
                violations.append("... further violations suppressed")
            }
        }

        let finite = sim.endPosition.x.isFinite && sim.endPosition.y.isFinite
            && sim.endVelocity.x.isFinite && sim.endVelocity.y.isFinite && sim.totalDuration.isFinite
        if !finite { flag("non-finite output") ; continue }

        if v > BallPhysics.maxPlausiblePeakVelocity {
            if sim.outcome != .rejected { flag("spike NOT rejected: \(tag)") }
            continue
        }
        if let last = sim.path.last {
            if simd_length(sim.endPosition - last.position) > 1e-9 { flag("endPosition != last path sample") }
            if abs(sim.totalDuration - last.time) > 1e-9 { flag("totalDuration != last sample time") }
        }
        for k in 1..<sim.path.count where sim.path[k].time <= sim.path[k - 1].time {
            flag("non-monotonic time at path[\(k)]"); break
        }
        if sim.outcome == .captured {
            let d = simd_length(sim.endPosition - SIMD2<Double>(cupX, 0))
            if d > 0.054 + 1e-6 { flag("captured but ended \(f(d, 4)) m from cup") }
        }
        if sim.outcome == .stopped {
            let s = simd_length(sim.endVelocity)
            if s > 0.05 + 1e-9 { flag("stopped but endSpeed \(f(s, 4))") }
        }
        // Teleport check away from the cup (lip-out legitimately snaps near it).
        let cup = SIMD2<Double>(cupX, 0)
        for k in 1..<sim.path.count {
            let a = sim.path[k - 1], b = sim.path[k]
            if simd_length(a.position - cup) < 0.15 || simd_length(b.position - cup) < 0.15 { continue }
            let dt = b.time - a.time
            let vmax = max(simd_length(a.velocity), simd_length(b.velocity))
            if simd_length(b.position - a.position) > vmax * dt * 1.5 + 1e-9 {
                flag("teleport at path[\(k)]: moved \(f(simd_length(b.position - a.position), 4)) in \(f(dt, 4))s at vmax \(f(vmax, 3))")
                break
            }
        }
    }
    print("BallPhysics outcomes over \(n) runs: \(outcomes.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))")

    // --- StanceGeometry LH/RH mirror property ---
    var stanceChecked = 0
    var stanceViolations = 0
    for i in 0..<(n / 10) {
        let ball = SIMD3<Float>(Float(rng.range(-2, 2)), Float(rng.range(-1.5, 0)), Float(rng.range(-2, 2)))
        let hole = ball + SIMD3<Float>(Float(rng.range(-3, 3)), 0, Float(rng.range(-3, 3)))
        let height = rng.range(120, 210)
        let profile = UserProfile(heightCm: height, handedness: .right)
        let stance = StanceGeometry.compute(profile: profile)
        guard let rh = StanceGeometry.addressPlacement(ball: ball, hole: hole, stance: stance, handedness: .right),
              let lh = StanceGeometry.addressPlacement(ball: ball, hole: hole, stance: stance, handedness: .left)
        else { continue }
        stanceChecked += 1

        guard let aim = GreenFrame.aim(ball: ball, hole: hole) else { continue }
        let perp = GreenFrame.leftPerp(of: aim)
        func mirror(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let rel = p - ball
            let along = simd_dot(rel, aim)
            let across = simd_dot(rel, perp)
            let up = rel - aim * along - perp * across
            return ball + aim * along - perp * across + up
        }
        let aimYaw = atan2(aim.x, aim.z)
        func mirrorYaw(_ y: Float) -> Float {
            var d = 2 * aimYaw - y
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            return d
        }
        func yawDelta(_ a: Float, _ b: Float) -> Float {
            var d = a - b
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            return abs(d)
        }
        let posTol: Float = 1e-4
        let yawTol: Float = 1e-4
        var bad: [String] = []
        if simd_length(mirror(rh.leadFootPosition) - lh.leadFootPosition) > posTol { bad.append("leadPos") }
        if simd_length(mirror(rh.trailFootPosition) - lh.trailFootPosition) > posTol { bad.append("trailPos") }
        if simd_length(mirror(rh.stanceCenter) - lh.stanceCenter) > posTol { bad.append("center") }
        if yawDelta(mirrorYaw(rh.leadFootYaw), lh.leadFootYaw) > yawTol { bad.append("leadYaw") }
        if yawDelta(mirrorYaw(rh.trailFootYaw), lh.trailFootYaw) > yawTol { bad.append("trailYaw") }
        if !bad.isEmpty {
            stanceViolations += 1
            if violations.count < 40 {
                violations.append("[stance #\(i)] LH is not the mirror of RH: \(bad.joined(separator: ",")) ball=\(ball) hole=\(hole) h=\(f(height, 0))")
            }
        }
    }
    print("Stance LH/RH mirror: \(stanceChecked) configs checked, \(stanceViolations) violations")

    // --- MarioKart bucket boundaries + non-finite inputs ---
    let mk = MarioKartAssist()
    for deg in [-20.0001, -20.0, -19.9999, -12.0001, -12.0, -11.9999, -6.0001, -6.0, -5.9999,
                5.9999, 6.0, 6.0001, 11.9999, 12.0, 12.0001, 19.9999, 20.0, 20.0001] {
        let r = mk.bucket(faceAngleDeg: deg)
        print("bucket(\(deg)) -> \(r.bucket.rawValue) display=\(f(r.displayDegrees, 4))")
    }
    let nanR = mk.bucket(faceAngleDeg: .nan)
    print("bucket(NaN) -> \(nanR.bucket.rawValue) display=\(nanR.displayDegrees)")
    let infR = mk.bucket(faceAngleDeg: .infinity)
    print("bucket(+inf) -> \(infR.bucket.rawValue) display=\(infR.displayDegrees)")

    print("")
    if violations.isEmpty {
        print("RESULT: NO INVARIANT VIOLATIONS")
    } else {
        print("RESULT: \(violations.count) violation reports:")
        violations.forEach { print("  " + $0) }
    }
}
