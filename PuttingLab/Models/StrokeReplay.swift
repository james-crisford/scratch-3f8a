import Foundation
import simd

/// Codable wrapper for a captured stroke + its window + the resulting impact.
/// Used to save real iPhone strokes from TestFlight to disk so we can replay them
/// through the algorithm offline and debug. JSON-friendly.
///
/// **Schema version 1** (2026-05-29). Future fields MUST be added via `decodeIfPresent`
/// in `init(from:)` so v1 tester JSONs continue to deserialize forever.
struct StrokeReplay: Sendable, Codable {
    let schemaVersion: Int
    let capturedAt: Date
    let deviceModel: String
    let appVersion: String
    let samples: [SerializedSample]
    let lock: SerializedLock
    let windowStart: TimeInterval
    let windowEnd: TimeInterval
    let result: SerializedImpactResult?
    let userNote: String?
    /// User's judgment of the algorithm's chosen impact time, captured via the
    /// per-stroke "How did this feel?" buttons in the result panel. v1 replays
    /// without this field decode as nil. Added 2026-05-30 for B7 data collection.
    let userImpactJudgment: String?
    /// Identifier of the test batch this stroke belongs to (e.g. "cal", "A",
    /// "B"). v1 replays without this field decode as nil. Added 2026-05-30 (B8)
    /// so we can group strokes by intended type when analysing offline.
    let batchId: String?
    /// 1-indexed position of this stroke within its batch.
    let batchStrokeIndex: Int?
    /// Human-readable stroke type (e.g. "Clean baseline stroke",
    /// "Deliberate PULL stroke") — copied from `TestBatch.strokeTypeLabel`.
    let batchStrokeType: String?

    struct SerializedSample: Sendable, Codable {
        let timestamp: TimeInterval
        let rotationRate: [Double]    // [x, y, z]
        let userAcceleration: [Double]
        let gravity: [Double]
        let attitude: [Double]        // [ix, iy, iz, r]
    }

    struct SerializedLock: Codable, Sendable {
        let yawTargetCompass: Double
        let gravity: [Double]
        let lockedAt: TimeInterval
    }

    struct SerializedImpactResult: Codable, Sendable {
        let timestamp: TimeInterval
        let peakVelocity: Double
        let faceAngleRaw: Double
        let confidence: Double
        let snappedToSquare: Bool
        let snapReason: String?
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, capturedAt, deviceModel, appVersion
        case samples, lock, windowStart, windowEnd, result, userNote
        case userImpactJudgment
        case batchId, batchStrokeIndex, batchStrokeType
    }
}

// MARK: - Schema-versioned + bounds-checked decoders
//
// Backward-compat note: v1 tester JSONs do NOT carry `schemaVersion`. We decode it
// with `decodeIfPresent ?? 1` so future additions can advance the version without
// breaking old files on disk. The custom `init(from:)` here OVERRIDES the synthesized
// decoder; the synthesized `encode(to:)` is preserved.
extension StrokeReplay {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        self.deviceModel = try c.decode(String.self, forKey: .deviceModel)
        self.appVersion = try c.decode(String.self, forKey: .appVersion)
        self.samples = try c.decode([SerializedSample].self, forKey: .samples)
        self.lock = try c.decode(SerializedLock.self, forKey: .lock)
        self.windowStart = try c.decode(TimeInterval.self, forKey: .windowStart)
        self.windowEnd = try c.decode(TimeInterval.self, forKey: .windowEnd)
        self.result = try c.decodeIfPresent(SerializedImpactResult.self, forKey: .result)
        self.userNote = try c.decodeIfPresent(String.self, forKey: .userNote)
        self.userImpactJudgment = try c.decodeIfPresent(String.self, forKey: .userImpactJudgment)
        self.batchId = try c.decodeIfPresent(String.self, forKey: .batchId)
        self.batchStrokeIndex = try c.decodeIfPresent(Int.self, forKey: .batchStrokeIndex)
        self.batchStrokeType = try c.decodeIfPresent(String.self, forKey: .batchStrokeType)
    }
}

extension StrokeReplay.SerializedLock {
    enum LockKeys: String, CodingKey {
        case yawTargetCompass, gravity, lockedAt
    }

