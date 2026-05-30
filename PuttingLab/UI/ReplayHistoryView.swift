import SwiftUI
import UIKit

struct ReplayHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [Entry] = []
    @State private var loadError: String?
    @State private var shareItem: ShareableURL?
    @State private var isPreparingExport: Bool = false
    @State private var exportError: String?

    let store: StrokeReplayStore

    init(store: StrokeReplayStore = .shared) {
        self.store = store
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Stroke history")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button { exportAll() } label: {
                                Label(
                                    entries.isEmpty
                                        ? "Export all (none yet)"
                                        : "Export all (\(entries.count))",
                                    systemImage: "square.and.arrow.up.on.square"
                                )
                            }
                            .disabled(entries.isEmpty || isPreparingExport)
                            Button { reload() } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            Button(role: .destructive) {
                                try? store.clear()
                                reload()
                            } label: {
                                Label("Clear all", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if let err = exportError {
                        Text(err)
                            .font(.caption)
                            .padding(8)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.red)
                            .padding()
                            .transition(.opacity)
                    }
                }
                .overlay {
                    if isPreparingExport {
                        ProgressView("Bundling strokes…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
        }
        .task { reload() }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    /// Stage every saved JSON into a curated snapshot directory (under the
    /// store lock, so no parallel save can sneak a half-written file in),
    /// zip it via NSFileCoordinator(.forUploading), and present the system
    /// share sheet so the user can AirDrop / save to Drive / email it as one
    /// item.
    ///
    /// Swift 6 strict-concurrency pattern: outer `Task` inherits the View
    /// body's MainActor isolation; inner `Task.detached` does the file I/O
    /// off-main; awaiting its `.value` lands back on MainActor so the
    /// `@State` mutations are isolation-correct.
    private func exportAll() {
        guard !isPreparingExport else { return }
        isPreparingExport = true
        exportError = nil
        let storeRef = store
        Task {
            do {
                let zipURL = try await Task.detached(priority: .userInitiated) {
                    try Self.buildExportZip(store: storeRef)
                }.value
                isPreparingExport = false
                shareItem = ShareableURL(url: zipURL)
            } catch {
                isPreparingExport = false
                exportError = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    /// Pure function: stage a snapshot, zip it, copy the zip to a UUID-named
    /// path, clean the staging dir. Throws on any failure. Caller (and the
    /// system share sheet) own the returned URL.
    nonisolated private static func buildExportZip(store: StrokeReplayStore) throws -> URL {
        let staging = try store.stageExportSnapshot()
        // Always clean up the staging dir, even if zipping fails.
        defer { try? FileManager.default.removeItem(at: staging) }

        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var savedURL: URL?
        var caughtError: Error?
        coordinator.coordinate(
            readingItemAt: staging,
            options: .forUploading,
            error: &coordError
        ) { zipURL in
            do {
                // UUID in the destination filename guarantees no collision
                // across rapid re-opens of the History sheet (H3 race fix).
                let stableName = "PuttingLab-strokes-\(timestampSuffix())-\(UUID().uuidString.prefix(8)).zip"
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(String(stableName))
                // Idempotent: ignore "no such file" but propagate other errors.
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
        throw NSError(
            domain: "ReplayHistoryView", code: 100,
            userInfo: [NSLocalizedDescriptionKey: "Unknown export failure (no URL, no error)"]
        )
    }

    /// Locale-pinned (en_US_POSIX) and UTC-pinned filename timestamp. Without
    /// the pin, Thai Buddhist / Japanese Imperial calendar devices produce
    /// non-Gregorian year strings ("2569", "令6") — still valid filenames,
    /// but un-sortable across mixed devices and unfamiliar to receiving
    /// support staff.
    nonisolated private static func timestampSuffix() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }

    @ViewBuilder
    private var content: some View {
        if let err = loadError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text(err).font(.callout)
            }
            .foregroundStyle(.secondary)
            .padding()
        } else if entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No strokes captured yet")
                    .foregroundStyle(.secondary)
                Text("Stroke recordings appear here automatically after each completed stroke.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .padding()
        } else {
            List(entries) { entry in
                row(entry)
            }
        }
    }

    private func row(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.formattedTime)
                    .font(.headline)
                Spacer()
                if let batchTag = entry.batchTag {
                    Text(batchTag)
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
                if let snap = entry.snapReason {
                    Text(snap)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
            }
            if let strokeType = entry.strokeType {
                Text(strokeType)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading) {
                    Text("face").font(.caption2).foregroundStyle(.secondary)
                    Text(entry.faceLabel).font(.callout.monospaced())
                }
                VStack(alignment: .leading) {
                    Text("peak").font(.caption2).foregroundStyle(.secondary)
                    Text(entry.peakLabel).font(.callout.monospaced())
                }
                VStack(alignment: .leading) {
                    Text("conf").font(.caption2).foregroundStyle(.secondary)
                    Text(entry.confidenceLabel).font(.callout.monospaced())
                }
                Spacer()
                Button {
                    shareItem = ShareableURL(url: entry.url)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
            }
            Text("\(entry.sampleCount) samples · \(entry.deviceModel)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func reload() {
        do {
            let urls = try store.list()
            var loaded: [Entry] = []
            loaded.reserveCapacity(urls.count)
            for u in urls.prefix(50) {
                if let r = try? store.load(from: u) {
                    loaded.append(Entry(url: u, replay: r))
                }
            }
            entries = loaded
            loadError = nil
        } catch {
            loadError = "Couldn't read history: \(error.localizedDescription)"
        }
    }

    fileprivate struct Entry: Identifiable {
        let url: URL
        let replay: StrokeReplay
        var id: String { url.lastPathComponent }

        var formattedTime: String {
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .medium
            return f.string(from: replay.capturedAt)
        }
        var faceLabel: String {
            guard let r = replay.result else { return "—" }
            if r.snappedToSquare { return "Square" }
            let deg = r.faceAngleRaw * 180.0 / .pi
            return String(format: "%+.2f°", deg)
        }
        var peakLabel: String {
            guard let r = replay.result else { return "—" }
            return String(format: "%.2f m/s", r.peakVelocity)
        }
        var confidenceLabel: String {
            guard let r = replay.result else { return "—" }
            return String(format: "%.2f", r.confidence)
        }
        var snapReason: String? { replay.result?.snapReason }
        var sampleCount: Int { replay.samples.count }
        var deviceModel: String { replay.deviceModel }
        var batchTag: String? {
            guard let id = replay.batchId, !id.isEmpty else { return nil }
            if let idx = replay.batchStrokeIndex, idx > 0 {
                return "\(id) · #\(idx)"
            }
            return id
        }
        var strokeType: String? {
            guard let t = replay.batchStrokeType, !t.isEmpty else { return nil }
            if let j = replay.userImpactJudgment, !j.isEmpty {
                return "\(t) · felt \(j.replacingOccurrences(of: "_", with: " "))"
            }
            return t
        }
    }
}

private struct ShareableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
