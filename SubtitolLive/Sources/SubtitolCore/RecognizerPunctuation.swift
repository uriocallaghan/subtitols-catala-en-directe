import Foundation

/// The marks and capitals a recogniser writes itself (NVIDIA's Spanish and English
/// models, BSC's punctuated LoS model), used as the punctuation of a language that has
/// no punctuation model of its own.
///
/// The stabiliser is given bare lowercase words, so a word keeps one identity whatever
/// mark a window puts on it. The marks are kept apart, per stretch of audio, from the
/// newest window that heard the word well inside it: a window that ends just after a
/// word tends to close it with a full stop ("del." at the edge, "del" once "clima" is
/// heard), and one that starts just before a word tends to capitalise it.
public final class RecognizerPunctuation: PunctuationPredicting, @unchecked Sendable {
    struct Entry {
        let key: String
        let start: UInt64
        let end: UInt64
        let label: PunctuationLabel

        var midpoint: UInt64 { start + (end - start) / 2 }
    }

    /// A word this close to the end of its window has not been heard in context yet.
    public static let trailingGuardSeconds = 0.6
    /// Nor has one this close to the window's start, unless the session starts there.
    public static let leadingGuardSeconds = 0.5
    /// How far a word may drift between windows and still be the same word.
    static let matchSeconds = 0.4
    /// Marks older than this behind the newest audio are forgotten.
    static let memorySeconds = 60.0

    private let lock = NSLock()
    /// From words heard well inside a window, newest window first to win.
    private var settled: [Entry] = []
    /// Every word of the newest window, for a word never heard well inside one.
    private var latest: [Entry] = []
    private var sampleRate: Int32 = 16_000

