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
        let jsons = await collect(dirName: "ARSessionLogs", ext: "json")
        let mp4s  = await collect(dirName: "ARSessionRecordings", ext: "mp4")
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
}
