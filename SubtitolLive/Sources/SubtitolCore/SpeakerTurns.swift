import Foundation

/// Finds where a different voice takes over, from the audio alone, so a new speaker
/// starts a new paragraph in any language.
///
/// A small segmentation model (pyannote segmentation-3.0, 6 MB) labels every 17 ms of
/// a 10 s window as silence, one of up to three voices, or two at once. Voices are only
/// told apart inside a window, which is all a paragraph needs: a turn ends where the
/// voice changes. The tracker keeps the last 10 s at 16 kHz, asks for an analysis every
/// `hopSeconds`, and confirms a change once two windows have seen it with at least
/// `minimumTurnSeconds` of each voice around it. Short replies ("sí", "vale") and
/// overlapping speech do not count: a wrong paragraph costs the reader more than a
/// missed one. On a 15-minute podcast with 3-6 voices, the offline version of this
/// placed 23 breaks, at guests, section announcers and jingles, and let a fast
/// two-voice exchange run on (`.work/voice-turns`).
public struct SpeakerTurnTracker: Sendable {
    public static let modelSampleRate: Int32 = 16_000
    public static let windowSamples = 160_000
    /// The model's frames: one every 270 samples, each looking at 990.
    public static let frameStepSamples = 270
    public static let frameSpanSamples = 990
    public static let hopSeconds = 0.5
    /// Voice needed on both sides of a change, and silence that still joins one turn.
    public static let minimumTurnSeconds = 0.6
    static let joinGapSeconds = 0.5
    /// Detections closer than this are the same change.
    static let clusterSeconds = 0.5
    static let votesToConfirm = 2
    /// Audio needed before the first analysis.
    static let minimumAudioSeconds = 2.0

    /// 10 s of audio for the model, ending at `endSequence` on the capture clock.
    public struct Window: Sendable {
        public let samples: [Float]
        public let endSequence: UInt64
        /// Capture samples per model sample.
        let ratio: Double
    }

    private var captureRate: Int32 = 0
    private var ratio = 1.0
    /// Resampled audio: the newest `windowSamples`, oldest first.
    private var buffer: [Float] = []
    private var nextSequence: UInt64?
    /// Capture samples per output sample still being averaged.
    private var phase = 0.0
    private var partialSum: Float = 0
    private var partialCount = 0
    private var capturedSinceStart: UInt64 = 0
    private var lastAnalysedEnd: UInt64?
    private var pending: [(sequence: UInt64, votes: Int)] = []
    private var confirmed: [UInt64] = []
    private var analysedThrough: UInt64 = 0
    /// Whether the model heard a voice in each of its frames, newest analysis first:
    /// `speechFrames[i]` covers the frame that starts `speechFirstFrame + i` frames
    /// from the session's start, on the capture clock.
    private var speechFrames: [Bool] = []
    private var speechFirstFrame: UInt64 = 0
    private var speechAnalysedThrough: UInt64 = 0

    public init() {}

    public mutating func reset() {
        self = SpeakerTurnTracker()
    }

    /// Feeds `samples`, whose last sample is `endSequence - 1` on the capture clock.
    /// Audio already fed is skipped, so overlapping snapshots can be passed as they are.
    public mutating func append<Samples: Collection>(
        _ samples: Samples,
        endSequence: UInt64,
        sampleRate: Int32
    ) where Samples.Element == Float, Samples.Index == Int {
        guard sampleRate > 0, !samples.isEmpty else { return }
        if sampleRate != captureRate {
            reset()
            captureRate = sampleRate
            ratio = Double(sampleRate) / Double(Self.modelSampleRate)
        }
        let count = UInt64(samples.count)
        let firstSequence = endSequence >= count ? endSequence - count : 0
        if let expected = nextSequence, firstSequence > expected {
            // Audio was lost: what came before cannot be compared with what follows.
            buffer.removeAll(keepingCapacity: true)
            pending.removeAll()
            phase = 0
            partialSum = 0
            partialCount = 0
        }
        let start = max(nextSequence ?? firstSequence, firstSequence)
        guard endSequence > start else { return }
        for sample in samples.dropFirst(Int(start - firstSequence)) {
            // Averaging over each output sample's span keeps what the model hears below
            // 8 kHz without aliasing the rest into it.
            partialSum += sample
            partialCount += 1
            phase += 1
            if phase >= ratio {
                phase -= ratio
                buffer.append(partialSum / Float(partialCount))
                partialSum = 0
                partialCount = 0
            }
        }
        capturedSinceStart += endSequence - start
        nextSequence = endSequence
        if buffer.count > Self.windowSamples * 2 {
            buffer.removeFirst(buffer.count - Self.windowSamples)
        }
    }

