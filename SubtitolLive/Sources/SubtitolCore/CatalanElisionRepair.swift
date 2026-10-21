import Foundation

/// Restores Catalan elisions that a recogniser emitted as two words: "l acordió" →
/// "l'acordió", "m encanta" → "m'encanta", "se n va" → "se'n va".
///
/// Some training transcripts (notably parliamentary ones) drop the apostrophe, so a
/// model can learn to write the elided article or pronoun as a word of its own. In
/// Catalan none of d, l, m, n, s, t is ever a word by itself, so joining one of them to
/// a following word that starts with a vowel or h is safe. Before a consonant the same
/// letter is a reduced pronoun that leans on the pronoun before it ("se'n", "me'l").
/// When the letter is also written on the next word ("l l'Scratch") it is a stutter of
/// the decoder and is dropped. The merged word spans both timings, which keeps the
/// stabiliser's sample clock intact.
public enum CatalanElisionRepair {
    private static let elidingLetters: Set<String> = ["d", "l", "m", "n", "s", "t"]
    private static let vowelsAndH = Set("aàeèéiíïoòóuúüh")
    /// Pronouns a reduced "'n", "'m", "'l", "'s" or "'t" attaches to.
    private static let procliticHosts: Set<String> = ["se", "me", "te", "ne", "li"]

    /// The same repair on plain text, for results that carry no word timings.
    public static func repair(text: String) -> String {
        let words = text.split(separator: " ").map {
            RecognizedWord(text: String($0), startMilliseconds: 0, endMilliseconds: 0, confidence: nil)
        }
        return repair(words).map(\.text).joined(separator: " ")
    }

    public static func repair(_ words: [RecognizedWord]) -> [RecognizedWord] {
        guard words.count > 1 else { return words }
        var repaired: [RecognizedWord] = []
        repaired.reserveCapacity(words.count)
        var index = 0
        while index < words.count {
            let word = words[index]
            let letter = word.text.lowercased()
            guard index + 1 < words.count, elidingLetters.contains(letter) else {
                repaired.append(word)
                index += 1
                continue
            }
            let next = words[index + 1]
            let nextText = next.text.lowercased()
            if nextText.hasPrefix(letter + "'") {
                repaired.append(merged(word, next, text: next.text))
                index += 2
            } else if let first = nextText.first, vowelsAndH.contains(first) {
                repaired.append(merged(word, next, text: word.text + "'" + next.text))
                index += 2
            } else if let host = repaired.last, procliticHosts.contains(host.text.lowercased()) {
                repaired[repaired.count - 1] = merged(host, word, text: host.text + "'" + word.text)
                index += 1
            } else {
                repaired.append(word)
                index += 1
            }
        }
        return repaired
    }

    private static func merged(_ first: RecognizedWord, _ second: RecognizedWord, text: String) -> RecognizedWord {
        RecognizedWord(
            text: text,
            startMilliseconds: first.startMilliseconds,
            endMilliseconds: max(first.endMilliseconds, second.endMilliseconds),
            confidence: first.confidence.flatMap { a in second.confidence.map { min(a, $0) } }
        )
    }
}
