import Foundation

/// What the punctuation model decides for one word: the mark after it and its casing.
///
/// The model's 24 labels are "<mark><case>" strings such as ".u" or "l".
public struct PunctuationLabel: Equatable, Hashable, Sendable {
    public enum Mark: String, CaseIterable, Sendable {
        case none = ""
        case comma = ","
        case period = "."
        case question = "?"
        case exclamation = "!"
        case colon = ":"

        /// Marks after which the next word starts a sentence.
        public var endsSentence: Bool {
            self == .period || self == .question || self == .exclamation
        }
    }

    public enum Casing: Character, Sendable {
        case lower = "l"
        /// First letter upper-case: "Jordi".
        case capitalized = "u"
        /// Capital after an elision: "l'Empordà".
        case capitalizedAfterElision = "e"
        /// Every letter upper-case: "BSC".
        case allCaps = "a"
    }

    /// Spanish opens a question or an exclamation with its own mark.
    public enum Opening: String, Sendable {
        case none = ""
        case question = "¿"
        case exclamation = "¡"
    }

    public let mark: Mark
    public let casing: Casing
    /// Written before the word; only recognisers that write it set it.
    public let opening: Opening

    public static let plain = PunctuationLabel(mark: .none, casing: .lower)

    public init(mark: Mark, casing: Casing, opening: Opening = .none) {
        self.mark = mark
        self.casing = casing
        self.opening = opening
    }

    /// Parses a model label; `nil` for anything outside the 24-label scheme.
    public init?(modelLabel: String) {
        guard let caseCharacter = modelLabel.last,
              let casing = Casing(rawValue: caseCharacter),
              let mark = Mark(rawValue: String(modelLabel.dropLast())) else { return nil }
        self.init(mark: mark, casing: casing)
    }

    /// The word written with this casing, without the mark.
    public func cased(_ word: String) -> String {
        switch casing {
        case .lower:
            return word
        case .capitalized:
            return Self.capitalizingFirstLetter(word)
        case .allCaps:
            return word.uppercased()
        case .capitalizedAfterElision:
            // "l'empordà" → "l'Empordà"; "qu'" as well as single-letter elisions.
            guard let apostrophe = word.firstIndex(of: "'") else { return word }
            let prefix = word[..<apostrophe].lowercased()
            guard ["l", "d", "s", "m", "t", "n", "qu"].contains(prefix) else { return word }
            let rest = word[word.index(after: apostrophe)...]
            return word[...apostrophe] + Self.capitalizingFirstLetter(String(rest))
        }
    }

    public static func capitalizingFirstLetter(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }
}

/// The model's view of one word: its own choice, and how sure it is about each mark.
public struct PunctuationPrediction: Equatable, Sendable {
    /// The most probable of the model's labels.
    public let best: PunctuationLabel
    /// Probability of each mark after the word, summed over casings.
    public let markProbabilities: [PunctuationLabel.Mark: Float]

    public init(best: PunctuationLabel, markProbabilities: [PunctuationLabel.Mark: Float]) {
        self.best = best
        self.markProbabilities = markProbabilities
    }

    /// A certain prediction: all probability on `label`.
    public init(certain label: PunctuationLabel) {
        self.init(best: label, markProbabilities: [label.mark: 1])
    }

    /// From one probability per model label.
    public init(labels: [PunctuationLabel], probabilities: [Float]) {
        precondition(labels.count == probabilities.count && !labels.isEmpty)
        var marks: [PunctuationLabel.Mark: Float] = [:]
        var bestIndex = 0
        for (index, label) in labels.enumerated() {
            marks[label.mark, default: 0] += probabilities[index]
            if probabilities[index] > probabilities[bestIndex] { bestIndex = index }
        }
        self.init(best: labels[bestIndex], markProbabilities: marks)
    }

    public func probability(of mark: PunctuationLabel.Mark) -> Float {
        markProbabilities[mark] ?? 0
    }

    /// Probability that a sentence ends after the word.
    public var sentenceEndProbability: Float {
        PunctuationLabel.Mark.allCases.filter(\.endsSentence).reduce(0) { $0 + probability(of: $1) }
    }
}