    /// Bounds-checked decoder. A truncated `gravity` array used to decode
    /// successfully, then crash later in `toStrokeWindow()` where the array
    /// is force-indexed at [0..2]. Catching the mismatch here turns a hard
    /// crash into a skipped record at the per-file load layer.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LockKeys.self)
        self.yawTargetCompass = try c.decode(Double.self, forKey: .yawTargetCompass)
        self.lockedAt = try c.decode(TimeInterval.self, forKey: .lockedAt)
        let grv = try c.decode([Double].self, forKey: .gravity)
        guard grv.count == 3 else {
            throw DecodingError.dataCorruptedError(
                forKey: .gravity, in: c,
                debugDescription: "gravity must have 3 elements, got \(grv.count)"
            )
        }
        self.gravity = grv
    }
}

extension StrokeReplay.SerializedSample {
    enum SampleKeys: String, CodingKey {
        case timestamp, rotationRate, userAcceleration, gravity, attitude
    }

    // Bounds-checked decoder. Index-out-of-range on truncated arrays would crash the
    // ENTIRE batch load (e.g. when the tester opens History). Catching at decode time
    // turns the bad sample into a single skipped file, not a process death.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: SampleKeys.self)
        self.timestamp = try c.decode(TimeInterval.self, forKey: .timestamp)
        let rot = try c.decode([Double].self, forKey: .rotationRate)
        let acc = try c.decode([Double].self, forKey: .userAcceleration)
        let grv = try c.decode([Double].self, forKey: .gravity)
        let att = try c.decode([Double].self, forKey: .attitude)
        guard rot.count == 3 else {
            throw DecodingError.dataCorruptedError(
                forKey: .rotationRate, in: c,
                debugDescription: "rotationRate must have 3 elements, got \(rot.count)"
            )
        }
        guard acc.count == 3 else {
            throw DecodingError.dataCorruptedError(
                forKey: .userAcceleration, in: c,
                debugDescription: "userAcceleration must have 3 elements, got \(acc.count)"
            )
        }
        guard grv.count == 3 else {
            throw DecodingError.dataCorruptedError(
                forKey: .gravity, in: c,
                debugDescription: "gravity must have 3 elements, got \(grv.count)"
            )
        }
        guard att.count == 4 else {
            throw DecodingError.dataCorruptedError(
                forKey: .attitude, in: c,
                debugDescription: "attitude quaternion must have 4 elements, got \(att.count)"
            )
        }
        self.rotationRate = rot
        self.userAcceleration = acc
        self.gravity = grv
        self.attitude = att
    }
}

extension StrokeReplay {
    init(
        window: StrokeWindow,
        result: ImpactResult?,
        deviceModel: String,
        appVersion: String,
        userNote: String? = nil,
        userImpactJudgment: String? = nil,
        batchId: String? = nil,
        batchStrokeIndex: Int? = nil,
        batchStrokeType: String? = nil,
        now: Date = Date()
    ) {
        self.schemaVersion = 1
        self.capturedAt = now
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.userNote = userNote
        self.userImpactJudgment = userImpactJudgment
        self.batchId = batchId
        self.batchStrokeIndex = batchStrokeIndex
        self.batchStrokeType = batchStrokeType
        self.samples = window.samples.map { s in
            SerializedSample(
                timestamp: s.timestamp,
                rotationRate: [s.rotationRate.x, s.rotationRate.y, s.rotationRate.z],
                userAcceleration: [s.userAcceleration.x, s.userAcceleration.y, s.userAcceleration.z],
                gravity: [s.gravity.x, s.gravity.y, s.gravity.z],
                attitude: [s.attitude.imag.x, s.attitude.imag.y, s.attitude.imag.z, s.attitude.real]
            )
        }
        self.lock = SerializedLock(
            yawTargetCompass: window.lock.yawTargetCompass,
            gravity: [window.lock.gravity.x, window.lock.gravity.y, window.lock.gravity.z],
            lockedAt: window.lock.lockedAt
        )
        self.windowStart = window.start
        self.windowEnd = window.end
        if let r = result {
            self.result = SerializedImpactResult(
                timestamp: r.timestamp,
                peakVelocity: r.peakVelocity,
                faceAngleRaw: r.faceAngleRaw,
                confidence: r.confidence,
                snappedToSquare: r.snappedToSquare,
                snapReason: r.snapReason.map { String(describing: $0) }
            )
        } else {
            self.result = nil
        }
    }

