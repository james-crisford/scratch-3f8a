import Foundation

struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xdeadbeef : seed
    }

    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let bits = state >> 11
        return Double(bits) / Double(UInt64.max >> 11)
    }

    mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
        lo + next() * (hi - lo)
    }

    mutating func gaussian(mean: Double = 0, stddev: Double = 1) -> Double {
        let u1 = max(next(), 1e-9)
        let u2 = next()
        let z = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
        return mean + stddev * z
    }
}
