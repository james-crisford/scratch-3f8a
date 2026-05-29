import Foundation

enum PhaseState: Sendable, Equatable {
    case arm
    case address
    case ready
    case stroke
    case impact
    case roll
}
