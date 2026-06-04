import SwiftUI
import UIKit

/// Wraps `UIActivityViewController` so SwiftUI can present the iOS
/// share sheet over all JSONs in `Documents/ARSessionLogs/`. James uses
/// this to AirDrop / Mail / Files-out the AR session data so we can see
/// what the slices actually captured on-device.
struct ARLogShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context: Context) {}
}

/// Collects every JSON snapshot the ARSessionLogger has written into
/// `Documents/ARSessionLogs/` and every MP4 the ARScreenRecorder has
/// saved into `Documents/ARSessionRecordings/`. Returns an empty array
/// if neither directory has been created yet (first-launch case).
///
/// Marked `nonisolated` so the filesystem walk doesn't lock the main
/// thread (Gemini B21 finding #2). Callers should `await`.
enum ARLogExport {
    static func collectAllLogURLs() async -> [URL] {
        let jsons  = await collect(dirName: "ARSessionLogs", ext: "json")
        let mp4s   = await collect(dirName: "ARSessionRecordings", ext: "mp4")
        // B39 dropped on-device JPG key-frame extraction now that
        // Gemini 2.5 Pro reads the MP4 natively at 30-60 fps — the
        // 1 Hz JPG snapshots it produced were strictly worse than
        // the live video. Pre-B39 builds may still have leftover
        // frames in the recordings dir; we intentionally do NOT
        // bundle them so the export stays lean. If a user wants
        // them, they're still in Documents/ARSessionRecordings/
        // via Files-app.
        return jsons + mp4s
    }

