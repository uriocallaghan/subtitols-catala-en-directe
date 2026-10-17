import Foundation

/// Spoken English numbers → digits, in the BBC's subtitling style.
///
/// Choices, and where they come from:
/// - Letters vs digits: one to ten stay in words, 11 and above take numerals; a number
///   with a unit takes the numeral whatever its size ("5 kilometres", "3 dollars").
///   Emphatic numbers stay in words ("a thousand times"; "hundreds of people" is never a
///   number word to begin with). BBC Subtitle Guidelines §18.1,
///   https://www.bbc.co.uk/accessibility/forproducts/guides/subtitles/#Numbers
/// - Grouping: a comma every three digits from four digits on ("1,500", as the BBC's own
///   example writes it). Years are never grouped. BBC §18.1 (same URL).
/// - Dates: the day of the month in numerals with a lowercase ordinal suffix when it is
///   spoken as an ordinal ("April 23rd", "the 23rd of April"), plain when spoken as a
///   cardinal ("April 23"). BBC §18.2,
///   https://www.bbc.co.uk/accessibility/forproducts/guides/subtitles/#Dates
/// - Ordinals outside dates follow the cardinal threshold: "first" … "tenth" stay in
///   words, "21st century" takes numerals (BBC §18.1: "On her 21st birthday").
/// - Percent: the numeral and "%" with no space, "15%", "2.5%"; always digits.
///   AP Stylebook 2019, https://www.poynter.org/reporting-editing/2019/ap-says-the-percentage-sign-now-ok-when-used-with-a-numeral-thats-shift5/
/// - Years in figures without a comma ("1992", "2026"), decades as "1990s"; AP Stylebook
///   ("years", "decades"), https://www.apstylebook.com/. A year read in halves
///   ("nineteen ninety two") only becomes one where the context says year: after "in",
///   "since", "year", a month or a date, before "BC"/"AD". Elsewhere it stays in words.
/// - Round millions keep the word: "3 million", "1.5 million" (AP, BBC News practice);
///   "a million" stays in words, like "a thousand thanks".
/// - Time: "4 o'clock" (BBC §18.4). Currency words are kept, not turned into symbols
///   ("50 dollars"): "pounds" is also a weight.
/// - Not applied: the BBC's "spell out a number that begins a sentence" (sentence starts
///   are not known here).
public struct EnglishNumbers: NumberNormalizing {
    public init() {}

    public func replacements(in words: [String], boundaries: Set<Int>) -> [NumberReplacement] {
        EnglishNumberParser(words: words, boundaries: boundaries).replacements()
    }

    public func mayExtendNumber(_ word: String, after previous: String?) -> Bool {
        let word = EnglishNumberParser.clean(word)
        if EnglishNumberParser.atom(word) != nil || EnglishNumberParser.isDigits(word) { return true }
        // "a" may become "a hundred"; once shown it could no longer be replaced.
        if word == "a" { return true }
        guard let previous = previous.map(EnglishNumberParser.clean) else { return false }
        let afterNumber = EnglishNumberParser.atom(previous) != nil || EnglishNumberParser.isDigits(previous)
        return afterNumber && ["and", "per", "point", "oh", "o", "nought"].contains(word)
    }
}

private struct EnglishNumberParser {
    let words: [String]
    let boundaries: Set<Int>

    init(words: [String], boundaries: Set<Int>) {
        self.words = words.map(Self.clean)
        self.boundaries = boundaries
    }

