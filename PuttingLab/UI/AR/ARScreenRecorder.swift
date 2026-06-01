import Foundation
import Observation
import ReplayKit

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
}