    private static func collect(dirName: String, ext: String) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                return [URL]()
            }
            let dir = docs.appendingPathComponent(dirName, isDirectory: true)
            guard let items = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                           includingPropertiesForKeys: [.contentModificationDateKey],
                                                                           options: [.skipsHiddenFiles]) else {
                return [URL]()
            }
            return items.filter { $0.pathExtension == ext }
                .sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return da > db
                }
        }.value
    }

    // MARK: - B68 unified bundle export
    //
    // Pre-B68 the AR Send flow handed UIActivityViewController a raw list
    // of file URLs (JSON + MP4). On AirDrop / Mail / Drive that lands as
    // 2-N separate files; the recipient must manually pair them by
    // timestamp suffix. Stroke-test export (StrokeReplayStore) sidesteps
    // this by zipping every replay into one archive via `stageExportSnapshot`
    // + `NSFileCoordinator(.forUploading)`, giving the user a single tap +
    // single artefact.
    //
    // This B68 helper mirrors that pattern for AR sessions: stage the
    // session's JSON + MP4 + a manifest into a temp dir, then zip it as
    // one `PuttingLab-ar-<sessionId-suffix>-<timestamp>.zip`. The Share
    // Sheet receives ONE url.
    //
    // The manifest doubles as proof-of-pairing for downstream review: it
    // records device model, app version, session duration, ARKit state
    // at session start, AND — critically — whether a CalibrationProfile
    // was loaded at onAppear with its bias/factor values. That last field
    // closes the "did the calibration actually save?" question we hit on
    // 2026-06-04 (a workflow agent claimed the profile wasn't persisted
    // because UserDefaults isn't on disk on the dev machine).

    /// Bundle scope for the unified export ZIP.
    enum BundleScope: Sendable {
        /// One session, identified by its logger.sessionId stem.
        case session(id: String)
        /// Every AR session JSON + MP4 currently on disk.
        case all
    }

    /// Lightweight manifest written into every bundle as `manifest.json`.
    /// Captures the metadata a reviewer cannot infer from raw file
    /// contents alone — version, ARKit state, calibration-profile
    /// presence at session start, file inventory.
    struct BundleManifest: Codable, Sendable {
        let bundleVersion: Int          // schema version of THIS manifest
        let createdAt: String           // ISO-8601 UTC
        let scope: String               // "session" | "all"
        let appVersion: String
        let deviceModel: String
        let osVersion: String
        let sessionIds: [String]        // every session stem represented in the bundle
        let files: [FileEntry]
        let calibrationProfileLoaded: Bool?
        let calibrationFaceAngleBiasDeg: Double?
        let calibrationSpeedToDistanceFactor: Double?
        let strokeReplaysIncluded: Int  // 0 when the bundle is AR-only

        struct FileEntry: Codable, Sendable {
            let filename: String
            let bytes: Int64
            let kind: String            // "session_json" | "recording_mp4" | "keyframe_jpg" | "stroke_replay_json"
        }
    }

    /// Stage the requested AR session(s) + the manifest into a fresh
    /// temp dir. Caller is responsible for cleaning the dir after the
    /// ZIP is produced (mirrors `StrokeReplayStore.stageExportSnapshot`).
    static func stageBundleSnapshot(scope: BundleScope,
                                    manifest: BundleManifest) throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let logsDir = docs.appendingPathComponent("ARSessionLogs", isDirectory: true)
        let recsDir = docs.appendingPathComponent("ARSessionRecordings", isDirectory: true)

        let stagingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PuttingLab-ar-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        let stems: [String]
        switch scope {
        case .session(let id):
            stems = [id]
        case .all:
            // Every JSON stem in ARSessionLogs/. Falls back to empty list
            // when first-launch (no logs yet).
            let jsons = (try? FileManager.default.contentsOfDirectory(at: logsDir,
                                                                       includingPropertiesForKeys: nil)) ?? []
            stems = jsons.filter { $0.pathExtension == "json" }
                .map { $0.deletingPathExtension().lastPathComponent }
        }

        for stem in stems {
            let jsonSrc = logsDir.appendingPathComponent("\(stem).json")
            if FileManager.default.fileExists(atPath: jsonSrc.path) {
                let dst = stagingURL.appendingPathComponent(jsonSrc.lastPathComponent)
                try FileManager.default.copyItem(at: jsonSrc, to: dst)
            }
            let mp4Src = recsDir.appendingPathComponent("\(stem).mp4")
            if FileManager.default.fileExists(atPath: mp4Src.path) {
                let dst = stagingURL.appendingPathComponent(mp4Src.lastPathComponent)
                try FileManager.default.copyItem(at: mp4Src, to: dst)
            }
            // Pre-B39 frame JPGs (if a build still has them on disk).
            let frames = (try? FileManager.default.contentsOfDirectory(at: recsDir,
                                                                        includingPropertiesForKeys: nil)) ?? []
            for f in frames where f.lastPathComponent.hasPrefix("\(stem)-frame-") {
                let dst = stagingURL.appendingPathComponent(f.lastPathComponent)
                try? FileManager.default.copyItem(at: f, to: dst)
            }
        }

        // B68 — also copy the on-disk calibration-profile mirror
        // (`Documents/calibrationProfile.json`) if it exists. The mirror
        // is written by PracticeSessionViewModel.persistCalibrationIfReady
        // after every cal-batch save. Including it in every AR bundle
        // closes the "did calibration actually persist?" gap: the
        // bundle's manifest carries the AR view's calibrationProfile
        // SNAPSHOT at session start, and `calibrationProfile.json`
        // carries the LAST WRITE from PracticeSession — comparing the
        // two tells us whether the profile flowed through ProfileStore
        // correctly.
        let calMirror = docs.appendingPathComponent("calibrationProfile.json")
        if FileManager.default.fileExists(atPath: calMirror.path) {
            let dst = stagingURL.appendingPathComponent(calMirror.lastPathComponent)
            try? FileManager.default.copyItem(at: calMirror, to: dst)
        }

        // Manifest as `manifest.json` at the root of the staging dir.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: stagingURL.appendingPathComponent("manifest.json"))

        return stagingURL
    }

    /// Zip the staging directory into a final share-ready URL. Uses
    /// `NSFileCoordinator(.forUploading)` — the same technique
    /// StrokeReplayStore uses for the stroke-test ZIP. Caller still
    /// owns cleanup of the staging URL.
    static func zipStagedBundle(stagingURL: URL,
                                bundleFilename: String) throws -> URL {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var savedURL: URL?
        var caughtError: Error?
        coordinator.coordinate(readingItemAt: stagingURL,
                                options: .forUploading,
                                error: &coordError) { zipURL in
            do {
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(bundleFilename)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: zipURL, to: dest)
                savedURL = dest
            } catch {
                caughtError = error
            }
        }
        if let url = savedURL { return url }
        if let e = caughtError { throw e }
        if let e = coordError { throw e }
        throw NSError(domain: "ARLogExport", code: 100,
                      userInfo: [NSLocalizedDescriptionKey: "Unknown bundle zip failure (no URL, no error)"])
    }

    /// One-shot helper: stage + zip + clean up the staging dir. Returns
    /// the final ZIP URL. Throws on any failure.
    static func buildBundleZip(scope: BundleScope,
                                manifest: BundleManifest) throws -> URL {
        let staging = try stageBundleSnapshot(scope: scope, manifest: manifest)
        defer { try? FileManager.default.removeItem(at: staging) }
        let suffix: String = {
            switch scope {
            case .session(let id):
                // Use the last 6 chars of the sessionId for a stable suffix.
                return String(id.suffix(6))
            case .all:
                return "all"
            }
        }()
        let stamp = bundleTimestamp()
        let filename = "PuttingLab-ar-\(suffix)-\(stamp).zip"
        return try zipStagedBundle(stagingURL: staging, bundleFilename: filename)
    }

    /// Locale-pinned (en_US_POSIX) and UTC-pinned filename timestamp.
    /// Without the pin, Thai-Buddhist / Japanese-Imperial calendars
    /// produce non-Gregorian year strings ("2569", "令6") — still valid
    /// filenames, but un-sortable across devices.
    nonisolated static func bundleTimestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }

    /// Inventory the staged files for the manifest. Cheap directory
    /// walk; runs after stageBundleSnapshot writes the files.
    static func inventoryStagedFiles(stagingURL: URL) -> [BundleManifest.FileEntry] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: stagingURL,
                                                                        includingPropertiesForKeys: [.fileSizeKey]) else {
            return []
        }
        return items
            .filter { $0.lastPathComponent != "manifest.json" }
            .map { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                let kind: String = {
                    switch url.pathExtension.lowercased() {
                    case "json": return "session_json"
                    case "mp4":  return "recording_mp4"
                    case "jpg":  return "keyframe_jpg"
                    default:     return "other"
                    }
                }()
                return BundleManifest.FileEntry(
                    filename: url.lastPathComponent,
                    bytes: size,
                    kind: kind
                )
            }
            .sorted { $0.filename < $1.filename }
    }
}
