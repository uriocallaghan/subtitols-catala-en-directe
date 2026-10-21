import Foundation

/// Predicts punctuation for every word of a lowercase, unpunctuated sequence.
public protocol PunctuationPredicting: AnyObject {
    /// One prediction per word, or `nil` if the prediction failed.
    func predictions(for words: [String]) -> [PunctuationPrediction]?
    /// The same, knowing where each word was heard (audio sample spans, `nil` when
    /// unknown). A recogniser that writes its own marks answers from them.
    func predictions(for words: [String], spans: [(start: UInt64, end: UInt64)?]) -> [PunctuationPrediction]?
}

extension PunctuationPredicting {
    public func predictions(for words: [String], spans: [(start: UInt64, end: UInt64)?]) -> [PunctuationPrediction]? {
        predictions(for: words)
    }

    /// The model's own choice for every word, without the voice.
    public func labels(for words: [String]) -> [PunctuationLabel]? {
        predictions(for: words)?.map(\.best)
    }
}

/// What a pause in the voice says about a sentence boundary.
///
/// Readers pause longer at a full stop than at a comma, and longer at a comma than
/// between words: in the founder's reading the median silences were 320, 160 and 80 ms.
/// The pause shifts the model's log-odds that a sentence ends; it never decides alone,
/// because spontaneous speech also pauses to hesitate.
public enum PauseEvidence {
    /// A pause this long after a finished sentence opens a new paragraph, and one this
    /// long at the live edge settles the words before it without waiting for more.
    public static let paragraphPause: TimeInterval = 0.5
    /// A pause this long starts a new line even inside a sentence: the speaker stopped,
    /// and the reader should see it. Rare mid-sentence (4 in 4,500 words of spontaneous
    /// parliamentary speech), so it does not fragment ordinary hesitations.
    public static let lineBreakPause: TimeInterval = 1.0
    /// Without audible silence (steady noise), this long without a new word also
    /// settles the edge.
    public static let wordlessPause: TimeInterval = 1.5
    /// How much the pause after a word weighs against the model's view.
    public struct Rule: Equatable, Sendable {
        /// Log-odds of a sentence end added per unit of natural-log pause length, the
        /// pause that adds none, and the range the addition is kept in.
        public var slope: Double
        public var neutralPause: TimeInterval
        public var bounds: ClosedRange<Double>
        /// Another voice taking over counts as a pause of at least this long.
        public var turnPause: TimeInterval
        /// When set, a word that ends no sentence takes a comma if the model's log-odds
        /// of a comma against no mark, plus this evidence, is positive; when `nil`, the
        /// model's own choice stands.
        public var comma: CommaEvidence?

        public struct CommaEvidence: Equatable, Sendable {
            public var bias: Double
            public var slope: Double
            public var neutralPause: TimeInterval
            public var bounds: ClosedRange<Double>
        }

        /// Live listening. Fitted with `.work/tools/pause_calibrate.py` on 148 sentence
        /// ends (the founder's three recordings and 87 ParlamentParla clips, punctuation
        /// model v3): sentence-end F1 62 with the model alone, 67 with the voice. Any
        /// slope from 0.5 to 1.0 with a neutral pause of 0.1-0.2 s scores within two
        /// points; these are the middle.
        public static let live = Rule(
            slope: 0.75, neutralPause: 0.15, bounds: -1.0...3.0,
            turnPause: paragraphPause, comma: nil
        )

        /// A whole file. The model reads a dozen words past every word here (live, three),
        /// and the pause after a word says more than it does live: fitted on four
        /// Softcatalà episodes (Quinze glaçons 3 and 9, EMpodcat 23 and 47, `.work/video-audit`)
        /// and checked on three others (15GdH4, Ep35, Ep54), where sentence-end F1 went
        /// from 61 to 65 and commas held (63). A change of voice ends a sentence three
        /// times in four there, so it weighs as a one-second pause. Any slope from 1.25
        /// to 2 scores within a point.
        public static let file = Rule(
            slope: 1.5, neutralPause: 0.15, bounds: -1.0...4.0,
            turnPause: 1.0,
            comma: CommaEvidence(bias: 0.5, slope: 0.25, neutralPause: 0.2, bounds: -1.0...2.0)
        )

        /// Log-odds of a sentence end contributed by `pause` seconds of silence.
        public func sentenceEndLogOdds(_ pause: TimeInterval) -> Double {
            let value = slope * log(max(pause, 0.01) / neutralPause)
            return min(max(value, bounds.lowerBound), bounds.upperBound)
        }
    }

