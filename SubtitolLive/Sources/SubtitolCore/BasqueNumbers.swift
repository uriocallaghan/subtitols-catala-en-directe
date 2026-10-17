import Foundation

/// Spoken Basque numbers → digits, following Euskaltzaindia's rule 203 on numerical
/// expressions (EBO VI, 2024): https://www.euskaltzaindia.eus/dok/arauak/Araua_0203.pdf
///
/// - Letters or digits (§13.1–13.2): numbers written as one word stay in letters (bat …
///   hemeretzi, hogei, berrogei, hirurogei, laurogei, ehun, berrehun … bederatziehun,
///   mila); numbers above twenty that take more than one word are digits ("hogeita bost"
///   → 25, "bi mila" → 2000). Round millions below ten stay in letters ("bi milioi");
///   from ten on the count is digits and the word stays ("hamabost milioi" → "15 milioi").
/// - Grouping (§3.2.1.1): digits in threes with a space from five digits on ("10 000");
///   four digits and years are never grouped ("1992", "2026an"). The space is a
///   no-break space, as the rule asks, so a number never splits across lines.
/// - Case suffixes (§12): attached straight to the digits, no hyphen or apostrophe
///   ("1ean", "5ean", "10ean", "2026an", "100etik"). The suffix is the spoken one after
///   the number's stem: "-a" of hamaika and mila merges ("hamaikan" → "11n", "milan" →
///   "2000n"), the doubled r of hamar and the plural r of hiru and lau are not written
///   ("hamarrean" → "10ean", "hiruretan" → "3etan").
/// - Percent (§7.1, §13.2): the sign first, a space, then digits, always digits:
///   "ehuneko hamabost" → "% 15", "ehuneko zazpik" → "% 7k", "hiru koma bi" → "3,2".
/// - Dates (§13.2, §15.1): the day of the month is digits after the month's genitive:
///   "apirilaren hogeita hiruan" → "apirilaren 23an", "urriaren hamaikan" → "urriaren 11n".
///   Years are ordinary multi-word numbers, so always digits ("2026ko", "1992an").
/// - Decades (§17): "hirurogeiko hamarkada" → "60ko hamarkada".
/// - Ordinals (§5): a multi-word ordinal becomes digits and a point instead of -garren
///   ("hogeita bosgarren urteurrena" → "25. urteurrena"); one-word ordinals stay letters.
///   Centuries always take Roman numerals (§18): "hemeretzigarren mendean" → "XIX. mendean".
/// - Kept in words: idioms and loose quantities are single words anyway ("mila esker",
///   "hamaika aldiz", "milaka", "ehunka"); "bat" after a number means "about" and is
///   never joined to it ("mila bat lagun", "hogeita hamar bat"), and "-en bat" is
///   "about" too ("hogeita hamarren bat"); the time of day stays
///   in letters as speech gives it (§14.1): "hamarrak eta hogeita bost".
public struct BasqueNumbers: NumberNormalizing {
    public init() {}

    public func replacements(in words: [String], boundaries: Set<Int>) -> [NumberReplacement] {
        BasqueNumberParser(words: words, boundaries: boundaries).replacements()
    }

    public func mayExtendNumber(_ word: String, after previous: String?) -> Bool {
        let word = word.lowercased()
        let previous = previous?.lowercased()
        let previousIsNumber = previous.map { Self.isBareNumberWord($0) || Self.isDigits($0) } ?? false
        switch word {
        case "ehuneko": return true
        case "koma": return previousIsNumber
        case "eta":
            // "ehun eta" / "mila eta" may still become 120 or 1005.
            guard let previous, let pieces = BasqueNumberParser.analyse(previous), let last = pieces.last else { return false }
            return last.suffix == nil && !last.ordinal && [.hundred, .thousand, .million].contains(last.kind)
        case "bat":
            // The article "gizon bat" must not hold the line; only after a number word
            // ("hogeita bat" → "hogeita bat mila") can it still grow.
            return previousIsNumber || previous == "ehuneko" || previous == "koma"
        default:
            guard let pieces = BasqueNumberParser.analyse(word), let last = pieces.last else { return false }
            // "hogeigarren" becomes "XX." once "mendean" follows.
            if last.ordinal { return last.suffix == "" }
            if let suffix = last.suffix {
                // "hirurogeiko" becomes "60ko" once "hamarkada" follows.
                return pieces.count == 1 && (last.kind == .tens || last.value == 10) && (suffix == "ko" || suffix == "eko")
            }
            return true
        }
    }

