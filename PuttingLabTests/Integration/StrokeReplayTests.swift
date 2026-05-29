import Testing
import Foundation
import simd
@testable import PuttingLab

@Suite("StrokeReplay — JSON round-trip")
struct StrokeReplayTests {

    @Test("encode → decode preserves all sample fields")
    func roundTripPreservesSamples() throws {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let r = try ImpactDetector().detect(in: fixture.window)
        let replay = StrokeReplay(
            window: fixture.window,
            result: r,
            deviceModel: "iPhone13,4",
            appVersion: "0.1.0 (1)"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(replay)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StrokeReplay.self, from: data)

        #expect(decoded.samples.count == replay.samples.count)
        #expect(decoded.deviceModel == "iPhone13,4")
        #expect(decoded.appVersion == "0.1.0 (1)")
        #expect(decoded.windowStart == replay.windowStart)
        #expect(decoded.windowEnd == replay.windowEnd)
        #expect(decoded.result?.snappedToSquare == false)
    }

    @Test("decoded replay produces same impact result as the original (the replay invariant)")
    func replayInvariant() throws {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let originalResult = try ImpactDetector().detect(in: fixture.window)

        let replay = StrokeReplay(
            window: fixture.window,
            result: originalResult,
            deviceModel: "test",
            appVersion: "test"
        )
        let data = try JSONEncoder().encode(replay)
        let decoded = try JSONDecoder().decode(StrokeReplay.self, from: data)
        let reconstructedWindow = decoded.toStrokeWindow()
        let replayedResult = try ImpactDetector().detect(in: reconstructedWindow)

        // JSON encoding via Double loses no precision for the values we care about,
        // so the replayed result should be byte-equal to the original.
        #expect(abs(replayedResult.faceAngleRaw - originalResult.faceAngleRaw) < 1e-9)
        #expect(abs(replayedResult.peakVelocity - originalResult.peakVelocity) < 1e-9)
        #expect(abs(replayedResult.timestamp - originalResult.timestamp) < 1e-9)
        #expect(replayedResult.snappedToSquare == originalResult.snappedToSquare)
    }

    @Test("snapped result replay round-trips")
    func snappedReplayRoundTrip() throws {
        let fixture = StrokeFixtures.flickShort(ms: 150)
        let r = try ImpactDetector().detect(in: fixture.window)
        #expect(r.snappedToSquare)

        let replay = StrokeReplay(window: fixture.window, result: r, deviceModel: "t", appVersion: "t")
        let data = try JSONEncoder().encode(replay)
        let decoded = try JSONDecoder().decode(StrokeReplay.self, from: data)
        #expect(decoded.result?.snappedToSquare == true)
        #expect(decoded.result?.snapReason == "strokeTooShort")
    }

    @Test("StrokeReplayStore save+load+list round-trip in a temp directory")
    func storeRoundTrip() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("PuttingLabTest_\(UUID().uuidString)", isDirectory: true)
        let store = StrokeReplayStore(directory: tmp)
        defer { try? store.clear() }

        let fixture = StrokeFixtures.cleanStraight8ft()
        let r = try ImpactDetector().detect(in: fixture.window)
        let replay = StrokeReplay(window: fixture.window, result: r, deviceModel: "t", appVersion: "t")
        let url = try store.save(replay)

        #expect(FileManager.default.fileExists(atPath: url.path))
        let listed = try store.list()
        #expect(listed.count == 1)

        let loaded = try store.load(from: url)
        #expect(loaded.samples.count == replay.samples.count)
    }
}
