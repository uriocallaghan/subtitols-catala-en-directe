import Foundation

/// A video's subtitles as short lines to read and correct, like a song's lyrics.
///
/// The session's words are grouped into lines a viewer reads at a glance: a line ends at
/// a paragraph, a sentence, a pause, after `maximumLineSeconds`, or before it would pass
/// `maximumCharacters` (then preferably after a comma). Every word keeps its own time.
/// Correcting a line keeps the time of every word that is still there (case and accents
/// aside) and shares the time of the words that were replaced among the words that
/// replaced them, by length; so the word-per-cue `.srt` and the burnt-in captions stay in
/// step with the voice after any correction.
public struct SubtitleDocument: Codable, Equatable, Sendable {
    public struct Word: Codable, Equatable, Sendable {
        public var text: String
        public var start: TimeInterval
        public var end: TimeInterval

        public init(text: String, start: TimeInterval, end: TimeInterval) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    public struct Line: Codable, Identifiable, Equatable, Sendable {
        public let id: Int
        public var words: [Word]
        /// The line opens a paragraph in the text exports.
        public var startsParagraph: Bool
        /// The line follows a long pause mid-sentence (see `SessionTranscript.Word`).
        public var startsLine: Bool

        public init(id: Int, words: [Word], startsParagraph: Bool = false, startsLine: Bool = false) {
            self.id = id
            self.words = words
            self.startsParagraph = startsParagraph
            self.startsLine = startsLine
        }

        public var text: String { words.map(\.text).joined(separator: " ") }
        public var start: TimeInterval { words.first?.start ?? 0 }
        public var end: TimeInterval { words.last?.end ?? start }
    }

    /// A line as burnt into the picture: on screen from `start` to `end`, which runs on
    /// across a short gap to the next line, so the captions do not blink between lines.
    public struct Cue: Equatable, Sendable {
        public let lineID: Int
        public let words: [Word]
        public let start: TimeInterval
        public let end: TimeInterval

        public var text: String { words.map(\.text).joined(separator: " ") }
    }

    /// About two seconds of reading, and one row of a landscape picture.
    public static let maximumCharacters = 42
    public static let maximumLineSeconds: TimeInterval = 7
    /// A silence this long between two words starts a new line.
    public static let pauseBreakSeconds: TimeInterval = 0.7
    /// A caption stays this long after its last word when nothing follows soon.
    static let holdSeconds: TimeInterval = 0.6
    /// Gaps up to this long are bridged: the caption stays until the next one.
    static let bridgedGapSeconds: TimeInterval = 1.0
    static let minimumCueSeconds: TimeInterval = 0.8
    /// The shortest time a word is given when a correction adds words.
    static let minimumWordSeconds: TimeInterval = 0.08

    public private(set) var lines: [Line]
    public let duration: TimeInterval
    public let startedAt: Date?
    /// The id the next new line takes (a split or an added line); ids are never reused.
    private var nextLineID: Int

    public init(session: SessionTranscript) {
        duration = session.duration
        startedAt = session.startedAt
        lines = Self.lines(from: Self.timed(session.words))
        nextLineID = lines.count
    }

    public var isEmpty: Bool { lines.isEmpty }
    public var wordCount: Int { lines.reduce(0) { $0 + $1.words.count } }

    public func line(id: Int) -> Line? { lines.first { $0.id == id } }
    public func index(of id: Int) -> Int? { lines.firstIndex { $0.id == id } }

    /// The line being said at `time`, or the last one said before it: between two lines
    /// the one just heard stays current. `nil` before the first.
    public func lineIndex(at time: TimeInterval) -> Int? {
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }

    // MARK: - Correcting

    /// Replaces a line's text. Words still there keep their time; new words share the
    /// time of the words they replaced. An empty text removes the line. Returns whether
    /// anything changed.
    @discardableResult
    public mutating func setText(_ text: String, ofLine id: Int) -> Bool {
        guard let index = index(of: id) else { return false }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let old = lines[index].words
        guard tokens != old.map(\.text) else { return false }
        if tokens.isEmpty {
            let removed = lines.remove(at: index)
            // The paragraph it opened goes on with the line after it.
            if removed.startsParagraph, index < lines.count { lines[index].startsParagraph = true }
            return true
        }
        // New words may take the silence around the line, never the next line's time.
        let floor = index > 0 ? lines[index - 1].end : 0
        let lastEnd = old.last?.end ?? 0
        let ceiling = index + 1 < lines.count ? lines[index + 1].start : (duration > lastEnd ? duration : .infinity)
        lines[index].words = Self.retimed(old, to: tokens, within: min(floor, old.first?.start ?? floor)...max(ceiling, lastEnd))
        return true
    }

