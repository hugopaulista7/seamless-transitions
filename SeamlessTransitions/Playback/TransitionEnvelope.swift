import Foundation

/// Four-step DJ EQ envelope as a pure function of output time `tau` in [0, duration].
///
/// | Step | Span | B low | B mid/high | A low | A mid/high |
/// |---|---|---|---|---|---|
/// | 1 fader up | 35% of (T - swap) | 0 | -inf -> -6 dB | 1 | 1 |
/// | 2 mids/highs up | 25% of (T - swap) | 0 | -6 -> 0 dB | 1 | 1 |
/// | 3 bass swap | swap = min(5 s, 0.2 T) | 0 -> 1 (sin) | 0 dB | 1 -> 0 (cos) | 1 |
/// | 4 A fade out | rest | 1 | 0 dB | 0 | 1 -> 0 (cos) |
///
/// Ends are exact: `tau <= 0` gives A = (1, 1), B = (0, 0); `tau >= duration` gives A = (0, 0), B = (1, 1).
struct TransitionEnvelope: Sendable, Equatable {
    struct Gains: Sendable, Equatable {
        var aLow: Float
        var aHigh: Float
        var bLow: Float
        var bHigh: Float
    }

    static let maxSwapSeconds = 5.0
    static let swapFractionCap = 0.2
    static let step1Fraction = 0.35
    static let step2Fraction = 0.25
    /// Level B's mid/high reach at the end of step 1.
    static let entryDB = -6.0

    let duration: Double
    let swap: Double
    let step1End: Double
    let step2End: Double
    let swapEnd: Double

    init(duration: Double) {
        self.duration = max(duration, 0.001)
        let swap = min(Self.maxSwapSeconds, Self.swapFractionCap * self.duration)
        let rest = self.duration - swap
        self.swap = swap
        step1End = Self.step1Fraction * rest
        step2End = (Self.step1Fraction + Self.step2Fraction) * rest
        swapEnd = step2End + swap
    }

    func gains(at tau: Double) -> Gains {
        if tau <= 0 { return Gains(aLow: 1, aHigh: 1, bLow: 0, bHigh: 0) }
        if tau >= duration { return Gains(aLow: 0, aHigh: 0, bLow: 1, bHigh: 1) }
        let half = Double.pi / 2
        if tau < step1End {
            let u = tau / step1End
            let g = pow(10, Self.entryDB / 20) * sin(half * u)
            return Gains(aLow: 1, aHigh: 1, bLow: 0, bHigh: Float(g))
        }
        if tau < step2End {
            let v = (tau - step1End) / (step2End - step1End)
            let g = pow(10, (Self.entryDB * (1 - v)) / 20)
            return Gains(aLow: 1, aHigh: 1, bLow: 0, bHigh: Float(g))
        }
        if tau < swapEnd {
            let w = (tau - step2End) / swap
            return Gains(aLow: Float(cos(half * w)), aHigh: 1, bLow: Float(sin(half * w)), bHigh: 1)
        }
        let z = (tau - swapEnd) / (duration - swapEnd)
        return Gains(aLow: 0, aHigh: Float(cos(half * z)), bLow: 1, bHigh: 1)
    }
}
