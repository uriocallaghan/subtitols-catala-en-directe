import Foundation

/// Spoken Galician numbers → digits.
///
/// Style (subtitles, so the Spanish subtitling norm first, then the Xunta's style guide
/// and the RAG for everything the norm leaves open):
/// - Zero to ten stay in letters; from 11 on, digits. UNE 153010 (subtitling for deaf
///   and hard-of-hearing viewers, which Spanish broadcasters including CRTVG follow)
///   writes 0–10 in letters and the rest in figures:
///   https://www.une.org/encuentra-tu-norma/busca-tu-norma/norma?c=N0049426
/// - Groups of three separated by a space from five digits on ("10 000"), four digits
///   compact ("2026", "1500"); years are never grouped. Manual de estilo do DOG, "Escrita
///   dos números": https://wikidog.xunta.gal/index.php/Escrita_dos_n%c3%bameros
/// - Percentages always in digits with a space before the sign ("15 %", "3,5 %"), same
///   source. The decimal mark is a comma.
/// - Calendar days (1–31 before "de" + month) and years always in digits: "o 2 de maio de
///   2026" (same source: "22 de xuño de 2012"). Galician dates use cardinals; the ordinal
///   "primeiro de maio" is left in words (ordinals are always written in letters, same
///   source). Years are read whole ("mil novecentos noventa e dous"), never in halves.
/// - Round millions keep the word ("20 millóns", DOG: "50 millóns de habitantes"); a
///   head of ten or less stays in letters ("tres millóns").
/// - Idioms stay in words: "mil grazas", "mil veces", "mil bicos", "mil perdóns", "(as)
///   mil e unha (noites)", "cen por cento" / "cen por cen" (as Catalan keeps "cent per
///   cent").
///
/// Words (RAG, Normas ortográficas e morfolóxicas, numerais:
/// https://academia.gal/normas-ortograficas-e-morfoloxicas): un/unha, dous/dúas,
/// dezaseis…dezanove, vinte e un/unha, corenta, cen (alone) / cento (before tens or
/// units: "cento vinte"), douscentos/duascentas … novecentos/novecentas, cincocentos or
/// quiñentos, mil, millón/millóns. The "e" joins tens and units; "cento e vinte" and "mil
/// e cen" are tolerated too. "doce" is also the adjective "sweet" ("auga doce"), so on
/// its own it becomes 12 only when a plural noun follows or a plural determiner or
/// another number is next to it.
public struct GalicianNumbers: NumberNormalizing {
    public init() {}

