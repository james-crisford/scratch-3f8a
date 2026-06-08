import Testing
import Foundation
import simd
@testable import PuttingLab

@Suite("StrokeDetector — arm + idle")
struct StrokeDetectorArmTests {

    @Test("starts in .idle")
    func startsIdle() {
        let d = StrokeDetector()
        #expect(d.phase == .idle)
    }

    @Test("consume in .idle returns nil and stays .idle")
    func idleConsumeNoop() {
        let d = StrokeDetector()
        let w = d.consume(spinSample(t: 0, rate: 40 * .pi / 180.0))
        #expect(w == nil)
        #expect(d.phase == .idle)
    }

    @Test("arm() transitions .idle → .armed")
    func armFromIdle() throws {
        let d = StrokeDetector()
        try d.arm(with: testLock())
        #expect(d.phase == .armed)
    }

    @Test("arm() throws armWhileActive when .starting")
    func armWhileStartingThrows() throws {
        let d = StrokeDetector()
        try d.arm(with: testLock())
        _ = d.consume(spinSample(t: 0, rate: 1.0))  // above 30°/s threshold
        #expect(d.phase == .starting)
        #expect(throws: StrokeDetectorError.armWhileActive) {
            try d.arm(with: testLock())
        }
    }

    @Test("arm() throws armWhileActive when .recording")
    func armWhileRecordingThrows() throws {
        let d = StrokeDetector()
        try d.arm(with: testLock())
        for i in 0...10 {
            _ = d.consume(spinSample(t: TimeInterval(i) * 0.01, rate: 1.0))
        }
        #expect(d.phase == .recording)
        #expect(throws: StrokeDetectorError.armWhileActive) {
            try d.arm(with: testLock())
        }
    }

    @Test("re-arm allowed from .ended")
    func reArmFromEnded() throws {
        let d = StrokeDetector()
        try d.arm(with: testLock())
        let window = simulateStrokeAndEnd(d: d, baseT: 0)
        #expect(window != nil)
        #expect(d.phase == .ended)
        try d.arm(with: testLock())
        #expect(d.phase == .armed)
    }

    @Test("reset() returns to .idle")
    func resetReturnsToIdle() throws {
        let d = StrokeDetector()
        try d.arm(with: testLock())
        d.reset()
        #expect(d.phase == .idle)
    }
}

@Suite("StrokeDetector — start detection")
struct StrokeDetectorStartTests {

    @Test("50ms above threshold transitions .starting → .recording")
    func fiftyMsTransitions() throws {
        let d = StrokeDetector()
        try d.arm(with: testLock())
        var phaseAtEnd: StrokeDetectorPhase = .idle
        for i in 0...5 {
            _ = d.consume(spinSample(t: TimeInterval(i) * 0.01, rate: 1.0))
            phaseAtEnd = d.phase
        }
        #expect(phaseAtEnd == .recording)
    }

    @Test("flick rejected: 40ms above threshold then drop → returns to .armed")
    func flickRejected() throws {
        let d = StrokeDetector()
        try d.arm(with: testLock())
        for i in 0...3 {
            _ = d.consume(spinSample(t: TimeInterval(i) * 0.01, rate: 1.0))
        }
        #expect(d.phase == .starting)
        _ = d.consume(spinSample(t: 0.04, rate: 0.0))  // dip below
        #expect(d.phase == .armed)
        #expect(d.sampleCount == 0)
    }

    @Test("boundary: rate exactly at 30°/s → not above (strict >)")
    func rateAtThresholdNotAbove() throws {
        let d = StrokeDetector()
        try d.arm(with: testLock())
        let exactly30 = StrokeDetector.startThresholdRadPerSec
        _ = d.consume(spinSample(t: 0, rate: exactly30))
        #expect(d.phase == .armed)
    }

    @Test("boundary: rate just above 30°/s starts detection")
    func rateJustAboveThreshold() throws {
        let d = StrokeDetector()
        try d.arm(with: testLock())
        let justAbove = StrokeDetector.startThresholdRadPerSec + 1e-6
        _ = d.consume(spinSample(t: 0, rate: justAbove))
        #expect(d.phase == .starting)
    }
}

