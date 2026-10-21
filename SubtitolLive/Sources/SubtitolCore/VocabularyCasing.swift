import Foundation

/// Writes the vocabulary's terms as the user typed them. The Conformer writes
/// lowercase, so a boosted "Korotkoff" arrives as "korotkoff"; the reader should see
/// the name as it was given. A term of several words ("Artur Mas") is matched as a
/// run of words, so "mas" on its own stays as it is; a term of one word matches
/// wherever it appears. Accents must match; case and the marks around a word do not.
public struct VocabularyCasing: Sendable {
    private struct Term {
        let words: [String]
        let keys: [String]
    }

    private let terms: [Term]

    public init(_ vocabulary: [String]) {
        terms = vocabulary.compactMap { term in
            let words = term.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !words.isEmpty, words.contains(where: { $0 != $0.lowercased() }) else { return nil }
            return Term(words: words, keys: words.map(Self.key))
        }
        .sorted { $0.words.count > $1.words.count }
    }

    public var isEmpty: Bool { terms.isEmpty }

    public func apply(to snapshot: ReadableTranscriptSnapshot) -> ReadableTranscriptSnapshot {
        guard !terms.isEmpty else { return snapshot }
        let committed = snapshot.committedWords
        let provisional = snapshot.provisionalWords
        var texts = (committed + provisional).map(\.text)
        let keys = texts.map(Self.key)
        var taken = [Bool](repeating: false, count: texts.count)
        for term in terms {
            var index = 0
            while index + term.keys.count <= keys.count {
                if !taken[index], Array(keys[index..<(index + term.keys.count)]) == term.keys {
                    for offset in term.words.indices {
                        texts[index + offset] = Self.recased(texts[index + offset], as: term.words[offset])
                        taken[index + offset] = true
                    }
                    index += term.keys.count
                } else {
                    index += 1
                }
            }
        }
        func rewritten(_ words: [StableTranscriptWord], from offset: Int) -> [StableTranscriptWord] {
            words.enumerated().map { position, word in
                let text = texts[offset + position]
                guard text != word.text else { return word }
                return StableTranscriptWord(
                    id: word.id, text: text, isCommitted: word.isCommitted, anchor: word.anchor,
                    startSequence: word.startSequence, endSequence: word.endSequence,
                    startsParagraph: word.startsParagraph, startsLine: word.startsLine, confidence: word.confidence
                )
            }
        }
        return ReadableTranscriptSnapshot(
            committedWords: rewritten(committed, from: 0),
            provisionalWords: rewritten(provisional, from: committed.count),
            latestCommittedEndSequence: snapshot.latestCommittedEndSequence,
            latestVisibleEndSequence: snapshot.latestVisibleEndSequence,
            audioEndSequence: snapshot.audioEndSequence,
            sampleRate: snapshot.sampleRate,
            lastHeardEndSequence: snapshot.lastHeardEndSequence
        )
    }

    /// The word without the marks around it, lowercased.
    private static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }

    /// `text` with its letters replaced by the term's spelling, keeping the marks
    /// around it ("korotkoff," → "Korotkoff,").
    private static func recased(_ text: String, as term: String) -> String {
        let core = text.trimmingCharacters(in: .punctuationCharacters)
        guard let range = text.range(of: core) else { return text }
        return text.replacingCharacters(in: range, with: term)
    }
}
