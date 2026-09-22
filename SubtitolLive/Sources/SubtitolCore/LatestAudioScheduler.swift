public struct LatestAudioScheduler: Sendable {
    public let minimumHopSamples: UInt64
    public private(set) var isInFlight = false

    private var lastSubmittedSequence: UInt64 = 0
    private var latestSequence: UInt64 = 0
    private var hasPendingAudio = false

    public init(minimumHopSamples: UInt64) {
        self.minimumHopSamples = max(1, minimumHopSamples)
    }

    public mutating func noteAudio(sequence: UInt64) -> UInt64? {
        latestSequence = max(latestSequence, sequence)
        if isInFlight {
            hasPendingAudio = true
            return nil
        }
        return submitIfReady(sequence: latestSequence)
    }

    public mutating func complete(latestSequence sequence: UInt64) -> UInt64? {
        latestSequence = max(latestSequence, sequence)
        isInFlight = false
        guard hasPendingAudio else { return nil }
        hasPendingAudio = false
        return submitIfReady(sequence: latestSequence)
    }

    public mutating func alignInFlightSnapshot(sequence: UInt64) {
        guard isInFlight else { return }
        lastSubmittedSequence = max(lastSubmittedSequence, sequence)
        latestSequence = max(latestSequence, sequence)
    }

    public mutating func reset() {
        isInFlight = false
        lastSubmittedSequence = 0
        latestSequence = 0
        hasPendingAudio = false
    }

    private mutating func submitIfReady(sequence: UInt64) -> UInt64? {
        guard sequence >= lastSubmittedSequence,
              sequence - lastSubmittedSequence >= minimumHopSamples else { return nil }
        lastSubmittedSequence = sequence
        isInFlight = true
        return sequence
    }
}