    static func isBareNumberWord(_ word: String) -> Bool {
        guard let pieces = BasqueNumberParser.analyse(word), let last = pieces.last else { return false }
        return last.suffix == nil && !last.ordinal
    }

    static func isDigits(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy(\.isASCII) && word.allSatisfy(\.isNumber)
    }
}

/// One number word, or one half of a joined form such as "hogeitabat" or "laumila".
struct BasquePiece {
    enum Kind { case unit, tens, link, hundred, thousand, million, other }
    var kind: Kind
    var value: Int
    /// What follows the digits when written: nil for the bare word, "an" for "seian".
    var suffix: String?
    /// "-garren": the rest after it ("a" for "bosgarrena") sits in `suffix`.
    var ordinal = false
    var word = 0
    /// Part of a joined form: the word counts as more than one.
    var joined = false

    /// A suffix or -garren closes the number.
    var terminal: Bool { suffix != nil || ordinal }
}

struct BasqueNumberParser {
    private static let units: [String: Int] = [
        "zero": 0, "bat": 1, "bi": 2, "hiru": 3, "lau": 4, "bost": 5, "sei": 6, "zazpi": 7,
        "zortzi": 8, "bederatzi": 9, "hamar": 10, "hamaika": 11, "hamabi": 12, "hamahiru": 13,
        "hamalau": 14, "hamabost": 15, "hamasei": 16, "hamazazpi": 17, "hemezortzi": 18,
        "hamazortzi": 18, "hemeretzi": 19,
    ]
    private static let tens: [String: Int] = ["hogei": 20, "berrogei": 40, "hirurogei": 60, "laurogei": 80]
    /// "hogeita bost": the twenties that take a unit after them.
    private static let links: [String: Int] = ["hogeita": 20, "berrogeita": 40, "hirurogeita": 60, "laurogeita": 80]
    private static let hundreds: [String: Int] = [
        "ehun": 100, "berrehun": 200, "hirurehun": 300, "laurehun": 400, "bostehun": 500,
        "seiehun": 600, "zazpiehun": 700, "zortziehun": 800, "bederatziehun": 900,
    ]
    private static let lexicon: [(stem: String, kind: BasquePiece.Kind, value: Int)] = {
        var entries: [(String, BasquePiece.Kind, Int)] = []
        entries += units.map { ($0.key, .unit, $0.value) }
        entries += tens.map { ($0.key, .tens, $0.value) }
        entries += hundreds.map { ($0.key, .hundred, $0.value) }
        entries += [("mila", .thousand, 1_000), ("milioi", .million, 1_000_000)]
        // Longest first: "bederatziehunean" is 900, not 9 + "ehunean".
        return entries.sorted { ($0.0.count, $1.0) > ($1.0.count, $0.0) }
    }()

    /// What may follow the digits (Euskaltzaindia writes them as spoken after the
    /// number's own letters). Distributives and derivations ("milaka", "hamarkada",
    /// "bana") are not on it, so those words stay as they are.
    private static let caseEndings: Set<String> = {
        var endings: Set<String> = [
            "a", "ak", "k", "ek", "i", "ri", "ari", "ei", "n", "en", "ren", "aren",
            "an", "ean", "etan", "tan",
            "tik", "etik", "etatik", "tatik", "dik",
            "ra", "era", "etara", "tara", "rako", "erako", "etarako", "tarako",
            "raino", "eraino", "etaraino", "rantz", "erantz",
            "rekin", "arekin", "ekin", "rentzat", "arentzat", "entzat",
            "z", "ez", "az", "rengatik", "engatik", "arengatik",
        ]
        for head in ["ko", "eko", "tako", "etako"] {
            for tail in ["", "a", "ak", "an", "ari", "aren", "arekin", "ek", "ei", "en", "etan", "tik", "etik", "ra", "era"] {
                endings.insert(head + tail)
            }
        }
        return endings
    }()
    private static let ordinalEndings: Set<String> = [
        "", "a", "ak", "ari", "aren", "arekin", "ean", "eko", "ekoa", "ekoak", "etik", "era",
        "erako", "eraino", "ek", "ei", "en", "etan", "ez", "ekin", "entzat", "i",
    ]
    private static let monthDays: Set<String> = {
        let months = [
            "urtarril", "otsail", "martxo", "apiril", "maiatz", "ekain", "uztail", "abuztu",
            "agorril", "irail", "urri", "azaro", "abendu",
        ]
        // "apirilaren 23an", and the apposition "martxoak 8" (§15.1).
        var forms: Set<String> = ["hilaren"]
        for month in months {
            forms.insert(month + "aren")
            forms.insert(month + "ak")
        }
        return forms
    }()
    /// The time of day as spoken: "hamarrak", "seietan", "hiruretatik".
    private static let hourEndings: Set<String> = ["ak", "etan", "etatik", "etara", "etarako", "etako", "etaraino"]

