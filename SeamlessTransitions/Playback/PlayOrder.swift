import Foundation

/// Play order over track indices, with shuffle that preserves the current track.
struct PlayOrder: Sendable, Equatable {
    /// Track indices in play order.
    private(set) var order: [Int]
    /// Index into `order` of the current track.
    var position: Int
    private let count: Int

    init(count: Int, shuffled: Bool, startingAt trackIndex: Int? = nil) {
        var rng = SystemRandomNumberGenerator()
        self.init(count: count, shuffled: shuffled, startingAt: trackIndex, using: &rng)
    }

    init(count: Int, shuffled: Bool, startingAt trackIndex: Int? = nil, using rng: inout some RandomNumberGenerator) {
        self.count = count
        let start = trackIndex.flatMap { (0..<count).contains($0) ? $0 : nil }
        if shuffled {
            order = Self.shuffledOrder(count: count, first: start, using: &rng)
            position = 0
        } else {
            order = Array(0..<count)
            position = start ?? 0
        }
    }

    var currentTrackIndex: Int? { order.indices.contains(position) ? order[position] : nil }

    mutating func setShuffle(_ on: Bool) {
        var rng = SystemRandomNumberGenerator()
        setShuffle(on, using: &rng)
    }

    mutating func setShuffle(_ on: Bool, using rng: inout some RandomNumberGenerator) {
        let current = currentTrackIndex
        if on {
            order = Self.shuffledOrder(count: count, first: current, using: &rng)
            position = 0
        } else {
            order = Array(0..<count)
            position = current ?? 0
        }
    }

    /// Next position, nil at end (no wrap).
    func nextPosition(after p: Int) -> Int? { p + 1 < order.count && p >= -1 ? p + 1 : nil }

    /// Previous position, nil at start.
    func previousPosition(before p: Int) -> Int? { p - 1 >= 0 && p <= order.count ? p - 1 : nil }

    /// Makes `trackIndex` current (position of it within the existing order).
    mutating func moveTo(trackIndex: Int) {
        if let p = order.firstIndex(of: trackIndex) { position = p }
    }

    private static func shuffledOrder(count: Int, first: Int?, using rng: inout some RandomNumberGenerator) -> [Int] {
        var rest = Array(0..<count)
        if let first { rest.remove(at: first) }
        rest.shuffle(using: &rng)  // Fisher-Yates
        return (first.map { [$0] } ?? []) + rest
    }
}
