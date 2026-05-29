import Testing
import Foundation
import simd
@testable import PuttingLab

@Suite("StrokeHistoryStore — persistence")
struct StrokeHistoryStoreTests {

    @Test("empty store load returns []")
    func emptyLoad() throws {
        let store = makeStore()
        defer { store.clear() }
        let records = try store.load()
        #expect(records.isEmpty)
    }

    @Test("append then load returns single record")
    func appendOne() throws {
        let store = makeStore()
        defer { store.clear() }
        let r = makeRecord(distance: 8.0)
        try store.append(r)
        let loaded = try store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first == r)
    }

    @Test("50 records stored, 51st evicts the oldest (FIFO)")
    func evictsOldest() throws {
        let store = makeStore(cap: 50)
        defer { store.clear() }
        for i in 0..<51 {
            try store.append(makeRecord(distance: Double(i)))
        }
        let loaded = try store.load()
        #expect(loaded.count == 50)
        #expect(loaded.first?.distanceFeet == 1.0)
        #expect(loaded.last?.distanceFeet == 50.0)
    }

    @Test("small cap of 3 evicts older records")
    func smallCap() throws {
        let store = makeStore(cap: 3)
        defer { store.clear() }
        for i in 0..<5 {
            try store.append(makeRecord(distance: Double(i)))
        }
        let loaded = try store.load()
        #expect(loaded.count == 3)
        #expect(loaded.map { $0.distanceFeet } == [2.0, 3.0, 4.0])
    }

    @Test("clear removes all records")
    func clearRemoves() throws {
        let store = makeStore()
        try store.append(makeRecord(distance: 8.0))
        store.clear()
        let loaded = try store.load()
        #expect(loaded.isEmpty)
    }

    @Test("StrokeRecord Codable round-trips through JSON")
    func codableRoundTrip() throws {
        let r = makeRecord(distance: 7.5)
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(StrokeRecord.self, from: data)
        #expect(decoded == r)
    }

    @Test("StrokeRecord init from ImpactResult/DistanceResult/DirectionResult")
    func recordFromResults() {
        let impact = ImpactResult(
            timestamp: 1.3,
            peakVelocity: 1.0,
            faceAngleRaw: -0.087,
            attitudeAtImpact: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
            confidence: 0.95
        )
        let distance = DistanceResult(displayedFeet: 8.0, lowFeet: 6.8, highFeet: 9.2, ballSpeedFps: 3.3, rawFeet: 8.0)
        let direction = DirectionResult(
            bucket: .slightPull,
            label: "Slight pull",
            displayDegrees: -5.0,
            cause: "Face closed a touch — toe of the putter led.",
            snappedToSquare: false
        )
        let r = StrokeRecord(
            recordedAt: Date(timeIntervalSince1970: 0),
            impact: impact,
            strokeDurationSeconds: 0.6,
            distance: distance,
            direction: direction
        )
        #expect(r.distanceFeet == 8.0)
        #expect(r.directionBucket == .slightPull)
        #expect(r.peakVelocity == 1.0)
    }
}

@Suite("StatsAggregator")
struct StatsAggregatorTests {

    @Test("empty records → zero stats")
    func emptyStats() {
        let stats = StatsAggregator.aggregate([], referenceDate: Date(timeIntervalSince1970: 0))
        #expect(stats.totalStrokes == 0)
        #expect(stats.longestFeet == 0)
        #expect(stats.todayStreak == 0)
    }