    let words: [String]
    let boundaries: Set<Int>
    private var pieces: [BasquePiece] = []

    init(words: [String], boundaries: Set<Int>) {
        self.words = words.map { $0.lowercased() }
        self.boundaries = boundaries
        for (index, word) in self.words.enumerated() {
            if let analysed = Self.analyse(word) {
                pieces += analysed.map { var piece = $0; piece.word = index; return piece }
            } else {
                pieces.append(BasquePiece(kind: .other, value: 0, word: index))
            }
        }
    }

    // MARK: Words

    /// The pieces of one number word, or nil if it is not one.
    static func analyse(_ word: String) -> [BasquePiece]? {
        if let value = links[word] { return [BasquePiece(kind: .link, value: value)] }
        if let piece = single(word) { return [piece] }
        // Joined forms: "hogeitabat", "berrogeitahamarrean".
        for (link, value) in links where word.hasPrefix(link) {
            if let unit = single(String(word.dropFirst(link.count))), unit.kind == .unit, (1...19).contains(unit.value) {
                var second = unit
                second.joined = true
                return [BasquePiece(kind: .link, value: value, joined: true), second]
            }
        }
        // "laumila", as one transcript writes "lau mila".
        for (unit, value) in units where (2...9).contains(value) && word.hasPrefix(unit) {
            if var thousand = single(String(word.dropFirst(unit.count))), thousand.kind == .thousand, !thousand.ordinal {
                thousand.joined = true
                return [BasquePiece(kind: .unit, value: value, joined: true), thousand]
            }
        }
        return nil
    }

    /// One lexicon word, bare or with a case suffix or -garren.
    private static func single(_ word: String) -> BasquePiece? {
        for entry in lexicon where word.hasPrefix(ordinalStem(entry.stem)) {
            let rest = String(word.dropFirst(ordinalStem(entry.stem).count))
            if rest.hasPrefix("garren") {
                let ending = String(rest.dropFirst("garren".count))
                guard ordinalEndings.contains(ending) else { continue }
                return BasquePiece(kind: entry.kind, value: entry.value, suffix: ending, ordinal: true)
            }
        }
        for entry in lexicon {
            if word == entry.stem { return BasquePiece(kind: entry.kind, value: entry.value) }
            guard let suffix = writtenSuffix(word, stem: entry.stem), caseEndings.contains(suffix) else { continue }
            return BasquePiece(kind: entry.kind, value: entry.value, suffix: suffix)
        }
        return nil
    }

    /// "bost" → "bos" (bosgarren); every other stem takes -garren as it is.
    private static func ordinalStem(_ stem: String) -> String {
        stem == "bost" ? "bos" : stem
    }

    /// The part of `word` written after the digits, if `word` is `stem` plus an ending.
    private static func writtenSuffix(_ word: String, stem: String) -> String? {
        if stem.hasSuffix("a") {
            // hamaika, mila: a + a = a, a + e = e ("milan" → "n", "milek" → "ek").
            let base = String(stem.dropLast())
            guard word.hasPrefix(base), word.count > stem.count else { return nil }
            let rest = String(word.dropFirst(base.count))
            if rest.hasPrefix("a") { return String(rest.dropFirst()) }
            return rest.hasPrefix("e") ? rest : nil
        }
        // hamar doubles its r before a vowel; hiru and lau take a plural r ("hiruretan").
        if stem.hasSuffix("r") || stem == "hiru" || stem == "lau" {
            let doubled = stem + "r"
            if word.hasPrefix(doubled), let next = word.dropFirst(doubled.count).first, "aeiou".contains(next) {
                return String(word.dropFirst(doubled.count))
            }
        }
        guard word.hasPrefix(stem), word.count > stem.count else { return nil }
        return String(word.dropFirst(stem.count))
    }