@Suite("StrokeDetector — end detection")
struct StrokeDetectorEndTests {

    @Test("ends via return-to-stillness after 300ms quiet")
    func endsViaQuiet() throws {
        let d = StrokeDetector()
        try d.arm(with: testLock())
        for i in 0...10 {
            _ = d.consume(spinSample(t: TimeInterval(i) * 0.01, rate: 1.0))
        }
        #expect(d.phase == .recording)
        var window: StrokeWindow?
        for i in 0...30 {
            let t = 0.11 + TimeInterval(i) * 0.01
            window = d.consume(spinSample(t: t, rate: 0.0))
            if window != nil { break }
        }
        #expect(window != nil)
        #expect(d.phase == .ended)
    }

    @Test("ends via 2s hard cutoff with continuous high rotation")
    func endsViaHardCutoff() throws {
        let d = StrokeDetector()
        try d.arm(with: testLock())
        var window: StrokeWindow?
        for i in 0...210 {
            let t = TimeInterval(i) * 0.01
            window = d.consume(spinSample(t: t, rate: 5.0))
            if window != nil { break }
        }
        #expect(window != nil)
        #expect(d.phase == .ended)
        #expect(window!.duration + StrokeDetector.fpTolerance >= 2.0)
    }

    @Test("boundary: 299ms quiet does NOT end stroke")
    func quiet299MsDoesNotEnd() throws {
        let d = StrokeDetector()
        try d.arm(with: testLock())
        for i in 0...10 {
            _ = d.consume(spinSample(t: TimeInterval(i) * 0.01, rate: 1.0))
        }
        var window: StrokeWindow?
        for i in 0...29 {
            let t = 0.11 + TimeInterval(i) * 0.01
            window = d.consume(spinSample(t: t, rate: 0.0))
        }
        #expect(window == nil)
        #expect(d.phase == .recording)
    }

    @Test("StrokeWindow captures samples from start through end")
    func windowCapturesSamples() throws {
        let d = StrokeDetector()
        try d.arm(with: testLock())
        for i in 0...10 {
            _ = d.consume(spinSample(t: TimeInterval(i) * 0.01, rate: 1.0))
        }
        var window: StrokeWindow?
        for i in 0...30 {
            let t = 0.11 + TimeInterval(i) * 0.01
            window = d.consume(spinSample(t: t, rate: 0.0))
            if window != nil { break }
        }
        let w = try #require(window)
        #expect(w.samples.count >= 30)
        #expect(w.lock == testLock())
    }

    @Test("StrokeWindow.start equals first above-threshold timestamp")
    func windowStartTimestamp() throws {
        let d = StrokeDetector()
        try d.arm(with: testLock())
        let firstAbove: TimeInterval = 5.000
        _ = d.consume(spinSample(t: firstAbove, rate: 1.0))
        for i in 1...10 {
            _ = d.consume(spinSample(t: firstAbove + TimeInterval(i) * 0.01, rate: 1.0))
        }
        var window: StrokeWindow?
        for i in 0...30 {
            let t = firstAbove + 0.11 + TimeInterval(i) * 0.01
            window = d.consume(spinSample(t: t, rate: 0.0))
            if window != nil { break }
        }
        let w = try #require(window)
        #expect(abs(w.start - firstAbove) < 1e-9)
    }

    @Test("brief quiet that resumes above-threshold does NOT end stroke")
    func quietResetsOnReturn() throws {
        let d = StrokeDetector()
        try d.arm(with: testLock())
        for i in 0...10 {
            _ = d.consume(spinSample(t: TimeInterval(i) * 0.01, rate: 1.0))
        }
        // 100ms quiet (below 300ms)
        for i in 0...10 {
            _ = d.consume(spinSample(t: 0.11 + TimeInterval(i) * 0.01, rate: 0.0))
        }
        // back above threshold
        _ = d.consume(spinSample(t: 0.22, rate: 1.0))
        #expect(d.phase == .recording)
    }