    private static let units: [String: Int] = [
        "cero": 0, "un": 1, "unha": 1, "dous": 2, "dúas": 2, "duas": 2, "tres": 3, "catro": 4,
        "cinco": 5, "seis": 6, "sete": 7, "oito": 8, "nove": 9, "dez": 10, "once": 11,
        "doce": 12, "trece": 13, "catorce": 14, "quince": 15, "dezaseis": 16, "dezasete": 17,
        "dezaoito": 18, "dezanove": 19,
    ]
    private static let tens: [String: Int] = [
        "vinte": 20, "trinta": 30, "corenta": 40, "coarenta": 40, "cincuenta": 50,
        "sesenta": 60, "setenta": 70, "oitenta": 80, "noventa": 90,
    ]
    /// Hundreds from 200, both genders, and "centos" for a recogniser that splits them.
    private static let hundreds: [String: Int] = {
        var table = ["quiñentos": 500, "quiñentas": 500]
        for (stem, value) in [
            ("dous", 2), ("duas", 2), ("tres", 3), ("catro", 4), ("cinco", 5), ("seis", 6),
            ("sete", 7), ("oito", 8), ("nove", 9),
        ] {
            table["\(stem)centos"] = value * 100
            table["\(stem)centas"] = value * 100
        }
        return table
    }()
    private static let millionWords: Set<String> = ["millón", "millóns"]
    private static let months: Set<String> = [
        "xaneiro", "febreiro", "marzo", "abril", "maio", "xuño", "xullo", "agosto",
        "setembro", "septembro", "outubro", "novembro", "decembro",
    ]
    private static let idioms: [[String]] = [
        ["mil", "grazas"], ["mil", "veces"], ["mil", "bicos"], ["mil", "perdóns"],
        ["mil", "e", "unha"], ["mil", "e", "un"], ["cen", "por", "cento"], ["cen", "por", "cen"],
    ]
    /// Before "doce" these make it the number: "as doce", "dos doce".
    private static let pluralDeterminers: Set<String> = [
        "os", "as", "dos", "das", "nos", "nas", "aos", "ás", "polos", "polas", "cos", "coas",
        "uns", "unhas", "estes", "estas", "eses", "esas", "aqueles", "aquelas", "outros",
        "outras", "seus", "súas", "meus", "miñas", "teus", "túas", "nosos", "nosas",
    ]
    /// Words ending in -s after "doce" that are not a counted plural noun: "auga doce dos ríos".
    private static let pluralLookingFunctionWords: Set<String> = [
        "os", "as", "dos", "das", "nos", "nas", "aos", "ás", "polos", "polas", "cos", "coas",
        "mais", "máis", "pois", "despois", "tras", "menos", "vos", "lles", "ademais", "entrementres",
        "ves", "vas", "estás", "tes", "fas", "dis", "podes", "queres", "sabes",
    ]

    public func replacements(in words: [String], boundaries: Set<Int>) -> [NumberReplacement] {
        let words = words.map { $0.lowercased() }
        var result: [NumberReplacement] = []
        var index = 0
        func free(_ position: Int) -> Bool { !boundaries.contains(position) }
        func word(_ position: Int) -> String { position < words.count ? words[position] : "" }
        func isPercent(at position: Int) -> Bool {
            free(position - 1) && free(position) && word(position) == "por"
                && ["cento", "cen"].contains(word(position + 1))
        }

        while index < words.count {
            if let idiom = Self.idioms.first(where: { matches($0, in: words, at: index) }) {
                index += idiom.count
                continue
            }
            if Self.isDigits(words[index]) {
                if isPercent(at: index + 1) {
                    result.append(NumberReplacement(range: index..<(index + 3), text: "\(words[index]) %"))
                    index += 3
                } else {
                    index += 1
                }
                continue
            }
            guard let number = parseNumber(words, index, boundaries: boundaries) else {
                index += 1
                continue
            }
            let end = number.end
            let decimal = free(end - 1) && word(end) == "coma" && free(end)
                ? decimals(words, end + 1, boundaries: boundaries) : nil
            let text = Self.digits(number.value)

            if let decimal, isPercent(at: decimal.end) {
                result.append(NumberReplacement(range: index..<(decimal.end + 2), text: "\(text),\(decimal.digits) %"))
                index = decimal.end + 2
            } else if let decimal, number.value < 1_000, free(decimal.end - 1),
                      Self.millionWords.contains(word(decimal.end)) {
                result.append(NumberReplacement(
                    range: index..<(decimal.end + 1), text: "\(text),\(decimal.digits) \(word(decimal.end))"
                ))
                index = decimal.end + 1
            } else if let decimal, number.roundMillions == nil, number.value < 1_000_000 {
                result.append(NumberReplacement(range: index..<decimal.end, text: "\(text),\(decimal.digits)"))
                index = decimal.end
            } else if isPercent(at: end) {
                result.append(NumberReplacement(range: index..<(end + 2), text: "\(text) %"))
                index = end + 2
            } else if (1...31).contains(number.value), free(end - 1), word(end) == "de", free(end),
                      Self.months.contains(word(end + 1)) {
                result.append(NumberReplacement(range: index..<end, text: text))
                index = end
            } else if let head = number.roundMillions {
                if head > 10 {
                    result.append(NumberReplacement(range: index..<end, text: "\(Self.digits(head)) \(words[end - 1])"))
                }
                index = end
            } else if number.value > 10, end - index > 1 || words[index] != "doce" || isTwelve(words, index, boundaries) {
                result.append(NumberReplacement(range: index..<end, text: text))
                index = end
            } else {
                index = end
            }
        }
        return result
    }

