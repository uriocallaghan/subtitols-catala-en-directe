import Foundation

/// A recording held whole in memory, mono, as 16-bit samples: an hour at 16 kHz is
/// 115 MB, half of what `Float` would take, and 16 bits keep 96 dB, far below any room.
public struct PCMRecording: Sendable {
    public let samples: ContiguousArray<Int16>
    public let sampleRate: Int32

    public init(samples: ContiguousArray<Int16>, sampleRate: Int32) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public init<Samples: Sequence>(floats: Samples, sampleRate: Int32) where Samples.Element == Float {
        self.samples = ContiguousArray(floats.lazy.map { Int16((max(-1, min(1, $0)) * 32_767).rounded()) })
        self.sampleRate = sampleRate
    }

    public var count: Int { samples.count }
    public var duration: TimeInterval { sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0 }

    /// Samples `range` as floats in -1...1.
    public func floats(_ range: Range<Int>) -> [Float] {
        let clamped = range.clamped(to: 0..<samples.count)
        return samples[clamped].map { Float($0) / 32_768 }
    }
}

/// Transcribes a whole recording (a video's sound, a podcast) as fast as the recogniser
/// runs, into the same punctuated, paragraphed session the live reader exports.
///
/// Live listening sees each word through many 7 s windows as it arrives. A file has no
/// "now": every stretch is decoded once, with context on both sides. The recording is
/// cut into windows that meet at the quietest moment near their ideal length, so a
/// cut falls between words, not through one; each window also hears `contextSeconds`
/// beyond both ends, and keeps only the words whose middle lies between its cuts.
/// Everything after recognition is the live path unchanged: the silence and voice
/// change trackers hear the audio in order, and the formatter settles words with the
/// same right context, strictly in order, so marks, capitals, digits and paragraphs are
/// decided exactly as they are for the live reader.
public struct FileTranscriber {
    public struct Configuration: Sendable {
        /// Audio decoded per window, context included. The Conformer learnt from clips of
        /// up to 15 s.
        public var windowSeconds: TimeInterval
        /// Audio heard beyond each cut, on both sides, whose words belong to the
        /// neighbouring window.
        public var contextSeconds: TimeInterval
        /// How far before its ideal place a cut may move to find a pause.
        public var cutSearchSeconds: TimeInterval

        /// How the pause after a word weighs against the punctuation model.
        public var pauseRule: PauseEvidence.Rule

        public init(
            windowSeconds: TimeInterval = 14,
            contextSeconds: TimeInterval = 1.5,
            cutSearchSeconds: TimeInterval = 4,
            pauseRule: PauseEvidence.Rule = .file
        ) {
            self.windowSeconds = windowSeconds
            self.contextSeconds = contextSeconds
            self.cutSearchSeconds = cutSearchSeconds
            self.pauseRule = pauseRule
        }
    }

    /// One recognition window, in samples of the recording.
    public struct Window: Equatable, Sendable {
        /// The audio decoded.
        public let audio: Range<Int>
        /// The words kept: those whose middle lies here.
        public let keep: Range<Int>
    }

    public struct Progress: Sendable {
        /// 0...1 of the recording heard.
        public let fraction: Double
        /// The session so far, as it will be exported.
        public let session: SessionTranscript
        /// The newest words, formatted, as the reading pane shows them: the settled ones
        /// committed, the rest still waiting for context.
        public let snapshot: ReadableTranscriptSnapshot
    }

    public struct Result: Sendable {
        /// Punctuated, with paragraphs and word times: what is exported.
        public let session: SessionTranscript
        /// Every word kept, as the recogniser heard it, before punctuation and digits.
        public let heardWords: [String]
        /// Words found by hearing a stretch again, where a window had left voice without
        /// words. For diagnostics.
        public var repairedWords = 0
        /// Windows decoded, the second hearings included. For diagnostics.
        public var decodedWindows = 0
        /// Every formatting decision, when `decisions` was set. For calibration.
        public var decisions: [TranscriptFormatter.Decision]?
    }

    public enum TranscriptionError: LocalizedError {
        case cancelled

        public var errorDescription: String? { localized("S'ha cancel·lat la transcripció.") }
    }

    /// Words the formatter is given per step. With its 32 words of left context this
    /// stays well inside the punctuation model's 256 tokens, which drops the oldest
    /// words of a longer request.
    static let formattingStepWords = 24
    /// Words kept in the formatter's view, as the live stabiliser keeps.
    static let retainedWords = 160