    private static func isHourWord(_ word: String) -> Bool {
        guard let pieces = analyse(word), pieces.count == 1, let piece = pieces.first, !piece.ordinal,
              let suffix = piece.suffix, (1...12).contains(piece.value), piece.kind == .unit else { return false }
        return hourEndings.contains(suffix)
    }

    // MARK: Grammar

    private struct Parsed {
        var value: Int
        var end: Int
        var last: BasquePiece
        var terminal: Bool { last.terminal }
    }

    private func word(_ piece: Int) -> String { words[pieces[piece].word] }

    /// No mark between piece `index` and the next one.
    private func open(_ index: Int) -> Bool {
        guard index + 1 < pieces.count else { return false }
        return pieces[index].word == pieces[index + 1].word || !boundaries.contains(pieces[index].word)
    }

    private func isEta(_ index: Int) -> Bool {
        index < pieces.count && pieces[index].kind == .other && word(index) == "eta"
    }

    /// 1–99: "bost", "hogei", "hogeita hamabi".
    private func belowHundred(_ index: Int) -> Parsed? {
        guard index < pieces.count else { return nil }
        let piece = pieces[index]
        switch piece.kind {
        case .link:
            guard open(index), pieces[index + 1].kind == .unit, (1...19).contains(pieces[index + 1].value) else { return nil }
            return Parsed(value: piece.value + pieces[index + 1].value, end: index + 2, last: pieces[index + 1])
        case .unit, .tens:
            return Parsed(value: piece.value, end: index + 1, last: piece)
        default:
            return nil
        }
    }

    /// Hundreds, then "eta" and the rest: "ehun eta hogei", "bost ehun".
    private func belowThousand(_ index: Int) -> Parsed? {
        guard index < pieces.count else { return nil }
        var hundred: Parsed?
        if pieces[index].kind == .hundred {
            hundred = Parsed(value: pieces[index].value, end: index + 1, last: pieces[index])
        } else if pieces[index].kind == .unit, !pieces[index].terminal, (2...9).contains(pieces[index].value),
                  open(index), pieces[index + 1].kind == .hundred, pieces[index + 1].value == 100 {
            // Spaced as some transcripts write it: "bost ehun".
            hundred = Parsed(value: pieces[index].value * 100, end: index + 2, last: pieces[index + 1])
        }
        guard var result = hundred else { return belowHundred(index) }
        // "ehun bat" is "about a hundred": only "eta" joins a hundred to its rest.
        if !result.terminal, isEta(result.end), open(result.end - 1), open(result.end),
           let rest = belowHundred(result.end + 1) {
            result = Parsed(value: result.value + rest.value, end: rest.end, last: rest.last)
        }
        return result
    }

    /// Where the part after "mila" or "milioi" starts: after "eta", at a hundred, or at a
    /// two-word compound ("bi mila hogeita sei"). Never a lone unit: "mila bat" is
    /// "about a thousand".
    private func continuation(_ index: Int) -> Int? {
        guard index < pieces.count, open(index - 1) else { return nil }
        if isEta(index) { return open(index) ? index + 1 : nil }
        if pieces[index].kind == .hundred || pieces[index].kind == .link { return index }
        if pieces[index].kind == .unit, index + 1 < pieces.count, pieces[index + 1].kind == .hundred, open(index) { return index }
        return nil
    }

