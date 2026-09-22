import Foundation

public enum LiveWindowPolicy {
    public static let minimumAudioSeconds: TimeInterval = 0.35
    /// Recognition may run faster internally, but new full-window hypotheses are not
    /// useful to a reader every 80 ms. A 180 ms hop gives the stabilizer independent
    /// observations without continuously churning the visible suffix.
    public static let minimumHopSeconds: TimeInterval = 0.18
    public static let liveWindowSeconds: TimeInterval = 4.0
    public static let finalWindowSeconds: TimeInterval = 6.0
    public static let warmupWindowSeconds: [TimeInterval] = [liveWindowSeconds, finalWindowSeconds]

    /// No interim window reaches further back than `targetSeconds` ever returns, so a
    /// word older than this can no longer be revised while recording. That makes it safe
    /// for the UI to treat as settled and stop moving it.
    public static let commitLagSeconds: TimeInterval = 4.0

    public static func targetSeconds(for capturedDuration: TimeInterval) -> TimeInterval {
        liveWindowSeconds
    }

    /// Sample position up to which words are settled, given the newest capture position.
    public static func committedThroughSequence(
        newestSequence: UInt64,
        sampleRate: Int32
    ) -> UInt64 {
        guard sampleRate > 0 else { return 0 }
        let lag = UInt64(Double(sampleRate) * commitLagSeconds)
        return newestSequence > lag ? newestSequence - lag : 0
    }
}
