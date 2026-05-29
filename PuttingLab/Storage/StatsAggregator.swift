import Foundation

struct SessionStats: Sendable, Equatable {
    let totalStrokes: Int
    let snappedStrokes: Int
    /// nil when no real (non-snapped) strokes exist — distinguishes "no data" from "0 ft achieved".
    let longestFeet: Double?
    /// nil when no real strokes — was previously 0 which read as "pin-perfect" in UI.
    let closestPinFeetFromTarget: Double?
    let bestTempoSeconds: TimeInterval?
    let mostAccurateFaceAngleDeg: Double?
    let todayStreak: Int
}

enum StatsAggregator {

    static let idealTempoSeconds: TimeInterval = 0.6

    static func aggregate(
        _ records: [StrokeRecord],
        targetFeet: Double = 8.0,
        referenceDate: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> SessionStats {
        guard !records.isEmpty else {
            return SessionStats(
                totalStrokes: 0,
                snappedStrokes: 0,
                longestFeet: nil,
                closestPinFeetFromTarget: nil,
                bestTempoSeconds: nil,
                mostAccurateFaceAngleDeg: nil,
                todayStreak: 0
            )
        }

        // Snapped (confidence==0) strokes pollute pin-distance + accuracy stats
        // (they'd register as "0 ft from pin" and "0° face angle"). Filter them out
        // of value stats; report the count separately.
        let real = records.filter { $0.confidence > 0 }
        let snapped = records.count - real.count
        let todayStreak = streak(records: records, referenceDate: referenceDate, calendar: calendar)

        guard !real.isEmpty else {
            return SessionStats(
                totalStrokes: records.count,
                snappedStrokes: snapped,
                longestFeet: nil,
                closestPinFeetFromTarget: nil,
                bestTempoSeconds: nil,
                mostAccurateFaceAngleDeg: nil,
                todayStreak: todayStreak
            )
        }

        let longest = real.map { $0.distanceFeet }.max()
        let closest = real.map { abs($0.distanceFeet - targetFeet) }.min()
        let bestTempo = real.map { $0.strokeDurationSeconds }
            .min(by: { abs($0 - Self.idealTempoSeconds) < abs($1 - Self.idealTempoSeconds) })
        let mostAccurate = real.map { abs($0.faceAngleRaw * 180.0 / .pi) }.min()

        return SessionStats(
            totalStrokes: records.count,
            snappedStrokes: snapped,
            longestFeet: longest,
            closestPinFeetFromTarget: closest,
            bestTempoSeconds: bestTempo,
            mostAccurateFaceAngleDeg: mostAccurate,
            todayStreak: todayStreak
        )
    }

    static func streak(
        records: [StrokeRecord],
        referenceDate: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Int {
        let today = calendar.startOfDay(for: referenceDate)
        return records.filter { calendar.startOfDay(for: $0.recordedAt) == today }.count
    }
}