    /// Log-odds of a sentence end contributed by `pause` seconds of silence, live.
    public static func sentenceEndLogOdds(_ pause: TimeInterval) -> Double {
        Rule.live.sentenceEndLogOdds(pause)
    }

    /// The label for a word, from the model's view and the silence after the word.
    public static func decide(
        _ prediction: PunctuationPrediction,
        pauseAfter: TimeInterval?,
        rule: Rule = .live
    ) -> PunctuationLabel {
        guard let pauseAfter else { return prediction.best }
        let probability = min(max(Double(prediction.sentenceEndProbability), 1e-4), 1 - 1e-4)
        let endsSentence = log(probability / (1 - probability)) + rule.sentenceEndLogOdds(pauseAfter) > 0
        func label(_ mark: PunctuationLabel.Mark) -> PunctuationLabel {
            mark == prediction.best.mark
                ? prediction.best
                : PunctuationLabel(mark: mark, casing: prediction.best.casing, opening: prediction.best.opening)
        }
        if !endsSentence, let comma = rule.comma {
            let odds = log(max(Double(prediction.probability(of: .comma)), 1e-4))
                - log(max(Double(max(prediction.probability(of: .none), prediction.probability(of: .colon))), 1e-4))
            let evidence = min(max(comma.slope * log(max(pauseAfter, 0.01) / comma.neutralPause), comma.bounds.lowerBound), comma.bounds.upperBound)
            if odds + comma.bias + evidence > 0 { return label(.comma) }
            return label(prediction.probability(of: .colon) > prediction.probability(of: .none) ? .colon : .none)
        }
        guard endsSentence != prediction.best.mark.endsSentence else { return prediction.best }
        let marks = PunctuationLabel.Mark.allCases.filter { $0.endsSentence == endsSentence }
        let mark = marks.max { prediction.probability(of: $0) < prediction.probability(of: $1) } ?? .none
        return label(mark)
    }
}

/// Turns the stabiliser's raw words into readable text: marks, capitals, digits and
/// paragraphs.
///
/// A word's formatting is decided once and then frozen, so text the reader has seen
/// never changes again. A word freezes when it is committed and the model has heard
/// `rightContextWords` words after it (three to five words of right context already
/// reach full-context quality), or when the speaker pauses after it; words freeze
/// strictly in reading order. Until then a word is shown as recognised, capitalised
/// only when the frozen word before it ends a sentence. Numbers turn into digits only
/// when every word they depend on is frozen.
///
/// The output marks as committed only the words whose text is final, so the reading
/// pane places each word once, already punctuated. Everything after them stays in the
/// live lane, where a change cannot move text the reader has already passed.
/// Word identity (`id`, `anchor`) is preserved; words absorbed into a number are hidden.
public struct TranscriptFormatter {
    public static let rightContextWords = 3
    /// Words of already-frozen text given to the model as left context.
    public static let leftContextWords = 32
    /// Words wait for the voice change detector only while it is at most this far
    /// behind the audio.
    public static let maximumSpeakerLagSeconds = 3.0

    private struct Frozen {
        let raw: String
        let label: PunctuationLabel
        let startsSentence: Bool
        /// A sentence ended here and the speaker paused, or another voice takes over:
        /// the next word opens a paragraph.
        let breaksParagraph: Bool
        /// The speaker stopped here for a second or more inside a sentence: the next
        /// word starts a new line of the same paragraph.
        let breaksLine: Bool
        /// A new voice starts with this word, found after the word before it froze.
        let opensTurn: Bool
    }

    /// One frozen word, as decided: for calibrating the pause evidence offline.
    public struct Decision: Sendable {
        public let word: String
        public let startSequence: UInt64?
        public let endSequence: UInt64?
        public let prediction: PunctuationPrediction
        public let pauseAfter: TimeInterval?
        public let wordsHeardAfter: Int
        /// Another voice takes over after the word.
        public let turnEnds: Bool
        public let label: PunctuationLabel
    }

    private var frozen: [UInt64: Frozen] = [:]
    /// Text of every word already shown as settled, and the settled words a number
    /// absorbed. Settled text never changes: without this, a number whose first word
    /// scrolled out of the stabiliser's window was read again from its second word
    /// ("dos mil vint" became "2020 1020 20") and the reading pane was rebuilt.
    private var settledText: [UInt64: String] = [:]
    private var absorbed = Set<UInt64>()
    /// Mark of the newest frozen word; `nil` before the session's first word.
    private var lastFrozenMark: PunctuationLabel.Mark?
    /// When set, every freeze is appended here. Off in the app.
    public var decisions: [Decision]?
    /// How the pause after a word weighs against the model: `.live` while listening,
    /// `.file` for a whole recording.
    public var pauseRule: PauseEvidence.Rule = .live