    static func clean(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    // MARK: Vocabulary

    enum Kind: Equatable {
        case unit      // 0–9
        case teen      // 10–19
        case tens      // 20, 30 … 90
        case compound  // 21–99 written with a hyphen
        case hundred
        case scale     // thousand, million, billion, trillion
    }

    struct Atom {
        let value: Int
        let kind: Kind
        let isOrdinal: Bool
    }

    private static let cardinals: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7,
        "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13,
        "fourteenth": 14, "fifteenth": 15, "sixteenth": 16, "seventeenth": 17,
        "eighteenth": 18, "nineteenth": 19, "twentieth": 20, "thirtieth": 30, "fortieth": 40,
        "fiftieth": 50, "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
    ]
    private static let scales: [String: Int] = [
        "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
        "trillion": 1_000_000_000_000,
    ]
    private static let ordinalScales: [String: Int] = [
        "hundredth": 100, "thousandth": 1_000, "millionth": 1_000_000, "billionth": 1_000_000_000,
    ]
    private static let decadePlurals: [String: Int] = [
        "tens": 10, "twenties": 20, "thirties": 30, "forties": 40, "fifties": 50,
        "sixties": 60, "seventies": 70, "eighties": 80, "nineties": 90,
    ]
    private static let digitWords: [String: Character] = [
        "zero": "0", "oh": "0", "o": "0", "nought": "0", "one": "1", "two": "2", "three": "3",
        "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    ]
    static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
    ]
    /// "may" and "march" are also a verb; as a month they need a word like "on" before them.
    private static let ambiguousMonths: Set<String> = ["may", "march"]
    private static let monthLeads: Set<String> = [
        "on", "in", "of", "since", "until", "till", "by", "from", "before", "after", "early",
        "late", "mid", "last", "next", "this", "every", "each", "through", "to",
    ]
    private static let eras: Set<String> = ["bc", "ad", "bce", "ce", "b.c", "a.d"]
    /// Words that say the number after them is a year, whatever its form.
    private static let yearLeads: Set<String> = [
        "since", "year", "until", "till", "circa", "spring", "summer", "autumn", "fall",
        "winter", "christmas",
    ]
    /// Also before a year, but also before quantities: a year read in halves is clear
    /// enough after them; "two thousand and six" only when nothing noun-like follows.
    private static let weakYearLeads: Set<String> = [
        "in", "from", "during", "before", "after", "around", "of", "to", "and", "through",
        "between", "by", "early", "late", "mid",
    ]
    /// Before a year said as a cardinal ("in two thousand and six"), when nothing
    /// noun-like follows it: "in two thousand cases" is a quantity.
    private static let cardinalYearLeads: Set<String> = ["in", "during", "before", "after"]
    /// What may follow "in two thousand and six" when it is a year.
    private static let afterYear: Set<String> = [
        "the", "a", "an", "and", "but", "so", "i", "we", "you", "he", "she", "they", "it",
        "there", "when", "was", "were", "is", "that", "which", "who", "at", "on", "in", "for",
        "with", "after", "before", "until", "then", "or",
    ]
    private static let units: Set<String> = [
        "dollar", "dollars", "euro", "euros", "pound", "pounds", "pence", "cent", "cents",
        "yen", "kilometre", "kilometres", "kilometer", "kilometers", "km", "metre", "metres",
        "meter", "meters", "centimetre", "centimetres", "centimeter", "centimeters",
        "millimetre", "millimetres", "millimeter", "millimeters", "mile", "miles", "kilogram",
        "kilograms", "kilo", "kilos", "kg", "gram", "grams", "litre", "litres", "liter",
        "liters", "degree", "degrees", "mph",
    ]
    private static let oClock: Set<String> = ["o'clock", "oclock"]
    /// Emphatic or fixed phrases that stay in words.
    private static let idioms: [[String]] = [
        ["a", "thousand", "thanks"], ["a", "thousand", "times"], ["a", "hundred", "times"],
        ["a", "thousand", "words"], ["a", "thousand", "apologies"], ["eleventh", "hour"],
        ["nineteen", "to", "the", "dozen"], ["forty", "winks"], ["fourth", "of", "july"],
        ["july", "fourth"], ["sixty", "four", "thousand", "dollar", "question"],
        ["sixty-four", "thousand", "dollar", "question"],
    ]
    /// Fixed phrases with their own written form.
    private static let fixedForms: [([String], String)] = [
        (["twenty", "four", "seven"], "24/7"), (["twenty-four", "seven"], "24/7"),
        (["fifty", "fifty"], "50-50"), (["fifty-fifty"], "50-50"), (["nine", "eleven"], "9/11"),
    ]