    /// The next window to analyse, when `hopSeconds` of new audio have arrived.
    public func nextWindow() -> Window? {
        guard let end = nextSequence, captureRate > 0,
              Double(capturedSinceStart) >= Self.minimumAudioSeconds * Double(captureRate) else { return nil }
        if let lastAnalysedEnd, Double(end - lastAnalysedEnd) < Self.hopSeconds * Double(captureRate) {
            return nil
        }
        var samples = Array(buffer.suffix(Self.windowSamples))
        if samples.count < Self.windowSamples {
            samples.insert(contentsOf: repeatElement(0, count: Self.windowSamples - samples.count), at: 0)
        }
        return Window(samples: samples, endSequence: end, ratio: ratio)
    }

    /// Takes the model's class for every frame of `window`: 0 silence, 1-3 one voice,
    /// 4-6 two voices at once.
    public mutating func ingest(frameClasses: [Int], of window: Window) {
        lastAnalysedEnd = window.endSequence
        guard !frameClasses.isEmpty else { return }
        let rate = Double(Self.modelSampleRate)
        let frameSeconds = Double(Self.frameStepSamples) / rate
        let offsetSeconds = Double(Self.frameSpanSamples) / 2 / rate
        let windowSeconds = Double(Self.windowSamples) / rate

        // Turns: runs of one voice, joined across short silences; overlap breaks a run.
        var runs: [(voice: Int, start: Double, end: Double)] = []
        for (index, frameClass) in frameClasses.enumerated() {
            let time = offsetSeconds + Double(index) * frameSeconds
            guard (1...3).contains(frameClass) else {
                // Two voices at once: neither turn continues across it.
                if frameClass >= 4, runs.last?.voice != -1 {
                    runs.append((voice: -1, start: time, end: time))
                }
                continue
            }
            if let last = runs.last, last.voice == frameClass, time - last.end < Self.joinGapSeconds {
                runs[runs.count - 1].end = time + frameSeconds
            } else {
                runs.append((voice: frameClass, start: time, end: time + frameSeconds))
            }
        }
        var turns: [(voice: Int, start: Double, end: Double)] = []
        for run in runs where run.voice > 0 && run.end - run.start >= Self.minimumTurnSeconds {
            if let last = turns.last, last.voice == run.voice {
                turns[turns.count - 1].end = run.end
            } else {
                turns.append(run)
            }
        }

        let captureRate = Double(self.captureRate)
        let windowStart = Double(window.endSequence) - windowSeconds * captureRate
        recordSpeech(frameClasses, windowStart: windowStart, frameSeconds: frameSeconds, offsetSeconds: offsetSeconds)
        let cluster = UInt64(Self.clusterSeconds * captureRate)
        for (previous, next) in zip(turns, turns.dropFirst()) where previous.voice != next.voice {
            let position = windowStart + next.start * captureRate
            guard position > 0 else { continue }
            let sequence = UInt64(position)
            if confirmed.contains(where: { distance($0, sequence) < cluster }) { continue }
            if let index = pending.firstIndex(where: { distance($0.sequence, sequence) < cluster }) {
                pending[index].votes += 1
                if pending[index].votes >= Self.votesToConfirm {
                    confirmed.append(pending[index].sequence)
                    confirmed.sort()
                    pending.remove(at: index)
                }
            } else {
                pending.append((sequence: sequence, votes: 1))
            }
        }
        // A change is final once enough audio after it has been analysed twice.
        let settled = window.endSequence - min(window.endSequence, UInt64((Self.minimumTurnSeconds + Self.hopSeconds) * captureRate))
        pending.removeAll { $0.sequence + UInt64(windowSeconds * captureRate) < window.endSequence }
        analysedThrough = max(analysedThrough, settled)
        let retained = UInt64(60 * captureRate)
        if window.endSequence > retained {
            confirmed.removeAll { $0 < window.endSequence - retained }
        }
    }

    public var map: SpeakerChangeMap {
        SpeakerChangeMap(sampleRate: captureRate, changes: confirmed, decidedThrough: analysedThrough)
    }

