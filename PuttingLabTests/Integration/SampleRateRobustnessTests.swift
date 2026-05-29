import Testing
import Foundation
import simd
@testable import PuttingLab

@Suite("Sample-rate robustness — ImpactDetector inferDt")
struct SampleRateRobustnessTests {

    @Test("80 Hz fixture: face angle within ±3° of 0")
    func eightyHz() throws {
        let fix = StrokeFixtures.synthesise(rateHz: 80)
        let r = try ImpactDetector().detect(in: fix.window)
        let deg = r.faceAngleRaw * 180.0 / .pi
        #expect(abs(deg) < 3.0)
    }

    @Test("90 Hz fixture: face angle within ±3° of 0")
    func ninetyHz() throws {
        let fix = StrokeFixtures.synthesise(rateHz: 90)
        let r = try ImpactDetector().detect(in: fix.window)
        let deg = r.faceAngleRaw * 180.0 / .pi
        #expect(abs(deg) < 3.0)
    }

    @Test("110 Hz fixture: face angle within ±3° of 0")
    func oneHundredTenHz() throws {
        let fix = StrokeFixtures.synthesise(rateHz: 110)
        let r = try ImpactDetector().detect(in: fix.window)
        let deg = r.faceAngleRaw * 180.0 / .pi
        #expect(abs(deg) < 3.0)
    }

    @Test("120 Hz fixture: peak velocity within ±10% of 1.0 m/s")
    func oneHundredTwentyHz() throws {
        let fix = StrokeFixtures.synthesise(rateHz: 120)
        let r = try ImpactDetector().detect(in: fix.window)
        #expect(r.peakVelocity > 0.9 && r.peakVelocity < 1.1)
    }

    @Test("varied sample rates: impact time within ±10ms across all rates")
    func sampleRateImpactTimeConsistency() throws {
        let rates: [Double] = [80, 90, 100, 110, 120]
        var times: [TimeInterval] = []
        for hz in rates {
            let fix = StrokeFixtures.synthesise(rateHz: hz)
            let r = try ImpactDetector().detect(in: fix.window)
            times.append(r.timestamp)
        }
        let mean = times.reduce(0, +) / Double(times.count)
        for t in times {
            #expect(abs(t - mean) < 0.010)
        }
    }

    @Test("tour-pro empirical fixture (317ms, 1.51 m/s): detected within ±2° of 0.3°")
    func tourProEmpirical() throws {
        let fix = StrokeFixtures.tourProDownswing()
        let r = try ImpactDetector().detect(in: fix.window)
        let deg = r.faceAngleRaw * 180.0 / .pi
        #expect(abs(deg - 0.3) < 2.0)
    }

    @Test("tour-pro empirical impact speed (1.51 m/s) → DistanceModel ≈ 10-13 ft on Stimp 10")
    func tourProDistance() {
        let r = DistanceModel().compute(peakSpeedMps: 1.51)
        #expect(r.displayedFeet > 10.0 && r.displayedFeet < 14.0)
    }

    @Test("amateur recreational stroke (900ms, 1.0 m/s): detected and reasonable distance")
    func amateurFixture() throws {
        let fix = StrokeFixtures.amateurStroke()
        let r = try ImpactDetector().detect(in: fix.window)
        let distance = DistanceModel().compute(peakSpeedMps: r.peakVelocity)
        #expect(distance.displayedFeet > 3.0 && distance.displayedFeet < 10.0)
    }
}