    func toStrokeWindow() -> StrokeWindow {
        let motionSamples = samples.map { s in
            MotionSample(
                timestamp: s.timestamp,
                rotationRate: SIMD3(s.rotationRate[0], s.rotationRate[1], s.rotationRate[2]),
                userAcceleration: SIMD3(s.userAcceleration[0], s.userAcceleration[1], s.userAcceleration[2]),
                gravity: SIMD3(s.gravity[0], s.gravity[1], s.gravity[2]),
                attitude: simd_quatd(
                    ix: s.attitude[0],
                    iy: s.attitude[1],
                    iz: s.attitude[2],
                    r: s.attitude[3]
                )
            )
        }
        let stillnessLock = StillnessLock(
            yawTargetCompass: lock.yawTargetCompass,
            gravity: SIMD3(lock.gravity[0], lock.gravity[1], lock.gravity[2]),
            lockedAt: lock.lockedAt
        )
        return StrokeWindow(
            start: windowStart,
            end: windowEnd,
            samples: motionSamples,
            lock: stillnessLock
        )
    }
}

/// Stores stroke replays in Application Support so testers can save real strokes from
/// TestFlight and email the JSON back for offline debugging.
final class StrokeReplayStore: @unchecked Sendable {
    static let shared = StrokeReplayStore()

    private let directory: URL
    private let lock = NSLock()

    init(directory: URL? = nil) {
        if let d = directory {
            self.directory = d
        } else {
            // Documents (not Application Support) so the iOS Files app can see it.
            // Combined with UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace
            // in Info.plist, this lets the tester bulk-export every JSON to Drive.
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = documents.appendingPathComponent("StrokeReplays", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func save(_ replay: StrokeReplay) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: replay.capturedAt)
            .replacingOccurrences(of: ":", with: "-")
        let batchSegment: String = {
            guard let id = replay.batchId, !id.isEmpty,
                  let idx = replay.batchStrokeIndex, idx > 0 else { return "" }
            // Keep filename filesystem-safe: only letters/digits/dash.
            let safeId = id.filter { $0.isLetter || $0.isNumber }
            return safeId.isEmpty ? "" : "\(safeId)-\(idx)-"
        }()
        let filename = "stroke-\(batchSegment)\(timestamp).json"
        let url = directory.appendingPathComponent(filename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        // CoreMotion legitimately emits NaN/Inf during bad sensor fixes (e.g. magnetometer
        // calibration glitches). Default JSON refuses these, throws EncodingError, and
        // loses the stroke. Convert to string sentinels so the file is still written;
        // the matching decoder strategy round-trips them back to NaN/Inf.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "+inf",
            negativeInfinity: "-inf",
            nan: "nan"
        )
        let data = try encoder.encode(replay)
        try data.write(to: url, options: .atomic)
        return url
    }

    func load(from url: URL) throws -> StrokeReplay {
        let data = try Data(contentsOf: url)
        // Hard size cap — a corrupted/malicious 100MB JSON would OOM on iPhone 12.
        // 75 strokes × 200 samples × 6 doubles × ~16 chars JSON each ≈ ~1.5MB upper bound.
        // 10MB gives ~6x headroom for future schema growth + pretty printing variations.
        guard data.count <= 10 * 1024 * 1024 else {
            throw NSError(
                domain: "StrokeReplayStore", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Stroke replay too large (\(data.count) bytes)"]
            )
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "+inf",
            negativeInfinity: "-inf",
            nan: "nan"
        )
        return try decoder.decode(StrokeReplay.self, from: data)
    }

    func list() throws -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return try listLocked()
    }

    private func listLocked() throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// NOTE: NSLock is NOT reentrant. clear() previously called list() under its own lock
    /// → deadlock. Use the locked-helper version instead.
    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        let urls = try listLocked()
        for u in urls {
            try FileManager.default.removeItem(at: u)
        }
    }

    var directoryURL: URL { directory }
}