    public init() {}

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        settled.removeAll()
        latest.removeAll()
    }

    /// Splits the marks and capitals off one window's words, remembers them, and
    /// returns the bare lowercase words for the stabiliser. A mark the recogniser wrote
    /// as a word of its own (" , ", "¿ ") joins the word it belongs to.
    public func strip(
        _ words: [TranscriptObservationWord],
        windowStart: UInt64,
        windowEnd: UInt64,
        sampleRate: Int32,
        includesSessionStart: Bool,
        isFinal: Bool = false
    ) -> [TranscriptObservationWord] {
        let parsed = Self.parse(words)
        let rate = Double(max(1, sampleRate))
        let trailing = UInt64(Self.trailingGuardSeconds * rate)
        let leading = UInt64(Self.leadingGuardSeconds * rate)
        let entries = parsed.map { Entry(key: $0.bare.text, start: $0.bare.startSequence, end: $0.bare.endSequence, label: $0.label) }

        lock.lock()
        defer { lock.unlock() }
        self.sampleRate = max(1, sampleRate)
        latest = entries
        for entry in entries {
            let insideEnd = isFinal || entry.end.saturatingAdd(trailing) <= windowEnd
            let insideStart = includesSessionStart || entry.start >= windowStart.saturatingAdd(leading)
            guard insideEnd, insideStart else { continue }
            let tolerance = UInt64(0.08 * rate)
            settled.removeAll { old in
                old.start < entry.end.saturatingAdd(tolerance) && entry.start < old.end.saturatingAdd(tolerance)
            }
            let index = settled.firstIndex { $0.start > entry.start } ?? settled.count
            settled.insert(entry, at: index)
        }
        let horizon = UInt64(Self.memorySeconds * rate)
        if windowEnd > horizon {
            settled.removeAll { $0.end < windowEnd - horizon }
        }
        return parsed.map(\.bare)
    }

    public func predictions(for words: [String]) -> [PunctuationPrediction]? {
        predictions(for: words, spans: words.map { _ in nil })
    }

    public func predictions(
        for words: [String],
        spans: [(start: UInt64, end: UInt64)?]
    ) -> [PunctuationPrediction]? {
        guard words.count == spans.count else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return zip(words, spans).map { word, span in
            let key = Self.bare(word)
            let label = span.flatMap { span in
                Self.nearest(key: key, span: span, in: settled, sampleRate: sampleRate)
                    ?? Self.nearest(key: key, span: span, in: latest, sampleRate: sampleRate)
            }?.label ?? PunctuationLabel.plain
            return Self.prediction(for: label)
        }
    }

    /// Sure of the recogniser's mark, but not certain: a long pause can still end a
    /// sentence the recogniser ran on (`PauseEvidence`), never undo one it ended.
    static func prediction(for label: PunctuationLabel) -> PunctuationPrediction {
        let other: PunctuationLabel.Mark = label.mark == .none ? .period : .none
        return PunctuationPrediction(best: label, markProbabilities: [label.mark: 0.9, other: 0.1])
    }

    private static func nearest(
        key: String,
        span: (start: UInt64, end: UInt64),
        in entries: [Entry],
        sampleRate: Int32
    ) -> Entry? {
        let midpoint = span.start + (span.end - span.start) / 2
        let reach = UInt64(matchSeconds * Double(sampleRate))
        return entries
            .filter { $0.key == key }
            .map { ($0, $0.midpoint > midpoint ? $0.midpoint - midpoint : midpoint - $0.midpoint) }
            .filter { $0.1 <= max(reach, (span.end - span.start)) }
            .min { $0.1 < $1.1 }?.0
    }

    // MARK: - Parsing

    struct Parsed {
        let bare: TranscriptObservationWord
        let label: PunctuationLabel
    }

    private static let closingMarks: [Character: PunctuationLabel.Mark] = [
        ".": .period, "…": .period, ",": .comma, ";": .comma, ":": .colon,
        "?": .question, "!": .exclamation,
    ]
    private static let openingMarks: [Character: PunctuationLabel.Opening] = ["¿": .question, "¡": .exclamation]
    private static let decoration = CharacterSet(charactersIn: "\"«»“”()[]{}")

    static func bare(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".…,;:?!¿¡").union(decoration).union(.whitespaces))
    }

    static func parse(_ words: [TranscriptObservationWord]) -> [Parsed] {
        var result: [Parsed] = []
        var pendingOpening: PunctuationLabel.Opening = .none
        for word in words {
            var text = Substring(word.text.trimmingCharacters(in: decoration.union(.whitespaces)))
            var opening = pendingOpening
            while let first = text.first, let mark = openingMarks[first] {
                opening = mark
                text = text.dropFirst()
            }
            var mark: PunctuationLabel.Mark = .none
            while let last = text.last, let found = closingMarks[last] {
                // The strongest mark wins: "?!" asks, "…," is still a stop.
                if mark == .none || (found.endsSentence && !mark.endsSentence) { mark = found }
                text = text.dropLast()
            }
            let core = String(text).trimmingCharacters(in: decoration)
            if core.isEmpty {
                // A mark written as its own word: it closes the word before it, or
                // opens the one after it.
                if mark != .none, let previous = result.popLast() {
                    let joined = previous.label.mark == .none || (mark.endsSentence && !previous.label.mark.endsSentence)
                        ? mark : previous.label.mark
                    result.append(Parsed(bare: previous.bare, label: PunctuationLabel(
                        mark: joined, casing: previous.label.casing, opening: previous.label.opening
                    )))
                }
                pendingOpening = opening
                continue
            }
            pendingOpening = .none
            result.append(Parsed(
                bare: TranscriptObservationWord(
                    text: core.lowercased(),
                    startSequence: word.startSequence,
                    endSequence: word.endSequence,
                    confidence: word.confidence
                ),
                label: PunctuationLabel(mark: mark, casing: casing(of: core), opening: opening)
            ))
        }
        return result
    }

    static func casing(of word: String) -> PunctuationLabel.Casing {
        let letters = word.filter(\.isLetter)
        guard let first = letters.first, first.isUppercase else { return .lower }
        return letters.count > 1 && letters.allSatisfy(\.isUppercase) ? .allCaps : .capitalized
    }
}

private extension UInt64 {
    func saturatingAdd(_ other: UInt64) -> UInt64 {
        let (value, overflow) = addingReportingOverflow(other)
        return overflow ? .max : value
    }
}

/// For a language with no punctuation of any kind: words still settle on schedule,
/// unpunctuated, and only a long pause ends a sentence.
public final class PlainPunctuation: PunctuationPredicting, @unchecked Sendable {
    public init() {}

    public func predictions(for words: [String]) -> [PunctuationPrediction]? {
        words.map { _ in RecognizerPunctuation.prediction(for: .plain) }
    }
}
