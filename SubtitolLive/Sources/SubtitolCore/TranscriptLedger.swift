import Foundation

public struct RecognizedWord: Equatable, Sendable {
    public let text: String
    public let startMilliseconds: Int32
    public let endMilliseconds: Int32
    public let confidence: Float?

    public init(
        text: String,
        startMilliseconds: Int32,
        endMilliseconds: Int32,
        confidence: Float?
    ) {
        self.text = text
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.confidence = confidence
    }
}

public struct TranscriptLedger: Sendable {
    public struct Word: Equatable, Sendable {
        public let text: String
        public let startSequence: UInt64
        public let endSequence: UInt64
        public let confidence: Float?
    }

    public private(set) var words: [Word] = []

    public init() {}

    public mutating func reset() {
        words.removeAll(keepingCapacity: true)
    }

    public mutating func merge(
        words incoming: [RecognizedWord],
        windowStartSequence: UInt64,
        windowEndSequence: UInt64,
        sampleRate: Int32,
        isInitialWindow: Bool
    ) {
        guard sampleRate > 0, windowEndSequence >= windowStartSequence else { return }

        let boundaryGuardMilliseconds: Int32 = isInitialWindow ? 0 : 250
        let mapped = incoming.compactMap { word -> Word? in
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  word.endMilliseconds >= word.startMilliseconds,
                  word.startMilliseconds >= boundaryGuardMilliseconds else { return nil }

            let startOffset = Self.samples(for: word.startMilliseconds, sampleRate: sampleRate)
            let endOffset = Self.samples(for: word.endMilliseconds, sampleRate: sampleRate)
            return Word(
                text: text,
                startSequence: min(windowStartSequence &+ startOffset, windowEndSequence),
                endSequence: min(windowStartSequence &+ endOffset, windowEndSequence),
                confidence: word.confidence
            )
        }

        let guardedStart = windowStartSequence &+ Self.samples(
            for: boundaryGuardMilliseconds,
            sampleRate: sampleRate
        )
        let replacementStart = min(guardedStart, windowEndSequence)
        let replacementEnd = windowEndSequence

        words.removeAll { existing in
            existing.startSequence >= replacementStart
                && existing.startSequence <= replacementEnd
        }
        words.append(contentsOf: mapped)
        words.sort {
            if $0.startSequence == $1.startSequence { return $0.endSequence < $1.endSequence }
            return $0.startSequence < $1.startSequence
        }
    }

    public func visibleTail(limit: Int) -> String {
        visibleTailWords(limit: limit).map(\.text).joined(separator: " ")
    }

    /// The same tail as `visibleTail`, but keeping the sequence positions the UI needs
    /// to tell settled words from ones the recognizer can still revise.
    public func visibleTailWords(limit: Int) -> [Word] {
        guard limit > 0 else { return [] }
        return Array(words.suffix(limit))
    }

    private static func samples(for milliseconds: Int32, sampleRate: Int32) -> UInt64 {
        guard milliseconds > 0 else { return 0 }
        return UInt64(milliseconds) * UInt64(sampleRate) / 1_000
    }
}
