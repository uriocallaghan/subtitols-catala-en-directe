import Foundation

/// A transcription kept on the device after listening: its words as heard, with their
/// times, and the text as the reader keeps it, which they can title, describe and correct.
///
/// The text is the record; the heard words only time it. A corrected text is timed again
/// against them (`session`), the way the subtitle editor times a corrected line: words
/// kept keep their times, new words share the time of the words they replaced.
public struct SavedTranscript: Codable, Identifiable, Equatable, Sendable {
    /// Bumped when the file's shape changes; older files are then left unread.
    public static let formatVersion = 1

    public var version: Int
    public let id: UUID
    /// What the reader called it; empty until they do (`displayTitle` stands in).
    public var title: String
    /// The one line under the title.
    public var summary: String
    /// When listening started.
    public let createdAt: Date
    public var modifiedAt: Date
    public let languageID: String?
    /// Seconds of audio heard.
    public let duration: TimeInterval
    /// The words as heard, with their times.
    public let heard: [SessionTranscript.Word]
    /// The text as the reader keeps it: one paragraph per line, a blank line between them.
    public var text: String

    public init(id: UUID = UUID(), session: SessionTranscript, languageID: String?, savedAt: Date = Date()) {
        version = Self.formatVersion
        self.id = id
        title = ""
        summary = ""
        createdAt = session.startedAt ?? savedAt
        modifiedAt = savedAt
        self.languageID = languageID
        duration = session.duration
        heard = session.words
        text = TranscriptExport.paragraphs(session).joined(separator: "\n\n")
    }

    /// The entry the list shows: everything but the heard words.
    public var listing: SavedTranscriptListing {
        SavedTranscriptListing(
            id: id,
            title: title,
            summary: summary,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            languageID: languageID,
            duration: duration,
            text: text
        )
    }

    // MARK: - The text, timed

    /// The text's paragraphs: every line that holds a word.
    public static func paragraphs(in text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The text as a session, for the exports: each word timed by the words heard.
    public var session: SessionTranscript {
        let paragraphs = Self.paragraphs(in: text)
        var tokens: [String] = []
        var opensParagraph: [Bool] = []
        for paragraph in paragraphs {
            for (index, token) in paragraph.split(whereSeparator: \.isWhitespace).enumerated() {
                tokens.append(String(token))
                opensParagraph.append(index == 0)
            }
        }
        let times = Self.times(of: tokens, heard: heard)
        let words = tokens.indices.map { index in
            SessionTranscript.Word(
                text: tokens[index],
                start: times[index]?.start,
                end: times[index]?.end,
                startsParagraph: opensParagraph[index]
            )
        }
        return SessionTranscript(words: words, duration: duration, startedAt: createdAt)
    }

    /// Beyond this many word pairs a corrected stretch is timed in proportion instead of
    /// by the common subsequence, whose table would take too much memory.
    static let largestAlignment = 4_000_000

    /// Each token's time. Only the stretch between the unchanged start and the unchanged
    /// end is aligned (with one unchanged word either side as its anchor): a reader's
    /// corrections are local, so even an hour's text aligns a few words.
    static func times(of tokens: [String], heard: [SessionTranscript.Word]) -> [(start: TimeInterval, end: TimeInterval)?] {
        guard !tokens.isEmpty else { return [] }
        let timed = timedHeard(heard)
        guard !timed.isEmpty else { return Array(repeating: nil, count: tokens.count) }
        if tokens == heard.map(\.text) { return timed.map { ($0.start, $0.end) } }

        let oldKeys = timed.map { SubtitleDocument.key($0.text) }
        let newKeys = tokens.map(SubtitleDocument.key)
        var prefix = 0
        while prefix < oldKeys.count, prefix < newKeys.count, oldKeys[prefix] == newKeys[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < oldKeys.count - prefix, suffix < newKeys.count - prefix,
              oldKeys[oldKeys.count - 1 - suffix] == newKeys[newKeys.count - 1 - suffix] { suffix += 1 }

        var times = [(start: TimeInterval, end: TimeInterval)?](repeating: nil, count: tokens.count)
        for index in 0..<prefix { times[index] = (timed[index].start, timed[index].end) }
        for offset in 0..<suffix {
            let old = timed[timed.count - 1 - offset]
            times[tokens.count - 1 - offset] = (old.start, old.end)
        }
        let newMiddle = prefix..<(tokens.count - suffix)
        guard !newMiddle.isEmpty else { return times }

        // One unchanged word either side anchors the stretch in time.
        let lower = max(0, prefix - 1)
        let oldUpper = min(timed.count, timed.count - suffix + 1)
        let newUpper = min(tokens.count, tokens.count - suffix + 1)
        let oldSlice = Array(timed[lower..<oldUpper])
        let newSlice = Array(tokens[lower..<newUpper])
        let retimed: [SubtitleDocument.Word]
        if oldSlice.count * newSlice.count <= largestAlignment {
            retimed = SubtitleDocument.retimed(oldSlice, to: newSlice)
        } else {
            let from = oldSlice.first?.start ?? 0
            let to = oldSlice.last?.end ?? from
            let share = (to - from) / Double(newSlice.count)
            retimed = newSlice.enumerated().map { index, text in
                SubtitleDocument.Word(text: text, start: from + share * Double(index), end: from + share * Double(index + 1))
            }
        }
        for index in newMiddle {
            let word = retimed[index - lower]
            times[index] = (word.start, word.end)
        }
        return times
    }

    /// The heard words with a time each: a word heard without one takes the end of the
    /// word before it. Empty when none was timed.
    private static func timedHeard(_ heard: [SessionTranscript.Word]) -> [SubtitleDocument.Word] {
        guard heard.contains(where: { $0.start != nil }) else { return [] }
        var previousEnd: TimeInterval = 0
        return heard.map { word in
            let start = word.start ?? previousEnd
            let end = max(word.end ?? (start + SubtitleDocument.minimumWordSeconds), start)
            previousEnd = end
            return SubtitleDocument.Word(text: word.text, start: start, end: end)
        }
    }

    // MARK: - Out

    /// The title the files take: the reader's, else the date's.
    public var exportTitle: String {
        let chosen = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return chosen.isEmpty ? TranscriptExport.title(for: session) : chosen
    }

    public func render(_ format: TranscriptExportFormat) -> String {
        let session = self.session
        switch format {
        case .text:
            return TranscriptExport.plainText(session)
        case .markdown:
            return TranscriptExport.markdown(session, title: exportTitle, description: summary)
        case .subtitles:
            return TranscriptExport.subRip(session)
        }
    }

    /// For Notes: the title, the description, then the text.
    public var note: String {
        var parts = [exportTitle]
        let line = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { parts.append(line) }
        return parts.joined(separator: "\n") + "\n\n" + TranscriptExport.plainText(session)
    }

    public func filename(for format: TranscriptExportFormat) -> String {
        TranscriptExport.filename(title: title, fallback: session, format: format)
    }
}

/// What the list of transcriptions needs of each: no heard words, so the whole list loads
/// at once however long the recordings were.
public struct SavedTranscriptListing: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var summary: String
    public let createdAt: Date
    public var modifiedAt: Date
    public let languageID: String?
    public let duration: TimeInterval
    public var text: String

    public init(
        id: UUID,
        title: String,
        summary: String,
        createdAt: Date,
        modifiedAt: Date,
        languageID: String?,
        duration: TimeInterval,
        text: String
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.languageID = languageID
        self.duration = duration
        self.text = text
    }

    public var hasTitle: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The reader's title, else the start of what was said, as Notes does.
    public var displayTitle: String {
        hasTitle ? title.trimmingCharacters(in: .whitespacesAndNewlines) : automaticTitle
    }

    /// The first sentence when it is short, else its first words.
    public var automaticTitle: String {
        Self.opening(of: text).title
    }

    /// The line under the title: the reader's description, else the words that follow
    /// the title.
    public var detailLine: String {
        let line = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { return line }
        return hasTitle ? Self.flattened(text) : Self.opening(of: text).rest
    }

    public var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Whether the transcription holds `query`, ignoring case and accents.
    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return [title, summary, text].contains { $0.range(of: needle, options: options) != nil }
    }