    public let configuration: Configuration
    public let rules: LanguageRules
    /// Told about every second hearing, for diagnostics (the harness's
    /// `SUBTITOL_TRACE_HOLES`).
    public var trace: ((String) -> Void)?
    /// When set (to empty), every formatting decision is returned with the result, for
    /// calibrating `PauseEvidence.Rule.file` (the harness's `--decisions`).
    public var decisions: [TranscriptFormatter.Decision]?

    public init(rules: LanguageRules, configuration: Configuration = .init()) {
        self.rules = rules
        self.configuration = configuration
    }

    // MARK: - Windows

    /// The windows `recording` is decoded in, tiling it without gaps or overlap in what
    /// they keep.
    public func windows(for recording: PCMRecording) -> [Window] {
        let rate = Double(recording.sampleRate)
        let total = recording.count
        guard total > 0, rate > 0 else { return [] }
        let context = Int(configuration.contextSeconds * rate)
        let length = Int(configuration.windowSeconds * rate)
        let span = max(Int(1 * rate), length - 2 * context)
        let search = min(span / 2, Int(configuration.cutSearchSeconds * rate))
        let levels = Self.frameLevels(recording)
        let frame = Self.frameLength(recording.sampleRate)

        var windows: [Window] = []
        var keepStart = 0
        while keepStart < total {
            // The last window may stretch into its trailing context rather than leave a
            // sliver for a window of its own.
            if total - keepStart <= span + context {
                windows.append(Window(audio: Self.widened(max(0, keepStart - context)..<total, to: length, total: total), keep: keepStart..<total))
                break
            }
            let ideal = keepStart + span
            let cut = Self.quietestPoint(in: (ideal - search)..<ideal, levels: levels.loudness, frameLength: frame)
            windows.append(Window(
                audio: Self.widened(max(0, keepStart - context)..<min(total, cut + context), to: length, total: total),
                keep: keepStart..<cut
            ))
            keepStart = cut
        }
        return windows
    }

    /// `audio` grown to `length` samples, with more of the recording before it (or after
    /// it, at the start): every window the recogniser hears has one of a few lengths.
    /// The runtime builds and keeps a graph for each length it is given; windows of a
    /// different length each time filled an iPhone's memory within a minute of video.
    /// The extra audio is only context: what a window keeps does not change.
    static func widened(_ audio: Range<Int>, to length: Int, total: Int) -> Range<Int> {
        guard audio.count < length, total > 0 else { return audio }
        let end = max(audio.upperBound, min(total, length))
        return max(0, end - length)..<end
    }

    static func frameLength(_ sampleRate: Int32) -> Int {
        max(1, Int(Double(sampleRate) * SilenceTracker.frameSeconds))
    }

    /// The levels of every 10 ms frame `SilentWordFilter` judges voice by.
    static func frameLevels(_ recording: PCMRecording) -> SilentWordFilter.FrameLevels {
        recording.samples.withUnsafeBufferPointer { buffer in
            SilentWordFilter.FrameLevels(buffer, frameLength: frameLength(recording.sampleRate)) { Double($0) / 32_768 }
        }
    }

    /// The middle of the quietest stretch in `range`: the centre of the longest pause
    /// when there is one, and the gap between two words in continuous speech.
    static func quietestPoint(in range: Range<Int>, levels: [Float], frameLength: Int) -> Int {
        let span = 10
        let first = max(0, range.lowerBound / frameLength)
        let last = min(levels.count - span, range.upperBound / frameLength - span)
        guard last >= first else { return range.upperBound }
        // Mean level of the 100 ms starting at each frame.
        var means: [Float] = []
        means.reserveCapacity(last - first + 1)
        var sum = levels[first..<(first + span)].reduce(0, +)
        means.append(sum / Float(span))
        if first < last {
            for index in (first + 1)...last {
                sum += levels[index + span - 1] - levels[index - 1]
                means.append(sum / Float(span))
            }
        }
        // Every stretch within 3 dB of the quietest counts as quiet; the longest wins.
        let quietest = means.min() ?? 0
        var best = (start: 0, length: 0)
        var runStart: Int?
        for (index, mean) in means.enumerated() {
            if mean <= quietest + 3 {
                if runStart == nil { runStart = index }
                let length = index - runStart! + 1
                if length >= best.length { best = (runStart!, length) }
            } else {
                runStart = nil
            }
        }
        let centre = first + best.start + (best.length - 1) / 2 + span / 2
        return max(range.lowerBound, min(range.upperBound, centre * frameLength))
    }

