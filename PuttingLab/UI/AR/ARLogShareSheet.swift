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
/// `Documents/ARSessionLogs/`. Returns an empty array if the directory
/// hasn't been created yet (first-launch case).
enum ARLogExport {
    @MainActor
    static func collectAllLogURLs() -> [URL] {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        let dir = docs.appendingPathComponent("ARSessionLogs", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                       includingPropertiesForKeys: [.contentModificationDateKey],
                                                                       options: [.skipsHiddenFiles]) else {
            return []
        }
        // Newest first so the share-sheet preview lands on the most
        // recent run — usually the one James just finished.
        return items.filter { $0.pathExtension == "json" }
            .sorted { (a, b) in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
    }
}