    private func cardinal(_ index: Int) -> Parsed? {
        var total = 0
        var result: Parsed?
        var next = index
        func finish(_ value: Int, _ end: Int, _ last: BasquePiece) -> Parsed {
            Parsed(value: value, end: end, last: last)
        }
        // Millions.
        if let head = belowThousand(next), !head.terminal, head.end < pieces.count, open(head.end - 1),
           pieces[head.end].kind == .million, !pieces[head.end].ordinal {
            total = head.value * 1_000_000
            result = finish(total, head.end + 1, pieces[head.end])
            if pieces[head.end].terminal { return result }
            next = head.end + 1
        }
        // Thousands.
        // After "milioi" the thousands may follow straight on: "bi milioi hamar mila".
        let thousandsStart = result == nil ? next : continuation(next) ?? (next < pieces.count && open(next - 1) ? next : nil)
        if let start = thousandsStart {
            if let head = belowThousand(start), !head.terminal, head.end < pieces.count, open(head.end - 1),
               pieces[head.end].kind == .thousand, !pieces[head.end].ordinal {
                total += head.value * 1_000
                result = finish(total, head.end + 1, pieces[head.end])
            } else if start < pieces.count, pieces[start].kind == .thousand, !pieces[start].ordinal {
                total += 1_000
                result = finish(total, start + 1, pieces[start])
            }
            if let parsed = result, parsed.terminal { return parsed }
            if let parsed = result { next = parsed.end }
        }
        // The rest, below a thousand.
        let tailStart = result == nil ? index : continuation(next)
        if let start = tailStart, let tail = belowThousand(start) {
            // After a scale word, a lone unit is not joined ("mila bat"); "eta" or a
            // hundred or a compound is (continuation checked the first two).
            return finish(total + tail.value, tail.end, tail.last)
        }
        return result
    }

    /// "hiru koma bi", "bat koma zero bost": the decimals after a whole number.
    private func decimals(after whole: Parsed) -> (digits: String, parsed: Parsed)? {
        guard !whole.terminal, whole.end < pieces.count, pieces[whole.end].kind == .other,
              word(whole.end) == "koma", open(whole.end - 1), open(whole.end) else { return nil }
        var index = whole.end + 1
        var digits = ""
        var last: Parsed?
        while index < pieces.count, pieces[index].kind == .unit, pieces[index].value == 0 {
            digits += "0"
            last = Parsed(value: 0, end: index + 1, last: pieces[index])
            if pieces[index].terminal || !open(index) { return last.map { (digits, $0) } }
            index += 1
        }
        if let rest = belowThousand(index) {
            digits += String(rest.value)
            last = rest
        }
        return last.map { (digits, $0) }
    }

    // MARK: Replacements

    func replacements() -> [NumberReplacement] {
        var result: [NumberReplacement] = []
        var index = 0
        while index < pieces.count {
            // Numbers start at a word's first piece.
            if index > 0, pieces[index - 1].word == pieces[index].word {
                index += 1
                continue
            }
            if let (replacement, end) = percent(at: index) ?? number(at: index) {
                if let replacement { result.append(replacement) }
                index = end
            } else {
                index += 1
            }
        }
        return result
    }

    private func range(_ start: Int, _ end: Int) -> Range<Int>? {
        // A number that ends inside a joined word is not one ("hogeitabat" is whole).
        guard end == pieces.count || pieces[end].word != pieces[end - 1].word else { return nil }
        return pieces[start].word..<(pieces[end - 1].word + 1)
    }

    /// "ehuneko hamabost" → "% 15" (also "ehuneko 15" when the recogniser wrote digits).
    private func percent(at index: Int) -> (NumberReplacement?, Int)? {
        // "ehuneko" is also "of a hundred" (a hundred piece): the word decides.
        guard word(index) == "ehuneko", open(index) else { return nil }
        let next = index + 1
        if pieces[next].kind == .other, BasqueNumbers.isDigits(String(word(next).prefix { $0.isNumber })) {
            let text = word(next)
            let digits = String(text.prefix { $0.isNumber })
            guard Self.caseEndings.contains(String(text.dropFirst(digits.count))) || digits.count == text.count else { return nil }
            return (NumberReplacement(range: pieces[index].word..<(pieces[next].word + 1), text: "%\u{00A0}" + text), next + 1)
        }
        guard let whole = cardinal(next), !whole.last.ordinal else { return nil }
        var text = digits(whole.value)
        var parsed = whole
        if let (fraction, rest) = decimals(after: whole) {
            text += "," + fraction
            parsed = rest
        }
        guard let span = self.range(index, parsed.end) else { return nil }
        return (NumberReplacement(range: span, text: "%\u{00A0}" + text + (parsed.last.suffix ?? "")), parsed.end)
    }