    /// The language's numbers and ordinary words.
    public let rules: LanguageRules

    public init(rules: LanguageRules = .catalan) {
        self.rules = rules
    }

    public mutating func reset() {
        frozen.removeAll(keepingCapacity: true)
        settledText.removeAll(keepingCapacity: true)
        absorbed.removeAll(keepingCapacity: true)
        lastFrozenMark = nil
    }

    /// Formats `snapshot`. With `isFinal`, every remaining word freezes. `silences`, the
    /// pauses measured in the audio, let the voice shape sentences and paragraphs;
    /// `speakers`, where another voice takes over, starts a paragraph there.
    public mutating func format(
        _ snapshot: ReadableTranscriptSnapshot,
        silences: SilenceMap? = nil,
        speakers: SpeakerChangeMap? = nil,
        isFinal: Bool = false,
        predictor: PunctuationPredicting?
    ) -> ReadableTranscriptSnapshot {
        let words = snapshot.words
        guard !words.isEmpty else { return snapshot }

        // The frozen prefix: every word from the start whose frozen entry still matches.
        var frozenCount = 0
        while frozenCount < words.count,
              let entry = frozen[words[frozenCount].id],
              entry.raw == words[frozenCount].text {
            frozenCount += 1
        }
        // Anything after a gap was revised (for example by the final correction); it is
        // decided again rather than trusted.
        let visibleIDs = Set(words.map(\.id))
        for index in frozenCount..<words.count {
            frozen[words[index].id] = nil
            settledText[words[index].id] = nil
            absorbed.remove(words[index].id)
        }
        frozen = frozen.filter { visibleIDs.contains($0.key) }
        settledText = settledText.filter { visibleIDs.contains($0.key) }
        absorbed.formIntersection(visibleIDs)
        if frozenCount > 0 { lastFrozenMark = frozen[words[frozenCount - 1].id]?.label.mark }

        func span(_ word: StableTranscriptWord) -> (start: UInt64, end: UInt64)? {
            guard let start = word.startSequence, let end = word.endSequence, end >= start else { return nil }
            return (start, end)
        }
        func silence(after index: Int) -> TimeInterval? {
            guard let silences, index + 1 < words.count,
                  let first = span(words[index]), let second = span(words[index + 1]) else { return nil }
            return silences.pause(between: first, and: second)
        }
        // The speaker has stopped after the newest word: what is committed can be
        // settled now instead of waiting for words that are not coming. Silence heard
        // in the audio says so first; in steady noise, where no silence can be heard,
        // a long stretch without new words says it later.
        let edgeSilence = words.last.flatMap(span).flatMap { silences?.trailingSilence(after: $0) } ?? 0
        let pausedAtEdge = edgeSilence >= PauseEvidence.paragraphPause
            || (snapshot.trailingSilence ?? 0) >= PauseEvidence.wordlessPause
        // Words a new voice starts with. A word waits to freeze until the voice change
        // detector has settled the audio up to the next word, so a change is known
        // before the word that ends a turn is decided; if the detector falls behind,
        // nothing waits for it.
        let turnStarts = speakers?.turnStarts(in: words.map(span)) ?? []
        func speakerSettled(through index: Int) -> Bool {
            guard let speakers, speakers.sampleRate > 0, !isFinal else { return true }
            let audioEnd = snapshot.audioEndSequence ?? 0
            let lag = audioEnd > speakers.decidedThrough
                ? Double(audioEnd - speakers.decidedThrough) / Double(speakers.sampleRate) : 0
            guard lag <= Self.maximumSpeakerLagSeconds else { return true }
            let next = index + 1 < words.count ? words[index + 1].startSequence : words[index].endSequence
            return (next ?? 0) <= speakers.decidedThrough
        }

        // Undecided words that follow a long pause after what already sounds like the end
        // of a sentence: they are shown on their new line from the start, rather than
        // jumping there once the sentence end is decided a second later.
        var expectedParagraphs = Set<Int>()
        var expectedLines = Set<Int>()
        if frozenCount < words.count, let predictor {
            let contextStart = max(0, frozenCount - Self.leftContextWords)
            let raw = words[contextStart...].map { $0.text.lowercased() }
            let spans = words[contextStart...].map(span)
            if let predictions = predictor.predictions(for: Array(raw), spans: spans), predictions.count == raw.count {
                var index = frozenCount
                while index < words.count {
                    let word = words[index]
                    let isLast = index == words.count - 1
                    let pause = isLast ? (edgeSilence > 0 ? edgeSilence : nil) : silence(after: index)
                    let heardAfter = words.count - 1 - index
                    let longPause = (pause ?? 0) >= PauseEvidence.paragraphPause
                    guard isFinal || (word.isCommitted && (heardAfter >= Self.rightContextWords || longPause || pausedAtEdge)
                                      && speakerSettled(through: index)) else { break }
                    // Another voice after this word: a turn usually ends a sentence, so
                    // it counts as a paragraph pause would.
                    let turnEnds = turnStarts.contains(index + 1)
                    let evidence = turnEnds ? max(pause ?? 0, pauseRule.turnPause) : pause
                    var label = PauseEvidence.decide(predictions[index - contextStart], pauseAfter: evidence, rule: pauseRule)
                    // The model sometimes capitalises an ordinary word as if a sentence
                    // started, after only a comma: "Roig, La meva germana". Sentence breaks
                    // come from marks alone, so such a capital is dropped; proper nouns
                    // are never on the list and keep theirs.
                    if label.casing == .capitalized, !(lastFrozenMark?.endsSentence ?? true),
                       rules.isOrdinaryWord(word.text) {
                        label = PunctuationLabel(mark: label.mark, casing: .lower, opening: label.opening)
                    }
                    frozen[word.id] = Frozen(
                        raw: word.text,
                        label: label,
                        startsSentence: lastFrozenMark?.endsSentence ?? true,
                        breaksParagraph: (label.mark.endsSentence && longPause) || turnEnds,
                        breaksLine: (pause ?? 0) >= PauseEvidence.lineBreakPause
                            && !(label.mark.endsSentence || turnEnds),
                        opensTurn: turnStarts.contains(index)
                    )
                    decisions?.append(Decision(
                        word: word.text,
                        startSequence: word.startSequence,
                        endSequence: word.endSequence,
                        prediction: predictions[index - contextStart],
                        pauseAfter: pause,
                        wordsHeardAfter: heardAfter,
                        turnEnds: turnEnds,
                        label: label
                    ))
                    lastFrozenMark = label.mark
                    index += 1
                }
                frozenCount = index
                for index in frozenCount..<max(frozenCount, words.count - 1) {
                    guard let pause = silence(after: index), pause >= PauseEvidence.paragraphPause else { continue }
                    if PauseEvidence.decide(predictions[index - contextStart], pauseAfter: pause, rule: pauseRule).mark.endsSentence {
                        expectedParagraphs.insert(index + 1)
                    } else if pause >= PauseEvidence.lineBreakPause {
                        expectedLines.insert(index + 1)
                    }
                }
                // A new voice is shown in its own paragraph from its first word.
                expectedParagraphs.formUnion(turnStarts.filter { $0 >= frozenCount })
                expectedLines.subtract(expectedParagraphs)
            }
        }

        return render(
            snapshot,
            frozenCount: frozenCount,
            expectedParagraphs: expectedParagraphs,
            expectedLines: expectedLines,
            isFinal: isFinal
        )
    }

