import Foundation

/// Spoken numbers → digits, for one language.
///
/// The input is the recogniser's word stream (any case, marks already split off). Each
/// replacement reports which words it covers, so a display can hide them and keep word
/// identity.
public protocol NumberNormalizing: Sendable {
    /// Replacements for `words`, in order and non-overlapping. A number never extends
    /// past a word listed in `boundaries` (for instance, one followed by a comma).
    func replacements(in words: [String], boundaries: Set<Int>) -> [NumberReplacement]
    /// True when `word`, after `previous`, may still be part of a number or change one
    /// already heard. A display waits for the two words after it before settling it:
    /// "quinze" becomes "15 %" once "per cent" arrives.
    func mayExtendNumber(_ word: String, after previous: String?) -> Bool
}

public struct NumberReplacement: Equatable, Sendable {
    /// Input words `range` become `text`.
    public let range: Range<Int>
    public let text: String

    public init(range: Range<Int>, text: String) {
        self.range = range
        self.text = text
    }
}

extension NumberNormalizing {
    /// Convenience for plain text: every replacement applied to space-separated words.
    public func normalize(_ text: String) -> String {
        let words = text.split(separator: " ").map(String.init)
        var output: [String] = []
        var index = 0
        for replacement in replacements(in: words, boundaries: []) {
            output.append(contentsOf: words[index..<replacement.range.lowerBound])
            output.append(replacement.text)
            index = replacement.range.upperBound
        }
        output.append(contentsOf: words[index...])
        return output.joined(separator: " ")
    }
}

/// Groups `value`'s digits in threes with `separator` from `minimum` on: 1992 stays
/// compact, 10.000 does not.
func groupedDigits(_ value: Int, separator: String, minimum: Int = 10_000) -> String {
    guard value >= minimum else { return String(value) }
    var groups: [String] = []
    var remaining = value
    while remaining >= 1_000 {
        groups.insert(String(format: "%03d", remaining % 1_000), at: 0)
        remaining /= 1_000
    }
    groups.insert(String(remaining), at: 0)
    return groups.joined(separator: separator)
}

/// What changes from one language to the next once words are recognised: where the
/// punctuation comes from, how numbers are written, and which words are only
/// capitalised at the start of a sentence.
public struct LanguageRules: Sendable {
    /// The manifest's language id ("ca", "es", …).
    public let id: String
    public let numbers: (any NumberNormalizing)?
    /// Common words the punctuation may not capitalise mid-sentence (after a comma).
    /// Proper nouns are never on it.
    public let ordinaryWords: Set<String>
    /// Elided articles and pronouns ("l'", "d'") whose word is ordinary too.
    public let elidedPrefixes: [String]
    /// Spanish opens a question or exclamation with ¿ or ¡.
    public let opensQuestionsAndExclamations: Bool

    public init(
        id: String,
        numbers: (any NumberNormalizing)?,
        ordinaryWords: Set<String>,
        elidedPrefixes: [String] = [],
        opensQuestionsAndExclamations: Bool = false
    ) {
        self.id = id
        self.numbers = numbers
        self.ordinaryWords = ordinaryWords
        self.elidedPrefixes = elidedPrefixes
        self.opensQuestionsAndExclamations = opensQuestionsAndExclamations
    }

    public func isOrdinaryWord(_ word: String) -> Bool {
        let lower = word.lowercased()
        return ordinaryWords.contains(lower) || elidedPrefixes.contains { lower.hasPrefix($0) }
    }

    /// The rules for a manifest language id; languages without their own rules get
    /// none of the language-specific steps.
    public static func forLanguage(_ id: String) -> LanguageRules {
        switch id {
        case "ca": return .catalan
        case "es": return .spanish
        case "gl": return .galician
        case "eu": return .basque
        case "en": return .english
        default: return LanguageRules(id: id, numbers: nil, ordinaryWords: [])
        }
    }