    // MARK: - Holes

    /// Gaps between words (and at either end of `keep`) this long or longer are checked.
    static let holeSeconds = 0.8
    /// A gap is a hole when this much of it is voice, as `SilentWordFilter` tells voice
    /// from the quietest frames of the audio around it.
    static let holeVoicedSeconds = 0.35
    /// A word covers at most this much of the audio. When the decoder skips a stretch it
    /// often stretches the word before over it ("episodiam", 4.5 s, over 19 words lost
    /// in Ep54 at 24:02; "Pocketcassacions", 9.9 s), and the stretch then looked like
    /// speech with a word in it.
    static let maximumWordSeconds = 1.5
    /// The windows a hole is heard again in, one round each while holes remain: first
    /// live listening's, which the model is tuned to, then two other cuts.
    public static let repairRounds: [TimeInterval] = [LiveWindowPolicy.liveWindowSeconds, 10, 5]
    public static let repairWindowSeconds = LiveWindowPolicy.liveWindowSeconds
    static let repairContextSeconds = 1.5
    /// Now and then the Conformer returns no word at all for a whole window, clear speech
    /// included: in 15GdH3 at 15:13 every 7 and 14 s window starting between 905 and
    /// 915 s came back empty, 5 of its 141 windows in all. Which windows it does this to
    /// looks arbitrary; the same speech comes back whole from a window that starts a
    /// little later, though not always half a second later (Ep54's first 14 s did not),
    /// hence two tries. A window with voice and no word is heard again with its start
    /// moved on by each of these, in seconds, the audio it no longer hears replaced by
    /// silence in front so its length stays the same.
    static let emptyWindowShifts: [TimeInterval] = [0.5, 1]

    /// Stretches of `keep` with voice but no word.
    static func holes(
        in keep: Range<Int>,
        words: [TranscriptObservationWord],
        levels: SilentWordFilter.FrameLevels,
        frameLength: Int,
        sampleRate: Int32
    ) -> [Range<Int>] {
        let rate = Double(sampleRate)
        let firstFrame = keep.lowerBound / frameLength
        let lastFrame = min(levels.count, keep.upperBound / frameLength)
        guard lastFrame > firstFrame else { return [] }
        let voice = SilentWordFilter.VoiceThresholds(levels, frames: firstFrame..<lastFrame)
        var edges = [keep.lowerBound]
        for word in words {
            edges.append(Int(word.startSequence))
            edges.append(min(Int(word.endSequence), Int(word.startSequence) + Int(maximumWordSeconds * rate)))
        }
        edges.append(keep.upperBound)
        var holes: [Range<Int>] = []
        for pair in stride(from: 0, to: edges.count - 1, by: 2) {
            let gap = edges[pair]..<max(edges[pair], edges[pair + 1])
            guard Double(gap.count) >= holeSeconds * rate else { continue }
            let frames = (gap.lowerBound / frameLength)..<min(levels.count, gap.upperBound / frameLength)
            let voiced = frames.reduce(0) { $0 + (voice.isVoice(levels, frame: $1) ? 1 : 0) }
            if Double(voiced) * SilenceTracker.frameSeconds >= holeVoicedSeconds { holes.append(gap) }
        }
        return holes
    }

    /// Short windows covering `holes`: holes close together share one, and a hole
    /// longer than a window's span is heard in several.
    public static func repairWindows(
        for holes: [Range<Int>],
        total: Int,
        sampleRate: Int32,
        windowSeconds: TimeInterval = repairWindowSeconds
    ) -> [Window] {
        let rate = Double(sampleRate)
        let context = Int(repairContextSeconds * rate)
        let length = Int(windowSeconds * rate)
        let span = length - 2 * context
        var windows: [Window] = []
        var pending = holes.sorted { $0.lowerBound < $1.lowerBound }[...]
        // Kept stretches never overlap, or a word could be taken twice.
        var keptThrough = 0
        while var first = pending.first {
            // A hole the last window's context already kept is done; one it reached
            // into goes on from there.
            if first.upperBound <= keptThrough {
                pending.removeFirst()
                continue
            }
            if first.lowerBound < keptThrough {
                first = keptThrough..<first.upperBound
                pending[pending.startIndex] = first
            }
            var start = first.lowerBound
            // A hole longer than a span is heard a span at a time.
            if first.count > span {
                let end = start + span
                windows.append(Window(audio: widened(max(0, start - context)..<min(total, end + context), to: length, total: total), keep: start..<end))
                keptThrough = end
                pending[pending.startIndex] = end..<first.upperBound
                continue
            }
            var end = first.upperBound
            pending.removeFirst()
            while let next = pending.first, next.upperBound - start <= span {
                end = next.upperBound
                pending.removeFirst()
            }
            // Short holes are heard centred in the window, with context on both sides.
            let spare = max(0, span - (end - start)) / 2
            start = max(keptThrough, start - spare)
            end = min(total, end + spare)
            windows.append(Window(audio: widened(max(0, start - context)..<min(total, end + context), to: length, total: total), keep: start..<end))
            keptThrough = end
        }
        return windows
    }

