import Testing
import Foundation
import simd
@testable import PuttingLab

@Suite("MarioKartAssist — snap-to-square integration (C3 fix)")
struct MarioKartSnapIntegrationTests {

    @Test("bucket(from: snapped ImpactResult) returns Square with snap-specific cause")
    func snappedResultGetsSnapCause() {
        let snapped = ImpactResult(
            timestamp: 1.3,
            peakVelocity: 0,
            faceAngleRaw: 0,
            attitudeAtImpact: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
            confidence: 0,
            snappedToSquare: true,
            snapReason: .strokeTooShort
        )
        let r = MarioKartAssist().bucket(from: snapped)
        #expect(r.bucket == .square)
        #expect(r.snappedToSquare)
        #expect(r.cause.lowercased().contains("quick"))
    }

    @Test("bucket(from: clean ImpactResult with deg=0) returns Square with normal cause")
    func cleanZeroGetsCentreCause() {
        let clean = ImpactResult(
            timestamp: 1.3,
            peakVelocity: 1.0,
            faceAngleRaw: 0,
            attitudeAtImpact: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
            confidence: 1.0,
            snappedToSquare: false,
            snapReason: nil
        )
        let r = MarioKartAssist().bucket(from: clean)
        #expect(r.bucket == .square)
        #expect(!r.snappedToSquare)
        #expect(r.cause.lowercased().contains("centre") || r.cause.lowercased().contains("target"))
    }

    @Test("each snap reason maps to a distinct cause string")
    func snapReasonsHaveDistinctCauses() {
        let reasons: [SnapReason] = [.strokeTooShort, .noClearPeak, .arkitLost, .peakSpeedTooLow]
        var causes: Set<String> = []
        for reason in reasons {
            let impact = ImpactResult(
                timestamp: 0, peakVelocity: 0, faceAngleRaw: 0,
                attitudeAtImpact: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
                confidence: 0, snappedToSquare: true, snapReason: reason
            )
            causes.insert(MarioKartAssist().bucket(from: impact).cause)
        }
        #expect(causes.count == 4)
    }
}

@Suite("MarioKartAssist — bucket boundaries")
struct MarioKartBucketTests {

    @Test("0° → Square")
    func zeroSquare() {
        let r = MarioKartAssist().bucket(faceAngleDeg: 0)
        #expect(r.bucket == .square)
        #expect(r.displayDegrees == 0)
    }

    @Test("just under 6° → Square")
    func justUnderSquare() {
        let r = MarioKartAssist().bucket(faceAngleDeg: 5.9)
        #expect(r.bucket == .square)
    }

    @Test("exactly 6° → slight pull/push (not Square)")
    func atSixBoundary() {
        let r = MarioKartAssist().bucket(faceAngleDeg: 6.0)
        #expect(r.bucket == .slightPush)
    }

    @Test("just under 12° → slight pull/push")
    func justUnderTwelve() {
        let r = MarioKartAssist().bucket(faceAngleDeg: 11.9)
        #expect(r.bucket == .slightPush)
    }

    @Test("exactly 12° → pull/push")
    func atTwelveBoundary() {
        let r = MarioKartAssist().bucket(faceAngleDeg: 12.0)
        #expect(r.bucket == .push)
    }

    @Test("just under 20° → pull/push")
    func justUnderTwenty() {
        let r = MarioKartAssist().bucket(faceAngleDeg: 19.9)
        #expect(r.bucket == .push)
    }

    @Test("exactly 20° → miss")
    func atTwentyBoundary() {
        let r = MarioKartAssist().bucket(faceAngleDeg: 20.0)
        #expect(r.bucket == .miss)
    }

    @Test("25° → miss")
    func twentyFiveMiss() {
        let r = MarioKartAssist().bucket(faceAngleDeg: 25.0)
        #expect(r.bucket == .miss)
    }

    @Test("just under -6° → Square (negative boundary)")
    func justUnderMinusSix() {
        let r = MarioKartAssist().bucket(faceAngleDeg: -5.9)
        #expect(r.bucket == .square)
    }

    @Test("exactly -6° → slightPull (negative boundary)")
    func atMinusSixBoundary() {
        let r = MarioKartAssist().bucket(faceAngleDeg: -6.0)
        #expect(r.bucket == .slightPull)
    }

    @Test("exactly -12° → pull (negative boundary)")
    func atMinusTwelveBoundary() {
        let r = MarioKartAssist().bucket(faceAngleDeg: -12.0)
        #expect(r.bucket == .pull)
    }

    @Test("exactly -20° → miss (negative boundary)")
    func atMinusTwentyBoundary() {
        let r = MarioKartAssist().bucket(faceAngleDeg: -20.0)
        #expect(r.bucket == .miss)
    }
}

@Suite("MarioKartAssist — sign / pull-push")
struct MarioKartSignTests {

    @Test("negative 7° → slight pull (not slight push)")
    func minusSevenSlightPull() {
        let r = MarioKartAssist().bucket(faceAngleDeg: -7.0)
        #expect(r.bucket == .slightPull)
        #expect(r.displayDegrees == -7.0)
    }

    @Test("positive 7° → slight push")
    func plusSevenSlightPush() {
        let r = MarioKartAssist().bucket(faceAngleDeg: 7.0)
        #expect(r.bucket == .slightPush)
    }

    @Test("negative 15° → pull")
    func minusFifteenPull() {
        let r = MarioKartAssist().bucket(faceAngleDeg: -15.0)
        #expect(r.bucket == .pull)
    }