    public static let catalan = LanguageRules(
        id: "ca",
        numbers: CatalanNumbers(),
        ordinaryWords: CatalanOrdinaryWords.all.union([
            "a", "al", "als", "aleshores", "allò", "amb", "aquest", "aquesta", "aquestes", "aquests",
            "aquí", "ara", "així", "bé", "com", "crec", "de", "del", "dels", "des", "després", "doncs",
            "el", "ell", "ella", "elles", "ells", "els", "em", "en", "ens", "es", "és", "et", "fins",
            "hi", "ho", "home", "i", "jo", "la", "les", "li", "llavors", "mentre", "molt", "ni", "no",
            "nosaltres", "o", "on", "per", "però", "perquè", "potser", "que", "què", "quan", "si", "sí",
            "també", "tot", "tota", "totes", "tots", "tu", "un", "una", "unes", "uns", "us", "va",
            "vaig", "vam", "vosaltres",
        ]),
        elidedPrefixes: ["l'", "d'", "m'", "n'", "s'", "t'", "qu'"]
    )

    public static let spanish = LanguageRules(
        id: "es",
        numbers: SpanishNumbers(),
        ordinaryWords: [
            "a", "al", "ahora", "así", "aquí", "bien", "cada", "como", "con", "cuando", "de", "del",
            "desde", "después", "donde", "el", "ella", "ellas", "ellos", "en", "entonces", "era",
            "es", "esa", "ese", "eso", "esta", "este", "esto", "está", "fue", "ha", "hay", "la",
            "las", "le", "les", "lo", "los", "me", "mi", "muy", "más", "nada", "ni", "no", "nos",
            "nosotros", "o", "para", "pero", "por", "porque", "pues", "que", "qué", "se", "si", "sí",
            "sin", "su", "sus", "también", "te", "todo", "tu", "tú", "un", "una", "unas", "unos",
            "usted", "y", "ya", "yo",
        ],
        opensQuestionsAndExclamations: true
    )

    public static let galician = LanguageRules(
        id: "gl",
        numbers: GalicianNumbers(),
        ordinaryWords: [
            "a", "agora", "ao", "aos", "as", "así", "aquí", "ben", "cada", "cando", "como", "con",
            "da", "das", "de", "do", "dos", "e", "el", "ela", "elas", "eles", "en", "entón", "era",
            "esa", "ese", "iso", "esta", "este", "isto", "está", "foi", "ha", "hai", "lle", "lles",
            "mais", "me", "moi", "na", "nas", "nin", "no", "nos", "non", "nós", "o", "os", "ou",
            "para", "pero", "por", "porque", "pois", "que", "se", "si", "sen", "seu", "súa", "tamén",
            "te", "todo", "ti", "un", "unha", "unhas", "uns", "vostede", "xa", "eu",
        ]
    )

    public static let basque = LanguageRules(
        id: "eu",
        numbers: BasqueNumbers(),
        ordinaryWords: [
            "bai", "baina", "baino", "bat", "batzuk", "bere", "beraz", "da", "dira", "du", "dute",
            "edo", "egin", "ere", "eta", "ez", "gu", "guk", "hau", "hori", "hura", "hemen", "hori",
            "izan", "ni", "nik", "oso", "orain", "zer", "zu", "zuk", "hala", "gero", "baita", "ezta",
        ]
    )

    public static let english = LanguageRules(
        id: "en",
        numbers: EnglishNumbers(),
        ordinaryWords: [
            "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "had", "has",
            "have", "he", "her", "his", "it", "its", "of", "on", "or", "our", "she", "so", "that",
            "the", "their", "them", "then", "there", "they", "this", "to", "was", "we", "were",
            "what", "when", "which", "who", "will", "with", "would", "you", "your",
        ]
    )
}

/// `CatalanNumberNormalizer` behind the common interface.
public struct CatalanNumbers: NumberNormalizing {
    public init() {}

    public func replacements(in words: [String], boundaries: Set<Int>) -> [NumberReplacement] {
        CatalanNumberNormalizer.replacements(in: words, boundaries: boundaries).map {
            NumberReplacement(range: $0.range, text: $0.text)
        }
    }

    public func mayExtendNumber(_ word: String, after previous: String?) -> Bool {
        CatalanNumberNormalizer.isNumberWord(word)
            || (word.lowercased() == "per" && previous.map(CatalanNumberNormalizer.isNumberWord) == true)
    }
}
