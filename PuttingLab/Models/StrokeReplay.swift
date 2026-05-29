import Foundation
import simd

/// Codable wrapper for a captured stroke + its window + the resulting impact.
/// Used to save real iPhone strokes from TestFlight to disk so we can replay them
/// through the algorithm offline and debug. JSON-friendly.
struct StrokeReplay: Codable, Sendable {
    let capturedAt: Date
    let deviceModel: String
    let appVersion: String
    let samples: [SerializedSample]
    let lock: SerializedLock
    let windowStart: TimeInterval
    let windowEnd: TimeInterval
    let result: SerializedImpactResult?
    let userNote: String?

    struct SerializedSample: Codable, Sendable {
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
}

extension StrokeReplay {
    init(
        window: StrokeWindow,
        result: ImpactResult?,
        deviceModel: String,
        appVersion: String,
        userNote: String? = nil,
        now: Date = Date()
    ) {
        self.capturedAt = now
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.userNote = userNote
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
        let filename = "stroke-\(formatter.string(from: replay.capturedAt)).json"
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent(filename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(replay)
        try data.write(to: url, options: .atomic)
        return url
    }

    func load(from url: URL) throws -> StrokeReplay {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
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
