import Foundation

enum SensorClock {
    private static let nanosPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    static func now() -> TimeInterval {
        let ticks = mach_absolute_time()
        return Double(ticks) * nanosPerTick / 1_000_000_000.0
    }
}