    // MARK: - Transcription

    /// Transcribes `recording`.
    ///
    /// - `recognize` decodes one window (samples at the recording's rate, and the index
    ///   of its first sample in the recording) and returns its words, in milliseconds
    ///   from the window's first sample.
    /// - `predictor` decides marks and capitals; `recognizerMarks`, for a recogniser that
    ///   writes its own, is fed every window and then serves as the predictor.
    /// - `speakers`, when given, labels the frames of a 10 s window for the voice change
    ///   detector.
    /// - `progress` is called after every window; `isCancelled` is checked before each.
    public func transcribe(
        _ recording: PCMRecording,
        recognize: ([Float], Int) throws -> [RecognizedWord],
        predictor: PunctuationPredicting?,
        recognizerMarks: RecognizerPunctuation? = nil,
        speakers: (@Sendable ([Float]) -> [Int]?)? = nil,
        isCancelled: () -> Bool = { false },
        progress: (Progress) -> Void = { _ in }
    ) throws -> Result {
        let rate = recording.sampleRate
        var session = SessionTranscript()
        session.begin()
        let windows = windows(for: recording)
        guard !windows.isEmpty else { return Result(session: session, heardWords: [], repairedWords: 0) }
        let predictor: PunctuationPredicting? = recognizerMarks ?? predictor

        var silenceTracker = SilenceTracker()
        var formatter = TranscriptFormatter(rules: rules)
        formatter.decisions = decisions
        formatter.pauseRule = configuration.pauseRule
        var words: [StableTranscriptWord] = []
        var formattedThrough = 0
        var settledAll = false
        var repairedWords = 0
        var decodedWindows = 0
        var latest = ReadableTranscriptSnapshot()
        var heardThrough = 0
        // The voice change detector runs on the CPU beside recognition, which has the GPU:
        // run one after the other, it doubled the time a file took.
        let speakerPass = speakers.map { SpeakerPass(recording: recording, classify: $0) }
        defer { speakerPass?.cancel() }
        var speakerMap: SpeakerChangeMap?

        /// Silence is measured in order, as the live tracker does, and voice changes are
        /// read as they stood once the detector had heard the same audio.
        func hear(through end: Int) {
            let chunkSamples = Int(SpeakerTurnTracker.hopSeconds * Double(rate))
            while heardThrough < end {
                let next = min(end, heardThrough + max(1, chunkSamples))
                silenceTracker.append(recording.floats(heardThrough..<next), endSequence: UInt64(next), sampleRate: rate)
                heardThrough = next
            }
            speakerMap = speakerPass?.map(through: end)
        }

        func snapshot(through end: Int, audioEnd: UInt64) -> ReadableTranscriptSnapshot {
            let visible = Array(words[max(0, end - Self.retainedWords)..<end])
            return ReadableTranscriptSnapshot(
                committedWords: visible,
                latestCommittedEndSequence: visible.last?.endSequence,
                latestVisibleEndSequence: visible.last?.endSequence,
                audioEndSequence: audioEnd,
                sampleRate: rate,
                lastHeardEndSequence: visible.last?.endSequence
            )
        }

        /// Settles what the words heard so far allow, a step at a time, so the
        /// punctuation model sees every word with the right context the live reader
        /// gives it, and never more words than it can take.
        func format(isFinal: Bool) {
            // The last step always runs, to settle the words still waiting for context.
            while formattedThrough < words.count || (isFinal && !words.isEmpty && formattedThrough == words.count && !settledAll) {
                let end = min(words.count, formattedThrough + Self.formattingStepWords)
                let last = isFinal && end == words.count
                // Until the last step, the audio "ends" with the newest word, so the
                // formatter waits for the words after it instead of settling at an edge.
                let audioEnd = last ? UInt64(recording.count) : (words[end - 1].endSequence ?? 0)
                let formatted = formatter.format(
                    snapshot(through: end, audioEnd: audioEnd),
                    silences: silenceTracker.map,
                    speakers: speakerMap,
                    isFinal: last,
                    predictor: predictor
                )
                session.observe(formatted)
                latest = formatted
                formattedThrough = end
                if last { settledAll = true }
            }
        }

        let levels = Self.frameLevels(recording)
        let frame = Self.frameLength(rate)

        /// Recognises `whole` and returns its words on the recording's clock, without
        /// the ones written where nobody spoke. A window that returns no word although
        /// the stretch it keeps, `keep`, has voice is heard again from a little later.
        func decode(_ whole: Range<Int>, keep: Range<Int>, length: TimeInterval, isLast: Bool) throws -> [TranscriptObservationWord] {
            var range = whole
            var padding = 0
            var samples: [Float] = []
            var recognized: [RecognizedWord] = []
            for shift in [0] + Self.emptyWindowShifts {
                if isCancelled() { throw TranscriptionError.cancelled }
                range = min(whole.upperBound, whole.lowerBound + Int(shift * Double(rate)))..<whole.upperBound
                // A recording shorter than the window is heard after silence, as live
                // listening's first seconds are, so the window still has its usual length.
                padding = max(0, Int(length * Double(rate)) - range.count)
                samples = [Float](repeating: 0, count: padding) + recording.floats(range)
                decodedWindows += 1
                recognized = try recognize(samples, range.lowerBound - padding)
                guard recognized.isEmpty, shift != Self.emptyWindowShifts.last,
                      !Self.holes(in: keep, words: [], levels: levels, frameLength: frame, sampleRate: rate).isEmpty
                else { break }
                if let trace {
                    let r = Double(rate)
                    trace(String(format: "finestra %.1f-%.1f buida, s'escolta de nou %.1f s més tard", Double(range.lowerBound) / r, Double(range.upperBound) / r, Self.emptyWindowShifts.first { $0 > shift } ?? 0))
                }
            }
            let voiced = SilentWordFilter.voicedWords(recognized, samples: samples, sampleRate: rate, leadingPaddingSamples: padding)
            let observed: [TranscriptObservationWord] = voiced.compactMap { word in
                let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, word.endMilliseconds > word.startMilliseconds else { return nil }
                let startInWindow = Int(word.startMilliseconds) * Int(rate) / 1_000 - padding
                let endInWindow = Int(word.endMilliseconds) * Int(rate) / 1_000 - padding
                guard endInWindow > 0 else { return nil }
                let start = UInt64(range.lowerBound + max(0, startInWindow))
                let end = UInt64(range.lowerBound + endInWindow)
                return TranscriptObservationWord(
                    text: text,
                    startSequence: min(start, UInt64(range.upperBound)),
                    endSequence: min(end, UInt64(range.upperBound)),
                    confidence: word.confidence
                )
            }
            guard let recognizerMarks else { return observed }
            return recognizerMarks.strip(
                observed,
                windowStart: UInt64(range.lowerBound),
                windowEnd: UInt64(range.upperBound),
                sampleRate: rate,
                includesSessionStart: range.lowerBound == 0,
                isFinal: isLast
            )
        }

        func middle(_ word: TranscriptObservationWord) -> Int {
            Int(word.startSequence / 2 + word.endSequence / 2)
        }

        for (index, window) in windows.enumerated() {
            if isCancelled() { throw TranscriptionError.cancelled }
            let isLast = index == windows.count - 1
            var kept = try decode(window.audio, keep: window.keep, length: configuration.windowSeconds, isLast: isLast).filter { window.keep.contains(middle($0)) }
            // A long window now and then comes back with a stretch of speech missing (the
            // decoder skips to the words after a pause). Live listening hears every word
            // in dozens of windows and never notices; here each is heard once, so every
            // stretch of voice left without words is heard again in the short windows
            // live listening uses. On two podcast episodes this found 9 s and 30 words
            // lost in one window.
            // A later round hears again, in windows of another length, only the holes
            // where the round before found some words but left voice without any: there
            // speech is being dropped. Holes where it found nothing are music, laughter
            // or noise, and hearing those again only invents words.
            var evidence: [Range<Int>]?
            for seconds in Self.repairRounds {
                var holes = Self.holes(in: window.keep, words: kept, levels: levels, frameLength: frame, sampleRate: rate)
                if let evidence {
                    holes = holes.filter { hole in evidence.contains { $0.overlaps(hole) } }
                }
                guard !holes.isEmpty else { break }
                var found: [TranscriptObservationWord] = []
                for repair in Self.repairWindows(for: holes, total: recording.count, sampleRate: rate, windowSeconds: seconds) {
                    if isCancelled() { throw TranscriptionError.cancelled }
                    found += try decode(repair.audio, keep: repair.keep, length: seconds, isLast: false).filter { word in
                        let at = middle(word)
                        return repair.keep.contains(at) && holes.contains { $0.contains(at) }
                    }
                }
                if let trace {
                    let r = Double(rate)
                    let spans = holes.map { String(format: "%.1f-%.1f", Double($0.lowerBound) / r, Double($0.upperBound) / r) }.joined(separator: " ")
                    trace(String(format: "finestra %.1f-%.1f, ronda de %.0f s: %d forats (%@), %d paraules trobades", Double(window.audio.lowerBound) / r, Double(window.audio.upperBound) / r, seconds, holes.count, spans, found.count))
                }
                guard !found.isEmpty else { break }
                evidence = holes.filter { hole in found.contains { hole.contains(middle($0)) } }
                kept = (kept + found).sorted { $0.startSequence < $1.startSequence }
                repairedWords += found.count
            }
            for word in kept {
                // Sequences stay in order even if a window stamps a word early.
                let start = max(word.startSequence, words.last?.startSequence ?? 0)
                let id = UInt64(words.count + 1)
                words.append(StableTranscriptWord(
                    id: id,
                    text: word.text,
                    isCommitted: true,
                    anchor: id,
                    startSequence: start,
                    endSequence: max(start, word.endSequence)
                ))
            }
            hear(through: window.audio.upperBound)
            format(isFinal: isLast)
            progress(Progress(fraction: Double(window.keep.upperBound) / Double(recording.count), session: session, snapshot: latest))
        }
        return Result(session: session, heardWords: words.map(\.text), repairedWords: repairedWords, decodedWindows: decodedWindows, decisions: formatter.decisions)
    }
}

