import Foundation

/// Finds the pauses in the voice from the audio itself.
///
/// Recognisers disagree about where a word ends: on the same reading, the gap before a
/// new sentence measured 0.34 s from Parakeet's timestamps and 0.55 s from the
/// Conformer's. The microphone does not disagree with itself, so pauses are measured
/// here, on 10 ms frames: a frame is silent when it is 12 dB above the noise floor or
/// less, the floor being the quietest tenth of the last eight seconds. Silent runs of
/// 80 ms or more are pauses. On the founder's recordings, 13 of 16 read sentence ends
/// had a pause of half a second or more, against none of 176 word boundaries inside
/// a sentence. `.work/tools/vad_causal.py` is the same algorithm in Python.
public struct SilenceTracker: Sendable {
    public static let frameSeconds = 0.01
    static let marginDecibels: Float = 12
    static let floorSeconds = 8.0
    static let floorQuantile = 0.1
    static let floorRefreshFrames = 50
    public static let minimumPauseSeconds = 0.08
    static let retainedSeconds = 60.0

    public private(set) var sampleRate: Int32 = 0
    private var frameLength = 0
    /// Sequence of the next sample to analyse.
    private var nextSequence: UInt64?
    private var partialSum: Double = 0
    private var partialCount = 0
    private var levels: [Float] = []
    private var levelCursor = 0
    private var framesSinceFloor = 0
    private var floor: Float?
    private var runStart: UInt64?
    private var pauses: [Range<UInt64>] = []

    public init() {}

    public mutating func reset() {
        self = SilenceTracker()
    }

    /// Feeds `samples`, whose last sample is `endSequence - 1` on the capture clock.
    /// Audio already analysed is skipped, so overlapping windows can be passed as they are.
    public mutating func append<Samples: Collection>(
        _ samples: Samples,
        endSequence: UInt64,
        sampleRate: Int32
    ) where Samples.Element == Float, Samples.Index == Int {
        guard sampleRate > 0, !samples.isEmpty else { return }
        if sampleRate != self.sampleRate {
            reset()
            self.sampleRate = sampleRate
            frameLength = max(1, Int((Double(sampleRate) * Self.frameSeconds).rounded()))
        }
        let count = UInt64(samples.count)
        let firstSequence = endSequence >= count ? endSequence - count : 0
        if let expected = nextSequence, firstSequence > expected {
            // Audio was lost: a pause cannot be measured across the hole.
            closeRun(at: expected)
            partialSum = 0
            partialCount = 0
            nextSequence = firstSequence
        }
        let start = nextSequence ?? firstSequence
        guard endSequence > start else { return }
        let skip = Int(start - firstSequence)
        var sequence = start
        for sample in samples.dropFirst(skip) {
            partialSum += Double(sample) * Double(sample)
            partialCount += 1
            sequence += 1
            if partialCount == frameLength {
                analyseFrame(endingAt: sequence)
            }
        }
        nextSequence = sequence
        let retained = UInt64(Self.retainedSeconds * Double(sampleRate))
        if sequence > retained {
            let horizon = sequence - retained
            pauses.removeAll { $0.upperBound < horizon }
        }
    }

    /// Pauses found so far, including one still running at the end of the audio.
    public var map: SilenceMap {
        var all = pauses
        if let runStart, let nextSequence, nextSequence > runStart,
           Double(nextSequence - runStart) >= Self.minimumPauseSeconds * Double(sampleRate) {
            all.append(runStart..<nextSequence)
        }
        return SilenceMap(sampleRate: sampleRate, pauses: all, analysedThrough: nextSequence ?? 0)
    }

    private mutating func analyseFrame(endingAt end: UInt64) {
        let decibels = Float(10 * log10(partialSum / Double(partialCount) + 1e-12))
        partialSum = 0
        partialCount = 0
        let capacity = max(1, Int(Self.floorSeconds / Self.frameSeconds))
        if levels.count < capacity {
            levels.append(decibels)
        } else {
            levels[levelCursor] = decibels
            levelCursor = (levelCursor + 1) % capacity
        }
        framesSinceFloor += 1
        if floor == nil || framesSinceFloor >= Self.floorRefreshFrames {
            let sorted = levels.sorted()
            floor = sorted[Int(Self.floorQuantile * Double(sorted.count - 1))]
            framesSinceFloor = 0
        }
        let start = end - UInt64(frameLength)
        if decibels < (floor ?? decibels) + Self.marginDecibels {
            if runStart == nil { runStart = start }
        } else {
            closeRun(at: start)
        }
    }

    private mutating func closeRun(at end: UInt64) {
        guard let runStart else { return }
        self.runStart = nil
        if end > runStart, Double(end - runStart) >= Self.minimumPauseSeconds * Double(sampleRate) {
            pauses.append(runStart..<end)
        }
    }
}

/// The pauses in a stretch of audio, on the capture clock.
public struct SilenceMap: Equatable, Sendable {
    public let sampleRate: Int32
    /// Silent runs of at least `SilenceTracker.minimumPauseSeconds`, oldest first. The
    /// last one may still be running at `analysedThrough`.
    public let pauses: [Range<UInt64>]
    public let analysedThrough: UInt64

    public init(sampleRate: Int32, pauses: [Range<UInt64>], analysedThrough: UInt64) {
        self.sampleRate = sampleRate
        self.pauses = pauses
        self.analysedThrough = analysedThrough
    }

    /// Seconds of the longest pause between two words: one centred after the middle of
    /// the first and before the middle of the second. Centres rather than edges, because
    /// word timestamps may overlap the silence by a frame or two.
    public func pause(
        between first: (start: UInt64, end: UInt64),
        and second: (start: UInt64, end: UInt64)
    ) -> TimeInterval {
        guard sampleRate > 0 else { return 0 }
        let from = first.start / 2 + first.end / 2
        let to = second.start / 2 + second.end / 2
        let longest = pauses.lazy
            .filter { let centre = $0.lowerBound / 2 + $0.upperBound / 2; return centre >= from && centre < to }
            .map { $0.upperBound - $0.lowerBound }
            .max() ?? 0
        return Double(longest) / Double(sampleRate)
    }

    /// Seconds of the silence still running at the end of the audio, if it began after
    /// the middle of the word the speaker said last.
    public func trailingSilence(after word: (start: UInt64, end: UInt64)) -> TimeInterval {
        guard sampleRate > 0, let last = pauses.last, last.upperBound >= analysedThrough,
              last.lowerBound >= word.start / 2 + word.end / 2 else { return 0 }
        return Double(analysedThrough - last.lowerBound) / Double(sampleRate)
    }
}