    @Test("positive 15° → push")
    func plusFifteenPush() {
        let r = MarioKartAssist().bucket(faceAngleDeg: 15.0)
        #expect(r.bucket == .push)
    }

    @Test("negative 25° → miss with negative display angle")
    func minusTwentyFiveMiss() {
        let r = MarioKartAssist().bucket(faceAngleDeg: -25.0)
        #expect(r.bucket == .miss)
        #expect(r.displayDegrees < 0)
    }
}

@Suite("MarioKartAssist — low-confidence snap")
struct MarioKartConfidenceTests {

    @Test("ARKit-lost flag → Square regardless of face angle")
    func arkitLostSnapToSquare() {
        let flags = ConfidenceFlags(
            arkitLostMoreThanHalf: true,
            strokeUnder200ms: false,
            noClearPeak: false,
            peakSpeedUnder0_3Mps: false
        )
        let r = MarioKartAssist().bucket(faceAngleDeg: 25.0, flags: flags)
        #expect(r.bucket == .square)
        #expect(r.displayDegrees == 0)
        #expect(r.snappedToSquare)
    }

    @Test("stroke-too-short flag → Square")
    func tooShortSnap() {
        let flags = ConfidenceFlags(
            arkitLostMoreThanHalf: false,
            strokeUnder200ms: true,
            noClearPeak: false,
            peakSpeedUnder0_3Mps: false
        )
        let r = MarioKartAssist().bucket(faceAngleDeg: -25.0, flags: flags)
        #expect(r.bucket == .square)
        #expect(r.snappedToSquare)
    }

    @Test("no-clear-peak flag → Square")
    func noPeakSnap() {
        let flags = ConfidenceFlags(
            arkitLostMoreThanHalf: false,
            strokeUnder200ms: false,
            noClearPeak: true,
            peakSpeedUnder0_3Mps: false
        )
        let r = MarioKartAssist().bucket(faceAngleDeg: 25.0, flags: flags)
        #expect(r.bucket == .square)
        #expect(r.snappedToSquare)
    }

    @Test("low peak velocity flag → Square + cause mentions swing speed")
    func slowSwingSnap() {
        let flags = ConfidenceFlags(
            arkitLostMoreThanHalf: false,
            strokeUnder200ms: false,
            noClearPeak: false,
            peakSpeedUnder0_3Mps: true
        )
        let r = MarioKartAssist().bucket(faceAngleDeg: 15.0, flags: flags)
        #expect(r.bucket == .square)
        #expect(r.cause.lowercased().contains("swing speed") || r.cause.lowercased().contains("tap"))
    }

    @Test("no flags + 0° → Square but NOT snapped")
    func cleanSquareNotSnapped() {
        let r = MarioKartAssist().bucket(faceAngleDeg: 0, flags: .none)
        #expect(r.bucket == .square)
        #expect(!r.snappedToSquare)
    }
}

@Suite("MarioKartAssist — surfaced cause")
struct MarioKartCauseTests {

    @Test("Slight pull cause mentions face closing or toe")
    func slightPullCause() {
        let r = MarioKartAssist().bucket(faceAngleDeg: -8.0)
        let c = r.cause.lowercased()
        #expect(c.contains("closed") || c.contains("toe"))
    }

    @Test("Slight push cause mentions face opening or heel")
    func slightPushCause() {
        let r = MarioKartAssist().bucket(faceAngleDeg: 8.0)
        let c = r.cause.lowercased()
        #expect(c.contains("open") || c.contains("heel"))
    }

    @Test("Pull cause mentions left of line")
    func pullCause() {
        let r = MarioKartAssist().bucket(faceAngleDeg: -15.0)
        #expect(r.cause.lowercased().contains("left"))
    }

    @Test("Push cause mentions right of line")
    func pushCause() {
        let r = MarioKartAssist().bucket(faceAngleDeg: 15.0)
        #expect(r.cause.lowercased().contains("right"))
    }

    @Test("Miss cause mentions severe")
    func missCause() {
        let r = MarioKartAssist().bucket(faceAngleDeg: 25.0)
        #expect(r.cause.lowercased().contains("severe"))
    }

    @Test("Square (clean) cause mentions target line")
    func squareCleanCause() {
        let r = MarioKartAssist().bucket(faceAngleDeg: 0)
        #expect(r.cause.lowercased().contains("target") || r.cause.lowercased().contains("straight"))
    }
}

@Suite("MarioKartAssist — robustness")
struct MarioKartRobustnessTests {

    @Test("determinism")
    func determinism() {
        let a = MarioKartAssist().bucket(faceAngleDeg: 7.5)
        let b = MarioKartAssist().bucket(faceAngleDeg: 7.5)
        #expect(a == b)
    }

    @Test("DirectionResult Equatable")
    func resultEquatable() {
        let a = MarioKartAssist().bucket(faceAngleDeg: 7.5)
        let b = MarioKartAssist().bucket(faceAngleDeg: 7.5)
        #expect(a == b)
    }

    @Test("ConfidenceFlags.anyLow with all false → false")
    func noLowFlags() {
        #expect(!ConfidenceFlags.none.anyLow)
    }

    @Test("ConfidenceFlags.anyLow with any true → true")
    func anyLowTrue() {
        let f = ConfidenceFlags(
            arkitLostMoreThanHalf: false,
            strokeUnder200ms: false,
            noClearPeak: true,
            peakSpeedUnder0_3Mps: false
        )
        #expect(f.anyLow)
    }
}
