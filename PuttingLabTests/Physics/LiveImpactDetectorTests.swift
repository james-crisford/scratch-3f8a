import Testing
import Foundation
import simd
@testable import PuttingLab

@Suite("LiveImpactDetector — real-time impact haptic trigger")
@MainActor
struct LiveImpactDetectorTests {

    /// Build a sample at time `t` with a uniform-magnitude rotationRate.
    /// Other channels are filled with quiet/identity values that won't
    /// interfere with the detector (it only reads |rotationRate|).
    private func sample(t: TimeInterval, omegaMagnitude: Double) -> MotionSample {
        // Split the magnitude equally across x/y/z so simd_length matches
        // the requested value: comp = mag / sqrt(3).
        let comp = omegaMagnitude / sqrt(3.0)
        return MotionSample(
            timestamp: t,
            rotationRate: SIMD3(comp, comp, comp),
            userAcceleration: SIMD3(0, 0, 0),
            gravity: SIMD3(0, -1, 0),
            attitude: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        )
    }

    /// Synthesise a 1-second rising-and-falling rotation profile that crosses
    /// up through arm and back down through disarm. Returns one sample every
    /// 10ms (100 Hz), starting at t=0.
    /// Peak value = `peak` rad/s, baseline = `baseline`.
    private func bumpSamples(
        durationMs: Int = 1000,
        peak: Double,
        baseline: Double = 0.2,
        startTime: TimeInterval = 0
    ) -> [MotionSample] {
        let nSamples = durationMs / 10
        return (0..<nSamples).map { i in
            // Symmetric triangle: rises from baseline to peak at midpoint, then falls.
            let fraction = Double(i) / Double(max(1, nSamples - 1))
            let triangle = 1.0 - abs(fraction - 0.5) * 2.0  // 0 at ends, 1 at middle
            let mag = baseline + (peak - baseline) * triangle
            return sample(t: startTime + Double(i) * 0.01, omegaMagnitude: mag)
        }
    }

    /// Detector that skips the warm-up gate, for tests that only need to
    /// exercise the arm/disarm/cool-down state machine.
    private func instantDetector(
        armThreshold: Double = 2.0,
        disarmThreshold: Double = 1.0,
        coolDownSeconds: Double = 0.4
    ) -> LiveImpactDetector {
        LiveImpactDetector(
            armThreshold: armThreshold,
            disarmThreshold: disarmThreshold,
            coolDownSeconds: coolDownSeconds,
            warmUpSamplesBelowDisarm: 0
        )
    }

    @Test("fires exactly once for a single rising-falling burst above threshold")
    func singleBurstFiresOnce() {
        let det = instantDetector()
        let samples = bumpSamples(durationMs: 800, peak: 3.0)
        let fires = samples.filter { det.consume($0) }.count
        #expect(fires == 1, "expected exactly one fire for a single peak burst, got \(fires)")
    }

    @Test("never fires when the magnitude stays below arm threshold")
    func belowArmNeverFires() {
        let det = instantDetector()
        // Peak 1.5 rad/s — below arm. Should never fire.
        let samples = bumpSamples(durationMs: 800, peak: 1.5)
        let fires = samples.filter { det.consume($0) }.count
        #expect(fires == 0)
    }

    @Test("two non-overlapping bursts both fire (one each)")
    func twoBurstsFireTwice() {
        let det = instantDetector(coolDownSeconds: 0.3)
        // First burst at t∈[0, 0.6], second at t∈[1.2, 1.8]. Cool-down (0.3s)
        // safely elapsed between the two.
        let first = bumpSamples(durationMs: 600, peak: 3.0, startTime: 0)
        let second = bumpSamples(durationMs: 600, peak: 3.0, startTime: 1.2)
        let combined = first + second
        let fires = combined.filter { det.consume($0) }.count
        #expect(fires == 2, "expected one fire per burst, got \(fires)")
    }

    @Test("cool-down suppresses a noisy double-peak from firing twice")
    func coolDownSuppressesNoisyRefire() {
        let det = instantDetector(coolDownSeconds: 0.5)
        // Two close peaks 100ms apart — cool-down 500ms should keep this to
        // one haptic fire.
        let first = bumpSamples(durationMs: 200, peak: 3.0, startTime: 0)
        let second = bumpSamples(durationMs: 200, peak: 3.0, startTime: 0.25)
        let combined = first + second
        let fires = combined.filter { det.consume($0) }.count
        #expect(fires == 1, "cool-down should collapse twin peaks to one, got \(fires)")
    }

