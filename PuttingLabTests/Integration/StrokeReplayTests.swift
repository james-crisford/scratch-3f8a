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

    // MARK: - B8: batch tagging fields

    @Test("batch fields (id/index/type) round-trip through JSON")
    func batchFieldsRoundTrip() throws {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let r = try ImpactDetector().detect(in: fixture.window)
        let replay = StrokeReplay(
            window: fixture.window,
            result: r,
            deviceModel: "iPhone14,3",
            appVersion: "0.1.4 (8)",
            userImpactJudgment: "just_right",
            batchId: "B",
            batchStrokeIndex: 7,
            batchStrokeType: "Deliberate PULL stroke"
        )
        let data = try JSONEncoder().encode(replay)
        let decoded = try JSONDecoder().decode(StrokeReplay.self, from: data)
        #expect(decoded.batchId == "B")
        #expect(decoded.batchStrokeIndex == 7)
        #expect(decoded.batchStrokeType == "Deliberate PULL stroke")
        #expect(decoded.userImpactJudgment == "just_right")
    }

    @Test("v1 replays (no batch fields) decode with nil values for new fields")
    func backwardCompatV1ReplayDecodes() throws {
        let fixture = StrokeFixtures.cleanStraight8ft()
        let r = try ImpactDetector().detect(in: fixture.window)
        let replay = StrokeReplay(window: fixture.window, result: r, deviceModel: "t", appVersion: "t")
        let data = try JSONEncoder().encode(replay)
        let decoded = try JSONDecoder().decode(StrokeReplay.self, from: data)
        #expect(decoded.batchId == nil)
        #expect(decoded.batchStrokeIndex == nil)
        #expect(decoded.batchStrokeType == nil)
        #expect(decoded.userImpactJudgment == nil)
    }

    @Test("filename includes batch-id and stroke-index when present")
    func filenameIncludesBatchInfo() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PuttingLabTest_\(UUID().uuidString)", isDirectory: true)
        let store = StrokeReplayStore(directory: tmp)
        defer { try? store.clear() }

        let fixture = StrokeFixtures.cleanStraight8ft()
        let r = try ImpactDetector().detect(in: fixture.window)
        let replay = StrokeReplay(
            window: fixture.window,
            result: r,
            deviceModel: "t",
            appVersion: "t",
            batchId: "A",
            batchStrokeIndex: 3,
            batchStrokeType: "Clean baseline stroke"
        )
        let url = try store.save(replay)
        let name = url.lastPathComponent
        #expect(name.hasPrefix("stroke-A-3-"), "expected 'stroke-A-3-…json' got '\(name)'")
        #expect(name.hasSuffix(".json"))
    }

    @Test("filename falls back to date-only when batch tag is absent")
    func filenameFallsBackWithoutBatch() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PuttingLabTest_\(UUID().uuidString)", isDirectory: true)
        let store = StrokeReplayStore(directory: tmp)
        defer { try? store.clear() }

        let fixture = StrokeFixtures.cleanStraight8ft()
        let r = try ImpactDetector().detect(in: fixture.window)
        let replay = StrokeReplay(window: fixture.window, result: r, deviceModel: "t", appVersion: "t")
        let url = try store.save(replay)
        let name = url.lastPathComponent
        // No batch segment when batchId is nil.
        #expect(name.hasPrefix("stroke-"))
        #expect(!name.contains("--"))
    }

    // MARK: - Build 9: load() hardening (size cap before read, JSON depth limit, NaN reject)

    @Test("schema v3: AR pose track round-trips; v2 stays v2 without poses")
    func schemaV3PoseRoundTrip() throws {
        // Minimal self-contained window (fixtures in CalibrationTests are
        // fileprivate): two quiet samples + identity press lock.
        let q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        let samples = [0.0, 0.01, 0.3].map { dt in
            MotionSample(timestamp: 100.0 + dt,
                         rotationRate: SIMD3(0.1, 0, 0),
                         userAcceleration: SIMD3(0.2, 0, 0),
                         gravity: SIMD3(0, -1, 0),
                         attitude: q)
        }
        let window = StrokeWindow(
            start: samples[0].timestamp,
            end: samples[samples.count - 1].timestamp,
            samples: samples,
            lock: StillnessLock(yawTargetCompass: 0, attitudeAtPress: q,
                                gravity: SIMD3(0, -1, 0),
                                lockedAt: samples[0].timestamp))

        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(0.1, 1.2, -0.3, 1)
        let poses = [
            ARPose(timestamp: window.start + 0.1,
                   transform: transform,
                   trackingState: .normal),
            ARPose(timestamp: window.start + 0.2,
                   transform: transform,
                   trackingState: .limited(.excessiveMotion)),
        ]
        let v3 = StrokeReplay(
            window: window, result: nil,
            deviceModel: "test", appVersion: "t", batchId: "ar",
            arPoses: poses)
        #expect(v3.schemaVersion == 3)

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PuttingLabTest_\(UUID().uuidString)", isDirectory: true)
        let store = StrokeReplayStore(directory: tmp)
        defer { try? store.clear() }
        let url = try store.save(v3)
        let loaded = try store.load(from: url)
        #expect(loaded.schemaVersion == 3)
        #expect(loaded.arPoses?.count == 2)
        #expect(loaded.arPoses?[0].transform.count == 16)
        #expect(abs((loaded.arPoses?[0].transform[13] ?? 0) - 1.2) < 1e-6)
        #expect(loaded.arPoses?[0].trackingNormal == true)
        #expect(loaded.arPoses?[1].trackingNormal == false)

        let v2 = StrokeReplay(
            window: window, result: nil,
            deviceModel: "test", appVersion: "t")
        #expect(v2.schemaVersion == 2)
        #expect(v2.arPoses == nil)
    }

    @Test("load rejects deep nesting hidden behind close-brackets in string literals")
    func loadRejectsStringMaskedDeepNesting() throws {
        // Attack: each repetition opens ONE real array level, then a
        // string containing "]]" — a scanner that counts brackets inside
        // strings sees its counter oscillate near zero while the true
        // structural depth grows unbounded (decoder stack-overflow DoS).
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PuttingLabTest_\(UUID().uuidString)", isDirectory: true)
        let store = StrokeReplayStore(directory: tmp)
        defer { try? store.clear() }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let attack = String(repeating: "[\"]]\",", count: 150)
        let url = tmp.appendingPathComponent("masked-nesting.json")
        try Data(attack.utf8).write(to: url)

        #expect(throws: (any Error).self) {
            _ = try store.load(from: url)
        }
        // And specifically the nesting guard (code 2), not a decode error.
        do {
            _ = try store.load(from: url)
        } catch let e as NSError {
            #expect(e.domain == "StrokeReplayStore")
            #expect(e.code == 2)
        }
    }

    @Test("load rejects an oversized JSON before reading it into memory")
    func loadRejectsOversizedFile() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PuttingLabTest_\(UUID().uuidString)", isDirectory: true)
        let store = StrokeReplayStore(directory: tmp)
        defer { try? store.clear() }

        // Write a 12MB blob that the OS sees as a .json by extension.
        // Content doesn't have to be valid JSON; the size check is the
        // first gate and should reject before parsing.
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let bigURL = tmp.appendingPathComponent("oversized.json")
        let payload = Data(repeating: UInt8(ascii: "a"), count: 12 * 1024 * 1024)
        try payload.write(to: bigURL)

        #expect(throws: NSError.self) {
            _ = try store.load(from: bigURL)
        }
    }

    @Test("load rejects a JSON whose nesting depth exceeds the cap")
    func loadRejectsDeepNesting() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PuttingLabTest_\(UUID().uuidString)", isDirectory: true)
        let store = StrokeReplayStore(directory: tmp)
        defer { try? store.clear() }

        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let deepURL = tmp.appendingPathComponent("deep.json")
        // 200 consecutive '[' — well over the 100 cap.
        let payload = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        try payload.write(to: deepURL, atomically: true, encoding: .utf8)

        #expect(throws: NSError.self) {
            _ = try store.load(from: deepURL)
        }
    }

    @Test("load rejects a replay carrying NaN timestamps in its samples")
    func loadRejectsNaNTimestamps() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PuttingLabTest_\(UUID().uuidString)", isDirectory: true)
        let store = StrokeReplayStore(directory: tmp)
        defer { try? store.clear() }

        // Save a real stroke, read back the JSON, mutate one timestamp to "nan".
        let fixture = StrokeFixtures.cleanStraight8ft()
        let r = try ImpactDetector().detect(in: fixture.window)
        let replay = StrokeReplay(window: fixture.window, result: r, deviceModel: "t", appVersion: "t")
        let url = try store.save(replay)
        var text = try String(contentsOf: url, encoding: .utf8)
        // Replace the very first timestamp value with "nan". The replays use
        // ISO-8601 string for capturedAt, but per-sample timestamps are bare
        // doubles, easy to swap.
        if let range = text.range(of: #""timestamp":[\s]*[0-9.]+"#, options: .regularExpression) {
            text.replaceSubrange(range, with: #""timestamp":"nan""#)
            try text.write(to: url, atomically: true, encoding: .utf8)
            #expect(throws: NSError.self) {
                _ = try store.load(from: url)
            }
        } else {
            Issue.record("Could not find timestamp pattern to mutate")
        }
    }

    @Test("stageExportSnapshot copies only saved .json files (curated, excludes dotfiles)")
    func stageSnapshotIsCurated() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PuttingLabTest_\(UUID().uuidString)", isDirectory: true)
        let store = StrokeReplayStore(directory: tmp)
        defer { try? store.clear() }

        // Save one real stroke.
        let fixture = StrokeFixtures.cleanStraight8ft()
        let r = try ImpactDetector().detect(in: fixture.window)
        let replay = StrokeReplay(window: fixture.window, result: r, deviceModel: "t", appVersion: "t")
        _ = try store.save(replay)

        // Drop a dotfile and a non-.json file in the same directory
        // (simulating an attacker via Files-app share).
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dot = tmp.appendingPathComponent(".DS_Store")
        let txt = tmp.appendingPathComponent("evil.txt")
        try Data("dotfile".utf8).write(to: dot)
        try Data("evil".utf8).write(to: txt)

        let staging = try store.stageExportSnapshot()
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagedNames = try FileManager.default.contentsOfDirectory(atPath: staging.path).sorted()
        #expect(stagedNames.count == 1, "only the .json file should be staged, got \(stagedNames)")
        #expect(stagedNames.first?.hasPrefix("stroke-") == true)
        #expect(!stagedNames.contains(".DS_Store"))
        #expect(!stagedNames.contains("evil.txt"))
    }
}
