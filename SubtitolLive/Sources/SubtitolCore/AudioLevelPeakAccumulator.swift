import Foundation

/// Bridges audio buffers, which arrive faster than rendered frames, without losing
/// a brief sound that begins and ends between two renderer reads.
public struct AudioLevelPeakAccumulator: Sendable {
    private var latestLevel: Float = 0
    private var pendingPeak: Float = 0
    private var hasPendingObservation = false

    public init() { }

    public mutating func observe(_ level: Float) {
        let sanitized = level.isFinite ? min(1, max(0, level)) : 0
        latestLevel = sanitized
        pendingPeak = hasPendingObservation ? max(pendingPeak, sanitized) : sanitized
        hasPendingObservation = true
    }

    /// Returns the loudest buffer since the preceding read. With no new buffer, the
    /// latest value remains available instead of manufacturing a silence sample.
    public mutating func consume() -> Float {
        guard hasPendingObservation else { return latestLevel }
        let result = pendingPeak
        pendingPeak = 0
        hasPendingObservation = false
        return result
    }

    /// Drops history accumulated while a consumer was paused, retaining only the most
    /// recent level so resuming cannot replay an old sound.
    public mutating func discardPendingPeak() {
        pendingPeak = 0
        hasPendingObservation = false
    }

    public mutating func reset() {
        latestLevel = 0
        pendingPeak = 0
        hasPendingObservation = false
    }
}
