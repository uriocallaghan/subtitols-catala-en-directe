/// What VoiceOver (and a braille display) should say while the transcript runs.
///
/// The reading pane is one element whose label is the whole text, which a VoiceOver user
/// can read back at any time; but nobody hears new text unless it is announced. Only
/// settled words are announced, since they are final: announcing the live tail would read
/// words the recogniser is about to change. They are gathered into phrases: a sentence
/// end, a new paragraph (a pause or another voice) or `maximumWords` closes one, and the
/// view flushes what is left after a quiet moment, so one announcement never cuts
/// another short in mid-word.
public struct TranscriptAnnouncer: Sendable {
    public static let maximumWords = 14

    private var spoken: Set<UInt64> = []
    private var pending: [String] = []

    public init() {}

    /// Marks `words` as already heard, so opening the screen, or switching VoiceOver on,
    /// does not read out everything that is on it.
    public mutating func reset(markingSpoken words: [StableTranscriptWord]) {
        spoken = Set(words.map(\.id))
        pending = []
    }

    /// Takes the settled words and returns the phrases that are ready to announce, in order.
    public mutating func observe(committed words: [StableTranscriptWord]) -> [String] {
        var ready: [String] = []
        for word in words where !spoken.contains(word.id) {
            if word.startsParagraph, let phrase = flush() { ready.append(phrase) }
            pending.append(word.text)
            if Self.endsSentence(word.text) || pending.count >= Self.maximumWords,
               let phrase = flush() {
                ready.append(phrase)
            }
        }
        // Only the words still in the list can come back; the list is bounded, so this is too.
        spoken = Set(words.map(\.id))
        return ready
    }

    /// The words gathered since the last announcement, if any.
    public mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        defer { pending = [] }
        return pending.joined(separator: " ")
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".?!…:".contains(last)
    }
}