    @Test("consume in .ended returns nil")
    func endedIgnoresInput() throws {
        let d = StrokeDetector()
        try d.arm(with: testLock())
        _ = simulateStrokeAndEnd(d: d, baseT: 0)
        #expect(d.phase == .ended)
        let w2 = d.consume(spinSample(t: 100, rate: 1.0))
        #expect(w2 == nil)
        #expect(d.phase == .ended)
    }
}

@Suite("StrokeDetector — robustness")
struct StrokeDetectorRobustnessTests {

    @Test("determinism: identical streams produce identical windows")
    func determinism() throws {
        let d1 = StrokeDetector()
        let d2 = StrokeDetector()
        try d1.arm(with: testLock())
        try d2.arm(with: testLock())
        let w1 = simulateStrokeAndEnd(d: d1, baseT: 0)
        let w2 = simulateStrokeAndEnd(d: d2, baseT: 0)
        #expect(w1?.start == w2?.start)
        #expect(w1?.end == w2?.end)
        #expect(w1?.samples.count == w2?.samples.count)
    }

    @Test("performance: 10k samples consumed in < 200ms")
    func performance() throws {
        let d = StrokeDetector()
        try d.arm(with: testLock())
        let start = Date()
        for i in 0..<10_000 {
            _ = d.consume(spinSample(t: TimeInterval(i) * 0.01, rate: 1.0))
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 0.2)
    }

    @Test("no retain cycle")
    func noRetainCycle() throws {
        weak var weakRef: StrokeDetector?
        try autoreleasepool {
            let d = StrokeDetector()
            try d.arm(with: testLock())
            weakRef = d
        }
        #expect(weakRef == nil)
    }

    @Test("concurrent reads of phase do not crash")
    func concurrentReads() async throws {
        let d = StrokeDetector()
        try d.arm(with: testLock())
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask { _ = d.phase }
                group.addTask { _ = d.sampleCount }
            }
        }
    }

    @Test("NaN rotation rate does NOT advance state")
    func nanIgnored() throws {
        let d = StrokeDetector()
        try d.arm(with: testLock())
        let s = MotionSample(
            timestamp: 0,
            rotationRate: SIMD3(.nan, 0, 0),
            userAcceleration: .zero,
            gravity: SIMD3(0, -1, 0),
            attitude: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        )
        _ = d.consume(s)
        #expect(d.phase == .armed)
    }

    @Test("100 reset cycles leave detector clean")
    func resetCycles() throws {
        let d = StrokeDetector()
        for _ in 0..<100 {
            try d.arm(with: testLock())
            d.reset()
        }
        #expect(d.phase == .idle)
    }
}

// MARK: - Fixture helpers

fileprivate func testLock() -> StillnessLock {
    StillnessLock(yawTargetCompass: 0.5, attitudeAtPress: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), gravity: SIMD3(0, -1, 0), lockedAt: 0)
}

fileprivate func spinSample(t: TimeInterval, rate: Double) -> MotionSample {
    MotionSample(
        timestamp: t,
        rotationRate: SIMD3(rate, 0, 0),
        userAcceleration: .zero,
        gravity: SIMD3(0, -1, 0),
        attitude: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    )
}

fileprivate func simulateStrokeAndEnd(d: StrokeDetector, baseT: TimeInterval) -> StrokeWindow? {
    // 11 samples at high rate (110ms) drives starting → recording
    for i in 0...10 {
        _ = d.consume(spinSample(t: baseT + TimeInterval(i) * 0.01, rate: 1.0))
    }
    // 31 quiet samples (310ms) ends the stroke
    var window: StrokeWindow?
    for i in 0...30 {
        let t = baseT + 0.11 + TimeInterval(i) * 0.01
        window = d.consume(spinSample(t: t, rate: 0.0))
        if window != nil { break }
    }
    return window
}