    static func isDigits(_ word: String) -> Bool {
        guard let first = word.first, first.isASCII, first.isNumber else { return false }
        return word.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "," || $0 == "." }
    }

    static func atom(_ word: String) -> Atom? {
        if let value = cardinals[word] {
            let kind: Kind = value < 10 ? .unit : value < 20 ? .teen : .tens
            return Atom(value: value, kind: kind, isOrdinal: false)
        }
        if let value = ordinals[word] {
            let kind: Kind = value < 10 ? .unit : value < 20 ? .teen : .tens
            return Atom(value: value, kind: kind, isOrdinal: true)
        }
        if word == "hundred" { return Atom(value: 100, kind: .hundred, isOrdinal: false) }
        if let value = scales[word] { return Atom(value: value, kind: .scale, isOrdinal: false) }
        if let value = ordinalScales[word] {
            return Atom(value: value, kind: value == 100 ? .hundred : .scale, isOrdinal: true)
        }
        // "twenty-three", "twenty-third".
        let parts = word.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let ten = cardinals[parts[0]], ten >= 20, ten % 10 == 0 else { return nil }
        if let unit = cardinals[parts[1]], (1...9).contains(unit) {
            return Atom(value: ten + unit, kind: .compound, isOrdinal: false)
        }
        if let unit = ordinals[parts[1]], (1...9).contains(unit) {
            return Atom(value: ten + unit, kind: .compound, isOrdinal: true)
        }
        return nil
    }

    // MARK: Cardinals and ordinals

    struct Number {
        var value: Int
        var end: Int
        var isOrdinal = false
        /// Digits after "point".
        var decimals: String?
        /// "three million": the multiplier and the scale word, kept as a word.
        var roundScale: (head: Int, word: String)?
        var startsWithA = false
    }

    /// Whether a number may run on from `position - 1` to `position`.
    private func open(_ position: Int, from start: Int) -> Bool {
        position == start || !boundaries.contains(position - 1)
    }

    private func word(_ index: Int) -> String? { index < words.count ? words[index] : nil }

    /// The below-hundred after an "and" at `index`: its end, or nil.
    private func smallAfterAnd(_ index: Int) -> Int? {
        guard !boundaries.contains(index), let next = word(index + 1), let small = Self.atom(next),
              [.unit, .teen, .tens, .compound].contains(small.kind), small.value > 0 else { return nil }
        var end = index + 2
        if small.kind == .tens, !small.isOrdinal, !boundaries.contains(index + 1),
           let unit = word(end).flatMap(Self.atom), unit.kind == .unit, unit.value > 0 {
            end += 1
        }
        return end
    }

    /// The longest cardinal or ordinal starting at `start`.
    func number(at start: Int) -> Number? {
        guard start < words.count else { return nil }
        var total = 0
        var current = 0
        var lastScale = Int.max
        var scaleCount = 0
        var groupHasHundred = false
        var last: Kind? = nil
        var sawAnd = false
        var isOrdinal = false
        var roundScaleWord: String? = nil
        var index = start
        var startsWithA = false

        if words[start] == "a" {
            guard let next = word(start + 1), ["hundred", "thousand"].contains(next),
                  !boundaries.contains(start) else { return nil }
            current = 1
            last = .unit
            startsWithA = true
            index += 1
        }

        loop: while index < words.count, open(index, from: start) {
            let text = words[index]
            if text == "and" {
                guard last == .hundred || last == .scale, let smallEnd = smallAfterAnd(index) else { break }
                // "five hundred and six hundred" is two numbers; "a hundred and fifty
                // thousand" is one.
                if let after = word(smallEnd), !boundaries.contains(smallEnd - 1), let atom = Self.atom(after) {
                    if atom.kind == .hundred, groupHasHundred { break }
                    if atom.kind == .scale, atom.value >= lastScale { break }
                }
                sawAnd = true
                last = nil
                index += 1
                continue
            }
            guard let atom = Self.atom(text) else { break }
            switch atom.kind {
            case .unit, .teen, .tens, .compound:
                let joinsTens = last == .tens && atom.kind == .unit && atom.value > 0
                let startsGroup = last == nil || last == .hundred || last == .scale
                guard joinsTens || startsGroup else { break loop }
                // "zero" only on its own.
                if atom.value == 0, index != start { break loop }
                current += atom.value
                last = atom.kind
            case .hundred:
                if last == nil, current == 0, total == 0 {
                    // A bare "hundred" only in "hundred and five" or "the hundredth".
                    guard index == start, atom.isOrdinal
                        || (!boundaries.contains(index) && word(index + 1) == "and" && smallAfterAnd(index + 1) != nil)
                    else { break loop }
                    current = 1
                } else {
                    guard let previous = last, [.unit, .teen, .tens, .compound].contains(previous),
                          !groupHasHundred, (1...99).contains(current) else { break loop }
                }
                current *= 100
                groupHasHundred = true
                last = .hundred
            case .scale:
                guard atom.value < lastScale else { break loop }
                if current == 0 {
                    guard index == start, atom.isOrdinal
                        || (!boundaries.contains(index) && word(index + 1) == "and" && smallAfterAnd(index + 1) != nil)
                    else { break loop }
                    current = 1
                } else if last == nil {
                    break loop
                }
                total += current * atom.value
                current = 0
                groupHasHundred = false
                lastScale = atom.value
                scaleCount += 1
                roundScaleWord = atom.value >= 1_000_000 ? text : nil
                last = .scale
            }
            index += 1
            if atom.isOrdinal {
                isOrdinal = true
                break
            }
            if atom.kind != .scale { roundScaleWord = nil }
        }
        if last == nil, sawAnd { index -= 1 }
        guard index > start + (startsWithA ? 1 : 0) else { return nil }
        var number = Number(value: total + current, end: index, isOrdinal: isOrdinal, startsWithA: startsWithA)
        if !isOrdinal, let scaleWord = roundScaleWord, scaleCount == 1, current == 0, let scale = Self.scales[scaleWord] {
            number.roundScale = (total / scale, scaleWord)
        }
        if !isOrdinal, number.roundScale == nil, last != .scale { readDecimals(into: &number) }
        return number
    }

    /// "two point five", "one point five million".
    private func readDecimals(into number: inout Number) {
        var index = number.end
        guard word(index) == "point", !boundaries.contains(index - 1), !boundaries.contains(index) else { return }
        index += 1
        var digits = ""
        while let text = word(index), let digit = Self.digitWords[text] {
            digits.append(digit)
            index += 1
            if boundaries.contains(index - 1) { break }
        }
        guard !digits.isEmpty else { return }
        number.decimals = digits
        number.end = index
        if !boundaries.contains(index - 1), let text = word(index), let scale = Self.scales[text], scale >= 1_000_000 {
            number.roundScale = (number.value, text)
            number.end = index + 1
        }
    }

    // MARK: Years read in halves

    enum HalvesForm {
        case year(Int)
        case hundred(Int)   // "nineteen hundred", also a quantity ("twelve hundred people")
        case decade(Int)    // "nineteen nineties"
    }

    /// "nineteen ninety two", "twenty twenty six", "nineteen oh five", "nineteen hundred
    /// (and five)", "the nineteen nineties".
    func halves(at start: Int) -> (HalvesForm, Int)? {
        guard let first = Self.cardinals[words[start]], (10...20).contains(first),
              let second = word(start + 1), !boundaries.contains(start) else { return nil }
        if second == "hundred" {
            var value = first * 100
            var end = start + 2
            if word(end) == "and", !boundaries.contains(end - 1), let smallEnd = smallAfterAnd(end),
               let rest = number(at: end + 1), !rest.isOrdinal, rest.end == smallEnd {
                value += rest.value
                end = smallEnd
            }
            return (.hundred(value), end)
        }
        if second == "hundreds" { return (.decade(first * 100), start + 2) }
        if let decade = Self.decadePlurals[second], decade >= 10 { return (.decade(first * 100 + decade), start + 2) }
        if ["oh", "o", "nought"].contains(second), !boundaries.contains(start + 1),
           let unit = word(start + 2).flatMap(Self.atom), unit.kind == .unit, !unit.isOrdinal, unit.value > 0 {
            return (.year(first * 100 + unit.value), start + 3)
        }
        guard let rest = Self.atom(second), !rest.isOrdinal, [.teen, .tens, .compound].contains(rest.kind) else { return nil }
        var value = rest.value
        var end = start + 2
        if rest.kind == .tens, !boundaries.contains(start + 1), let unit = word(end).flatMap(Self.atom),
           unit.kind == .unit, !unit.isOrdinal, unit.value > 0 {
            value += unit.value
            end += 1
        }
        // "nineteen twenty thousand" is not a year.
        if !boundaries.contains(end - 1), let after = word(end).flatMap(Self.atom),
           after.kind == .hundred || after.kind == .scale {
            return nil
        }
        return (.year(first * 100 + value), end)
    }

    // MARK: Context

    private func isMonth(_ index: Int) -> Bool {
        guard index >= 0, let text = word(index), Self.months.contains(text) else { return false }
        guard Self.ambiguousMonths.contains(text) else { return true }
        return index > 0 && Self.monthLeads.contains(words[index - 1])
    }

    private func followedByEra(_ end: Int) -> Bool {
        !boundaries.contains(end - 1) && word(end).map(Self.eras.contains) == true
    }

    /// The context before `start` says year: a year lead, a month, or a date or year
    /// just before (a comma in between is fine: "April 23rd, 2026").
    private func strongYearContext(_ start: Int, end: Int, lastDateOrYearEnd: Int?) -> Bool {
        if followedByEra(end) { return true }
        guard start > 0 else { return false }
        let previous = words[start - 1]
        if Self.yearLeads.contains(previous) || isMonth(start - 1) { return true }
        if lastDateOrYearEnd == start { return true }
        // "from 1990 to 1995".
        if ["to", "and", "through", "until", "till", "or"].contains(previous), lastDateOrYearEnd == start - 1 {
            return !boundaries.contains(start - 2)
        }
        return false
    }

    private func weakYearContext(_ start: Int) -> Bool {
        start > 0 && Self.weakYearLeads.contains(words[start - 1])
    }

    // MARK: Output

    private static func ordinalSuffix(_ value: Int) -> String {
        if (11...13).contains(value % 100) { return "th" }
        switch value % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    private static func quantity(_ number: Number) -> String {
        if let decimals = number.decimals {
            let head = "\(groupedDigits(number.value, separator: ",", minimum: 1_000)).\(decimals)"
            return number.roundScale.map { "\(head) \($0.word)" } ?? head
        }
        if let (head, word) = number.roundScale {
            return "\(groupedDigits(head, separator: ",", minimum: 1_000)) \(word)"
        }
        let digits = groupedDigits(number.value, separator: ",", minimum: 1_000)
        return number.isOrdinal ? digits + ordinalSuffix(number.value) : digits
    }

    private func matches(_ phrase: [String], at index: Int, crossingMarks: Bool) -> Bool {
        guard index + phrase.count <= words.count, Array(words[index..<(index + phrase.count)]) == phrase else { return false }
        return crossingMarks || !(index..<(index + phrase.count - 1)).contains(where: boundaries.contains)
    }

    func replacements() -> [NumberReplacement] {
        var result: [NumberReplacement] = []
        var lastDateOrYearEnd: Int? = nil
        var index = 0
        func emit(_ range: Range<Int>, _ text: String) {
            result.append(NumberReplacement(range: range, text: text))
            index = range.upperBound
        }
        while index < words.count {
            if let idiom = Self.idioms.first(where: { matches($0, at: index, crossingMarks: false) }) {
                index += idiom.count
                continue
            }
            if let (phrase, text) = Self.fixedForms.first(where: { matches($0.0, at: index, crossingMarks: false) }) {
                emit(index..<(index + phrase.count), text)
                continue
            }
            let start = index
            // Digits the recogniser wrote itself: only "10 per cent" → "10%".
            if Self.isDigits(words[start]) {
                if let end = percentEnd(after: start + 1) {
                    emit(start..<end, words[start] + "%")
                } else {
                    index += 1
                }
                continue
            }
            if let (form, end) = halves(at: start) {
                switch form {
                case .decade(let value):
                    emit(start..<end, "\(value)s")
                    continue
                case .year(let value):
                    if strongYearContext(start, end: end, lastDateOrYearEnd: lastDateOrYearEnd) || weakYearContext(start) {
                        emit(start..<end, String(value))
                        lastDateOrYearEnd = end
                    } else {
                        // "nineteen ninety two" with nothing saying year: left as heard.
                        index = end
                    }
                    continue
                case .hundred(let value):
                    if strongYearContext(start, end: end, lastDateOrYearEnd: lastDateOrYearEnd) || weakYearContext(start) {
                        emit(start..<end, String(value))
                        lastDateOrYearEnd = end
                        continue
                    }
                    // Otherwise a quantity: read on as a cardinal.
                }
            }
            guard let number = number(at: start) else {
                index += 1
                continue
            }
            let end = number.end
            let plain = number.decimals == nil && number.roundScale == nil

            if !number.isOrdinal, let percentEnd = percentEnd(after: end) {
                emit(start..<percentEnd, Self.quantity(number) + "%")
                continue
            }
            if plain, !number.startsWithA, (1...31).contains(number.value), isDate(number, start: start) {
                emit(start..<end, number.isOrdinal ? "\(number.value)\(Self.ordinalSuffix(number.value))" : String(number.value))
                lastDateOrYearEnd = end
                continue
            }
            if plain, !number.isOrdinal, number.value > 0, number.value < 10_000 {
                let strong = strongYearContext(start, end: end, lastDateOrYearEnd: lastDateOrYearEnd)
                let yearRange = (1_000...2_099).contains(number.value)
                let followsLikeYear = end == words.count || boundaries.contains(end - 1)
                    || Self.afterYear.contains(words[end])
                if followedByEra(end) || (yearRange && (strong || (start > 0 && Self.cardinalYearLeads.contains(words[start - 1]) && followsLikeYear))) {
                    emit(start..<end, String(number.value))
                    lastDateOrYearEnd = end
                    continue
                }
            }
            let readsOn = end < words.count && !boundaries.contains(end - 1)
            if plain, !number.isOrdinal, readsOn, (1...12).contains(number.value), Self.oClock.contains(words[end]) {
                emit(start..<end, String(number.value))
                continue
            }
            if !number.isOrdinal, readsOn, Self.units.contains(words[end]), !number.startsWithA || number.value >= 11 {
                emit(start..<end, Self.quantity(number))
                continue
            }
            if !plain || number.value >= 11 {
                emit(start..<end, Self.quantity(number))
                continue
            }
            index = end
        }
        return result
    }

    /// The end of "percent", "per cent" or "%" right after `index - 1`.
    private func percentEnd(after index: Int) -> Int? {
        guard index > 0, index < words.count, !boundaries.contains(index - 1) else { return nil }
        if ["percent", "%"].contains(words[index]) { return index + 1 }
        if words[index] == "per", word(index + 1) == "cent", !boundaries.contains(index) { return index + 2 }
        return nil
    }

    /// "April 23rd", "April 23", "the 23rd of April", "23rd April".
    private func isDate(_ number: Number, start: Int) -> Bool {
        if start > 0, !boundaries.contains(start - 1), isMonth(start - 1) { return true }
        guard number.isOrdinal, number.end < words.count, !boundaries.contains(number.end - 1) else { return false }
        let next = words[number.end]
        if next == "of", !boundaries.contains(number.end) { return isMonth(number.end + 1) }
        return Self.months.contains(next) && !Self.ambiguousMonths.contains(next)
    }
}
