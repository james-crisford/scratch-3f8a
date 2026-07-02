import Testing
import Foundation
import simd
@testable import PuttingLab

@MainActor
@Suite("CalibrationCoordinator — flow")
struct CalibrationFlowTests {

    @Test("starts awaiting 5 strokes")
    func startsAwaiting() {
        let c = CalibrationCoordinator()
        if case .awaitingStrokes(let collected, let required) = c.status {
            #expect(collected == 0)
            #expect(required == 5)
        } else {
            Issue.record("Expected awaitingStrokes status")
        }
    }

    @Test("4 valid strokes → still awaiting")
    func fourStrokesIncomplete() throws {
        let c = CalibrationCoordinator()
        for _ in 0..<4 {
            let pair = try cleanCalibrationPair()
            c.ingest(window: pair.window, impact: pair.impact)
        }
        if case .awaitingStrokes(let collected, _) = c.status {
            #expect(collected == 4)
        } else {
            Issue.record("Expected awaitingStrokes after 4 strokes")
        }
    }

    @Test("5 valid strokes → complete with profile")
    func fiveStrokesComplete() throws {
        let c = CalibrationCoordinator()
        for _ in 0..<5 {
            let pair = try cleanCalibrationPair()
            c.ingest(window: pair.window, impact: pair.impact)
        }
        if case .complete(let profile) = c.status {
            #expect(profile.validStrokeCount == 5)
            #expect(profile.targetDistanceFeet == 8.0)
        } else {
            Issue.record("Expected complete status after 5 valid strokes")
        }
    }