    @Test("longest distance reported correctly")
    func longestDistance() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            makeRecord(distance: 7.0, at: now),
            makeRecord(distance: 12.0, at: now),
            makeRecord(distance: 8.5, at: now),
        ]
        let stats = StatsAggregator.aggregate(records, referenceDate: now)
        #expect(stats.longestFeet == 12.0)
    }

    @Test("closest pin = smallest |distance - target|")
    func closestPin() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            makeRecord(distance: 4.0, at: now),
            makeRecord(distance: 9.5, at: now),
            makeRecord(distance: 12.0, at: now),
        ]
        let stats = StatsAggregator.aggregate(records, targetFeet: 8.0, referenceDate: now)
        #expect(stats.closestPinFeetFromTarget == 1.5)
    }

    @Test("best tempo = duration closest to ideal 600ms")
    func bestTempo() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            makeRecord(distance: 8.0, duration: 0.40, at: now),
            makeRecord(distance: 8.0, duration: 0.65, at: now),
            makeRecord(distance: 8.0, duration: 0.95, at: now),
        ]
        let stats = StatsAggregator.aggregate(records, referenceDate: now)
        #expect(stats.bestTempoSeconds == 0.65)
    }

    @Test("most accurate face angle = smallest absolute deg")
    func mostAccurate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            makeRecord(distance: 8.0, faceAngleRad: -0.20, at: now),
            makeRecord(distance: 8.0, faceAngleRad: 0.03, at: now),
            makeRecord(distance: 8.0, faceAngleRad: 0.10, at: now),
        ]
        let stats = StatsAggregator.aggregate(records, referenceDate: now)
        #expect(abs(stats.mostAccurateFaceAngleDeg - 0.03 * 180.0 / .pi) < 1e-6)
    }
}

@Suite("StatsAggregator — streak")
struct StatsAggregatorStreakTests {

    @Test("3 strokes today → streak = 3")
    func threeTodayStreakThree() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            makeRecord(distance: 8.0, at: now),
            makeRecord(distance: 8.0, at: now.addingTimeInterval(60)),
            makeRecord(distance: 8.0, at: now.addingTimeInterval(120)),
        ]
        let s = StatsAggregator.streak(records: records, referenceDate: now)
        #expect(s == 3)
    }

    @Test("gap of 1 day → streak resets to 0")
    func gapResets() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let yesterday = now.addingTimeInterval(-86400)
        let records = [
            makeRecord(distance: 8.0, at: yesterday),
            makeRecord(distance: 8.0, at: yesterday.addingTimeInterval(60)),
        ]
        let s = StatsAggregator.streak(records: records, referenceDate: now)
        #expect(s == 0)
    }

    @Test("mix of yesterday + today → streak counts only today")
    func mixedDaysOnlyToday() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let yesterday = now.addingTimeInterval(-86400)
        let records = [
            makeRecord(distance: 8.0, at: yesterday),
            makeRecord(distance: 8.0, at: now),
            makeRecord(distance: 8.0, at: now.addingTimeInterval(60)),
        ]
        let s = StatsAggregator.streak(records: records, referenceDate: now)
        #expect(s == 2)
    }

    @Test("future records ignored from streak")
    func futureIgnored() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tomorrow = now.addingTimeInterval(86400)
        let records = [
            makeRecord(distance: 8.0, at: now),
            makeRecord(distance: 8.0, at: tomorrow),
        ]
        let s = StatsAggregator.streak(records: records, referenceDate: now)
        #expect(s == 1)
    }

    @Test("SessionStats Equatable")
    func equatable() {
        let a = SessionStats(totalStrokes: 5, longestFeet: 10, closestPinFeetFromTarget: 1, bestTempoSeconds: 0.6, mostAccurateFaceAngleDeg: 1, todayStreak: 3)
        let b = SessionStats(totalStrokes: 5, longestFeet: 10, closestPinFeetFromTarget: 1, bestTempoSeconds: 0.6, mostAccurateFaceAngleDeg: 1, todayStreak: 3)
        #expect(a == b)
    }
}

// MARK: - Helpers

fileprivate func makeStore(cap: Int = StrokeHistoryStore.defaultCap) -> StrokeHistoryStore {
    let key = "StrokeHistoryTest_\(UUID().uuidString)"
    return StrokeHistoryStore(defaults: .standard, key: key, cap: cap)
}

fileprivate func makeRecord(
    distance: Double,
    duration: TimeInterval = 0.6,
    faceAngleRad: Double = 0.0,
    at date: Date = Date(timeIntervalSince1970: 0)
) -> StrokeRecord {
    StrokeRecord(
        recordedAt: date,
        impactTimestamp: 0,
        peakVelocity: 1.0,
        faceAngleRaw: faceAngleRad,
        confidence: 0.95,
        distanceFeet: distance,
        strokeDurationSeconds: duration,
        directionBucket: .square
    )
}