    /// Where the model heard a voice, for `SpeechPresenceMap`. Every frame of a window
    /// is recorded (a voice, alone or with another, against silence or noise); the
    /// newest analysis of a frame replaces the older ones, since it hears more around it.
    private mutating func recordSpeech(_ frameClasses: [Int], windowStart: Double, frameSeconds: Double, offsetSeconds: Double) {
        let captureRate = Double(self.captureRate)
        let frameCapture = frameSeconds * captureRate
        guard frameCapture > 0 else { return }
        let firstTime = windowStart + offsetSeconds * captureRate
        // Frames before the session's start are padding.
        let skipped = firstTime < 0 ? Int((-firstTime / frameCapture).rounded(.up)) : 0
        guard skipped < frameClasses.count else { return }
        let firstFrame = UInt64(((firstTime + Double(skipped) * frameCapture) / frameCapture).rounded())
        let flags = frameClasses[skipped...].map { $0 >= 1 }
        if speechFrames.isEmpty || firstFrame < speechFirstFrame {
            speechFrames = flags
            speechFirstFrame = firstFrame
        } else {
            let offset = Int(firstFrame - speechFirstFrame)
            if speechFrames.count < offset + flags.count {
                speechFrames.append(contentsOf: repeatElement(false, count: offset + flags.count - speechFrames.count))
            }
            speechFrames.replaceSubrange(offset..<(offset + flags.count), with: flags)
        }
        speechAnalysedThrough = UInt64((Double(firstFrame) + Double(flags.count)) * frameCapture)
        let retainedFrames = Int(Self.retainedSpeechSeconds / frameSeconds)
        if speechFrames.count > retainedFrames {
            let drop = speechFrames.count - retainedFrames
            speechFrames.removeFirst(drop)
            speechFirstFrame += UInt64(drop)
        }
    }

    static let retainedSpeechSeconds = 60.0

    /// Where the model heard a voice, as far as it has listened.
    public var speech: SpeechPresenceMap {
        let frameSeconds = Double(Self.frameStepSamples) / Double(Self.modelSampleRate)
        return SpeechPresenceMap(
            sampleRate: captureRate,
            frameSamples: frameSeconds * Double(captureRate),
            firstFrame: speechFirstFrame,
            frames: speechFrames,
            analysedThrough: speechAnalysedThrough
        )
    }

    private func distance(_ a: UInt64, _ b: UInt64) -> UInt64 {
        a > b ? a - b : b - a
    }
}

/// Where the voice changed, on the capture clock.
public struct SpeakerChangeMap: Equatable, Sendable {
    /// A change whose next word starts later than this is not placed.
    public static let maximumOffsetSeconds = 0.5
    static let wordTailSeconds = 0.05
    static let wordHeadSeconds = 0.15

    public let sampleRate: Int32
    /// Confirmed changes, oldest first: the sample where the new voice starts.
    public let changes: [UInt64]
    /// Changes before this sample are final; after it, one may still be confirmed.
    public let decidedThrough: UInt64

    public init(sampleRate: Int32, changes: [UInt64], decidedThrough: UInt64) {
        self.sampleRate = sampleRate
        self.changes = changes
        self.decidedThrough = decidedThrough
    }

    /// Indices of the words a new voice starts with: for every change, the word it
    /// falls in, or the first one after it. The model marks a change where the new
    /// voice's first sound is, so on a 15-minute podcast changes fell within 0.1 s of a
    /// word's start; the nearest gap between words was often after that word, because
    /// a pause before a turn moves the gap's middle away.
    public func turnStarts(in spans: [(start: UInt64, end: UInt64)?]) -> Set<Int> {
        guard sampleRate > 0, spans.count > 1, !changes.isEmpty else { return [] }
        let rate = Double(sampleRate)
        let limit = UInt64(Self.maximumOffsetSeconds * rate)
        // The detector marks a change a few hundredths of a second into the new voice,
        // so a change up to 150 ms after a word starts belongs to that word, even past
        // the end of one as short as "no" or "i" (stamped 40 ms long). Otherwise a change
        // in a word's last 50 ms belongs to the next word.
        let tail = UInt64(Self.wordTailSeconds * rate)
        let head = UInt64(Self.wordHeadSeconds * rate)
        func holds(_ span: (start: UInt64, end: UInt64), _ change: UInt64) -> Bool {
            change < span.start + head || span.end > change + tail
        }
        var starts = Set<Int>()
        for change in changes {
            guard let index = spans.indices.first(where: { spans[$0].map { holds($0, change) } ?? false }),
                  index > 0, spans[index - 1] != nil, let span = spans[index],
                  span.start <= change + limit else { continue }
            starts.insert(index)
        }
        return starts
    }

