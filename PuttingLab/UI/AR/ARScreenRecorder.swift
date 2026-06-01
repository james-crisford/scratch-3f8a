import AVFoundation
import Foundation
import Observation
import ReplayKit
import UIKit

/// Wraps ReplayKit so an AR slice can record what's actually on screen
/// (camera feed + plane overlay + HUD + ground-truth marker taps) and
/// save the MP4 alongside the session's JSON. Filenames share the
/// logger's sessionId so a reviewer can pair them by name without any
/// manifest lookup.
///
/// ReplayKit prompts the user once per install for screen-recording
/// permission. No Info.plist key is required. The mic is left OFF so
/// James's voice notes don't accidentally end up in the file.
@MainActor
@Observable
final class ARScreenRecorder {
    /// Where the next stop() will save its MP4. Set in start() so the
    /// caller's sessionId stays in scope across the async stop callback.
    private(set) var pendingOutputURL: URL?
    private(set) var isRecording: Bool = false
    /// Most-recent failure surfaced so the HUD can show "Recording
    /// unavailable" instead of silently doing nothing.
    private(set) var lastError: String?

    /// `nonisolated` so @State property initialisers in @MainActor
    /// Views can build one without an actor hop (matches the treatment
    /// on ARSessionLogger.init and ARPlacementScene.init).
    nonisolated init() {}

    /// Returns the URL the MP4 will be saved to, OR nil if ReplayKit
    /// isn't available on this device / iOS build.
    func start(sessionId: String) -> URL? {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            lastError = "ReplayKit unavailable on this device"
            return nil
        }
        recorder.isMicrophoneEnabled = false
        recorder.isCameraEnabled = false

        let url = Self.outputURL(forSessionId: sessionId)
        // Pre-delete any existing file at the destination — atomic save
        // on iOS 14+'s stopRecording(withOutput:) doesn't overwrite.
        try? FileManager.default.removeItem(at: url)

