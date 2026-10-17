import Foundation

/// Spoken Spanish numbers → digits, for readers in Spain.
///
/// The recogniser (NVIDIA's Spanish FastConformer) writes numbers as words: "el
/// veintitrés de abril de dos mil veintiséis", "quince por ciento", "treinta y dos".
/// Style, with sources:
/// - Letters for zero to nine, digits from 10: Libro de estilo de El País ("se escriben
///   con todas sus letras solo las cifras del cero al nueve"), the press convention the
///   Spanish subtitling norm UNE 153010:2012 is applied with.
///   https://rapagura-tallergrafica.blogspot.com/2011/03/manual-de-estilo-el-pais-titulo-10.html
///   https://www.une.org/encuentra-tu-norma/busca-tu-norma/norma?c=N0049426
/// - Grouping: a space in groups of three from five digits on (10 000, never 10.000),
///   four digits stay compact (1992, 3200) and years are never grouped (RAE, Ortografía
///   2010 §8.2.2; DPD "números"). The space is a no-break space so "10 000" never splits.
///   https://www.rae.es/dpd/n%C3%BAmeros
/// - Round millions keep the word, as the press writes them: "20 millones", "3000
///   millones" (DPD "millón"); anything else is written out: "1 200 000".
///   https://www.rae.es/dpd/mill%C3%B3n
/// - Percent: always digits, the sign after a (no-break) space: "15 %", "2,5 %".
///   "por ciento" and "por cien" both count (DPD "ciento").
///   https://www.rae.es/dpd/ciento
/// - Decimals take the comma used in Spain: "dos coma cinco" → "2,5" (DPD "números").
/// - Calendar days always in digits: "el cinco de mayo" → "el 5 de mayo", "el día
///   cinco" → "el día 5"; Spain says days as cardinals, so no ordinals (DPD "fecha").
///   https://www.rae.es/dpd/fecha
/// - Years are ordinary numbers above nine ("en mil novecientos noventa y dos" → 1992).
///   Spanish does not read years in halves.
/// - Clock times stay in words, hour and minutes together, since digits and words must
///   not mix: "las ocho y veinte", "las once de la noche" (DPD "hora").
///   https://www.rae.es/dpd/hora
/// - Centuries take Roman numerals: "el siglo veintiuno" → "el siglo XXI" (DPD
///   "números romanos").
/// - Decades stay in words: "los años noventa" (DPD "años").
/// - Idioms stay in words: "mil gracias", "mil veces", "las mil y una", "cien por cien",
///   "cien veces". "un", "una vez", "uno de ellos" are below ten and never convert.
public struct SpanishNumbers: NumberNormalizing {
    public init() {}

    private static let space = "\u{00A0}"

    private static let units: [String: Int] = [
        "cero": 0, "un": 1, "uno": 1, "una": 1, "dos": 2, "tres": 3, "cuatro": 4,
        "cinco": 5, "seis": 6, "siete": 7, "ocho": 8, "nueve": 9, "diez": 10,
        "once": 11, "doce": 12, "trece": 13, "catorce": 14, "quince": 15,
        "dieciséis": 16, "dieciseis": 16, "diecisiete": 17, "dieciocho": 18, "diecinueve": 19,
        "veinte": 20, "veintiún": 21, "veintiun": 21, "veintiuno": 21, "veintiuna": 21,
        "veintidós": 22, "veintidos": 22, "veintitrés": 23, "veintitres": 23,
        "veinticuatro": 24, "veinticinco": 25, "veintiséis": 26, "veintiseis": 26,
        "veintisiete": 27, "veintiocho": 28, "veintinueve": 29,
    ]
    private static let tens: [String: Int] = [
        "treinta": 30, "cuarenta": 40, "cincuenta": 50, "sesenta": 60,
        "setenta": 70, "ochenta": 80, "noventa": 90,
    ]
    private static let hundreds: [String: Int] = [
        "doscientos": 200, "doscientas": 200, "trescientos": 300, "trescientas": 300,
        "cuatrocientos": 400, "cuatrocientas": 400, "quinientos": 500, "quinientas": 500,
        "seiscientos": 600, "seiscientas": 600, "setecientos": 700, "setecientas": 700,
        "ochocientos": 800, "ochocientas": 800, "novecientos": 900, "novecientas": 900,
    ]
    private static let millions: Set<String> = ["millón", "millon", "millones"]
    private static let billions: Set<String> = ["billón", "billon", "billones"]
    private static let months: Set<String> = [
        "enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto",
        "septiembre", "setiembre", "octubre", "noviembre", "diciembre",
    ]
    private static let idioms: [[String]] = [
        ["mil", "gracias"], ["mil", "veces"], ["mil", "perdones"], ["mil", "disculpas"],
        ["mil", "cosas"], ["mil", "maneras"], ["mil", "y", "una"], ["mil", "y", "un"],
        ["cien", "por", "cien"], ["cien", "veces"],
    ]
    private static let percentWords: Set<String> = ["ciento", "cien"]
    private static let dayLeads: Set<String> = ["el", "del", "al", "este", "ese", "aquel"]