    private func distance(_ a: UInt64, _ b: UInt64) -> UInt64 {
        a > b ? a - b : b - a
    }
}

/// Where the voice detector heard someone, on the capture clock, so that a word the
/// recogniser wrote where it heard nobody can be dropped.
///
/// The recogniser invents words in applause, in a crowd's murmur and in a room's noise:
/// the energy test of `SilentWordFilter` cannot tell those from a voice when they are
/// loud, but the segmentation model, trained to find voices against music and noise,
/// can. A word is dropped only once the detector has listened to all of its time and
/// heard no voice anywhere from `headSeconds` before it to `tailSeconds` after it; a
/// word the detector has not reached yet is kept for now and judged in the next
/// window, where the recogniser hears it again.
public struct SpeechPresenceMap: Equatable, Sendable {
    /// The recogniser stamps a phrase's first word up to 100 ms before its sound, and
    /// the detector's frames look 30 ms either side of their centre.
    public static let headSeconds = 0.10
    public static let tailSeconds = 0.10

    public let sampleRate: Int32
    /// Capture samples per detector frame.
    public let frameSamples: Double
    /// Index of the frame `frames[0]` describes, from the session's start.
    public let firstFrame: UInt64
    public let frames: [Bool]
    /// Audio before this sample has been listened to.
    public let analysedThrough: UInt64

    public init(sampleRate: Int32, frameSamples: Double, firstFrame: UInt64, frames: [Bool], analysedThrough: UInt64) {
        self.sampleRate = sampleRate
        self.frameSamples = frameSamples
        self.firstFrame = firstFrame
        self.frames = frames
        self.analysedThrough = analysedThrough
    }

    public static let empty = SpeechPresenceMap(sampleRate: 0, frameSamples: 1, firstFrame: 0, frames: [], analysedThrough: 0)

    public enum Verdict: Equatable, Sendable {
        case voice
        case nobody
        /// The detector has not listened to the whole span yet, or no longer keeps it.
        case undecided
    }

    /// Whether a voice was heard anywhere in `start..<end`, with the head and tail added.
    public func verdict(start: UInt64, end: UInt64) -> Verdict {
        guard sampleRate > 0, frameSamples > 0, !frames.isEmpty else { return .undecided }
        let rate = Double(sampleRate)
        let head = UInt64(Self.headSeconds * rate)
        let tail = UInt64(Self.tailSeconds * rate)
        let from = start > head ? start - head : 0
        let to = end.addingReportingOverflow(tail).partialValue
        guard to <= analysedThrough else { return .undecided }
        let firstIndex = Int((Double(from) / frameSamples).rounded(.down)) - Int(firstFrame)
        let lastIndex = Int((Double(to) / frameSamples).rounded(.up)) - Int(firstFrame)
        guard firstIndex >= 0 else { return .undecided }
        let range = firstIndex..<min(frames.count, max(firstIndex + 1, lastIndex))
        guard !range.isEmpty else { return .undecided }
        return frames[range].contains(true) ? .voice : .nobody
    }

    /// The words the detector does not rule out: those with a voice, and those it has
    /// not listened to yet.
    public func voicedWords(_ words: [TranscriptObservationWord]) -> [TranscriptObservationWord] {
        guard sampleRate > 0, !frames.isEmpty else { return words }
        return words.filter { verdict(start: $0.startSequence, end: $0.endSequence) != .nobody }
    }

    /// The words to keep when the energy test (`SilentWordFilter`) has also judged
    /// them: where the detector has listened, its verdict stands, a voice keeping the
    /// word whatever the energy said and nobody dropping it; where it has not, the
    /// energy test decides. `energyKept` holds the indices the energy test kept.
    public func voicedWords(_ words: [TranscriptObservationWord], energyKept: Set<Int>) -> [TranscriptObservationWord] {
        words.indices.filter { index in
            switch verdict(start: words[index].startSequence, end: words[index].endSequence) {
            case .voice: true
            case .nobody: false
            case .undecided: energyKept.contains(index)
            }
        }.map { words[$0] }
    }
}
