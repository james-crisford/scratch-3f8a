import Foundation

struct StrokeWindow: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let samples: [MotionSample]
    let lock: StillnessLock

    var duration: TimeInterval { end - start }
}

enum StrokeDetectorPhase: Sendable, Equatable {
    case idle
    case armed
    case starting
    case recording
    case ended
}