    public func mayExtendNumber(_ word: String, after previous: String?) -> Bool {
        let word = word.lowercased()
        let previous = previous?.lowercased()
        if word == "un" || word == "unha" {
            // Only where it can open a date or a percentage, or end a compound: "o un de
            // maio", "un un por cento", "vinte e un". The article alone never waits.
            return previous.map { ["e", "o", "do", "no", "ao", "polo", "un"].contains($0) } ?? false
        }
        if Self.isNumberWord(word) || Self.isDigits(word) { return true }
        guard let previous, ["e", "por", "coma"].contains(word) else { return false }
        return Self.isNumberWord(previous) || previous == "un" || previous == "unha"
            || (word == "por" && Self.isDigits(previous))
    }

    // MARK: - Parsing

    private struct Parsed {
        let value: Int
        let end: Int
        /// The millions when the number is exactly "<head> millón/millóns".
        let roundMillions: Int?
    }

    static func isNumberWord(_ word: String) -> Bool {
        (units[word] != nil && word != "un" && word != "unha") || tens[word] != nil
            || hundreds[word] != nil || millionWords.contains(word)
            || ["cen", "cento", "centos", "centas", "mil"].contains(word)
    }

    private static func isDigits(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private func matches(_ idiom: [String], in words: [String], at index: Int) -> Bool {
        index + idiom.count <= words.count && Array(words[index..<(index + idiom.count)]) == idiom
    }

    /// Unit, teen or tens (+ "e" + unit): "sete", "dezaseis", "vinte e unha".
    private func belowHundred(_ words: [String], _ index: Int, boundaries: Set<Int>) -> (Int, Int)? {
        guard index < words.count else { return nil }
        if let unit = Self.units[words[index]] { return (unit, index + 1) }
        guard let ten = Self.tens[words[index]] else { return nil }
        func unit(at position: Int) -> Int? {
            guard position < words.count, !boundaries.contains(position - 1),
                  let unit = Self.units[words[position]], (1...9).contains(unit) else { return nil }
            return unit
        }
        if index + 1 < words.count, !boundaries.contains(index), words[index + 1] == "e", let unit = unit(at: index + 2) {
            return (ten + unit, index + 3)
        }
        // "vinte tres", as a recogniser may write it when the "e" is swallowed.
        if let unit = unit(at: index + 1) { return (ten + unit, index + 2) }
        return (ten, index + 1)
    }

    /// [hundreds] [e] [below hundred]: "cento vinte", "duascentas dúas", "cen".
    private func belowThousand(_ words: [String], _ index: Int, boundaries: Set<Int>) -> (Int, Int)? {
        guard index < words.count else { return nil }
        var hundred: Int?
        var next = index
        let first = words[index]
        if let value = Self.hundreds[first] {
            hundred = value
            next = index + 1
        } else if first == "cen" || first == "cento" {
            hundred = 100
            next = index + 1
        } else if let unit = Self.units[first], (2...9).contains(unit), index + 1 < words.count,
                  !boundaries.contains(index), ["centos", "centas"].contains(words[index + 1]) {
            hundred = unit * 100
            next = index + 2
        }
        guard let hundred else { return belowHundred(words, index, boundaries: boundaries) }
        guard !boundaries.contains(next - 1) else { return first == "cento" ? nil : (hundred, next) }
        if let tail = belowHundred(words, next, boundaries: boundaries) {
            return (hundred + tail.0, tail.1)
        }
        if next < words.count, words[next] == "e", !boundaries.contains(next),
           let tail = belowHundred(words, next + 1, boundaries: boundaries) {
            return (hundred + tail.0, tail.1)
        }
        // "cento" on its own is the noun ("un cento de ovos"), not 100.
        return first == "cento" ? nil : (hundred, next)
    }

    /// Up to 999 999: "dous mil vinte e seis", "mil e cen", "cen mil".
    private func belowMillion(_ words: [String], _ index: Int, boundaries: Set<Int>) -> (Int, Int)? {
        var value = 0
        var next = index
        if let head = belowThousand(words, index, boundaries: boundaries) {
            guard head.1 < words.count, !boundaries.contains(head.1 - 1), words[head.1] == "mil", head.0 > 0 else {
                return head
            }
            value = head.0 * 1_000
            next = head.1 + 1
        } else if index < words.count, words[index] == "mil" {
            value = 1_000
            next = index + 1
        } else {
            return nil
        }
        guard !boundaries.contains(next - 1) else { return (value, next) }
        func isScale(_ position: Int) -> Bool {
            position < words.count && (words[position] == "mil" || Self.millionWords.contains(words[position]))
        }
        if let tail = belowThousand(words, next, boundaries: boundaries), !isScale(tail.1) {
            return (value + tail.0, tail.1)
        }
        // "mil e cen", but not "entre mil e dous mil".
        if next < words.count, words[next] == "e", !boundaries.contains(next),
           let tail = belowThousand(words, next + 1, boundaries: boundaries), !isScale(tail.1) {
            return (value + tail.0, tail.1)
        }
        return (value, next)
    }

    private func parseNumber(_ words: [String], _ index: Int, boundaries: Set<Int>) -> Parsed? {
        guard let head = belowMillion(words, index, boundaries: boundaries) else { return nil }
        let millionAt = head.1
        guard millionAt < words.count, !boundaries.contains(millionAt - 1),
              Self.millionWords.contains(words[millionAt]), head.0 > 0 else {
            return Parsed(value: head.0, end: head.1, roundMillions: nil)
        }
        let millions = head.0 * 1_000_000
        if !boundaries.contains(millionAt), let tail = belowMillion(words, millionAt + 1, boundaries: boundaries) {
            return Parsed(value: millions + tail.0, end: tail.1, roundMillions: nil)
        }
        return Parsed(value: millions, end: millionAt + 1, roundMillions: head.0)
    }

    /// After "coma": "cinco" → "5", "cero cinco" → "05", "vinte e cinco" → "25".
    private func decimals(_ words: [String], _ index: Int, boundaries: Set<Int>) -> (digits: String, end: Int)? {
        guard index < words.count else { return nil }
        if words[index] == "cero" {
            var digits = ""
            var next = index
            while next < words.count, let unit = Self.units[words[next]], unit < 10,
                  next == index || !boundaries.contains(next - 1) {
                digits += String(unit)
                next += 1
            }
            return (digits, next)
        }
        guard let part = belowThousand(words, index, boundaries: boundaries) else { return nil }
        return (String(part.0), part.1)
    }

    /// "doce" alone is 12 in "doce anos", "as doce", "once, doce, trece"; not in "auga doce".
    private func isTwelve(_ words: [String], _ index: Int, _ boundaries: Set<Int>) -> Bool {
        let before = index > 0 ? words[index - 1] : ""
        let after = index + 1 < words.count ? words[index + 1] : ""
        // Next to another number, even across a comma: a list "once, doce, trece".
        if Self.isNumberWord(before) || Self.isNumberWord(after) || Self.isDigits(before) { return true }
        if index > 0, !boundaries.contains(index - 1), Self.pluralDeterminers.contains(before) { return true }
        guard !boundaries.contains(index), after.count > 2 else { return false }
        return after.hasSuffix("s") && !Self.pluralLookingFunctionWords.contains(after)
    }

    /// Galician grouping: a space in threes from five digits on; 2026 stays compact.
    static func digits(_ value: Int) -> String {
        groupedDigits(value, separator: " ")
    }
}
