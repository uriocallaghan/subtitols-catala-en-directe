import Foundation

/// Everything said in one recording session, from Start to Stop, as the reader saw it:
/// punctuated, with its paragraphs, and with each word's time from the session start.
///
/// The stabiliser keeps only a bounded tail of committed words, so the session is kept
/// here instead. A word joins the record once it has slid out of the front of the
/// snapshot, which only settled words do; everything still in the snapshot is taken
/// from the newest one, so revisions and the final correction replace it.
public struct SessionTranscript: Equatable, Sendable {
    public struct Word: Codable, Equatable, Sendable {
        public let text: String
        /// Seconds from the start of the session; `nil` for a word heard without timings.
        public let start: TimeInterval?
        public let end: TimeInterval?
        public let startsParagraph: Bool
        public let startsLine: Bool

        public init(
            text: String,
            start: TimeInterval?,
            end: TimeInterval?,
            startsParagraph: Bool = false,
            startsLine: Bool = false
        ) {
            self.text = text
            self.start = start
            self.end = end
            self.startsParagraph = startsParagraph
            self.startsLine = startsLine
        }
    }

    public private(set) var startedAt: Date?
    /// Seconds of audio the session has heard.
    public private(set) var duration: TimeInterval = 0
    private var archived: [Word] = []
    private var live: [StableTranscriptWord] = []
    private var sampleRate: Int32 = 0

    public init() {}

    /// A finished session made of `words`, as the subtitle editor hands it back.
    public init(words: [Word], duration: TimeInterval, startedAt: Date?) {
        self.archived = words
        self.duration = duration
        self.startedAt = startedAt
    }

    /// Starts a new session; whatever the last one held is gone.
    public mutating func begin(at date: Date = Date()) {
        self = SessionTranscript()
        startedAt = date
    }

    /// Takes a formatted snapshot of this session.
    public mutating func observe(_ snapshot: ReadableTranscriptSnapshot) {
        if let rate = snapshot.sampleRate, rate > 0 { sampleRate = rate }
        let incoming = snapshot.words
        if let front = incoming.first?.anchor {
            let present = Set(incoming.map(\.id))
            archived += live
                .filter { $0.anchor < front && !present.contains($0.id) }
                .map(word)
        }
        live = incoming
        if let end = snapshot.audioEndSequence, sampleRate > 0 {
            duration = max(duration, Double(end) / Double(sampleRate))
        }
    }

    public var words: [Word] { archived + live.map(word) }
    public var isEmpty: Bool { archived.isEmpty && live.isEmpty }
    public var wordCount: Int { archived.count + live.count }

    private func word(_ word: StableTranscriptWord) -> Word {
        func seconds(_ sequence: UInt64?) -> TimeInterval? {
            guard let sequence, sampleRate > 0 else { return nil }
            return Double(sequence) / Double(sampleRate)
        }
        return Word(
            text: word.text,
            start: seconds(word.startSequence),
            end: seconds(word.endSequence),
            startsParagraph: word.startsParagraph,
            startsLine: word.startsLine
        )
    }
}

/// The files a session can be exported as.
public enum TranscriptExportFormat: String, CaseIterable, Identifiable, Sendable {
    case text
    case markdown
    case subtitles

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .text: "txt"
        case .markdown: "md"
        case .subtitles: "srt"
        }
    }

    public var mimeType: String {
        switch self {
        case .text: "text/plain"
        case .markdown: "text/markdown"
        case .subtitles: "application/x-subrip"
        }
    }
}

public enum TranscriptExport {
    /// The session in `format`.
    public static func render(_ session: SessionTranscript, as format: TranscriptExportFormat) -> String {
        switch format {
        case .text: plainText(session)
        case .markdown: markdown(session)
        case .subtitles: subRip(session)
        }
    }

    /// "Subtítol Live 2026-09-27 10.42.txt": sorts by date, and has no characters a
    /// file system or AirDrop objects to.
    public static func filename(for session: SessionTranscript, format: TranscriptExportFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let stamp = formatter.string(from: session.startedAt ?? Date())
        return "duna \(stamp).\(format.fileExtension)"
    }