    @Test("2 invalid + 5 valid → still completes at 5 valid")
    func invalidThenValid() throws {
        let c = CalibrationCoordinator()
        let invalidWindow = StrokeFixtures.flickShort(ms: 150).window
        let invalidImpact = ImpactResult(
            timestamp: 0, peakVelocity: 0.1, faceAngleRaw: 0,
            attitudeAtImpact: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), confidence: 0.2
        )
        for _ in 0..<2 {
            c.ingest(window: invalidWindow, impact: invalidImpact)
        }
        for _ in 0..<5 {
            let pair = try cleanCalibrationPair()
            c.ingest(window: pair.window, impact: pair.impact)
        }
        if case .complete = c.status {
            #expect(c.rejectedCount == 2)
        } else {
            Issue.record("Expected complete with 2 rejected")
        }
    }

    @Test("reset() returns to awaiting 0 of 5")
    func resetClears() throws {
        let c = CalibrationCoordinator()
        for _ in 0..<5 {
            let pair = try cleanCalibrationPair()
            c.ingest(window: pair.window, impact: pair.impact)
        }
        c.reset()
        if case .awaitingStrokes(let collected, _) = c.status {
            #expect(collected == 0)
            #expect(c.rejectedCount == 0)
        } else {
            Issue.record("Expected awaiting after reset")
        }
    }

    @Test("low-confidence impact rejected")
    func lowConfidenceRejected() throws {
        let c = CalibrationCoordinator()
        let pair = try cleanCalibrationPair()
        let bad = ImpactResult(
            timestamp: pair.impact.timestamp,
            peakVelocity: pair.impact.peakVelocity,
            faceAngleRaw: pair.impact.faceAngleRaw,
            attitudeAtImpact: pair.impact.attitudeAtImpact,
            confidence: 0.3
        )
        c.ingest(window: pair.window, impact: bad)
        #expect(c.rejectedCount == 1)
    }

    @Test("3 consecutive rejections triggers .stalled status with hint (C3 fix)")
    func threeRejectionsStall() throws {
        let c = CalibrationCoordinator()
        let invalidWindow = StrokeFixtures.flickShort(ms: 150).window
        let invalidImpact = ImpactResult(
            timestamp: 0, peakVelocity: 0.1, faceAngleRaw: 0,
            attitudeAtImpact: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), confidence: 0.2
        )
        for _ in 0..<3 {
            c.ingest(window: invalidWindow, impact: invalidImpact)
        }
        if case .stalled(let count, let hint) = c.status {
            #expect(count == 3)
            #expect(!hint.isEmpty)
        } else {
            Issue.record("Expected .stalled status after 3 rejections, got \(c.status)")
        }
    }

    @Test("a valid stroke resets the consecutive-rejection counter")
    func validStrokeResetsStall() throws {
        let c = CalibrationCoordinator()
        let invalidWindow = StrokeFixtures.flickShort(ms: 150).window
        let invalidImpact = ImpactResult(
            timestamp: 0, peakVelocity: 0.1, faceAngleRaw: 0,
            attitudeAtImpact: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), confidence: 0.2
        )
        for _ in 0..<2 {
            c.ingest(window: invalidWindow, impact: invalidImpact)
        }
        let pair = try cleanCalibrationPair()
        c.ingest(window: pair.window, impact: pair.impact)
        // Now a 4th rejection should NOT immediately stall — counter reset by the valid stroke.
        c.ingest(window: invalidWindow, impact: invalidImpact)
        if case .stalled = c.status {
            Issue.record("Should not be stalled — valid stroke reset the counter")
        }
    }

    @Test("too-soft impact rejected; a REAL median-speed stroke accepted")
    func lowPeakRejected() throws {
        // The original floor (0.3) predated device data: the 192-stroke
        // corpus median peak is ~0.15 in the detector's pseudo-units, so
        // 0.3 rejected virtually every genuine calibration stroke. The
        // floor is now the detector's own snap threshold (0.05).
        let c = CalibrationCoordinator()
        let pair = try cleanCalibrationPair()
        let tooSoft = ImpactResult(
            timestamp: pair.impact.timestamp,
            peakVelocity: 0.03,
            faceAngleRaw: pair.impact.faceAngleRaw,
            attitudeAtImpact: pair.impact.attitudeAtImpact,
            confidence: pair.impact.confidence
        )
        c.ingest(window: pair.window, impact: tooSoft)
        #expect(c.rejectedCount == 1)

        let realMedianStroke = ImpactResult(
            timestamp: pair.impact.timestamp,
            peakVelocity: 0.15,
            faceAngleRaw: pair.impact.faceAngleRaw,
            attitudeAtImpact: pair.impact.attitudeAtImpact,
            confidence: pair.impact.confidence
        )
        #expect(CalibrationCoordinator.isValid(impact: realMedianStroke, window: pair.window))
    }
}

@Suite("CalibrationModel — computed values")
struct CalibrationModelTests {

    @Test("mean tempo across VARIED durations is the true arithmetic mean (C3 fix - no longer tautological)")
    func meanTempoFromVariedDurations() throws {
        // 350+500+720+850+1100 = 3520, mean = 704 — guaranteed NOT to equal any fixture.
        // A "return middle element" or "return median" bug would now fail the test.
        let durationsMs = [350, 500, 720, 850, 1100]
        let inputs = try durationsMs.map { ms in
            try cleanCalibrationPair(durationSeconds: TimeInterval(ms) / 1000.0)
        }.map { CalibrationInput(window: $0.window, impact: $0.impact) }
        let profile = CalibrationModel.compute(from: inputs, targetDistanceFeet: 8.0)
        let expectedMean = inputs.map { $0.window.duration }.reduce(0, +) / Double(inputs.count)
        #expect(abs(profile.meanTempoSeconds - expectedMean) < 1e-6)
    }

    @Test("speedToDistanceFactor scales correctly: target 8ft, faster swing → smaller factor")
    func speedFactorMonotonic() throws {
        let slowInputs = try (0..<5).map { _ in
            try cleanCalibrationPair(peakVelocity: 1.0)
        }.map { CalibrationInput(window: $0.window, impact: $0.impact) }
        let fastInputs = try (0..<5).map { _ in
            try cleanCalibrationPair(peakVelocity: 2.0)
        }.map { CalibrationInput(window: $0.window, impact: $0.impact) }
        let slow = CalibrationModel.compute(from: slowInputs, targetDistanceFeet: 8.0)
        let fast = CalibrationModel.compute(from: fastInputs, targetDistanceFeet: 8.0)
        #expect(slow.speedToDistanceFactor > fast.speedToDistanceFactor)
    }

