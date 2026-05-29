import Foundation

struct SessionStats: Sendable, Equatable {
    let totalStrokes: Int
    let snappedStrokes: Int
    let longestFeet: Double
    let closestPinFeetFromTarget: Double
    let bestTempoSeconds: TimeInterval
    let mostAccurateFaceAngleDeg: Double
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
                longestFeet: 0,
                closestPinFeetFromTarget: 0,
                bestTempoSeconds: 0,
                mostAccurateFaceAngleDeg: 0,
                todayStreak: 0
            )
        }

        // Snapped (confidence==0) strokes pollute pin-distance + accuracy stats
        // (they'd register as "0 ft from pin" and "0° face angle"). Filter them out
        // of value stats; report the count separately.
        let real = records.filter { $0.confidence > 0 }
        let snapped = records.count - real.count

        let longest = real.map { $0.distanceFeet }.max() ?? 0
        let closest = real.map { abs($0.distanceFeet - targetFeet) }.min() ?? 0
        let bestTempo = real.map { $0.strokeDurationSeconds }
            .min(by: { abs($0 - Self.idealTempoSeconds) < abs($1 - Self.idealTempoSeconds) }) ?? 0
        let mostAccurate = real.map { abs($0.faceAngleRaw * 180.0 / .pi) }.min() ?? 0
        let todayStreak = streak(records: records, referenceDate: referenceDate, calendar: calendar)

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
