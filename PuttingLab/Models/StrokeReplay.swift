import Foundation
import simd

/// Codable wrapper for a captured stroke + its window + the resulting impact.
/// Used to save real iPhone strokes from TestFlight to disk so we can replay them
/// through the algorithm offline and debug. JSON-friendly.
///
/// **Schema version 2** (2026-06-08 — B78). v2 adds `attitudeAtPress` to the
/// serialized lock and a `faceAngleRawMeaning` tag on the result, both for the
/// press-attitude-delta face-angle pipeline. v1 replays still load — missing
/// `attitudeAtPress` falls back to the first sample's attitude, which is
/// approximately what would have been captured at press in the legacy
/// pipeline. New fields MUST keep using `decodeIfPresent` so old tester JSONs
/// continue to deserialize forever.
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
        /// B78 (schemaVersion 2) — `[ix, iy, iz, r]`. nil in v1 replays.
        let attitudeAtPress: [Double]?
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

        /// B80 — `faceAngleRaw` normalized to the CURRENT (v3 golf-sign)
        /// convention for display: v3-tagged records pass through; v2/v1/
        /// untagged records were captured under the inverted sign (CCW-
        /// positive impact − press) and are negated so old and new strokes
        /// read consistently in history views. Display-only — never write
        /// this back into a replay (round-trip must stay byte-faithful).
        var faceAngleRawCurrentConvention: Double {
            faceAngleRawMeaning == "v3_press_attitude_delta_golf_sign"
                ? faceAngleRaw
                : -faceAngleRaw
        }
        /// B78 (schemaVersion 2). One of:
        ///   * `"v3_press_attitude_delta_golf_sign"` — B80+: yaw(press) −
        ///     yaw(impact); negative = closed/pull/left (golf convention).
        ///   * `"v2_press_attitude_delta"` — B78/B79: yaw(impact) − yaw(press),
        ///     no bias. INVERTED sign relative to v3.
        ///   * `"v1_arkit_compass_fused_with_bias"` — legacy pipeline (also
        ///     pre-golf-sign).
        /// Lets offline analysers reason about cross-build mixes without
        /// re-deriving from schemaVersion + appVersion.
        let faceAngleRawMeaning: String?
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
        case yawTargetCompass, attitudeAtPress, gravity, lockedAt
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
        if let q = try c.decodeIfPresent([Double].self, forKey: .attitudeAtPress) {
            guard q.count == 4 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .attitudeAtPress, in: c,
                    debugDescription: "attitudeAtPress quaternion must have 4 elements, got \(q.count)"
                )
            }
            self.attitudeAtPress = q
        } else {
            self.attitudeAtPress = nil
        }
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
        self.schemaVersion = 2
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
        let q = window.lock.attitudeAtPress
        self.lock = SerializedLock(
            yawTargetCompass: window.lock.yawTargetCompass,
            attitudeAtPress: [q.imag.x, q.imag.y, q.imag.z, q.real],
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
                snapReason: r.snapReason.map { String(describing: $0) },
                // B80 — golf-sign convention (negative = closed/pull/left;
                // producer emits press - impact). v2-tagged or untagged
                // records carry the OLD inverted sign — offline tools and
                // history views must branch on this tag before comparing.
                faceAngleRawMeaning: "v3_press_attitude_delta_golf_sign"
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
        // B78 — v2 replays carry `attitudeAtPress` directly. v1 replays
        // predate the field; fall back to the first window sample's attitude,
        // which is the closest thing the legacy capture pipeline stored to a
        // press-moment quaternion. The legacy face-angle would have been
        // computed differently anyway, so replays of v1 strokes are for
        // window/impact inspection — not for re-deriving face angles.
        let pressAttitude: simd_quatd
        if let q = lock.attitudeAtPress {
            pressAttitude = simd_quatd(ix: q[0], iy: q[1], iz: q[2], r: q[3])
        } else if let firstSample = motionSamples.first {
            pressAttitude = firstSample.attitude
        } else {
            pressAttitude = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        }
        let stillnessLock = StillnessLock(
            yawTargetCompass: lock.yawTargetCompass,
            attitudeAtPress: pressAttitude,
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

    /// Max replay file size on disk (bytes). 75 strokes × 200 samples × 6
    /// doubles × ~16 chars JSON each ≈ ~1.5 MB; 10 MB gives ~6× headroom
    /// for pretty-printing + schema growth. Anything larger is rejected
    /// BEFORE we read it into memory.
    static let maxReplayFileSizeBytes: Int = 10 * 1024 * 1024

    /// Max consecutive opening brackets/braces in a replay JSON. Foundation's
    /// `JSONDecoder` does not enforce a nesting cap; a 9 MB file of `[[[…]]]`
    /// would recurse the decoder until it stack-overflows. 100 is far above
    /// any legitimate StrokeReplay nesting (~6 levels deep).
    static let maxJSONNestingDepth: Int = 100

    func load(from url: URL) throws -> StrokeReplay {
        // M5 (security): stat file BEFORE loading it into RAM. The old order
        // `Data(contentsOf:) → check size` pulled multi-hundred-MB files into
        // memory on iPhone 12 before noticing they were too big and got
        // jetsam-killed.
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs[.size] as? Int, size > Self.maxReplayFileSizeBytes {
            throw NSError(
                domain: "StrokeReplayStore", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Stroke replay too large (\(size) bytes, max \(Self.maxReplayFileSizeBytes))"]
            )
        }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maxReplayFileSizeBytes else {
            throw NSError(
                domain: "StrokeReplayStore", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Stroke replay too large (\(data.count) bytes)"]
            )
        }
        // M4 (security): cap JSON nesting depth before handing to decoder.
        // Cheap byte-scan: max run of consecutive `[` or `{` (string-literal
        // brackets count too, but that costs us nothing — a real replay
        // never has 100 consecutive open-brackets anywhere).
        try Self.assertJSONNestingDepthOK(data: data, max: Self.maxJSONNestingDepth)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "+inf",
            negativeInfinity: "-inf",
            nan: "nan"
        )
        let replay = try decoder.decode(StrokeReplay.self, from: data)
        // L1 (security/robustness): a malicious replay may carry NaN/Inf in
        // timestamp / rotationRate / userAcceleration / gravity / attitude.
        // The encoder's `convertToString` path round-trips them back to NaN
        // on decode — that NaN then propagates into ImpactDetector.detect()
        // and downstream UI formatters which can crash or render garbage.
        try Self.assertAllSamplesFinite(replay.samples)
        // Same defence for the cached ImpactResult — NaN in peakVelocity /
        // faceAngleRaw / confidence / timestamp would crash the history-
        // view formatters or skew offline algorithm replays.
        if let r = replay.result {
            try Self.assertResultFinite(r)
        }
        try Self.assertLockFinite(replay.lock)
        return replay
    }

    private static func assertJSONNestingDepthOK(data: Data, max: Int) throws {
        // Cheap heuristic — track actual nesting depth (open brackets
        // increment, close brackets decrement), not the longest
        // consecutive run of opens. The old "longest run" formulation
        // missed nesting that included sibling close-brackets between
        // open-brackets (`[[[]]],[[[]]]` looked depth-3 even when chained
        // into deeper structures). Brackets inside string literals still
        // count, but a real StrokeReplay never has 100 of those — a false
        // reject on a malicious file beats a stack overflow on a real one.
        var depth = 0
        for b in data {
            if b == UInt8(ascii: "[") || b == UInt8(ascii: "{") {
                depth += 1
                if depth > max {
                    throw NSError(
                        domain: "StrokeReplayStore", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "JSON nesting depth > \(max) — rejected (potential decoder stack overflow)"]
                    )
                }
            } else if b == UInt8(ascii: "]") || b == UInt8(ascii: "}") {
                if depth > 0 { depth -= 1 }
            }
        }
    }

    private static func assertAllSamplesFinite(_ samples: [StrokeReplay.SerializedSample]) throws {
        for (i, s) in samples.enumerated() {
            if !s.timestamp.isFinite {
                throw NSError(
                    domain: "StrokeReplayStore", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Non-finite timestamp at sample[\(i)]"]
                )
            }
            if !s.rotationRate.allSatisfy({ $0.isFinite }) ||
                !s.userAcceleration.allSatisfy({ $0.isFinite }) ||
                !s.gravity.allSatisfy({ $0.isFinite }) ||
                !s.attitude.allSatisfy({ $0.isFinite }) {
                throw NSError(
                    domain: "StrokeReplayStore", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Non-finite motion data at sample[\(i)]"]
                )
            }
        }
    }

    private static func assertResultFinite(_ r: StrokeReplay.SerializedImpactResult) throws {
        if !r.timestamp.isFinite || !r.peakVelocity.isFinite ||
            !r.faceAngleRaw.isFinite || !r.confidence.isFinite {
            throw NSError(
                domain: "StrokeReplayStore", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Non-finite ImpactResult field"]
            )
        }
    }

    private static func assertLockFinite(_ l: StrokeReplay.SerializedLock) throws {
        if !l.yawTargetCompass.isFinite || !l.lockedAt.isFinite ||
            !l.gravity.allSatisfy({ $0.isFinite }) {
            throw NSError(
                domain: "StrokeReplayStore", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Non-finite StillnessLock field"]
            )
        }
        if let q = l.attitudeAtPress, !q.allSatisfy({ $0.isFinite }) {
            throw NSError(
                domain: "StrokeReplayStore", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Non-finite attitudeAtPress quaternion"]
            )
        }
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

    /// Snapshot for bulk export. Under the write lock, copies every CURRENT
    /// `.json` stroke replay into a fresh staging directory and returns its
    /// URL. The caller (ReplayHistoryView) then zips THIS dir and shares it.
    ///
    /// Two security fixes vs the old "zip the whole StrokeReplays dir"
    /// approach:
    /// 1. Excludes any non-.json files an attacker dropped via the
    ///    Files-app share (`UIFileSharingEnabled=true`) — only files we
    ///    wrote ourselves are included.
    /// 2. Takes the store's write lock around the file-copy loop so a
    ///    parallel `save()` cannot leak a half-finished JSON into the
    ///    snapshot.
    ///
    /// Returns the staging dir URL. Caller is responsible for cleanup.
    func stageExportSnapshot() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let stagingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuttingLab-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        let urls = try listLocked()
        for u in urls {
            let dest = stagingURL.appendingPathComponent(u.lastPathComponent)
            try FileManager.default.copyItem(at: u, to: dest)
        }
        return stagingURL
    }
}