    /// The reader's title as a file name, without the characters a file system or
    /// AirDrop objects to; the date's name when there is none.
    public static func filename(title: String, fallback session: SessionTranscript, format: TranscriptExportFormat) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        let cleaned = title.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
            .split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !cleaned.isEmpty else { return filename(for: session, format: format) }
        return "\(cleaned.prefix(80)).\(format.fileExtension)"
    }

    /// "Transcripció · 27 de setembre de 2026, 10:42", in the interface language. The
    /// first line of a note in Notes becomes its title.
    public static func title(for session: SessionTranscript) -> String {
        let formatter = DateFormatter()
        formatter.locale = InterfaceLanguage.locale
        formatter.setLocalizedDateFormatFromTemplate("dMMMMyHHmm")
        let date = formatter.string(from: session.startedAt ?? Date())
        return localized("Transcripció · \(date)")
    }

    /// "4 min 12 s", "38 s", "1 h 02 min".
    public static func durationLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let rest = total % 60
        if hours > 0 { return String(format: "%d h %02d min", hours, minutes) }
        if minutes > 0 { return "\(minutes) min \(rest) s" }
        return "\(rest) s"
    }

    /// Paragraphs as the reader saw them, separated by a blank line.
    public static func paragraphs(_ session: SessionTranscript) -> [String] {
        var paragraphs: [String] = []
        var current: [String] = []
        for word in session.words {
            if word.startsParagraph, !current.isEmpty {
                paragraphs.append(current.joined(separator: " "))
                current.removeAll()
            }
            current.append(word.text)
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        return paragraphs
    }

    public static func plainText(_ session: SessionTranscript) -> String {
        let body = paragraphs(session).joined(separator: "\n\n")
        return body.isEmpty ? "" : body + "\n"
    }

    /// For Notes: the title on the first line, then the text.
    public static func note(_ session: SessionTranscript) -> String {
        title(for: session) + "\n\n" + plainText(session)
    }

    /// `title` and `description` are a kept transcription's own (`SavedTranscript`).
    public static func markdown(_ session: SessionTranscript, title chosen: String? = nil, description: String? = nil) -> String {
        var lines = ["# \(escapedMarkdown(chosen ?? title(for: session)))", ""]
        if let description = description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            lines.append(escapedMarkdown(description))
            lines.append("")
        }
        lines.append("*duna · \(durationLabel(session.duration)) · \(localized("\(session.wordCount) paraules"))*")
        for paragraph in paragraphs(session) {
            lines.append("")
            lines.append(escapedMarkdown(paragraph))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One cue per word, each on screen while it is said. A cue runs on to the next word
    /// across a short gap, so the captions do not flicker between words; across a real
    /// pause the screen is left empty. A word heard without timings takes the gap after
    /// the word before it.
    public static func subRip(_ session: SessionTranscript) -> String {
        let words = session.words
        var cues: [String] = []
        var previousEnd: TimeInterval = 0
        for (index, word) in words.enumerated() {
            let nextStart = words[(index + 1)...].lazy.compactMap(\.start).first
            var start = max(word.start ?? previousEnd, previousEnd)
            var end = word.end ?? (start + estimatedWordSeconds)
            if let nextStart {
                if nextStart - end <= bridgedGapSeconds { end = nextStart }
                end = min(end, nextStart)
                start = min(start, nextStart)
            }
            end = max(end, start + minimumCueSeconds)
            cues.append("\(cues.count + 1)\n\(timestamp(start)) --> \(timestamp(end))\n\(word.text)\n")
            previousEnd = end
        }
        return cues.joined(separator: "\n")
    }

    static let bridgedGapSeconds: TimeInterval = 0.3
    static let estimatedWordSeconds: TimeInterval = 0.3
    static let minimumCueSeconds: TimeInterval = 0.05

    /// "00:01:02,345"
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let milliseconds = Int((max(0, seconds) * 1_000).rounded())
        return String(
            format: "%02d:%02d:%02d,%03d",
            milliseconds / 3_600_000,
            milliseconds / 60_000 % 60,
            milliseconds / 1_000 % 60,
            milliseconds % 1_000
        )
    }

    /// Transcribed speech is prose: characters Markdown would read as formatting are
    /// escaped, and a paragraph that starts like a list or a heading is kept as text.
    public static func escapedMarkdown(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if "\\`*_[]<>#|".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        if let first = escaped.first, "-+".contains(first) { escaped = "\\" + escaped }
        let digits = escaped.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, escaped.dropFirst(digits.count).first == "." {
            escaped.insert("\\", at: escaped.index(escaped.startIndex, offsetBy: digits.count))
        }
        return escaped
    }
}
