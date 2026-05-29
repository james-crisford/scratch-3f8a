import Testing
import Foundation
@testable import PuttingLab

@Suite("DistanceModel — base behaviour")
struct DistanceModelBaseTests {

    @Test("1.0 m/s peak produces a putt-scale distance (3–15 ft)")
    func oneMpsPuttScale() {
        let m = DistanceModel()
        let r = m.compute(peakSpeedMps: 1.0)
        #expect(r.displayedFeet > 3.0 && r.displayedFeet < 15.0)
    }

    @Test("0 m/s peak → 0 distance")
    func zeroSpeedZeroDistance() {
        let r = DistanceModel().compute(peakSpeedMps: 0.0)
        #expect(r.displayedFeet == 0)
        #expect(r.ballSpeedFps == 0)
    }

    @Test("negative peak velocity clamped to 0")
    func negativeClampedToZero() {
        let r = DistanceModel().compute(peakSpeedMps: -1.0)
        #expect(r.displayedFeet == 0)
    }

    @Test("doubling peak velocity → 4× distance (quadratic per empirical putt physics)")
    func powerLawScaling() {
        let m = DistanceModel()
        let a = m.compute(peakSpeedMps: 1.0)
        let b = m.compute(peakSpeedMps: 2.0)
        let ratio = b.displayedFeet / a.displayedFeet
        #expect(ratio > 3.95 && ratio < 4.05)
    }

    @Test("calibration factor 2 → 4× distance vs factor 1 (quadratic)")
    func calibrationScales() {
        let m1 = DistanceModel(speedCalibrationFactor: 1.0)
        let m2 = DistanceModel(speedCalibrationFactor: 2.0)
        let r1 = m1.compute(peakSpeedMps: 1.0)
        let r2 = m2.compute(peakSpeedMps: 1.0)
        let ratio = r2.displayedFeet / r1.displayedFeet
        #expect(ratio > 3.95 && ratio < 4.05)
    }

    @Test("Stimp scaling: 2× Stimp → 2× distance (linear in green speed)")
    func stimpScalesLinearly() {
        let slow = DistanceModel(stimp: 6.0)
        let fast = DistanceModel(stimp: 12.0)
        let rSlow = slow.compute(peakSpeedMps: 1.5)
        let rFast = fast.compute(peakSpeedMps: 1.5)
        let ratio = rFast.displayedFeet / rSlow.displayedFeet
        #expect(ratio > 1.95 && ratio < 2.05)
    }

    @Test("empirical putter impact (1.51 m/s, Stimp 10) → 8-12 ft (matches Marquardt SAM data)")
    func empiricalPutterImpact() {
        let r = DistanceModel().compute(peakSpeedMps: 1.51)
        #expect(r.displayedFeet > 8.0 && r.displayedFeet < 14.0)
    }

    @Test("ball speed conversion: 1 m/s → 3.281 fps")
    func mpsToFpsConversion() {
        let r = DistanceModel().compute(peakSpeedMps: 1.0)
        #expect(abs(r.ballSpeedFps - 3.281) < 1e-9)
    }
}

@Suite("DistanceModel — confidence band")
struct DistanceModelBandTests {

    @Test("low < displayed < high always")
    func bandOrdering() {
        let m = DistanceModel()
        for speed in stride(from: 0.5, through: 3.0, by: 0.3) {
            let r = m.compute(peakSpeedMps: speed)
            #expect(r.lowFeet < r.displayedFeet)
            #expect(r.displayedFeet < r.highFeet)
        }
    }

    @Test("band is ±15% of displayed")
    func bandMagnitude() {
        let r = DistanceModel().compute(peakSpeedMps: 1.5)
        let bandFromLow = (r.displayedFeet - r.lowFeet) / r.displayedFeet
        let bandFromHigh = (r.highFeet - r.displayedFeet) / r.displayedFeet
        #expect(abs(bandFromLow - 0.15) < 1e-9)
        #expect(abs(bandFromHigh - 0.15) < 1e-9)
    }
}

@Suite("DistanceModel — jitter & determinism")
struct DistanceModelJitterTests {

    @Test("jitter 0 → displayed equals raw exactly")
    func zeroJitterExact() {
        let m = DistanceModel(jitterFraction: 0.0)
        let r = m.compute(peakSpeedMps: 1.0)
        #expect(r.displayedFeet == r.rawFeet)
    }

    @Test("jitter +1.0 → displayed = raw × 1.05")
    func maxJitterUp() {
        let m = DistanceModel(jitterFraction: 1.0)
        let r = m.compute(peakSpeedMps: 1.0)
        #expect(abs(r.displayedFeet - r.rawFeet * 1.05) < 1e-9)
    }

    @Test("jitter -1.0 → displayed = raw × 0.95")
    func maxJitterDown() {
        let m = DistanceModel(jitterFraction: -1.0)
        let r = m.compute(peakSpeedMps: 1.0)
        #expect(abs(r.displayedFeet - r.rawFeet * 0.95) < 1e-9)
    }

    @Test("jitter outside [-1, 1] clamped")
    func jitterClamped() {
        let m = DistanceModel(jitterFraction: 5.0)
        let r = m.compute(peakSpeedMps: 1.0)
        #expect(abs(r.displayedFeet - r.rawFeet * 1.05) < 1e-9)
    }

    @Test("determinism: same model + same input → same result")
    func determinism() {
        let m = DistanceModel(jitterFraction: 0.3)
        let a = m.compute(peakSpeedMps: 1.5)
        let b = m.compute(peakSpeedMps: 1.5)
        #expect(a == b)
    }

    @Test("DistanceResult is Equatable")
    func equatable() {
        let a = DistanceModel().compute(peakSpeedMps: 1.0)
        let b = DistanceModel().compute(peakSpeedMps: 1.0)
        #expect(a == b)
    }
}