    private mutating func render(
        _ snapshot: ReadableTranscriptSnapshot,
        frozenCount: Int,
        expectedParagraphs: Set<Int>,
        expectedLines: Set<Int>,
        isFinal: Bool
    ) -> ReadableTranscriptSnapshot {
        let words = snapshot.words
        var texts: [String] = []
        texts.reserveCapacity(words.count)
        var previousMark: PunctuationLabel.Mark? = nil
        // Every paragraph starts with a capital, even when a new voice or the speaker's
        // own pause cut a sentence without a full stop.
        func followsParagraphBreak(_ index: Int) -> Bool {
            index > 0 && index - 1 < frozenCount && frozen[words[index - 1].id]?.breaksParagraph == true
        }
        for (index, word) in words.enumerated() {
            if index < frozenCount, let entry = frozen[word.id] {
                var text = entry.label.cased(word.text)
                if entry.startsSentence || entry.opensTurn || followsParagraphBreak(index) {
                    text = PunctuationLabel.capitalizingFirstLetter(text)
                }
                texts.append(entry.label.opening.rawValue + text + entry.label.mark.rawValue)
                previousMark = entry.label.mark
            } else {
                // Not decided yet: shown as heard. Only a frozen full stop before it, or a
                // pause that already makes one near-certain, may capitalise it.
                let startsSentence = expectedParagraphs.contains(index) || followsParagraphBreak(index)
                    || (index == frozenCount && (previousMark?.endsSentence ?? (frozenCount == 0 && lastFrozenMark == nil)))
                texts.append(startsSentence ? PunctuationLabel.capitalizingFirstLetter(word.text) : word.text)
                previousMark = nil
            }
        }

        // Digits, inside the frozen prefix only. A number is final once the words its
        // rules look at (up to two after it) are frozen as well; until then its words
        // stay in the live lane with the rest of the undecided text.
        var hidden = Set<Int>()
        var settledCount = isFinal ? words.count : frozenCount
        // Words already shown as settled keep exactly what the reader saw.
        var shownCount = 0
        while shownCount < frozenCount {
            let id = words[shownCount].id
            if absorbed.contains(id) {
                hidden.insert(shownCount)
            } else if let text = settledText[id] {
                texts[shownCount] = text
            } else {
                break
            }
            shownCount += 1
        }
        if frozenCount > 0, let numbers = rules.numbers {
            let raw = words[..<frozenCount].map(\.text)
            let boundaries = Set((0..<frozenCount).filter { frozen[words[$0].id]?.label.mark != PunctuationLabel.Mark.none })
            for replacement in numbers.replacements(in: raw, boundaries: boundaries)
            where replacement.range.lowerBound >= shownCount {
                guard isFinal || replacement.range.upperBound + 1 < frozenCount else {
                    settledCount = min(settledCount, replacement.range.lowerBound)
                    continue
                }
                let last = replacement.range.upperBound - 1
                let mark = frozen[words[last].id]?.label.mark.rawValue ?? ""
                let opening = frozen[words[replacement.range.lowerBound].id]?.label.opening.rawValue ?? ""
                texts[replacement.range.lowerBound] = opening + replacement.text + mark
                for index in replacement.range.dropFirst() { hidden.insert(index) }
            }
            // A number that may still grow: its words wait until the two words after
            // them are frozen too, as "quinze" does before "per cent".
            if !isFinal {
                for index in max(shownCount, frozenCount - 2)..<frozenCount where !hidden.contains(index) {
                    if numbers.mayExtendNumber(words[index].text, after: index > 0 ? words[index - 1].text : nil) {
                        settledCount = min(settledCount, index)
                        break
                    }
                }
            }
        }

        for index in shownCount..<settledCount {
            if hidden.contains(index) {
                absorbed.insert(words[index].id)
            } else {
                settledText[words[index].id] = texts[index]
            }
        }

        func rebuilt(_ index: Int) -> StableTranscriptWord {
            let previous = index > 0 && index - 1 < frozenCount ? frozen[words[index - 1].id] : nil
            let opensParagraph = (previous?.breaksParagraph ?? false) || expectedParagraphs.contains(index)
                || (index < frozenCount && frozen[words[index].id]?.opensTurn == true)
            // A number written as digits lasts until its last spoken word ends, so its
            // subtitle stays up while "dos mil vint-i-quatre" is said.
            var end = words[index].endSequence
            var next = index + 1
            while next < words.count, hidden.contains(next) {
                end = words[next].endSequence ?? end
                next += 1
            }
            return StableTranscriptWord(
                id: words[index].id,
                text: texts[index],
                isCommitted: index < settledCount,
                anchor: words[index].anchor,
                startSequence: words[index].startSequence,
                endSequence: end,
                startsParagraph: opensParagraph,
                startsLine: !opensParagraph && ((previous?.breaksLine ?? false) || expectedLines.contains(index))
            )
        }
        return ReadableTranscriptSnapshot(
            committedWords: (0..<settledCount).filter { !hidden.contains($0) }.map(rebuilt),
            provisionalWords: (settledCount..<words.count).filter { !hidden.contains($0) }.map(rebuilt),
            latestCommittedEndSequence: snapshot.latestCommittedEndSequence,
            latestVisibleEndSequence: snapshot.latestVisibleEndSequence,
            audioEndSequence: snapshot.audioEndSequence,
            sampleRate: snapshot.sampleRate,
            lastHeardEndSequence: snapshot.lastHeardEndSequence
        )
    }
}