    @Test("spike-contaminated calibration never yields a pinned or garbage factor")
    func spikeContaminatedCalibrationFallsBack() {
        // Mean above the physics spike gate: every sim call inside the
        // bisection returns .rejected (rolled = 0), lo marches to the top
        // bound. Pre-fix this crashed a debug build (assert) or persisted
        // factor ~500 in release (2026-07-02 adversarial audit, CRITICAL).
        let pinned = CalibrationModel.factorDelivering(
            targetMetres: 8.0 * CalibrationModel.metresPerFoot,
            meanPeakVelocity: BallPhysics.maxPlausiblePeakVelocity + 1.0,
            stimpFeet: BallPhysics.defaultStimp
        )
        #expect(pinned == CalibrationProfile.defaultSpeedToDistanceFactor)
    }

    @Test("compute with spike-poisoned mean returns the default factor, not garbage")
    func computeSpikePoisonedMeanUsesDefault() throws {
        // 4 clean strokes + inputs whose mean exceeds the spike gate.
        var inputs = try (0..<4).map { _ in
            try cleanCalibrationPair(peakVelocity: 0.5)
        }.map { CalibrationInput(window: $0.window, impact: $0.impact) }
        let spike = try cleanCalibrationPair(peakVelocity: 30.0)
        inputs.append(CalibrationInput(window: spike.window, impact: spike.impact))
        let profile = CalibrationModel.compute(from: inputs, targetDistanceFeet: 8.0)
        #expect(profile.speedToDistanceFactor == CalibrationProfile.defaultSpeedToDistanceFactor)
    }

    @Test("calibration intake rejects a sensor-spike stroke")
    @MainActor
    func intakeRejectsSpikeStroke() throws {
        let clean = try cleanCalibrationPair(peakVelocity: 0.5)
        #expect(CalibrationCoordinator.isValid(impact: clean.impact, window: clean.window))
        // The fixture drives the REAL detector, whose smoothing detects a
        // slightly lower peak than requested — ask with margin and assert
        // the precondition so the test can't silently pass the gate.
        let spike = try cleanCalibrationPair(peakVelocity: BallPhysics.maxPlausiblePeakVelocity + 1.5)
        #expect(spike.impact.peakVelocity > BallPhysics.maxPlausiblePeakVelocity)
        #expect(!CalibrationCoordinator.isValid(impact: spike.impact, window: spike.window))
    }

