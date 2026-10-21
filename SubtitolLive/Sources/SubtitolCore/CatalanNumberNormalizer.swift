import Foundation

/// Spoken Catalan numbers → digits, in 3Cat's ésAdir subtitling style.
///
/// Quantities one to nineteen stay in letters; from 20 on they become digits.
/// Percentages always take digits and the % sign, and calendar days and years always
/// take digits. The input is the recogniser's lowercase word stream. Each conversion
/// reports which words it replaces, so a display can hide them and keep word identity.
/// Ported from `.work/tools/itn_ca.py`; the unit tests pin both to the same cases.
public enum CatalanNumberNormalizer {
    public struct Replacement: Equatable, Sendable {
        /// Input words `range` become `text`.
        public let range: Range<Int>
        public let text: String
    }

    private static let units: [String: Int] = [
        "zero": 0, "u": 1, "un": 1, "una": 1, "dos": 2, "dues": 2, "tres": 3, "quatre": 4,
        "cinc": 5, "sis": 6, "set": 7, "vuit": 8, "nou": 9, "deu": 10, "onze": 11,
        "dotze": 12, "tretze": 13, "catorze": 14, "quinze": 15, "setze": 16,
        "disset": 17, "divuit": 18, "dinou": 19,
    ]
    private static let tens: [String: Int] = [
        "vint": 20, "trenta": 30, "quaranta": 40, "cinquanta": 50,
        "seixanta": 60, "setanta": 70, "vuitanta": 80, "noranta": 90,
    ]
    private static let hundreds: [String: Int] = {
        var table = ["cent": 100, "dos-cents": 200, "dues-centes": 200]
        for (word, value) in [("tres", 3), ("quatre", 4), ("cinc", 5), ("sis", 6), ("set", 7), ("vuit", 8), ("nou", 9)] {
            table["\(word)-cents"] = value * 100
            table["\(word)-centes"] = value * 100
        }
        return table
    }()
    private static let months: Set<String> = [
        "gener", "febrer", "març", "abril", "maig", "juny", "juliol", "agost",
        "setembre", "octubre", "novembre", "desembre",
    ]
    private static let idioms: [[String]] = [["mil", "gràcies"], ["cent", "per", "cent"]]
    private static let yearLeads: Set<String> = ["l'any", "any", "anys", "el", "del", "al", "de", "l'"]

    /// Replacements for `words`, in order and non-overlapping. A number never extends
    /// past a word listed in `boundaries` (for instance, one followed by a comma).
    public static func replacements(in words: [String], boundaries: Set<Int> = []) -> [Replacement] {
        let words = words.map { $0.lowercased() }
        var result: [Replacement] = []
        var index = 0
        while index < words.count {
            if let idiom = idioms.first(where: { matches($0, in: words, at: index) }) {
                index += idiom.count
                continue
            }
            if let (year, end) = spokenYear(words, index) {
                result.append(Replacement(range: index..<end, text: digits(year)))
                index = end
                continue
            }
            guard let (value, end) = parseNumber(words, index, boundaries: boundaries) else {
                index += 1
                continue
            }
            let following = end < words.count ? words[end] : ""
            let canReadPast = !boundaries.contains(end - 1)
            let isPercent = canReadPast && end + 1 < words.count
                && words[end] == "per" && words[end + 1] == "cent" && !boundaries.contains(end)
            let isDate = canReadPast && (
                months.contains(following)
                    || (following == "de" && end + 1 < words.count && months.contains(words[end + 1]))
                    || (following.hasPrefix("d'") && months.contains(String(following.dropFirst(2))))
            )
            let isYear = index > 0 && yearLeads.contains(words[index - 1]) && (1_000...2_999).contains(value)
            if isPercent {
                result.append(Replacement(range: index..<(end + 2), text: "\(digits(value)) %"))
                index = end + 2
            } else if (isDate && (1...31).contains(value)) || isYear || value >= 20 {
                result.append(Replacement(range: index..<end, text: digits(value)))
                index = end
            } else {
                index = end
            }
        }
        return result
    }

    /// Convenience for plain text, as the Python prototype takes it.
    public static func normalize(_ text: String) -> String {
        let words = text.split(separator: " ").map(String.init)
        var output: [String] = []
        var index = 0
        for replacement in replacements(in: words) {
            output.append(contentsOf: words[index..<replacement.range.lowerBound])
            output.append(replacement.text)
            index = replacement.range.upperBound
        }
        output.append(contentsOf: words[index...])
        return output.joined(separator: " ")
    }

