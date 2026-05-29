import Foundation

enum StrokeDetectorError: Error, Equatable {
    case armWhileActive
}

final class StrokeDetector: @unchecked Sendable {
    static let startThresholdRadPerSec: Double = 30.0 * .pi / 180.0
    static let startSustainSeconds: TimeInterval = 0.050
    static let endQuietSeconds: TimeInterval = 0.300
    static let hardCutoffSeconds: TimeInterval = 2.0
    static let fpTolerance: TimeInterval = 1e-6

    private let lock = NSLock()
    private var state: StrokeDetectorPhase = .idle
    private var armedLock: StillnessLock?
    private var aboveSince: TimeInterval?
    private var belowSince: TimeInterval?
    private var strokeStart: TimeInterval?
    private var buffer: [MotionSample] = []

    var phase: StrokeDetectorPhase {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    var sampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count
    }

    func arm(with stillnessLock: StillnessLock) throws {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .starting, .recording:
            throw StrokeDetectorError.armWhileActive
        case .idle, .armed, .ended:
            armedLock = stillnessLock
            state = .armed
            aboveSince = nil
            belowSince = nil
            strokeStart = nil
            buffer.removeAll(keepingCapacity: true)
        }
    }

    func consume(_ sample: MotionSample) -> StrokeWindow? {
        lock.lock(); defer { lock.unlock() }
        let rotMag = sample.rotationMagnitude
        let above = rotMag > Self.startThresholdRadPerSec

        switch state {
        case .idle, .ended:
            return nil

        case .armed:
            if above {
                state = .starting
                aboveSince = sample.timestamp
                strokeStart = sample.timestamp
                buffer.append(sample)
            }
            return nil

        case .starting:
            buffer.append(sample)
            if above {
                let elapsed = sample.timestamp - (aboveSince ?? sample.timestamp)
                if elapsed + Self.fpTolerance >= Self.startSustainSeconds {
                    state = .recording
                    belowSince = nil
                }
            } else {
                state = .armed
                aboveSince = nil
                strokeStart = nil
                buffer.removeAll(keepingCapacity: true)
            }
            return nil

        case .recording:
            buffer.append(sample)
            if above {
                belowSince = nil
            } else {
                if belowSince == nil {
                    belowSince = sample.timestamp
                } else {
                    let quiet = sample.timestamp - (belowSince ?? sample.timestamp)
                    if quiet + Self.fpTolerance >= Self.endQuietSeconds {
                        return endStroke(at: sample.timestamp)
                    }
                }
            }
            let lifetime = sample.timestamp - (strokeStart ?? sample.timestamp)
            if lifetime + Self.fpTolerance >= Self.hardCutoffSeconds {
                return endStroke(at: sample.timestamp)
            }
            return nil
        }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        state = .idle
        armedLock = nil
        aboveSince = nil
        belowSince = nil
        strokeStart = nil
        buffer.removeAll(keepingCapacity: true)
    }

    private func endStroke(at endTime: TimeInterval) -> StrokeWindow? {
        guard let start = strokeStart, let stillnessLock = armedLock else {
            state = .ended
            return nil
        }
        let window = StrokeWindow(
            start: start,
            end: endTime,
            samples: buffer,
            lock: stillnessLock
        )
        state = .ended
        aboveSince = nil
        belowSince = nil
        return window
    }
}
