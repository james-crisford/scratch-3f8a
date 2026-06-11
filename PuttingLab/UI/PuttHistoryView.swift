import SwiftUI

/// B71 — user-facing putt history. Reads the same StrokeReplayStore that
/// the engineer-debug ReplayHistoryView reads, but presents one row per
/// putt with the user-relevant fields (time, peak velocity, face angle,
/// Mario Kart bucket label + color chip). Tap a row → simple detail
/// card. Groups by calendar day with friendly section headers.
///
/// Deliberately simple. No charts, no filters, no aggregate stats card —
/// those land in B72+ once we've validated this is the right shape.
struct PuttHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [Entry] = []
    @State private var loadError: String?
    @State private var selected: Entry?

    let store: StrokeReplayStore
    private let marioKart: MarioKartAssist

    init(store: StrokeReplayStore = .shared,
         marioKart: MarioKartAssist = MarioKartAssist()) {
        self.store = store
        self.marioKart = marioKart
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Putt history")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .task { reload() }
                .refreshable { reload() }
                .sheet(item: $selected) { entry in
                    PuttDetailCard(entry: entry)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let err = loadError {
            ContentUnavailableView(
                "Couldn't load",
                systemImage: "exclamationmark.triangle",
                description: Text(err)
            )
        } else if entries.isEmpty {
            ContentUnavailableView(
                "No putts yet",
                systemImage: "figure.golf",
                description: Text("Take your first putt in AR mode or PracticeSession — it'll show up here.")
            )
        } else {
            List {
                ForEach(groupedByDay(), id: \.section) { section in
                    Section(section.section) {
                        ForEach(section.entries) { entry in
                            Button { selected = entry } label: {
                                row(entry)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("putt.history.row")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(entry.bucketColor)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.timeText)
                        .font(.headline)
                        .monospacedDigit()
                    Text(entry.bucketLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(entry.bucketColor)
                }
                Text(entry.summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func reload() {
        do {
            let urls = try store.list()
            var loaded: [Entry] = []
            loaded.reserveCapacity(min(urls.count, 50))
            for u in urls.prefix(50) {
                if let r = try? store.load(from: u) {
                    // B80 — bucket on the sign-normalized value so pre-fix
                    // records don't display mirrored pull/push labels.
                    loaded.append(Entry(url: u, replay: r,
                                         direction: marioKart.bucket(
                                            faceAngleDeg: r.result.map { $0.faceAngleRawCurrentConvention * 180.0 / .pi } ?? 0
                                         )))
                }
            }
            entries = loaded
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func groupedByDay() -> [DaySection] {
        let cal = Calendar.current
        let now = Date()
        let groups = Dictionary(grouping: entries) { entry in
            cal.startOfDay(for: entry.replay.capturedAt)
        }
        let sortedKeys = groups.keys.sorted(by: >)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return sortedKeys.map { dayStart in
            let label: String = {
                if cal.isDateInToday(dayStart) { return "Today" }
                if cal.isDateInYesterday(dayStart) { return "Yesterday" }
                if let days = cal.dateComponents([.day], from: dayStart, to: now).day,
                   days < 7 {
                    let weekday = DateFormatter()
                    weekday.dateFormat = "EEEE"
                    return weekday.string(from: dayStart)
                }
                return formatter.string(from: dayStart)
            }()
            let sortedEntries = (groups[dayStart] ?? []).sorted { $0.replay.capturedAt > $1.replay.capturedAt }
            return DaySection(section: label, entries: sortedEntries)
        }
    }

    fileprivate struct DaySection: Identifiable {
        let section: String
        let entries: [Entry]
        var id: String { section }
    }

    fileprivate struct Entry: Identifiable {
        let url: URL
        let replay: StrokeReplay
        let direction: DirectionResult

        var id: String { url.lastPathComponent }

        var timeText: String {
            let f = DateFormatter()
            f.timeStyle = .short
            f.dateStyle = .none
            return f.string(from: replay.capturedAt)
        }

        var bucketLabel: String { direction.label }

        /// Colour mapping. Square = secondary (neutral); slight pulls/
        /// pushes = yellow; full pulls/pushes = orange; miss (snapped
        /// or otherwise rejected) = red. Kept distinct from the AR view's
        /// aim-line yellow so the user doesn't confuse history chips
        /// with aim affordances.
        var bucketColor: Color {
            switch direction.bucket {
            case .square: return .secondary
            case .slightPull, .slightPush: return .yellow
            case .pull, .push: return .orange
            case .miss: return .red
            }
        }

        var summaryText: String {
            let v = replay.result?.peakVelocity ?? 0
            let fdeg = (replay.result?.faceAngleRawCurrentConvention ?? 0) * 180.0 / .pi
            let snapped = replay.result?.snappedToSquare == true
            let faceText = snapped ? "snapped" : String(format: "%+.1f°", fdeg)
            let batch = (replay.batchId ?? "").isEmpty ? "" : " · \(replay.batchId!)"
            return String(format: "v=%.3f m/s · face %@%@", v, faceText, batch)
        }
    }
}

/// Compact detail card shown when a putt row is tapped. Just shows the
/// raw numbers + Mario Kart cause string. Nothing fancy — the engineer
/// debug view (ReplayHistoryView) is still the place for full telemetry.
private struct PuttDetailCard: View {
    let entry: PuttHistoryView.Entry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("When") {
                    LabeledContent("Date", value: dateText)
                    LabeledContent("Time", value: timeText)
                    if let id = entry.replay.batchId, !id.isEmpty {
                        LabeledContent("Batch", value: "\(id) · #\(entry.replay.batchStrokeIndex ?? 0)")
                    }
                }
                Section("Result") {
                    LabeledContent("Bucket", value: entry.bucketLabel)
                    LabeledContent("Cause") {
                        Text(entry.direction.cause)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Face angle",
                                   value: String(format: "%+.2f°",
                                                  (entry.replay.result?.faceAngleRawCurrentConvention ?? 0) * 180.0 / .pi))
                    LabeledContent("Peak velocity",
                                   value: String(format: "%.3f m/s", entry.replay.result?.peakVelocity ?? 0))
                    LabeledContent("Confidence",
                                   value: String(format: "%.2f", entry.replay.result?.confidence ?? 0))
                    if entry.replay.result?.snappedToSquare == true {
                        LabeledContent("Snap reason",
                                       value: entry.replay.result?.snapReason ?? "—")
                    }
                }
                Section("Stroke window") {
                    LabeledContent("Samples", value: "\(entry.replay.samples.count)")
                    LabeledContent("Window",
                                   value: String(format: "%.2fs",
                                                  entry.replay.windowEnd - entry.replay.windowStart))
                }
                Section("Recorded on") {
                    LabeledContent("Device", value: entry.replay.deviceModel)
                    LabeledContent("App version", value: entry.replay.appVersion)
                }
            }
            .navigationTitle("Putt detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var dateText: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: entry.replay.capturedAt)
    }
    private var timeText: String {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return f.string(from: entry.replay.capturedAt)
    }
}