    @Test("S2: calibrated factor makes the live sim roll the target distance (±1%)")
    func calibratedFactorRollsTargetThroughLiveSim() {
        let targetFeet = 8.0
        let targetMetres = targetFeet * CalibrationModel.metresPerFoot
        for meanV in [0.05, 0.0954, 0.151, 0.5, 1.0, 2.0] {
            let factor = CalibrationModel.factorDelivering(
                targetMetres: targetMetres,
                meanPeakVelocity: meanV,
                stimpFeet: BallPhysics.defaultStimp
            )
            let rolled = BallPhysics.simulatePutt(
                peakVelocity: meanV,
                faceAngleRaw: 0,
                speedCalibration: factor,
                stimpFeet: BallPhysics.defaultStimp,
                cupPosition: SIMD2<Double>(1e9, 0)
            ).endPosition.x
            #expect(
                abs(rolled - targetMetres) < targetMetres * 0.01,
                "meanV \(meanV): rolled \(rolled) m for target \(targetMetres) m (factor \(factor))"
            )
        }
    }

    @Test("S2 migration: pre-v4 profile factor resets to default on sanitize; v3 bias survives")
    func preV4FactorReset() {
        let v3 = CalibrationProfile(
            meanTempoSeconds: 0.6,
            speedToDistanceFactor: 14.183,
            faceAngleBiasRad: 0.05,
            swingPlaneAxis: SIMD3<Double>(1, 0, 0),
            arkitBaselineStability: 0.9,
            validStrokeCount: 5,
            targetDistanceFeet: 8.0,
            pipelineVersion: 3
        )
        let migrated = v3.sanitizedForCurrentPipeline
        #expect(migrated.speedToDistanceFactor == CalibrationProfile.defaultSpeedToDistanceFactor)
        #expect(migrated.faceAngleBiasRad == 0.05)

        let v2 = CalibrationProfile(
            meanTempoSeconds: 0.6,
            speedToDistanceFactor: 14.183,
            faceAngleBiasRad: 0.05,
            swingPlaneAxis: SIMD3<Double>(1, 0, 0),
            arkitBaselineStability: 0.9,
            validStrokeCount: 5,
            targetDistanceFeet: 8.0,
            pipelineVersion: 2
        )
        let migratedV2 = v2.sanitizedForCurrentPipeline
        #expect(migratedV2.speedToDistanceFactor == CalibrationProfile.defaultSpeedToDistanceFactor)
        #expect(migratedV2.faceAngleBiasRad == 0)

        let v4 = CalibrationProfile(
            meanTempoSeconds: 0.6,
            speedToDistanceFactor: 22.9,
            faceAngleBiasRad: 0.01,
            swingPlaneAxis: SIMD3<Double>(1, 0, 0),
            arkitBaselineStability: 0.9,
            validStrokeCount: 5,
            targetDistanceFeet: 8.0,
            pipelineVersion: 4
        )
        #expect(v4.sanitizedForCurrentPipeline == v4)
    }

    @Test("face angle bias detected when synthetic strokes systematically pull")
    func biasDetected() throws {
        // B80 — `faceAngleDeg` is the PHYSICAL CCW rotation; under the v3
        // golf sign +5° CCW READS −5° (pull). The fixture input flips so
        // these strokes still "systematically pull" as the name claims.
        let inputs = try (0..<5).map { _ in
            try cleanCalibrationPair(faceAngleDeg: 5.0)
        }.map { CalibrationInput(window: $0.window, impact: $0.impact) }
        let profile = CalibrationModel.compute(from: inputs, targetDistanceFeet: 8.0)
        let biasDeg = profile.faceAngleBiasRad * 180.0 / .pi
        #expect(biasDeg < 0)
        #expect(abs(biasDeg + 5.0) < 2.0)
    }

    @Test("applyBias subtracts the calibrated bias")
    func biasApplied() throws {
        // B80 — +3° CCW physical reads −3° (pull) under v3; a −3° bias
        // then zeroes an equally-pulled next stroke.
        let inputs = try (0..<5).map { _ in
            try cleanCalibrationPair(faceAngleDeg: 3.0)
        }.map { CalibrationInput(window: $0.window, impact: $0.impact) }
        let profile = CalibrationModel.compute(from: inputs, targetDistanceFeet: 8.0)
        let rawNextStroke = -3.0 * .pi / 180.0
        let adjusted = CalibrationModel.applyBias(rawNextStroke, profile: profile)
        #expect(abs(adjusted) < 0.03)
    }

    @Test("swing plane axis is unit length")
    func swingAxisUnit() throws {
        let inputs = try (0..<5).map { _ in try cleanCalibrationPair() }
            .map { CalibrationInput(window: $0.window, impact: $0.impact) }
        let profile = CalibrationModel.compute(from: inputs, targetDistanceFeet: 8.0)
        let len = simd_length(profile.swingPlaneAxis)
        #expect(abs(len - 1.0) < 1e-6)
    }

    @Test("ARKit baseline stability is in [0, 1]")
    func stabilityInRange() throws {
        let inputs = try (0..<5).map { _ in try cleanCalibrationPair() }
            .map { CalibrationInput(window: $0.window, impact: $0.impact) }
        let profile = CalibrationModel.compute(from: inputs, targetDistanceFeet: 8.0)
        #expect(profile.arkitBaselineStability >= 0.0)
        #expect(profile.arkitBaselineStability <= 1.0)
    }

    @Test("stability higher when face angles are consistent")
    func stabilityComparison() throws {
        let consistent = try (0..<5).map { _ in
            try cleanCalibrationPair(faceAngleDeg: 0)
        }.map { CalibrationInput(window: $0.window, impact: $0.impact) }
        let varied: [CalibrationInput] = try [-10.0, -5.0, 0.0, 5.0, 10.0].map { deg in
            let pair = try cleanCalibrationPair(faceAngleDeg: deg)
            return CalibrationInput(window: pair.window, impact: pair.impact)
        }
        let pConsistent = CalibrationModel.compute(from: consistent, targetDistanceFeet: 8.0)
        let pVaried = CalibrationModel.compute(from: varied, targetDistanceFeet: 8.0)
        #expect(pConsistent.arkitBaselineStability > pVaried.arkitBaselineStability)
    }
}

