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
    /// Same string used as the saved-JSON filename stem and the paired
    /// MP4 filename stem. `nonisolated` so other actors (the screen
    /// recorder, the share sheet) can read it without a hop.
    let sessionId: String
    private let startedAt: Date
    /// Surfaces failed snapshot writes (e.g. iCloud sync conflict on
    /// Documents/) so the HUD can show the user instead of silently
    /// swallowing the error. nil = last save succeeded or no save yet.
    private(set) var lastSaveError: String?
    /// Hard cap on in-memory events so a long verification session
    /// doesn't grow unbounded. The `.sessionStart` event is pinned so
    /// long sessions don't lose their header context (was M13 in the
    /// 2026-05-31 audit). 500 is plenty for any reasonable Slice 1/2
    /// session.
    nonisolated static let maxEvents: Int = 500

    /// Marked `nonisolated` so @State construction of this type works
    /// from SwiftUI Preview macros + nonisolated test factories. Body
    /// only touches String + Date — no isolated state read.
    nonisolated init(slice: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        // Append a short UUID suffix so two loggers constructed within
        // the same millisecond don't produce identical filenames (M-LOW
        // collision risk in the 2026-05-31 audit).
        let suffix = UUID().uuidString.prefix(6)
        self.sessionId = "ar-\(slice)-\(stamp)-\(suffix)"
        self.startedAt = Date()
    }

    func log(_ event: Event) {
        events.append(event)
        if events.count > Self.maxEvents {
            // Pin the .sessionStart event so 500+ event sessions still
            // carry their header in the saved JSON. Drop the OLDEST
            // non-sessionStart event instead.
            if let firstStartIdx = events.firstIndex(where: { $0.kind == .sessionStart }),
               firstStartIdx == 0 {
                // sessionStart is at position 0 — drop the SECOND element
                // (oldest non-start) to keep the array bounded.
                events.remove(at: 1)
            } else {
                events.removeFirst(events.count - Self.maxEvents)
            }
        }
    }

    /// Convenience for the most common case.
    func log(_ kind: Event.Kind, _ message: String, payload: [String: String] = [:]) {
        log(Event(timestamp: Date(), kind: kind, message: message, payload: payload))
    }

    /// Write the accumulated events to `Documents/ARSessionLogs/<id>.json`.
    /// Idempotent: callers can invoke this on dismantle, on a "save now"
    /// button, etc. Errors surface via `lastSaveError` so the HUD can
    /// show the user rather than silently writing to /tmp where they
    /// can't reach it.
    ///
    /// JSON encoding + atomic disk write happen on a detached background
    /// task so a long event log can't freeze the main thread (Gemini
    /// B21 finding #2). Fire-and-forget; for cases where the caller
    /// needs the write to land before reading the URL (e.g. Export),
    /// use `saveSnapshotAndWait()` instead.
    func saveSnapshot() {
        Task { await saveSnapshotAndWait() }
    }

    /// Async variant — awaits the disk write. Used by the Export
    /// button so the just-saved JSON is on disk before the share-sheet
    /// scan picks it up.
    func saveSnapshotAndWait() async {
        let snapshotSessionId = sessionId
        let snapshot = Snapshot(
            sessionId: snapshotSessionId,
            startedAt: startedAt,
            endedAt: Date(),
            events: events
        )
        let result = await Self.writeSnapshotToDisk(snapshot, sessionId: snapshotSessionId)
        lastSaveError = result
    }

    /// Background-thread file write. Returns `nil` on success, or an
    /// error description on failure. Static + nonisolated so it doesn't
    /// hop back to MainActor mid-encode.
    private nonisolated static func writeSnapshotToDisk(_ snapshot: Snapshot,
                                                         sessionId: String) async -> String? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return "Documents directory unavailable"
        }
        let dir = docs.appendingPathComponent("ARSessionLogs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var url = dir.appendingPathComponent("\(sessionId).json")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
            // Tell iCloud Backup to skip this file — at 1 MP4-equivalent
            // per session a heavy user fills their 5 GB iCloud quota in
            // ~3 sessions if these are backed up. Also exclude the
            // ARSessionLogs directory itself so future writes inherit.
            var dirCopy = dir
            try? setExcludedFromBackup(url: &url)
            try? setExcludedFromBackup(url: &dirCopy)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Mark a file URL as `.isExcludedFromBackup = true` so the file
    /// stays on-device but does not consume iCloud Backup quota.
    /// Static + nonisolated so it composes with the background-task
    /// snapshot writer.
    nonisolated static func setExcludedFromBackup(url: inout URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
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
///
/// Pure stateless formatter — `String(format:)` is reentrant and the
/// SIMD3 read is a value copy. No isolation required, so callable from
/// any context including nonisolated ARSessionDelegate bodies.
enum ARLogFmt {
    static func vec(_ v: SIMD3<Float>) -> String {
        String(format: "(%.2f, %.2f, %.2f)", v.x, v.y, v.z)
    }
    static func meters(_ d: Float) -> String {
        String(format: "%.2f m", d)
    }
}
