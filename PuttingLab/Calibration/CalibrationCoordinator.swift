import Foundation
import Observation

enum CalibrationStatus: Sendable, Equatable {
    case awaitingStrokes(collected: Int, required: Int)
    case stalled(consecutiveRejections: Int, hint: String)
    case complete(profile: CalibrationProfile)
}

@MainActor
@Observable
final class CalibrationCoordinator {
    let requiredStrokes: Int
    let targetDistanceFeet: Double

    var status: CalibrationStatus
    var rejectedCount: Int = 0

    private var inputs: [CalibrationInput] = []
    private var consecutiveRejections: Int = 0
    static let stallThreshold: Int = 3
    // B80 — "keep the phone vertical" was the dead one-hand hold spec;
    // the real grip is both hands, putter-style, pressed at address.
    static let stalledHint: String = "Couldn't read your last few strokes. Try a smoother arc and keep the same grip you pressed with."

    init(requiredStrokes: Int = 5, targetDistanceFeet: Double = 8.0) {
        self.requiredStrokes = requiredStrokes
        self.targetDistanceFeet = targetDistanceFeet
        self.status = .awaitingStrokes(collected: 0, required: requiredStrokes)
    }

    @discardableResult
    func ingest(window: StrokeWindow, impact: ImpactResult) -> CalibrationStatus {
        guard Self.isValid(impact: impact, window: window) else {
            rejectedCount += 1
            consecutiveRejections += 1
            if consecutiveRejections >= Self.stallThreshold {
                status = .stalled(consecutiveRejections: consecutiveRejections, hint: Self.stalledHint)
            }
            return status
        }
        consecutiveRejections = 0
        inputs.append(CalibrationInput(window: window, impact: impact))

        if inputs.count >= requiredStrokes {
            let profile = CalibrationModel.compute(
                from: inputs,
                targetDistanceFeet: targetDistanceFeet
            )
            status = .complete(profile: profile)
        } else {
            status = .awaitingStrokes(collected: inputs.count, required: requiredStrokes)
        }
        return status
    }

    func reset() {
        inputs.removeAll(keepingCapacity: true)
        rejectedCount = 0
        consecutiveRejections = 0
        status = .awaitingStrokes(collected: 0, required: requiredStrokes)
    }

    static func isValid(impact: ImpactResult, window: StrokeWindow) -> Bool {
        impact.confidence >= 0.5
            && window.duration >= 0.2
            && impact.peakVelocity >= 0.3
            && impact.peakVelocity.isFinite
            // A double-integration spike averaged into the 5-stroke mean
            // poisons the speed factor (one 9.0 among 0.35s -> factor
            // ~0.95 -> real putts roll centimetres). Mirror the physics
            // gate at intake so spikes count as rejections, not data.
            && impact.peakVelocity <= BallPhysics.maxPlausiblePeakVelocity
    }
}