@Suite("ProfileStore — persistence")
struct ProfileStorePersistenceTests {

    @Test("save then load returns identical profile")
    func roundTrip() throws {
        let key = "TestProfile_\(UUID().uuidString)"
        let store = ProfileStore(defaults: .standard, key: key)
        defer { store.clear() }
        let profile = sampleProfile()
        try store.save(profile)
        let loaded = try store.load()
        #expect(loaded == profile)
    }

    @Test("load with no saved profile returns nil")
    func loadEmptyReturnsNil() throws {
        let key = "TestProfile_\(UUID().uuidString)"
        let store = ProfileStore(defaults: .standard, key: key)
        defer { store.clear() }
        let loaded = try store.load()
        #expect(loaded == nil)
    }

    @Test("clear removes saved profile")
    func clearRemoves() throws {
        let key = "TestProfile_\(UUID().uuidString)"
        let store = ProfileStore(defaults: .standard, key: key)
        try store.save(sampleProfile())
        store.clear()
        let loaded = try store.load()
        #expect(loaded == nil)
    }

    @Test("CalibrationProfile Codable round-trip preserves SIMD3 axis")
    func codableRoundTrip() throws {
        let profile = sampleProfile()
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(CalibrationProfile.self, from: data)
        #expect(decoded == profile)
        #expect(decoded.swingPlaneAxis.x == profile.swingPlaneAxis.x)
        #expect(decoded.swingPlaneAxis.y == profile.swingPlaneAxis.y)
        #expect(decoded.swingPlaneAxis.z == profile.swingPlaneAxis.z)
    }

    @Test("CalibrationProfile is Equatable")
    func profileEquatable() {
        let a = sampleProfile()
        let b = sampleProfile()
        #expect(a == b)
    }
}

// MARK: - Helpers

fileprivate func cleanCalibrationPair(
    faceAngleDeg: Double = 0.0,
    peakVelocity: Double = 1.0,
    durationSeconds: TimeInterval = 0.6
) throws -> (window: StrokeWindow, impact: ImpactResult) {
    let fixture = StrokeFixtures.synthesise(
        durationSeconds: durationSeconds,
        peakVelocity: peakVelocity,
        faceAngleDeg: faceAngleDeg
    )
    let detector = ImpactDetector()
    let impact = try detector.detect(in: fixture.window)
    return (fixture.window, impact)
}

fileprivate func sampleProfile() -> CalibrationProfile {
    CalibrationProfile(
        meanTempoSeconds: 0.6,
        speedToDistanceFactor: 1.1,
        faceAngleBiasRad: -0.05,
        swingPlaneAxis: SIMD3(0.95, 0.0, 0.31),
        arkitBaselineStability: 0.85,
        validStrokeCount: 5,
        targetDistanceFeet: 8.0
    )
}