    @Test("reset() re-arms the detector for the next stroke")
    func resetReArms() {
        let det = instantDetector()
        let firstStroke = bumpSamples(durationMs: 600, peak: 3.0)
        let firesFirst = firstStroke.filter { det.consume($0) }.count
        #expect(firesFirst == 1)

        det.reset()
        // After reset, the cool-down is cleared too, so a fresh stroke
        // immediately after fires again.
        let secondStroke = bumpSamples(durationMs: 600, peak: 3.0, startTime: 10.0)
        let firesSecond = secondStroke.filter { det.consume($0) }.count
        #expect(firesSecond == 1)
    }

    @Test("fire occurs after the peak (on the descending side), not at the rising edge")
    func firesOnDescent() {
        let det = instantDetector(coolDownSeconds: 0.0)
        let samples = bumpSamples(durationMs: 1000, peak: 3.0)
        var fireIndex: Int?
        for (i, s) in samples.enumerated() where det.consume(s) {
            fireIndex = i
            break
        }
        let peakIndex = samples.firstIndex(where: { $0.rotationMagnitude >= 2.99 })
        #expect(fireIndex != nil, "should have fired")
        if let fire = fireIndex, let peak = peakIndex {
            #expect(fire > peak, "fire (i=\(fire)) should occur after the peak (i=\(peak))")
        }
    }

    @Test("realistic putting profile with default warm-up fires once on the real impact peak")
    func realisticPuttingProfileWithWarmUp() {
        // Default LiveImpactDetector (with warm-up=5). 1.7s burst gives
        // ~17 low-mag samples on the leading edge so warm-up engages cleanly.
        let det = LiveImpactDetector()
        let samples = bumpSamples(durationMs: 1700, peak: 3.0, baseline: 0.3)
        let fires = samples.filter { det.consume($0) }.count
        #expect(fires == 1)
    }

    // MARK: - Build 9 hardening

    @Test("warm-up gate suppresses a touchDown-time wrist flick from firing on sample 1")
    func warmUpGateSuppressesFirstSampleFlick() {
        // Simulates: user grabs phone, presses screen, and the very first
        // motion sample after touchDown shows |ω|=3.0 rad/s (wrist flick).
        // With warm-up=5 requiring 5 consecutive below-disarm samples first,
        // this single high-magnitude sample MUST NOT fire.
        let det = LiveImpactDetector(
            armThreshold: 2.0,
            disarmThreshold: 1.0,
            coolDownSeconds: 0.4,
            warmUpSamplesBelowDisarm: 5
        )
        let flick = sample(t: 0.0, omegaMagnitude: 3.0)
        #expect(det.consume(flick) == false, "first-sample flick should be suppressed by warm-up gate")
    }

    @Test("warm-up engages after N consecutive below-disarm samples, then a real peak fires")
    func warmUpEngagesThenFires() {
        let det = LiveImpactDetector(
            armThreshold: 2.0,
            disarmThreshold: 1.0,
            coolDownSeconds: 0.4,
            warmUpSamplesBelowDisarm: 5
        )
        // 5 quiet samples to satisfy warm-up.
        for i in 0..<5 {
            _ = det.consume(sample(t: Double(i) * 0.01, omegaMagnitude: 0.2))
        }
        // Now a real burst.
        let burst = bumpSamples(durationMs: 600, peak: 3.0, startTime: 0.05)
        let fires = burst.filter { det.consume($0) }.count
        #expect(fires == 1)
    }

    @Test("non-finite timestamp (NaN/Inf) is rejected and does not corrupt state")
    func nonFiniteTimestampRejected() {
        let det = instantDetector()
        // Feed a real peak, expect 1 fire.
        let real = bumpSamples(durationMs: 400, peak: 3.0)
        let firesBeforeJunk = real.filter { det.consume($0) }.count
        #expect(firesBeforeJunk == 1)

        // Reset and try to corrupt with NaN/Inf timestamp.
        det.reset()
        // 5 quiet samples to warm up.
        for i in 0..<5 {
            _ = det.consume(sample(t: Double(i) * 0.01, omegaMagnitude: 0.2))
        }
        let junkNaN = sample(t: .nan, omegaMagnitude: 3.0)
        let junkInf = sample(t: .infinity, omegaMagnitude: 3.0)
        _ = det.consume(junkNaN)
        _ = det.consume(junkInf)
        // After the junk, a real burst should still fire normally.
        let realAgain = bumpSamples(durationMs: 600, peak: 3.0, startTime: 1.0)
        let firesAfterJunk = realAgain.filter { det.consume($0) }.count
        #expect(firesAfterJunk == 1, "detector must survive non-finite timestamps and still fire on real bursts")
    }

    @Test("non-finite rotation magnitude is rejected silently")
    func nonFiniteRotationRejected() {
        let det = instantDetector()
        let nan = sample(t: 0.0, omegaMagnitude: .nan)
        let inf = sample(t: 0.01, omegaMagnitude: .infinity)
        #expect(det.consume(nan) == false)
        #expect(det.consume(inf) == false)
    }
}
