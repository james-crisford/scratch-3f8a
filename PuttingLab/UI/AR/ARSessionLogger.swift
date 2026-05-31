import Foundation
import Observation
import simd

/// In-memory + on-disk event log for AR Slice 1 / Slice 2 verification.
///
/// SwiftUI views observe `events` to render a live scrolling list in the
/// HUD — you can see what ARKit is doing in real-time, no Mac console
/// required. On `dismantleUIView` the coordinator calls `saveSnapshot()`
/// which writes the full event list as JSON to
/// `Documents/ARSessionLogs/`. The Files app + the History → Export All
/// button (UIFileSharingEnabled is on for this build) both pick up the
/// JSONs alongside stroke replays.
@MainActor
@Observable
final class ARSessionLogger {
    private(set) var events: [Event] = []
    private let sessionId: String
    private let startedAt: Date
    /// Hard cap on in-memory events so a long verification session
    /// doesn't grow unbounded. We still write everything we KEPT to disk.
    /// 500 is plenty for any reasonable Slice 1/2 session.
    static let maxEvents: Int = 500

    init(slice: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        self.sessionId = "ar-\(slice)-\(stamp)"
        self.startedAt = Date()
    }

    func log(_ event: Event) {
        events.append(event)
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
    }

    /// Convenience for the most common case.
    func log(_ kind: Event.Kind, _ message: String, payload: [String: String] = [:]) {
        log(Event(timestamp: Date(), kind: kind, message: message, payload: payload))
    }

    /// Write the accumulated events to `Documents/ARSessionLogs/<id>.json`.
    /// Idempotent: callers can invoke this on dismantle, on a "save now"
    /// button, etc. Errors are silently swallowed — this is debug data,
    /// not a critical path.
    func saveSnapshot() {
        let snapshot = Snapshot(
            sessionId: sessionId,
            startedAt: startedAt,
            endedAt: Date(),
            events: events
        )
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = docs.appendingPathComponent("ARSessionLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(sessionId).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    struct Snapshot: Codable, Sendable {
        let sessionId: String
        let startedAt: Date
        let endedAt: Date
        let events: [Event]
    }

    struct Event: Codable, Sendable, Identifiable {
        let id: UUID
        let timestamp: Date
        let kind: Kind
        let message: String
        let payload: [String: String]

        init(timestamp: Date, kind: Kind, message: String, payload: [String: String]) {
            self.id = UUID()
            self.timestamp = timestamp
            self.kind = kind
            self.message = message
            self.payload = payload
        }

        enum Kind: String, Codable, Sendable {
            case sessionStart
            case sessionEnd
            case trackingState
            case planeAdded
            case planeUpdated
            case planeRemoved
            case planeCount
            case tap
            case raycastHit
            case raycastMiss
            case ballPlaced
            case holePlaced
            case reset
            case interruption
            case interruptionEnded
            case failed
            case note
        }
    }
}

/// Helper for SwiftUI to format a SIMD3 position for the live HUD without
/// pulling in `simd`'s String(describing:) which is too noisy.
@MainActor
enum ARLogFmt {
    static func vec(_ v: SIMD3<Float>) -> String {
        String(format: "(%.2f, %.2f, %.2f)", v.x, v.y, v.z)
    }
    static func meters(_ d: Float) -> String {
        String(format: "%.2f m", d)
    }
}
