import CoreGraphics
import Foundation

public struct StableTranscriptWord: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let text: String
    /// True once the word is old enough that no interim window can revise it again.
    public let isCommitted: Bool
    /// Strictly increasing reading-order position used by the roll-up watermark. Identity
    /// is carried separately by `id`, so inserting a provisional word may change this
    /// position without destroying and rebuilding its view.
    public let anchor: UInt64

    public init(
        id: UInt64,
        text: String,
        isCommitted: Bool = false,
        anchor: UInt64 = 0
    ) {
        self.id = id
        self.text = text
        self.isCommitted = isCommitted
        self.anchor = anchor
    }
}

/// A word as offered by the recognizer, before identity is assigned.
public struct TranscriptWordInput: Equatable, Sendable {
    public let text: String
    public let isCommitted: Bool
    /// Strictly increasing reading-order position; see `StableTranscriptWord.anchor`.
    public let anchor: UInt64

    public init(text: String, isCommitted: Bool = false, anchor: UInt64 = 0) {
        self.text = text
        self.isCommitted = isCommitted
        self.anchor = anchor
    }
}

/// Keeps the identity of words that survive an interim ASR correction.
///
/// Committed and volatile words are reconciled differently on purpose. A committed word
/// cannot be revised any more — it can only slide out of the retained tail — so its
/// identity is recovered by finding that slide, never by re-matching text. Only the
/// volatile suffix goes through a diff. That split is what keeps identities from
/// rotating inside the region the reader is actually looking at.
public struct TranscriptWordReconciler: Sendable {
    public private(set) var words: [StableTranscriptWord] = []

    /// The oldest committed words are settled and safe to match on. The newest ones are
    /// not: a word can be revised in the very update that ages it past the commit
    /// horizon, so anchoring on it would fail to find the slide.
    private static let committedAnchorLength = 8

    private var nextID: UInt64 = 1

    public init() {}

    public mutating func reset() {
        words.removeAll(keepingCapacity: true)
    }

    /// Convenience for callers with no commit information; every word is volatile.
    @discardableResult
    public mutating func reconcile(_ text: String) -> [StableTranscriptWord] {
        reconcile(
            text
                .split(whereSeparator: { $0.isWhitespace })
                .map { TranscriptWordInput(text: String($0)) }
        )
    }

    @discardableResult
    public mutating func reconcile(
        _ incoming: [TranscriptWordInput]
    ) -> [StableTranscriptWord] {
        guard !incoming.isEmpty else {
            words.removeAll(keepingCapacity: true)
            return words
        }

        let committedCount = incoming.prefix(while: { $0.isCommitted }).count
        let incomingKeys = incoming.map { Self.matchKey($0.text) }
        let oldKeys = words.map { Self.matchKey($0.text) }
        let incomingCommittedKeys = incoming.map { Self.committedMatchKey($0.text) }
        let oldCommittedKeys = words.map { Self.committedMatchKey($0.text) }

        var reusedIDs = [Int: UInt64](minimumCapacity: incoming.count)
        let slide = Self.slideOffset(
            oldKeys: oldCommittedKeys,
            incomingKeys: incomingCommittedKeys,
            committedCount: committedCount
        )

        if let slide {
            for index in 0..<committedCount where slide + index < words.count {
                reusedIDs[index] = words[slide + index].id
            }
        }

        // Only the volatile suffix can actually change, so only it needs diffing.
        let volatileOldStart = min((slide ?? 0) + committedCount, words.count)
        let matches = Self.commonSubsequenceMatches(
            oldKeys: Array(oldKeys[volatileOldStart...]),
            newKeys: Array(incomingKeys[committedCount...])
        )
        for (newOffset, oldOffset) in matches {
            reusedIDs[committedCount + newOffset] = words[volatileOldStart + oldOffset].id
        }

        words = incoming.enumerated().map { index, token in
            let id: UInt64
            if let reused = reusedIDs[index] {
                id = reused
            } else {
                id = nextID
                nextID &+= 1
            }
            return StableTranscriptWord(
                id: id,
                text: token.text,
                isCommitted: token.isCommitted,
                anchor: token.anchor
            )
        }
        return words
    }

    /// How far the retained window has slid since the last update, found by anchoring on
    /// the oldest committed words. `nil` means no alignment exists and the caller should
    /// fall back to diffing everything.
    private static func slideOffset(
        oldKeys: [String],
        incomingKeys: [String],
        committedCount: Int
    ) -> Int? {
        guard committedCount > 0 else { return 0 }
        let anchor = min(committedCount, committedAnchorLength)
        guard oldKeys.count >= anchor else { return nil }

        for offset in 0...(oldKeys.count - anchor) {
            var matches = true
            for index in 0..<anchor where oldKeys[offset + index] != incomingKeys[index] {
                matches = false
                break
            }
            if matches { return offset }
        }
        return nil
    }

    /// Longest common subsequence, returned as (new index, old index) pairs.
    private static func commonSubsequenceMatches(
        oldKeys: [String],
        newKeys: [String]
    ) -> [(Int, Int)] {
        let oldCount = oldKeys.count
        let newCount = newKeys.count
        guard oldCount > 0, newCount > 0 else { return [] }

        let columns = newCount + 1
        var table = [Int](repeating: 0, count: (oldCount + 1) * columns)
        for oldIndex in stride(from: oldCount - 1, through: 0, by: -1) {
            for newIndex in stride(from: newCount - 1, through: 0, by: -1) {
                let index = oldIndex * columns + newIndex
                if oldKeys[oldIndex] == newKeys[newIndex] {
                    table[index] = 1 + table[(oldIndex + 1) * columns + newIndex + 1]
                } else {
                    table[index] = max(
                        table[(oldIndex + 1) * columns + newIndex],
                        table[oldIndex * columns + newIndex + 1]
                    )
                }
            }
        }

        var matches: [(Int, Int)] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldCount, newIndex < newCount {
            if oldKeys[oldIndex] == newKeys[newIndex] {
                matches.append((newIndex, oldIndex))
                oldIndex += 1
                newIndex += 1
            } else if table[(oldIndex + 1) * columns + newIndex]
                        >= table[oldIndex * columns + newIndex + 1] {
                oldIndex += 1
            } else {
                newIndex += 1
            }
        }
        return matches
    }

    private static func matchKey(_ word: String) -> String {
        word
            .trimmingCharacters(in: .punctuationCharacters)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func committedMatchKey(_ word: String) -> String {
        word
            .trimmingCharacters(in: .punctuationCharacters)
            .folding(options: [.caseInsensitive], locale: .current)
    }
}