        pendingOutputURL = url
        recorder.startRecording { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.lastError = error.localizedDescription
                    self.pendingOutputURL = nil
                    self.isRecording = false
                } else {
                    self.lastError = nil
                    self.isRecording = true
                }
            }
        }
        return url
    }

    /// Stop recording and write the MP4 to the URL chosen by `start()`.
    /// Idempotent — no-op when no recording is in flight (e.g. on view
    /// dismiss with recording already stopped). Returns the final file
    /// URL via the completion if the write succeeded. Completion is
    /// `@Sendable` so it can cross the ReplayKit-callback / Task hop
    /// without tripping Swift 6 strict-concurrency.
    func stop(completion: @escaping @Sendable (URL?) -> Void) {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isRecording, let url = pendingOutputURL else {
            completion(nil)
            return
        }
        recorder.stopRecording(withOutput: url) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.isRecording = false
                if let error {
                    self.lastError = error.localizedDescription
                    self.pendingOutputURL = nil
                    completion(nil)
                } else {
                    self.lastError = nil
                    let saved = self.pendingOutputURL
                    self.pendingOutputURL = nil
                    if var savedCopy = saved {
                        // Don't back the MP4 up to iCloud — they're
                        // 5-30 MB per minute and would burn the user's
                        // quota fast. Local file remains user-visible
                        // via the Files app + Share Sheet.
                        try? ARSessionLogger.setExcludedFromBackup(url: &savedCopy)
                    }
                    completion(saved)
                }
            }
        }
    }

    /// `Documents/ARSessionRecordings/<sessionId>.mp4` — same parent
    /// `Documents/` root as the JSON logs so UIFileSharingEnabled + the
    /// Files app pick both up, and the Export Share Sheet can include
    /// MP4s in the same picker.
    static func outputURL(forSessionId sessionId: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = docs.appendingPathComponent("ARSessionRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(sessionId).mp4")
    }

    /// All MP4s saved by the recorder, newest first. Used by the
    /// Export Share Sheet to bundle videos alongside the JSON logs.
    static func collectAllRecordingURLs() -> [URL] {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        let dir = docs.appendingPathComponent("ARSessionRecordings", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                       includingPropertiesForKeys: [.contentModificationDateKey],
                                                                       options: [.skipsHiddenFiles]) else {
            return []
        }
        return items.filter { $0.pathExtension == "mp4" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
    }

    // MARK: - Key-frame extraction
    //
    // After the MP4 is finalised, we extract a JPG still at every
    // visually-meaningful event timestamp from the session log
    // (ballPlaced, holePlaced, planeAdded, planeRemoved, raycastMiss,
    // reset, interruption + every user-tapped ground-truth marker).
    // Frames sit alongside the MP4 in `Documents/ARSessionRecordings/`
    // and inherit the `<sessionId>` filename stem with a
    // `-frame-<seq>-<kind>-<HHMMSS>.jpg` suffix, so the Share Sheet
    // and the preflight pick them up automatically.
    //
    // The point: when James AirDrops a session bundle, the multimodal
    // reviewer (Claude) can ingest the JPGs directly without needing
    // local video tooling — instant visual confirmation of "the ball
    // landed exactly where the crosshair was" or "the green plane
    // overlay drifted off the floor" at every key moment.
    //
    // Frame size 480×854 portrait, JPG quality 0.8 ≈ 40-80 KB per
    // frame. Typical 30 s session has 3-6 interesting events → under
    // 0.5 MB of extra payload. Negligible.

    /// Time-syncing the JSON events to the MP4. ReplayKit reports
    /// neither the actual capture-start instant nor any embedded
    /// PTS, so we anchor on the FIRST event's timestamp as a proxy
    /// for video time t=0. There's a 100-300 ms lag between
    /// recorder.start() and the encoder's first frame; for 30 s
    /// verification videos that's well under a single frame at
    /// 30 fps. The audit's deeper ClockBridge fix will replace this
    /// when it lands.
    nonisolated static func extractKeyFrames(
        mp4URL: URL,
        sessionStartedAt: Date,
        events: [ARSessionLogger.Event]
    ) async {
        let asset = AVURLAsset(url: mp4URL)
        // Sanity check: an MP4 that hasn't fully flushed will throw
        // on `image(at:)`; bail rather than emit a half-finished
        // frame set.
        guard let duration = try? await asset.load(.duration),
              duration.seconds > 0.5 else {
            return
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 854)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

        let parentDir = mp4URL.deletingLastPathComponent()
        let stem = mp4URL.deletingPathExtension().lastPathComponent

        // Which event kinds get a frame. ballPlaced/holePlaced are
        // the headline moments; planeAdded/Removed show the AR mesh
        // state; raycastMiss shows what the user was aiming at when
        // the tap was rejected; reset/interruption capture failure
        // recovery. Ground-truth markers (Good / Plane wrong /
        // Drifted / Lost / freeform note) are matched separately by
        // the payload tag.
        let interestingKinds: Set<ARSessionLogger.Event.Kind> = [
            .ballPlaced, .holePlaced,
            .planeAdded, .planeRemoved,
            .raycastMiss, .reset,
            .interruption, .interruptionEnded,
            .failed,
        ]

        // 1) Periodic samples at 1 Hz so I see the "between events"
        //    gaps too — James pointed out a lot can happen in 3 s
        //    that isn't logged as a discrete event (overlay drift,
        //    panning, lighting shift). On a 30 s video that's
        //    30 frames ≈ 1.5 MB at the 480×854 / q=0.8 settings.
        // 2) Event samples at every interesting moment from the
        //    logger. Event filename carries the kind+tag so it's
        //    distinguishable from the periodic frames when scanning
        //    alphabetically.
        //
        // We emit both lists into a single chronologically-ordered
        // collection so the on-disk filenames sort to the actual
        // capture order without a separate index pass.
        struct FrameRequest {
            let videoSeconds: Double
            let label: String
            let absoluteTimestamp: Date
        }
        var requests: [FrameRequest] = []

        // Periodic ticks
        let sessionStartSeconds = 0.0
        let endSeconds = max(sessionStartSeconds, duration.seconds - 0.05)
        var t = sessionStartSeconds
        while t <= endSeconds {
            requests.append(FrameRequest(
                videoSeconds: t,
                label: "tick",
                absoluteTimestamp: sessionStartedAt.addingTimeInterval(t)
            ))
            t += 1.0
        }

        // Event frames
        for event in events {
            let isInteresting =
                interestingKinds.contains(event.kind) ||
                (event.kind == .note && event.payload["source"] == "user_marker")
            guard isInteresting else { continue }
            let videoSeconds = event.timestamp.timeIntervalSince(sessionStartedAt)
            guard videoSeconds >= 0, videoSeconds < endSeconds else { continue }
            let tagSuffix: String = {
                if event.kind == .note, let tag = event.payload["tag"], !tag.isEmpty { return "-\(tag)" }
                return ""
            }()
            let label = "\(event.kind.rawValue)\(tagSuffix)"
            requests.append(FrameRequest(
                videoSeconds: videoSeconds,
                label: label,
                absoluteTimestamp: event.timestamp
            ))
        }

        // Sort by video time so the sequence numbers reflect playback
        // order. Two requests within 50 ms (an event coinciding with
        // a tick) get DEDUPED — keep the event label (more useful).
        requests.sort {
            if $0.videoSeconds != $1.videoSeconds { return $0.videoSeconds < $1.videoSeconds }
            // Equal time — events outrank ticks.
            return $0.label != "tick" && $1.label == "tick"
        }
        var deduped: [FrameRequest] = []
        for req in requests {
            if let last = deduped.last,
               abs(last.videoSeconds - req.videoSeconds) < 0.05 {
                // Prefer the event label over the tick label.
                if last.label == "tick" && req.label != "tick" {
                    deduped.removeLast()
                    deduped.append(req)
                }
                continue
            }
            deduped.append(req)
        }

        var seq = 0
        for req in deduped {
            let cmTime = CMTime(seconds: req.videoSeconds, preferredTimescale: 600)
            do {
                let result = try await generator.image(at: cmTime)
                let uiImage = UIImage(cgImage: result.image)
                guard let data = uiImage.jpegData(compressionQuality: 0.8) else { continue }
                let hhmmss = filenameStamp(req.absoluteTimestamp)
                let filename = "\(stem)-frame-\(String(format: "%03d", seq))-\(req.label)-\(hhmmss).jpg"
                var url = parentDir.appendingPathComponent(filename)
                try data.write(to: url, options: .atomic)
                try? ARSessionLogger.setExcludedFromBackup(url: &url)
                seq += 1
            } catch {
                continue
            }
        }
    }

    private nonisolated static func filenameStamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    /// Companion to `collectAllRecordingURLs` — every key-frame JPG.
    /// Sorted alphabetically by filename so JSON+MP4+frames travel
    /// as a coherent group through the Share Sheet.
    static func collectAllKeyFrameURLs() -> [URL] {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        let dir = docs.appendingPathComponent("ARSessionRecordings", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                       includingPropertiesForKeys: [.contentModificationDateKey],
                                                                       options: [.skipsHiddenFiles]) else {
            return []
        }
        return items.filter { $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