    private func number(at index: Int) -> (NumberReplacement?, Int)? {
        guard let whole = cardinal(index) else { return nil }
        let startWord = pieces[index].word
        let previous = startWord > 0 && !boundaries.contains(startWord - 1) ? words[startWord - 1] : nil
        var parsed = whole
        var text: String
        var convert: Bool

        if let (fraction, rest) = decimals(after: whole) {
            // Decimals are always digits (§13.2); "bi koma zortzi milioi" keeps the word.
            parsed = rest
            text = digits(whole.value) + "," + fraction
            if !rest.terminal, rest.end < pieces.count, pieces[rest.end].kind == .million,
               !pieces[rest.end].ordinal, open(rest.end - 1) {
                parsed = Parsed(value: 0, end: rest.end + 1, last: pieces[rest.end])
                text += "\u{00A0}milioi"
            }
            text += parsed.last.suffix ?? ""
            convert = true
        } else {
            let spoken = Set(pieces[index..<whole.end].map(\.word))
            let multiword = spoken.count > 1 || pieces[index..<whole.end].contains { $0.joined }
            let isDate = previous.map(Self.monthDays.contains) == true && (1...31).contains(whole.value) && !whole.last.ordinal
            let decade = !multiword && (whole.last.kind == .tens || whole.value == 10)
                && ["ko", "eko"].contains(whole.last.suffix ?? "") && !whole.last.ordinal
                && whole.end < pieces.count && open(whole.end - 1) && Self.isDecadeNoun(word(whole.end))
            let atHour = hourBefore(startWord)
            let following = whole.end < pieces.count && open(whole.end - 1) ? word(whole.end) : ""
            // "hogeita hamarren bat": "about thirty", a loose quantity kept in letters.
            let approximate = whole.last.suffix == "en" && following == "bat"
            // Centuries and millennia take Roman numerals (§18): "XXI. mendea".
            let century = whole.last.ordinal && (following.hasPrefix("mende") || following.hasPrefix("milurteko"))
                && (1...39).contains(whole.value)
            convert = isDate || decade || century || (multiword && whole.value >= 20 && !atHour && !approximate)
            if century {
                text = Self.roman(whole.value) + "." + (whole.last.suffix ?? "")
            } else if whole.last.ordinal {
                text = digits(whole.value) + "." + (whole.last.suffix ?? "")
            } else if whole.last.kind == .million, whole.value % 1_000_000 == 0 {
                // "hamabost milioi" → "15 milioi"; below ten the words stay (§13.1).
                let count = whole.value / 1_000_000
                convert = convert && count >= 10
                text = String(count) + "\u{00A0}milioi" + (whole.last.suffix ?? "")
            } else {
                text = digits(whole.value) + (whole.last.suffix ?? "")
            }
        }
        guard let span = range(index, parsed.end) else { return (nil, index + 1) }
        return (convert ? NumberReplacement(range: span, text: text) : nil, parsed.end)
    }

    private static func roman(_ value: Int) -> String {
        let numerals: [(Int, String)] = [(10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var remaining = value
        var text = ""
        for (amount, numeral) in numerals {
            while remaining >= amount {
                text += numeral
                remaining -= amount
            }
        }
        return text
    }

    private static func isDecadeNoun(_ word: String) -> Bool {
        word.hasPrefix("hamarkad") || word.hasPrefix("hamarraldi")
            || ["urteak", "urteek", "urteei", "urteen", "urteetan", "urteetako", "urteetatik", "urteetara"].contains(word)
    }

    /// "hamarrak eta hogeita bost", "zazpiak hogeita bost gutxi": minutes after a spoken
    /// hour stay in letters with it.
    private func hourBefore(_ startWord: Int) -> Bool {
        var previous = startWord - 1
        guard previous >= 0, !boundaries.contains(previous) else { return false }
        if words[previous] == "eta" {
            previous -= 1
            guard previous >= 0, !boundaries.contains(previous) else { return false }
        }
        return Self.isHourWord(words[previous])
    }

    /// Grouped with a no-break space from five digits on (§3.2.1.1).
    private func digits(_ value: Int) -> String {
        groupedDigits(value, separator: "\u{00A0}")
    }
}