    /// Removes a line; the paragraph it opened goes on with the line after it.
    @discardableResult
    public mutating func removeLine(id: Int) -> Bool {
        setText("", ofLine: id)
    }

    /// Cuts a line in two before its word `wordIndex`; every word keeps its time. Returns
    /// the new second line's id, or `nil` when there is nothing on one side.
    @discardableResult
    public mutating func split(lineID id: Int, beforeWord wordIndex: Int) -> Int? {
        guard let index = index(of: id), wordIndex > 0, wordIndex < lines[index].words.count else { return nil }
        let tail = Array(lines[index].words[wordIndex...])
        lines[index].words.removeSubrange(wordIndex...)
        let newID = nextLineID
        nextLineID += 1
        lines.insert(Line(id: newID, words: tail, startsParagraph: false, startsLine: false), at: index + 1)
        return newID
    }

    /// Where a line reads best cut in two: after the comma nearest its middle, else
    /// before the word nearest its middle (by characters). `nil` for a single word.
    public func naturalSplit(ofLine id: Int) -> Int? {
        guard let line = line(id: id), line.words.count > 1 else { return nil }
        let total = Double(line.text.count)
        var position = 0
        var best: (index: Int, score: Double)?
        for (offset, word) in line.words.enumerated().dropLast() {
            position += word.text.count + 1
            var score = abs(Double(position) / max(1, total) - 0.5)
            if Self.endsClause(word.text) || Self.endsSentence(word.text) { score -= 0.2 }
            if best == nil || score < best!.score { best = (offset + 1, score) }
        }
        return best?.index
    }

    /// Joins the line after `id` onto it; every word keeps its time. Returns whether
    /// there was a line to join.
    @discardableResult
    public mutating func mergeWithNext(lineID id: Int) -> Bool {
        guard let index = index(of: id), index + 1 < lines.count else { return false }
        let next = lines.remove(at: index + 1)
        lines[index].words += next.words
        return true
    }

    /// The silence after a line, where a line the recogniser missed can go: from its
    /// last word to the next line's first (or the end of the recording).
    public func gap(after id: Int) -> ClosedRange<TimeInterval>? {
        guard let index = index(of: id) else { return nil }
        let start = lines[index].end
        let end = index + 1 < lines.count ? lines[index + 1].start : max(duration, start)
        return end > start ? start...end : nil
    }

    /// A silence long enough to hold a line of its own.
    public static let minimumInsertSeconds: TimeInterval = 0.3

    /// Adds a line the recogniser missed after line `id` (or before the first line when
    /// `id` is `nil`), its words spread over `span` by length. Returns the new line's id.
    @discardableResult
    public mutating func insertLine(_ text: String, after id: Int?, span: ClosedRange<TimeInterval>) -> Int? {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }
        let position: Int
        if let id {
            guard let index = index(of: id) else { return nil }
            position = index + 1
        } else {
            position = 0
        }
        // The span may not reach into the lines either side.
        let floor = position > 0 ? lines[position - 1].end : 0
        let ceiling = position < lines.count ? lines[position].start : max(duration, span.upperBound)
        let from = min(max(span.lowerBound, floor), ceiling)
        let to = max(min(span.upperBound, ceiling), from)
        let weights = tokens.map { Double(max(1, $0.count)) }
        let total = weights.reduce(0, +)
        var cursor = from
        let words = zip(tokens, weights).map { token, weight in
            let length = (to - from) * weight / total
            defer { cursor += length }
            return Word(text: token, start: cursor, end: cursor + length)
        }
        let newID = nextLineID
        nextLineID += 1
        lines.insert(Line(id: newID, words: words, startsParagraph: false, startsLine: false), at: position)
        return newID
    }

    // MARK: - Finding and replacing

    /// Where a phrase is said: a line and the run of its words that say it.
    public struct Match: Equatable, Sendable {
        public let lineID: Int
        public let words: Range<Int>
    }