    public func replacements(in words: [String], boundaries: Set<Int>) -> [NumberReplacement] {
        let words = words.map { $0.lowercased() }
        func open(_ position: Int) -> Bool { position < words.count && !boundaries.contains(position - 1) }
        func isPercent(at position: Int) -> Bool {
            open(position) && open(position + 1) && words[position] == "por"
                && Self.percentWords.contains(words[position + 1])
        }
        var result: [NumberReplacement] = []
        var index = 0
        while index < words.count {
            if let idiom = Self.idioms.first(where: { Self.matches($0, in: words, at: index) }) {
                index += idiom.count
                continue
            }
            // Already digits: never converted again, only joined to "por ciento".
            if Self.isDigits(words[index]) {
                if isPercent(at: index + 1) {
                    result.append(NumberReplacement(range: index..<(index + 3), text: words[index] + Self.space + "%"))
                    index += 3
                } else {
                    index += 1
                }
                continue
            }
            guard let (value, end) = Self.parseNumber(words, index, boundaries: boundaries) else {
                index += 1
                continue
            }
            if let timeEnd = Self.clockTimeEnd(words, index, value: value, end: end, boundaries: boundaries) {
                index = timeEnd
                continue
            }
            var last = end
            var decimal: String?
            if value < 1_000, open(end), words[end] == "coma",
               let (fraction, fractionEnd) = Self.parseFraction(words, end + 1, boundaries: boundaries) {
                decimal = "\(value),\(fraction)"
                last = fractionEnd
                if open(last), Self.millions.contains(words[last]) || Self.billions.contains(words[last]) {
                    decimal! += Self.space + (Self.millions.contains(words[last]) ? "millones" : "billones")
                    last += 1
                }
            }
            if isPercent(at: last) {
                let number = decimal ?? Self.digits(value)
                result.append(NumberReplacement(range: index..<(last + 2), text: number + Self.space + "%"))
                index = last + 2
                continue
            }
            if let decimal {
                result.append(NumberReplacement(range: index..<last, text: decimal))
                index = last
                continue
            }
            // "siglo quince", and the second of "los siglos quince y dieciséis".
            let isCentury = index > 0 && (
                ["siglo", "siglos"].contains(words[index - 1])
                    || (["y", "e", "o", "u", "al", "a"].contains(words[index - 1]) && result.last.map {
                        $0.range.upperBound == index - 1 && $0.text.allSatisfy { "IVX".contains($0) }
                    } == true)
            )
            if isCentury, (1...30).contains(value) {
                result.append(NumberReplacement(range: index..<end, text: Self.roman(value)))
                index = end
                continue
            }
            let isDate = (1...31).contains(value) && words[index] != "una" && (
                (open(end) && open(end + 1) && words[end] == "de" && Self.months.contains(words[end + 1]))
                    || (index >= 2 && words[index - 1] == "día" && Self.dayLeads.contains(words[index - 2]))
            )
            let isDecade = end == index + 1 && index > 0 && words[index - 1] == "años"
                && (value == 20 || Self.tens.values.contains(value))
            if !isDecade, isDate || value >= 10, let text = Self.written(value) {
                result.append(NumberReplacement(range: index..<end, text: text))
            }
            index = end
        }
        return result
    }

    public func mayExtendNumber(_ word: String, after previous: String?) -> Bool {
        let word = word.lowercased()
        let previous = previous?.lowercased()
        let afterNumber = previous.map { Self.isNumberWord($0) || Self.isDigits($0) } ?? false
        switch word {
        // "un"/"una" are everywhere and only grow into a number in rare cases ("un
        // millón doscientos mil"), which then stays in words.
        case "un", "una": return false
        // "treinta y dos", and "mil y una" (an idiom that must not become "1000 y una").
        case "y": return previous.map { Self.tens[$0] != nil || $0 == "mil" } ?? false
        case "por", "coma": return afterNumber
        default: return Self.isNumberWord(word) || Self.isDigits(word)
        }
    }

    // MARK: - Parsing

    static func isNumberWord(_ word: String) -> Bool {
        let word = word.lowercased()
        return units[word] != nil || tens[word] != nil || hundreds[word] != nil
            || ["cien", "ciento", "mil"].contains(word) || millions.contains(word) || billions.contains(word)
    }

