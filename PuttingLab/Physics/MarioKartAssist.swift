import Foundation

enum DirectionBucket: String, Sendable, Equatable, Codable {
    case square
    case slightPull
    case slightPush
    case pull
    case push
    case miss
}

struct ConfidenceFlags: Sendable, Equatable {
    let arkitLostMoreThanHalf: Bool
    let strokeUnder200ms: Bool
    let noClearPeak: Bool
    let peakSpeedUnder0_3Mps: Bool

    var anyLow: Bool {
        arkitLostMoreThanHalf || strokeUnder200ms || noClearPeak || peakSpeedUnder0_3Mps
    }

    static let none = ConfidenceFlags(
        arkitLostMoreThanHalf: false,
        strokeUnder200ms: false,
        noClearPeak: false,
        peakSpeedUnder0_3Mps: false
    )
}

struct DirectionResult: Sendable, Equatable {
    let bucket: DirectionBucket
    let label: String
    let displayDegrees: Double
    let cause: String
    let snappedToSquare: Bool
}

final class MarioKartAssist: Sendable {
    static let squareThresholdDeg: Double = 6.0
    static let slightThresholdDeg: Double = 12.0
    static let pushPullThresholdDeg: Double = 20.0

    /// Snap-aware overload that derives flags from a snapped `ImpactResult` (preferred call site
    /// for consumers receiving an `ImpactResult` directly — ensures the spec §5.2 snap-to-square
    /// cause string is surfaced instead of the generic "Centre strike" copy.
    func bucket(from impact: ImpactResult, flags: ConfidenceFlags = .none) -> DirectionResult {
        if impact.snappedToSquare {
            let cause = causeForSnapReason(impact.snapReason)
            return DirectionResult(
                bucket: .square,
                label: "Square",
                displayDegrees: 0,
                cause: cause,
                snappedToSquare: true
            )
        }
        return bucket(faceAngleDeg: impact.faceAngleDegrees, flags: flags)
    }

    private func causeForSnapReason(_ reason: SnapReason?) -> String {
        switch reason {
        case .strokeTooShort:
            return "Too quick to read — slow it down a touch."
        case .noClearPeak:
            return "Couldn't find impact — try a smoother arc."
        case .arkitLost:
            return "Camera lost tracking — calling it Square to be safe."
        case .peakSpeedTooLow:
            return "Soft tap — not enough swing speed to read."
        case .none:
            return "Low confidence — calling it Square."
        }
    }

    func bucket(faceAngleDeg: Double, flags: ConfidenceFlags = .none) -> DirectionResult {
        // A non-finite face angle (NaN attitude from a bad sensor fix)
        // otherwise falls through every comparison into the widest bucket
        // and renders "+nan deg" to the user. Wii rule: err toward Square.
        // (Found by `plab fuzz` 2026-07-02.)
        guard faceAngleDeg.isFinite else {
            return DirectionResult(
                bucket: .square,
                label: "Square",
                displayDegrees: 0,
                cause: "Couldn't read the face angle on that one",
                snappedToSquare: true
            )
        }
        if flags.anyLow {
            return DirectionResult(
                bucket: .square,
                label: "Square",
                displayDegrees: 0,
                cause: lowConfidenceCause(flags),
                snappedToSquare: true
            )
        }

        let absD = abs(faceAngleDeg)
        let isPull = faceAngleDeg < 0

        if absD < Self.squareThresholdDeg {
            return DirectionResult(
                bucket: .square,
                label: "Square",
                displayDegrees: 0,
                cause: "Centre strike — straight on the target line.",
                snappedToSquare: false
            )
        }
        if absD < Self.slightThresholdDeg {
            return DirectionResult(
                bucket: isPull ? .slightPull : .slightPush,
                label: isPull ? "Slight pull" : "Slight push",
                displayDegrees: faceAngleDeg,
                cause: isPull
                    ? "Face closed a touch — toe of the putter led."
                    : "Face opened a touch — heel led through impact.",
                snappedToSquare: false
            )
        }
        if absD < Self.pushPullThresholdDeg {
            return DirectionResult(
                bucket: isPull ? .pull : .push,
                label: isPull ? "Pull" : "Push",
                displayDegrees: faceAngleDeg,
                cause: isPull
                    ? "Face closed at impact — ball goes left of the line."
                    : "Face open at impact — ball goes right of the line.",
                snappedToSquare: false
            )
        }
        return DirectionResult(
            bucket: .miss,
            label: "Miss",
            displayDegrees: faceAngleDeg,
            cause: isPull
                ? "Severe pull — face was well closed."
                : "Severe push — face was well open.",
            snappedToSquare: false
        )
    }

    private func lowConfidenceCause(_ flags: ConfidenceFlags) -> String {
        if flags.peakSpeedUnder0_3Mps {
            return "Soft tap — not enough swing speed to read."
        }
        if flags.strokeUnder200ms {
            return "Too quick to read — slow it down a touch."
        }
        if flags.noClearPeak {
            return "Couldn't find impact — try a smoother arc."
        }
        if flags.arkitLostMoreThanHalf {
            return "Camera lost tracking — calling it Square to be safe."
        }
        return "Low confidence — calling it Square."
    }
}