    /// Every place the phrase `query` is said, whole words only, without minding case,
    /// accents or the marks around a word; a word after an elision ("l'escola") counts
    /// as itself ("escola").
    public func matches(of query: String) -> [Match] {
        let wanted = query.split(whereSeparator: \.isWhitespace).map { Self.key(String($0)) }.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return [] }
        var found: [Match] = []
        for line in lines {
            let words = line.words.map { Self.parts($0.text) }
            var start = 0
            while start + wanted.count <= words.count {
                let fits = wanted.indices.allSatisfy { offset in
                    let word = words[start + offset]
                    return word.key == wanted[offset] || word.coreKey == wanted[offset]
                }
                if fits {
                    found.append(Match(lineID: line.id, words: start..<(start + wanted.count)))
                    start += wanted.count
                } else {
                    start += 1
                }
            }
        }
        return found
    }

    /// Replaces every place `query` is said with `replacement`; the marks around the
    /// words found and an elision before them stay, and a capital that began a sentence
    /// stays a capital. Returns how many places changed.
    @discardableResult
    public mutating func replaceAll(_ query: String, with replacement: String) -> Int {
        let found = matches(of: query)
        let newWords = replacement.split(whereSeparator: \.isWhitespace).map(String.init)
        // A search that spells the elision ("l'Hospitalet") matches the whole word: the
        // replacement then brings its own, and only the marks before it stay.
        let firstWanted = query.split(whereSeparator: \.isWhitespace).first.map { Self.key(String($0)) }
        var changed = 0
        for lineID in Set(found.map(\.lineID)) {
            guard let line = line(id: lineID) else { continue }
            var tokens = line.words.map(\.text)
            let inLine = found.filter { $0.lineID == lineID }
            // From the end, so earlier ranges stay where they were.
            for match in inLine.sorted(by: { $0.words.lowerBound > $1.words.lowerBound }) {
                let firstToken = tokens[match.words.lowerBound]
                var first = Self.parts(firstToken)
                if first.key == firstWanted, first.coreKey != firstWanted {
                    let marks = firstToken.prefix { !$0.isLetter && !$0.isNumber }
                    first = (String(marks), String(firstToken.dropFirst(marks.count)), first.suffix, first.key, first.coreKey)
                }
                let last = Self.parts(tokens[match.words.upperBound - 1])
                var replaced = newWords
                if !replaced.isEmpty {
                    if first.core.first?.isUppercase == true, let head = replaced[0].first, head.isLowercase {
                        replaced[0] = head.uppercased() + replaced[0].dropFirst()
                    }
                    replaced[0] = first.prefix + replaced[0]
                    replaced[replaced.count - 1] += last.suffix
                }
                tokens.replaceSubrange(match.words, with: replaced)
            }
            if setText(tokens.joined(separator: " "), ofLine: lineID) { changed += inLine.count }
        }
        return changed
    }

    /// A word cut into the marks and elision before it, its core, and the marks after.
    static func parts(_ text: String) -> (prefix: String, core: String, suffix: String, key: String, coreKey: String) {
        let characters = Array(text)
        var head = 0
        while head < characters.count, !characters[head].isLetter, !characters[head].isNumber { head += 1 }
        var tail = characters.count
        while tail > head, !characters[tail - 1].isLetter, !characters[tail - 1].isNumber { tail -= 1 }
        // "l'escola", "d’aquí": the elision goes with the marks before.
        if let apostrophe = characters[head..<tail].firstIndex(where: { $0 == "'" || $0 == "’" }),
           apostrophe - head <= 2, apostrophe + 1 < tail {
            head = apostrophe + 1
        }
        let core = String(characters[head..<tail])
        return (String(characters[..<head]), core, String(characters[tail...]), key(text), key(core))
    }

    /// The new words, timed: the longest run of words common to both (compared without
    /// case, accents or marks) keeps its times; each stretch of new words between two
    /// kept ones takes the time the replaced words had, shared out by length.
    static func retimed(
        _ old: [Word],
        to tokens: [String],
        within limits: ClosedRange<TimeInterval> = -TimeInterval.infinity...TimeInterval.infinity
    ) -> [Word] {
        guard let first = old.first, let last = old.last else {
            return tokens.map { Word(text: $0, start: 0, end: minimumWordSeconds) }
        }
        let oldKeys = old.map { key($0.text) }
        let newKeys = tokens.map(key)
        let pairs = commonSubsequence(oldKeys, newKeys)

        var times = [(start: TimeInterval, end: TimeInterval)?](repeating: nil, count: tokens.count)
        for (i, j) in pairs { times[j] = (old[i].start, old[i].end) }

        // Stretches between kept pairs, with the line's edges as pairs outside it.
        let anchors: [(i: Int, j: Int)] = [(-1, -1)] + pairs + [(old.count, tokens.count)]
        for (previous, next) in zip(anchors, anchors.dropFirst()) {
            var run = Array((previous.j + 1)..<next.j)
            guard !run.isEmpty else { continue }
            let replaced = (previous.i + 1)..<next.i
            var from: TimeInterval
            var to: TimeInterval
            if !replaced.isEmpty {
                from = old[replaced.lowerBound].start
                to = old[replaced.upperBound - 1].end
            } else {
                from = previous.i >= 0 ? old[previous.i].end : first.start
                to = next.i < old.count ? old[next.i].start : last.end
            }
            // Too little time for the new words: they share it with the kept word before
            // them (or after them, at the start of the line).
            if to - from < minimumWordSeconds * Double(run.count) {
                if previous.j >= 0, let kept = times[previous.j] {
                    from = kept.start
                    run.insert(previous.j, at: 0)
                } else if next.j < tokens.count, let kept = times[next.j] {
                    to = kept.end
                    run.append(next.j)
                }
                // Still too little: the run takes some of the silence after it (or before
                // it), but never a word outside it nor the lines either side.
                let needed = minimumWordSeconds * Double(run.count)
                let lower = run[0] > 0 ? (times[run[0] - 1]?.end ?? limits.lowerBound) : limits.lowerBound
                let upper = ((run[run.count - 1] + 1)..<tokens.count).lazy.compactMap { times[$0]?.start }.first
                    ?? limits.upperBound
                to = min(max(to, from + needed), max(upper, from))
                if to - from < needed { from = max(min(lower, from), to - needed) }
            }
            let weights = run.map { Double(max(1, tokens[$0].count)) }
            let total = weights.reduce(0, +)
            var cursor = from
            for (index, weight) in zip(run, weights) {
                let length = (to - from) * weight / total
                times[index] = (cursor, cursor + length)
                cursor += length
            }
        }
        return tokens.enumerated().map { index, text in
            let time = times[index] ?? (first.start, last.end)
            return Word(text: text, start: time.start, end: time.end)
        }
    }

    /// The word as compared across a correction: no case, accents or marks around it.
    static func key(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let letters = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return letters.isEmpty ? folded : String(String.UnicodeScalarView(letters))
    }

    /// Index pairs of a longest common subsequence, in order.
    static func commonSubsequence(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    // MARK: - Out

    /// The corrected subtitles as a session, for the `.srt`, text and Markdown exports.
    public var session: SessionTranscript {
        let words = lines.flatMap { line in
            line.words.enumerated().map { index, word in
                SessionTranscript.Word(
                    text: word.text,
                    start: word.start,
                    end: word.end,
                    startsParagraph: index == 0 && line.startsParagraph,
                    startsLine: index == 0 && line.startsLine
                )
            }
        }
        return SessionTranscript(words: words, duration: duration, startedAt: startedAt)
    }

    /// The lines as captions to burn into the picture.
    public var cues: [Cue] { cues(wordsPerCue: nil) }

    /// Captions of `wordsPerCue` words at a time (1–3), or whole lines when `nil` or 0. A
    /// caption never joins words of two lines, so a sentence end or a pause still
    /// starts a new one; it stays until the next one across a short gap, and a moment
    /// after its last word across a long one.
    public func cues(wordsPerCue: Int?) -> [Cue] {
        var groups: [(lineID: Int, words: [Word])] = []
        for line in lines {
            guard let size = wordsPerCue, size > 0 else {
                groups.append((line.id, line.words))
                continue
            }
            var start = 0
            while start < line.words.count {
                let end = min(line.words.count, start + size)
                groups.append((line.id, Array(line.words[start..<end])))
                start = end
            }
        }
        let wholeLines = (wordsPerCue ?? 0) <= 0
        let hold = wholeLines ? Self.holdSeconds : Self.holdSeconds * 0.6
        let minimum = wholeLines ? Self.minimumCueSeconds : 0.3
        groups.removeAll { $0.words.isEmpty }
        // Captions start in order and never overlap, whatever a correction did.
        var starts = groups.map { $0.words[0].start }
        for index in starts.indices.dropFirst() { starts[index] = max(starts[index], starts[index - 1]) }
        return groups.enumerated().map { index, group in
            let start = starts[index]
            let lastEnd = max(group.words[group.words.count - 1].end, start)
            let next = index + 1 < groups.count ? starts[index + 1] : nil
            var end = lastEnd + hold
            if let next, next - lastEnd <= Self.bridgedGapSeconds { end = next }
            end = max(end, start + minimum, start + 0.05)
            if let next { end = min(end, next) }
            return Cue(lineID: group.lineID, words: group.words, start: start, end: max(end, start))
        }
    }

    /// The subtitles as a `.srt`, `wordsPerCue` words to a cue (whole lines for 0), timed
    /// as the burnt-in captions are.
    public func subRip(wordsPerCue: Int) -> String {
        cues(wordsPerCue: wordsPerCue).enumerated().map { index, cue in
            "\(index + 1)\n\(TranscriptExport.timestamp(cue.start)) --> \(TranscriptExport.timestamp(cue.end))\n\(cue.text)\n"
        }
        .joined(separator: "\n")
    }

    // MARK: - Building the lines

    private struct Timed {
        let word: Word
        let startsParagraph: Bool
        let startsLine: Bool
    }

    /// Every word with a time: a word heard without one takes the gap after the word
    /// before it, as in the `.srt`.
    private static func timed(_ words: [SessionTranscript.Word]) -> [Timed] {
        var result: [Timed] = []
        var previousEnd: TimeInterval = 0
        for (index, word) in words.enumerated() {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let nextStart = words[(index + 1)...].lazy.compactMap(\.start).first
            var start = max(word.start ?? previousEnd, previousEnd)
            if let nextStart { start = min(start, nextStart) }
            var end = word.end ?? min(start + 0.3, nextStart ?? start + 0.3)
            end = max(end, start)
            result.append(Timed(
                word: Word(text: text, start: start, end: end),
                startsParagraph: word.startsParagraph,
                startsLine: word.startsLine
            ))
            previousEnd = end
        }
        return result
    }

    private static func lines(from words: [Timed]) -> [Line] {
        var lines: [Line] = []
        var current: [Timed] = []

        func flush() {
            guard let head = current.first else { return }
            lines.append(Line(
                id: lines.count,
                words: current.map(\.word),
                startsParagraph: head.startsParagraph,
                startsLine: head.startsLine
            ))
            current.removeAll()
        }

        func characters(_ words: some Collection<Timed>) -> Int {
            words.reduce(0) { $0 + $1.word.text.count } + max(0, words.count - 1)
        }

        for timed in words {
            if let last = current.last, let head = current.first {
                let breaks = timed.startsParagraph
                    || timed.startsLine
                    || endsSentence(last.word.text)
                    || timed.word.start - last.word.end >= pauseBreakSeconds
                    || timed.word.end - head.word.start > maximumLineSeconds
                if breaks {
                    flush()
                } else if characters(current) + 1 + timed.word.text.count > maximumCharacters {
                    // Rather after a comma in the line's latter part than mid-clause.
                    let cut = current.indices.last { index in
                        index < current.count - 1
                            && endsClause(current[index].word.text)
                            && characters(current[...index]) >= maximumCharacters / 3
                    }
                    if let cut {
                        let carried = Array(current[(cut + 1)...])
                        current.removeSubrange((cut + 1)...)
                        flush()
                        current = carried
                    } else {
                        flush()
                    }
                }
            }
            current.append(timed)
        }
        flush()
        return lines
    }

    private static let closers = CharacterSet(charactersIn: "\"'»”’)]")

    static func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: closers)
        return trimmed.last.map { ".?!…".contains($0) } ?? false
    }

    static func endsClause(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: closers)
        return trimmed.last.map { ",;:—".contains($0) } ?? false
    }
}