    /// Words a number can be made of. A display must not settle one while the words its
    /// rules look at (up to two after it) are still undecided: "quinze" becomes "15 %"
    /// once "per cent" arrives, and "dinou" becomes "1992" once "noranta-dos" does.
    public static func isNumberWord(_ word: String) -> Bool {
        let word = word.lowercased()
        return belowHundred(word) != nil || hundreds[word] != nil || ["mil", "milió", "milions"].contains(word)
    }

    private static func matches(_ idiom: [String], in words: [String], at index: Int) -> Bool {
        index + idiom.count <= words.count && Array(words[index..<(index + idiom.count)]) == idiom
    }

    static func belowHundred(_ word: String) -> Int? {
        if let unit = units[word] { return unit }
        if let ten = tens[word] { return ten }
        let parts = word.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3, parts[0] == "vint", parts[1] == "i" {
            guard let unit = units[parts[2]], unit > 0, unit < 10 else { return nil }
            return 20 + unit
        }
        if parts.count == 2, let ten = tens[parts[0]], ten != 20,
           let unit = units[parts[1]], unit > 0, unit < 10 {
            return ten + unit
        }
        return nil
    }

    /// [hundreds] [below-hundred] starting at `index`, stopping at a boundary.
    private static func belowThousand(_ words: [String], _ index: Int, boundaries: Set<Int>) -> (Int, Int)? {
        var value = 0
        var next = index
        if next < words.count, let hundred = hundreds[words[next]] {
            value = hundred
            next += 1
        }
        let mayContinue = next == index || !boundaries.contains(next - 1)
        if mayContinue, next < words.count, let small = belowHundred(words[next]) {
            value += small
            next += 1
            // Tens and unit written apart, as some recognisers do: "trenta dos".
            if tens[words[next - 1]] != nil, !boundaries.contains(next - 1), next < words.count,
               let unit = units[words[next]], (1..<10).contains(unit) {
                value += unit
                next += 1
            }
        }
        return next > index ? (value, next) : nil
    }

    /// After "l'any": a year read in two halves, "dinou noranta-dos" → 1992. The pattern
    /// is unambiguous there, so a punctuation model's commas between the halves ("dinou,
    /// noranta, dos", as if it were a list) do not split it.
    private static func spokenYear(_ words: [String], _ index: Int) -> (Int, Int)? {
        guard index > 0, ["l'any", "any"].contains(words[index - 1]), index + 1 < words.count,
              let century = words[index] == "vint" ? 20 : units[words[index]], (10...20).contains(century),
              hundreds[words[index + 1]] == nil,
              let (rest, end) = belowThousand(words, index + 1, boundaries: []),
              (10...99).contains(rest) else { return nil }
        return (century * 100 + rest, end)
    }

    /// The longest cardinal starting at `index`, up to the millions.
    private static func parseNumber(_ words: [String], _ index: Int, boundaries: Set<Int>) -> (Int, Int)? {
        var total = 0
        var next = index
        var parsed = false
        func open(_ position: Int) -> Bool { position == index || !boundaries.contains(position - 1) }
        for (scaleWords, scale) in [(["milió", "milions"], 1_000_000), (["mil"], 1_000)] {
            guard open(next) else { break }
            if let head = belowThousand(words, next, boundaries: boundaries),
               head.1 < words.count, open(head.1), scaleWords.contains(words[head.1]) {
                total += head.0 * scale
                next = head.1 + 1
                parsed = true
            } else if next < words.count, scale == 1_000, scaleWords.contains(words[next]) {
                total += 1_000
                next += 1
                parsed = true
            }
        }
        if open(next), let tail = belowThousand(words, next, boundaries: boundaries) {
            total += tail.0
            next = tail.1
            parsed = true
        }
        return parsed ? (total, next) : nil
    }

    /// Catalan grouping: 1992 stays compact; 10.000 and above use a point.
    static func digits(_ value: Int) -> String {
        guard value >= 10_000 else { return String(value) }
        var groups: [String] = []
        var remaining = value
        while remaining >= 1_000 {
            groups.insert(String(format: "%03d", remaining % 1_000), at: 0)
            remaining /= 1_000
        }
        groups.insert(String(remaining), at: 0)
        return groups.joined(separator: ".")
    }
}
