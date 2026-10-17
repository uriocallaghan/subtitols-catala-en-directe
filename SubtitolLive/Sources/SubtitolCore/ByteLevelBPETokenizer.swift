import Foundation

/// RoBERTa's byte-level BPE, for words that arrive already split.
///
/// Mirrors Hugging Face `tokenizers` with a ByteLevel pre-tokenizer
/// (`add_prefix_space: true`, `use_regex: true`) and `is_split_into_words=True`: every
/// word is prefixed with a space, cut by the GPT-2 pattern, mapped byte by byte onto
/// printable characters and merged by rank. The punctuation model depends on
/// reproducing Python's ids exactly, which the unit tests check against a fixture.
public final class ByteLevelBPETokenizer: @unchecked Sendable {
    public static let beginningOfSequence: Int32 = 0
    public static let endOfSequence: Int32 = 2
    public static let unknown: Int32 = 3

    private static let pattern = try! NSRegularExpression(
        pattern: #"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"#
    )
    private static let byteEncoder: [Character] = {
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var characters = bytes
        var next = 0
        for byte in 0...255 where !bytes.contains(byte) {
            bytes.append(byte)
            characters.append(256 + next)
            next += 1
        }
        var table = [Character](repeating: " ", count: 256)
        for (byte, scalar) in zip(bytes, characters) {
            table[byte] = Character(Unicode.Scalar(UInt32(scalar))!)
        }
        return table
    }()

    private let vocabulary: [String: Int32]
    private let mergeRanks: [String: Int]
    private let lock = NSLock()
    private var wordCache: [String: [Int32]] = [:]

    public init(vocabulary: [String: Int32], merges: [String]) {
        self.vocabulary = vocabulary
        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(merges.count)
        for (rank, merge) in merges.enumerated() where !merge.isEmpty {
            ranks[merge] = rank
        }
        mergeRanks = ranks
    }

    /// Loads `vocab.json` (token → id) and `merges.txt` (one "left right" pair per line).
    public convenience init(vocabularyURL: URL, mergesURL: URL) throws {
        let vocabulary = try JSONDecoder().decode([String: Int32].self, from: Data(contentsOf: vocabularyURL))
        let merges = try String(contentsOf: mergesURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("#version") }
        self.init(vocabulary: vocabulary, merges: merges)
    }

    /// Token ids for one word, without special tokens.
    public func tokens(forWord word: String) -> [Int32] {
        lock.lock()
        if let cached = wordCache[word] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let text = " " + word
        let range = NSRange(text.startIndex..., in: text)
        var ids: [Int32] = []
        for match in Self.pattern.matches(in: text, range: range) {
            guard let pieceRange = Range(match.range, in: text) else { continue }
            let mapped = String(text[pieceRange].utf8.map { Self.byteEncoder[Int($0)] })
            for token in bytePairEncode(mapped) {
                ids.append(vocabulary[token] ?? Self.unknown)
            }
        }

        lock.lock()
        if wordCache.count > 20_000 { wordCache.removeAll(keepingCapacity: true) }
        wordCache[word] = ids
        lock.unlock()
        return ids
    }

    /// `<s> word tokens… </s>`, and for each word the position of its first token.
    public func encode(words: [String]) -> (ids: [Int32], firstTokenPositions: [Int]) {
        var ids: [Int32] = [Self.beginningOfSequence]
        var positions: [Int] = []
        positions.reserveCapacity(words.count)
        for word in words {
            positions.append(ids.count)
            ids.append(contentsOf: tokens(forWord: word))
        }
        ids.append(Self.endOfSequence)
        return (ids, positions)
    }

    private func bytePairEncode(_ piece: String) -> [String] {
        var parts = piece.map { String($0) }
        guard parts.count > 1 else { return parts }
        while true {
            var bestRank = Int.max
            var bestIndex = -1
            for index in 0..<(parts.count - 1) {
                if let rank = mergeRanks[parts[index] + " " + parts[index + 1]], rank < bestRank {
                    bestRank = rank
                    bestIndex = index
                }
            }
            guard bestIndex >= 0 else { return parts }
            // Merge every occurrence of the best pair, left to right, as BPE does.
            let left = parts[bestIndex]
            let right = parts[bestIndex + 1]
            var merged: [String] = []
            merged.reserveCapacity(parts.count)
            var index = 0
            while index < parts.count {
                if index < parts.count - 1, parts[index] == left, parts[index + 1] == right {
                    merged.append(left + right)
                    index += 2
                } else {
                    merged.append(parts[index])
                    index += 1
                }
            }
            parts = merged
            if parts.count == 1 { return parts }
        }
    }
}