    static let titleWords = 7

    /// The title made from the text, and what follows it, on one line.
    static func opening(of text: String) -> (title: String, rest: String) {
        let words = flattened(String(text.prefix(600))).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return ("", "") }
        var count = min(words.count, titleWords)
        if let end = words.prefix(titleWords).firstIndex(where: SubtitleDocument.endsSentence) {
            count = end + 1
        }
        var title = words.prefix(count).joined(separator: " ")
        // A full stop or a comma ends a title badly; a question keeps its mark.
        while let last = title.last, ".,;:".contains(last) { title.removeLast() }
        if count < words.count, !SubtitleDocument.endsSentence(words[count - 1]) { title += "…" }
        return (title, words.dropFirst(count).prefix(40).joined(separator: " "))
    }

    /// The text on one line, as a preview.
    static func flattened(_ text: String) -> String {
        String(text.prefix(400))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

/// Where transcriptions are kept: one JSON file per transcription, and an index of their
/// listings so the list opens without reading every recording's words.
public struct TranscriptStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    private var indexURL: URL { root.appendingPathComponent("index.json") }

    private func url(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).json")
    }

    /// The listings, newest first. The index is rebuilt from the files when it is missing,
    /// unreadable or out of step with them (a write cut short by the app closing).
    public func listings() -> [SavedTranscriptListing] {
        let files = transcriptFiles()
        let ids = Set(files.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
        if let data = try? Data(contentsOf: indexURL),
           let index = try? JSONDecoder().decode([SavedTranscriptListing].self, from: data),
           Set(index.map(\.id)) == ids {
            return Self.sorted(index)
        }
        let rebuilt = files.compactMap { file -> SavedTranscriptListing? in
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { return nil }
            return load(id)?.listing
        }
        try? writeIndex(rebuilt)
        return Self.sorted(rebuilt)
    }

    public func load(_ id: UUID) -> SavedTranscript? {
        guard let data = try? Data(contentsOf: url(for: id)),
              let saved = try? JSONDecoder().decode(SavedTranscript.self, from: data),
              saved.version == SavedTranscript.formatVersion else { return nil }
        return saved
    }

    /// Keeps a transcription, then the index it belongs to, each in one atomic write.
    public func save(_ transcript: SavedTranscript, index: [SavedTranscriptListing]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(transcript).write(to: url(for: transcript.id), options: .atomic)
        try writeIndex(index)
    }

    public func remove(_ id: UUID, index: [SavedTranscriptListing]) {
        try? FileManager.default.removeItem(at: url(for: id))
        try? writeIndex(index)
    }

    public func writeIndex(_ index: [SavedTranscriptListing]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
    }

    private func transcriptFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return files.filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }
    }

    public static func sorted(_ listings: [SavedTranscriptListing]) -> [SavedTranscriptListing] {
        listings.sorted { $0.createdAt > $1.createdAt }
    }
}
