import Foundation

public struct LatencyDistribution: Equatable, Sendable {
    public let count: Int
    public let p50: Double?
    public let p95: Double?
    public let maximum: Double?

    public init(samples: [Double]) {
        let sorted = samples.filter(\.isFinite).sorted()
        count = sorted.count
        p50 = Self.percentile(0.50, in: sorted)
        p95 = Self.percentile(0.95, in: sorted)
        maximum = sorted.last
    }

    private static func percentile(_ percentile: Double, in sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
        return sorted[min(rank - 1, sorted.count - 1)]
    }
}