    private static func isDigits(_ word: String) -> Bool {
        guard let first = word.first, first.isASCII, first.isNumber else { return false }
        return word.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "." || $0 == "," }
    }

    private static func matches(_ idiom: [String], in words: [String], at index: Int) -> Bool {
        index + idiom.count <= words.count && Array(words[index..<(index + idiom.count)]) == idiom
    }

    /// One word below 30, a ten, or a ten joined to a unit by "y": "treinta y dos".
    private static func belowHundred(_ words: [String], _ index: Int, boundaries: Set<Int>) -> (Int, Int)? {
        guard index < words.count else { return nil }
        if let unit = units[words[index]] { return (unit, index + 1) }
        guard let ten = tens[words[index]] else { return nil }
        if index + 2 < words.count, words[index + 1] == "y",
           !boundaries.contains(index), !boundaries.contains(index + 1),
           let unit = units[words[index + 2]], (1...9).contains(unit) {
            return (ten + unit, index + 3)
        }
        return (ten, index + 1)
    }

    /// [hundreds] [below-hundred]: "cien", "ciento tres", "doscientas una", "cuarenta".
    private static func belowThousand(_ words: [String], _ index: Int, boundaries: Set<Int>) -> (Int, Int)? {
        guard index < words.count else { return nil }
        let word = words[index]
        let tail = boundaries.contains(index) ? nil : belowHundred(words, index + 1, boundaries: boundaries)
        if word == "cien" { return (100, index + 1) }
        if word == "ciento" {
            // Alone, "ciento" is the unit of "por ciento", not a number.
            guard let tail, tail.0 > 0 else { return nil }
            return (100 + tail.0, tail.1)
        }
        if let hundred = hundreds[word] {
            if let tail, tail.0 > 0 { return (hundred + tail.0, tail.1) }
            return (hundred, index + 1)
        }
        return belowHundred(words, index, boundaries: boundaries)
    }

    /// The longest cardinal starting at `index`: "tres mil doscientas", "un millón",
    /// "mil millones". Never crosses a boundary.
    private static func parseNumber(_ words: [String], _ index: Int, boundaries: Set<Int>) -> (Int, Int)? {
        var total = 0
        var group = 0
        var small: Int?
        var thousandsUsed = false
        var lastScale = Int.max
        var next = index
        while next < words.count, next == index || !boundaries.contains(next - 1) {
            let word = words[next]
            if small == nil, let (value, end) = belowThousand(words, next, boundaries: boundaries) {
                small = value
                next = end
            } else if word == "mil", !thousandsUsed, small != 0 {
                group += (small ?? 1) * 1_000
                small = nil
                thousandsUsed = true
                next += 1
            } else if let scale = millions.contains(word) ? 1_000_000 : billions.contains(word) ? 1_000_000_000_000 : nil,
                      scale < lastScale, small != nil || group > 0 {
                total += (group + (small ?? 0)) * scale
                group = 0
                small = nil
                thousandsUsed = false
                lastScale = scale
                next += 1
            } else {
                break
            }
        }
        return next > index ? (total + group + (small ?? 0), next) : nil
    }

    /// The digits after "coma": "cinco" → "5", "cero cinco" → "05", "veinticinco" → "25".
    private static func parseFraction(_ words: [String], _ index: Int, boundaries: Set<Int>) -> (String, Int)? {
        var digits = ""
        var next = index
        while next < words.count, words[next] == "cero", next == index || !boundaries.contains(next - 1) {
            digits += "0"
            next += 1
        }
        if next < words.count, next == index || !boundaries.contains(next - 1),
           let (value, end) = belowHundred(words, next, boundaries: boundaries), value > 0 {
            digits += String(value)
            next = end
        }
        return digits.isEmpty ? nil : (digits, next)
    }

    /// After "la"/"las", an hour followed by its minutes or "en punto" / "de la (tarde)":
    /// the end of the whole time, which stays in words.
    private static func clockTimeEnd(_ words: [String], _ index: Int, value: Int, end: Int, boundaries: Set<Int>) -> Int? {
        guard index > 0, ["la", "las"].contains(words[index - 1]), (1...12).contains(value),
              end + 1 < words.count, !boundaries.contains(end - 1), !boundaries.contains(end) else { return nil }
        let next = words[end]
        if next == "y" || next == "menos" {
            if ["cuarto", "media"].contains(words[end + 1]) { return end + 2 }
            if let (minutes, minutesEnd) = belowHundred(words, end + 1, boundaries: boundaries),
               (1...59).contains(minutes) { return minutesEnd }
            return nil
        }
        if (next == "en" && words[end + 1] == "punto") || (next == "de" && words[end + 1] == "la") {
            return end
        }
        return nil
    }

    // MARK: - Writing

    /// Digits for a number of ten or more; nil where it stays in words ("tres millones").
    private static func written(_ value: Int) -> String? {
        for (scale, word) in [(1_000_000_000_000, "billones"), (1_000_000, "millones")]
        where value >= scale && value % scale == 0 {
            let count = value / scale
            return count < 10 ? nil : digits(count) + space + word
        }
        return digits(value)
    }

    /// Centuries: 21 → "XXI".
    private static func roman(_ value: Int) -> String {
        var remaining = value
        var text = ""
        for (amount, letters) in [(10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")] {
            while remaining >= amount {
                text += letters
                remaining -= amount
            }
        }
        return text
    }

    /// 1992 and 3200 stay compact; 10 000 takes a no-break space.
    private static func digits(_ value: Int) -> String {
        groupedDigits(value, separator: space)
    }
}