/// The voice change detector over a whole recording, on a thread of its own: the same
/// tracker the live reader uses, fed every `SpeakerTurnTracker.hopSeconds`. What it had
/// decided after each stretch is kept, so the transcriber reads the voice changes as
/// they stood at any point, however far ahead the detector has run.
final class SpeakerPass: @unchecked Sendable {
    private let condition = NSCondition()
    /// The tracker's changes after hearing the audio up to `through`, oldest first.
    private var maps: [(through: Int, map: SpeakerChangeMap)] = []
    private var finished = false
    private var cancelled = false

    init(recording: PCMRecording, classify: @escaping @Sendable ([Float]) -> [Int]?) {
        let thread = Thread { [self] in run(recording, classify) }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    /// The changes decided once the audio up to `end` had been heard; waits for the
    /// detector to get there.
    func map(through end: Int) -> SpeakerChangeMap? {
        condition.lock()
        defer { condition.unlock() }
        while !finished && !cancelled && (maps.last?.through ?? 0) < end { condition.wait() }
        // The newest entry that had not heard past `end`.
        var low = 0
        var high = maps.count
        while low < high {
            let middle = (low + high) / 2
            if maps[middle].through <= end { low = middle + 1 } else { high = middle }
        }
        let found = low > 0 ? maps[low - 1].map : maps.first?.map
        // What the transcriber has passed is never asked for again.
        if low > 2 { maps.removeFirst(low - 2) }
        return found
    }

    private func run(_ recording: PCMRecording, _ classify: @Sendable ([Float]) -> [Int]?) {
        let rate = recording.sampleRate
        let hop = max(1, Int(SpeakerTurnTracker.hopSeconds * Double(rate)))
        var tracker = SpeakerTurnTracker()
        var position = 0
        while position < recording.count {
            condition.lock()
            let stop = cancelled
            condition.unlock()
            if stop { return }
            let next = min(recording.count, position + hop)
            tracker.append(recording.floats(position..<next), endSequence: UInt64(next), sampleRate: rate)
            if let window = tracker.nextWindow(), let classes = classify(window.samples) {
                tracker.ingest(frameClasses: classes, of: window)
            }
            position = next
            condition.lock()
            maps.append((through: next, map: tracker.map))
            condition.broadcast()
            condition.unlock()
        }
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }
}
