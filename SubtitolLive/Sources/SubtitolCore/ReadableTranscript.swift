import Foundation

public struct TranscriptObservationWord: Equatable, Sendable {
    public let text: String
    public let startSequence: UInt64
    public let endSequence: UInt64
    public let confidence: Float?

    public init(text: String, startSequence: UInt64, endSequence: UInt64, confidence: Float?) {
        self.text = text
        self.startSequence = startSequence
        self.endSequence = endSequence
        self.confidence = confidence
    }
}

public struct ReadableTranscriptSnapshot: Equatable, Sendable {
    public let committedWords: [StableTranscriptWord]
    public let provisionalWords: [StableTranscriptWord]
    public let latestCommittedEndSequence: UInt64?
    public let latestVisibleEndSequence: UInt64?
    /// Newest audio the snapshot accounts for, and its clock rate.
    public let audioEndSequence: UInt64?
    public let sampleRate: Int32?
    /// End of the newest word the recogniser has heard, shown yet or not. Silence since
    /// then is a pause the speaker is making right now.
    public let lastHeardEndSequence: UInt64?

    public init(
        committedWords: [StableTranscriptWord] = [],
        provisionalWords: [StableTranscriptWord] = [],
        latestCommittedEndSequence: UInt64? = nil,
        latestVisibleEndSequence: UInt64? = nil,
        audioEndSequence: UInt64? = nil,
        sampleRate: Int32? = nil,
        lastHeardEndSequence: UInt64? = nil
    ) {
        self.committedWords = committedWords
        self.provisionalWords = provisionalWords
        self.latestCommittedEndSequence = latestCommittedEndSequence
        self.latestVisibleEndSequence = latestVisibleEndSequence
        self.audioEndSequence = audioEndSequence
        self.sampleRate = sampleRate
        self.lastHeardEndSequence = lastHeardEndSequence
    }

    public var words: [StableTranscriptWord] { committedWords + provisionalWords }
    public var text: String { words.map(\.text).joined(separator: " ") }

    /// Seconds the speaker has been silent since the newest word heard.
    public var trailingSilence: TimeInterval? {
        guard let sampleRate, sampleRate > 0, let audioEndSequence, let lastHeardEndSequence else { return nil }
        return audioEndSequence > lastHeardEndSequence
            ? Double(audioEndSequence - lastHeardEndSequence) / Double(sampleRate) : 0
    }
}

public enum TranscriptTimingQuality: String, Equatable, Sendable {
    case wordOffsets
    case estimated

    public static func classify(
        transcriptText: String,
        timedWordTexts: [String]
    ) -> TranscriptTimingQuality {
        let transcriptTokens = normalizedTokens(in: transcriptText)
        let timedTokens = timedWordTexts.compactMap { normalizedToken($0) }
        return transcriptTokens == timedTokens ? .wordOffsets : .estimated
    }

    public static func spansAreTrustworthy(
        _ spans: [(start: UInt64, end: UInt64)]
    ) -> Bool {
        guard spans.allSatisfy({ $0.end > $0.start }) else { return false }
        return zip(spans, spans.dropFirst()).allSatisfy { previous, current in
            previous.start <= current.start && previous.end <= current.end
        }
    }

    private static func normalizedTokens(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap {
            normalizedToken(String($0))
        }
    }

    private static func normalizedToken(_ text: String) -> String? {
        let normalized = text
            .trimmingCharacters(in: .punctuationCharacters)
            .folding(options: [.caseInsensitive], locale: .current)
        return normalized.isEmpty ? nil : normalized
    }
}

public enum FinalCorrectionDisposition: String, Equatable, Sendable {
    case notFinalized
    case corrected
    case preservedBecauseTimingUnavailable
}

/// Turns independent full-window hypotheses into an append-only settled prefix and a
/// short, hysteretic visible tail. Raw candidates are separate from what the user sees:
/// candidates must earn publication and alternatives must earn replacement.
public struct ReadableTranscriptStabilizer: Sendable {
    private struct Candidate: Sendable {
        let id: UInt64
        let text: String
        let alignmentKey: String
        let confirmationKey: String
        let startSequence: UInt64
        let endSequence: UInt64
        let confidence: Float?
        /// Windows in a row that heard this form.
        let confirmations: Int
        /// Every form heard at this place since the word first appeared, by exact key.
        let votes: [String: Vote]
        /// Windows that heard some word at this place, whatever its form.
        let heard: Int

        struct Vote: Sendable {
            let text: String
            let count: Int
            /// Sum of the hearings' confidences, for their mean; 0 when the engine gives none.
            var confidenceSum: Float = 0
            var confidenceCount: Int = 0

            var meanConfidence: Float? { confidenceCount > 0 ? confidenceSum / Float(confidenceCount) : nil }
        }

        /// The mean confidence of the hearings of the current form.
        var meanConfidence: Float? { votes[confirmationKey]?.meanConfidence }

        func replacingID(with id: UInt64) -> Candidate {
            Candidate(
                id: id,
                text: text,
                alignmentKey: alignmentKey,
                confirmationKey: confirmationKey,
                startSequence: startSequence,
                endSequence: endSequence,
                confidence: confidence,
                confirmations: confirmations,
                votes: votes,
                heard: heard
            )
        }

        func replacingText(with text: String) -> Candidate {
            Candidate(
                id: id,
                text: text,
                alignmentKey: ReadableTranscriptStabilizer.alignmentKey(text),
                confirmationKey: ReadableTranscriptStabilizer.confirmationKey(text),
                startSequence: startSequence,
                endSequence: endSequence,
                confidence: confidence,
                confirmations: confirmations,
                votes: votes,
                heard: heard
            )
        }

        /// The form heard most often, the current one when tied. Forms that differ
        /// only in accents or case count together ("reaccionària", "reaccionaria"), and
        /// the exact spelling heard most among them is the one returned.
        var majority: Vote {
            var groups: [String: (text: String, count: Int, best: Int, sum: Float, heard: Int)] = [:]
            for vote in votes.values {
                let key = ReadableTranscriptStabilizer.alignmentKey(vote.text)
                var group = groups[key] ?? (vote.text, 0, 0, 0, 0)
                group.count += vote.count
                group.sum += vote.confidenceSum
                group.heard += vote.confidenceCount
                if vote.count > group.best || (vote.count == group.best && vote.text == text) {
                    group.best = vote.count
                    group.text = vote.text
                }
                groups[key] = group
            }
            let ownKey = ReadableTranscriptStabilizer.alignmentKey(text)
            guard let winner = groups.max(by: { a, b in
                a.value.count < b.value.count || (a.value.count == b.value.count && b.key == ownKey)
            }) else { return Vote(text: text, count: 1) }
            return Vote(text: winner.value.text, count: winner.value.count,
                        confidenceSum: winner.value.sum, confidenceCount: winner.value.heard)
        }

        func displayWord(anchor: UInt64) -> StableTranscriptWord {
            StableTranscriptWord(
                id: id,
                text: text,
                isCommitted: false,
                anchor: anchor,
                startSequence: startSequence,
                endSequence: endSequence,
                confidence: meanConfidence ?? confidence
            )
        }
    }

    private struct PendingReplacement: Sendable {
        let confirmationKey: String
        let observations: Int
    }

    private struct CommittedRecord: Sendable {
        let displayWord: StableTranscriptWord
        let alignmentKey: String
        let confirmationKey: String
        let startSequence: UInt64
        let endSequence: UInt64
    }

    private struct MatchScore: Equatable {
        var count = 0
        var distance: UInt64 = 0

        func adding(_ extra: UInt64) -> MatchScore {
            MatchScore(count: count + 1, distance: distance.saturatingAdd(extra))
        }

        func preferred(over other: MatchScore) -> Bool {
            count > other.count || (count == other.count && distance < other.distance)
        }
    }

    public private(set) var stabilityLagSeconds: TimeInterval
    public private(set) var confirmationsRequired: Int
    public let provisionalLimit: Int
    public let retainedCommittedLimit: Int
    public private(set) var policy: TranscriptStabilityPolicy

    private var commitConfirmationsRequired: Int
    private var committed: [CommittedRecord] = []
    private var candidates: [Candidate] = []
    private var visibleCandidates: [Candidate] = []
    private var pendingReplacements: [UInt64: PendingReplacement] = [:]
    private var missingObservations: [UInt64: Int] = [:]
    /// Places whose word was dropped as undecided: a word written there again inherits
    /// the hearings, so it is judged at once instead of holding the words after it.
    private var droppedPlaces: [(startSequence: UInt64, endSequence: UInt64, votes: [String: Candidate.Vote], heard: Int)] = []
    private var nextID: UInt64 = 1
    private var nextAnchor: UInt64 = 1
    private var emptyObservationStreak = 0
    private var partialObservationStreak = 0
    /// Observations set aside because they skipped words heard before. For diagnostics.
    public private(set) var ignoredPartialObservations = 0
    /// Words committed because they stayed undecided too long. For diagnostics.
    public private(set) var overdueCommits = 0
    private var audioEndSequence: UInt64?
    private var sampleRate: Int32?
    private var lastHeardEndSequence: UInt64?
    public private(set) var finalCorrectionDisposition: FinalCorrectionDisposition = .notFinalized

    /// Compatibility initializer for the former immediate behaviour.
    public init(
        stabilityLagSeconds: TimeInterval = 0.35,
        confirmationsRequired: Int = 2,
        provisionalLimit: Int = 3,
        retainedCommittedLimit: Int = 160
    ) {
        let lag = max(0, stabilityLagSeconds)
        self.stabilityLagSeconds = lag
        self.confirmationsRequired = max(1, confirmationsRequired)
        self.provisionalLimit = max(0, provisionalLimit)
        self.retainedCommittedLimit = max(1, retainedCommittedLimit)
        self.commitConfirmationsRequired = max(1, confirmationsRequired)
        self.policy = TranscriptStabilityPolicy(
            minimumHopSeconds: LiveWindowPolicy.minimumHopSeconds,
            initialEvidenceRequired: 1,
            replacementEvidenceRequired: 1,
            minimumWordAgeSeconds: 0,
            commitEvidenceRequired: max(1, confirmationsRequired),
            commitLagSeconds: lag
        )
    }

    public init(
        policy profile: TranscriptionProfile,
        provisionalLimit: Int = 3,
        retainedCommittedLimit: Int = 160
    ) {
        let policy = profile.policy
        self.stabilityLagSeconds = policy.commitLagSeconds
        self.confirmationsRequired = policy.initialEvidenceRequired
        self.provisionalLimit = max(0, provisionalLimit)
        self.retainedCommittedLimit = max(1, retainedCommittedLimit)
        self.commitConfirmationsRequired = policy.commitEvidenceRequired
        self.policy = policy
    }

    public init(
        policy: TranscriptStabilityPolicy,
        provisionalLimit: Int = 3,
        retainedCommittedLimit: Int = 160
    ) {
        self.stabilityLagSeconds = policy.commitLagSeconds
        self.confirmationsRequired = policy.initialEvidenceRequired
        self.provisionalLimit = max(0, provisionalLimit)
        self.retainedCommittedLimit = max(1, retainedCommittedLimit)
        self.commitConfirmationsRequired = policy.commitEvidenceRequired
        self.policy = policy
    }

    /// Switches profile mid-session. Everything heard and shown so far is kept; the new
    /// thresholds apply from the next observation.
    public mutating func adopt(_ profile: TranscriptionProfile) {
        let policy = profile.policy
        stabilityLagSeconds = policy.commitLagSeconds
        confirmationsRequired = policy.initialEvidenceRequired
        commitConfirmationsRequired = policy.commitEvidenceRequired
        self.policy = policy
    }

    public mutating func reset() {
        committed.removeAll(keepingCapacity: true)
        candidates.removeAll(keepingCapacity: true)
        visibleCandidates.removeAll(keepingCapacity: true)
        pendingReplacements.removeAll(keepingCapacity: true)
        missingObservations.removeAll(keepingCapacity: true)
        droppedPlaces.removeAll()
        nextID = 1
        nextAnchor = 1
        emptyObservationStreak = 0
        partialObservationStreak = 0
        audioEndSequence = nil
        sampleRate = nil
        lastHeardEndSequence = nil
        finalCorrectionDisposition = .notFinalized
    }

    private mutating func noteClock(audioEndSequence: UInt64, sampleRate: Int32, heard words: [TranscriptObservationWord]) {
        self.audioEndSequence = max(self.audioEndSequence ?? 0, audioEndSequence)
        self.sampleRate = sampleRate
        if let newest = words.map(\.endSequence).max() {
            lastHeardEndSequence = max(lastHeardEndSequence ?? 0, newest)
        }
    }

    /// `windowStartSequence`, where the recogniser's window began, lets the stabiliser
    /// tell a word the recogniser skipped from one the window has moved past.
    @discardableResult
    public mutating func observe(
        _ incoming: [TranscriptObservationWord],
        audioEndSequence: UInt64,
        sampleRate: Int32,
        windowStartSequence: UInt64? = nil
    ) -> ReadableTranscriptSnapshot {
        let allWords = sanitized(incoming)
        noteClock(audioEndSequence: audioEndSequence, sampleRate: sampleRate, heard: allWords)
        // A word the window has not heard the end of yet is not heard at all.
        let rightContext = UInt64(policy.minimumRightContextSeconds * Double(max(1, sampleRate)))
        let words = rightContext == 0 ? allWords
            : allWords.filter { $0.endSequence.saturatingAdd(rightContext) <= audioEndSequence }
        guard !words.isEmpty else {
            emptyObservationStreak += 1
            if emptyObservationStreak >= max(2, policy.replacementEvidenceRequired) {
                candidates.removeAll(keepingCapacity: true)
                visibleCandidates.removeAll(keepingCapacity: true)
                pendingReplacements.removeAll(keepingCapacity: true)
                missingObservations.removeAll(keepingCapacity: true)
            }
            return snapshot
        }

        emptyObservationStreak = 0
        // An RNNT decoder can fall silent for part of a window, typically after a pause:
        // it returns the words after the gap and drops the ones before, which it heard in
        // the previous windows. Accepting that would commit the later words and leave the
        // dropped ones behind the commit boundary for good ("quan vam arribar a
        // Montserrat" vanished that way). Such an observation is ignored, like an empty
        // one, unless it persists.
        if let windowStartSequence,
           skipsHeardWords(words, windowStartSequence: windowStartSequence, sampleRate: sampleRate) {
            partialObservationStreak += 1
            if partialObservationStreak < max(2, policy.replacementEvidenceRequired) {
                ignoredPartialObservations += 1
                return snapshot
            }
        }
        partialObservationStreak = 0
        let suffix = suffixAfterCommitted(
            in: words,
            sampleRate: sampleRate,
            leftEdgeEnd: windowStartSequence.flatMap {
                Self.leftEdgeEnd(windowStart: $0, audioEndSequence: audioEndSequence, sampleRate: sampleRate)
            }
        )
        candidates = reconcile(suffix, sampleRate: sampleRate)
        refreshVisibleCandidates(audioEndSequence: audioEndSequence, sampleRate: sampleRate)
        commitEligibleWords(audioEndSequence: audioEndSequence, sampleRate: sampleRate)
        return snapshot
    }

    /// Compatibility finalization. The window-aware overload performs safe replacement.
    @discardableResult
    public mutating func finalize(
        _ incoming: [TranscriptObservationWord],
        audioEndSequence: UInt64,
        sampleRate: Int32
    ) -> ReadableTranscriptSnapshot {
        let words = sanitized(incoming)
        noteClock(audioEndSequence: audioEndSequence, sampleRate: sampleRate, heard: words)
        guard !words.isEmpty else {
            candidates.removeAll(keepingCapacity: true)
            visibleCandidates.removeAll(keepingCapacity: true)
            return snapshot
        }
        let suffix = suffixAfterCommitted(in: words, sampleRate: sampleRate)
        candidates = reconcile(suffix, sampleRate: sampleRate)
        for candidate in candidates { appendCommitted(candidate) }
        candidates.removeAll(keepingCapacity: true)
        visibleCandidates.removeAll(keepingCapacity: true)
        return snapshot
    }

    /// Replaces the trusted part of a final decode in one state transition. The first
    /// 250 ms are excluded when a rolling window may start inside a word. Estimated
    /// offsets never authorize destructive replacement.
    @discardableResult
    public mutating func finalize(
        _ incoming: [TranscriptObservationWord],
        windowStartSequence: UInt64,
        windowIncludesSessionStart: Bool,
        timingQuality: TranscriptTimingQuality,
        audioEndSequence: UInt64,
        sampleRate: Int32
    ) -> ReadableTranscriptSnapshot {
        candidates.removeAll(keepingCapacity: true)
        visibleCandidates.removeAll(keepingCapacity: true)
        pendingReplacements.removeAll(keepingCapacity: true)
        missingObservations.removeAll(keepingCapacity: true)
        emptyObservationStreak = 0
        noteClock(audioEndSequence: audioEndSequence, sampleRate: sampleRate, heard: sanitized(incoming))

        guard timingQuality == .wordOffsets, sampleRate > 0 else {
            finalCorrectionDisposition = .preservedBecauseTimingUnavailable
            return snapshot
        }

        let guardSamples = windowIncludesSessionStart
            ? UInt64(0)
            : UInt64(sampleRate) / 4
        let trustedStart = min(windowStartSequence.saturatingAdd(guardSamples), audioEndSequence)
        committed.removeAll { record in
            record.startSequence >= trustedStart
        }
        nextAnchor = (committed.last?.displayWord.anchor ?? 0).saturatingAdd(1)

        for word in sanitized(incoming).sorted(by: {
            if $0.startSequence == $1.startSequence { return $0.endSequence < $1.endSequence }
            return $0.startSequence < $1.startSequence
        }) where word.startSequence >= trustedStart && word.startSequence <= audioEndSequence {
            let candidate = Candidate(
                id: nextID,
                text: word.text,
                alignmentKey: Self.alignmentKey(word.text),
                confirmationKey: Self.confirmationKey(word.text),
                startSequence: word.startSequence,
                endSequence: min(word.endSequence, audioEndSequence),
                confidence: word.confidence,
                confirmations: policy.initialEvidenceRequired,
                votes: [:],
                heard: 1
            )
            nextID &+= 1
            appendCommitted(candidate)
        }
        finalCorrectionDisposition = .corrected
        return snapshot
    }

    public var snapshot: ReadableTranscriptSnapshot {
        ReadableTranscriptSnapshot(
            committedWords: committed.map(\.displayWord),
            provisionalWords: visibleCandidates.prefix(provisionalLimit).enumerated().map {
                index, candidate in candidate.displayWord(anchor: nextAnchor + UInt64(index))
            },
            latestCommittedEndSequence: committed.last?.endSequence,
            latestVisibleEndSequence: visibleCandidates.prefix(provisionalLimit).last?.endSequence
                ?? committed.last?.endSequence,
            audioEndSequence: audioEndSequence,
            sampleRate: sampleRate,
            lastHeardEndSequence: lastHeardEndSequence
        )
    }

    /// True when a word heard in at least two earlier windows, well inside this window,
    /// has nothing at its time in this observation although later words are there: a
    /// hole, not a revision (a revised word is replaced by another at the same time).
    /// Words near the window's start are left out, since the window may cut them.
    private func skipsHeardWords(
        _ words: [TranscriptObservationWord],
        windowStartSequence: UInt64,
        sampleRate: Int32
    ) -> Bool {
        let tolerance = UInt64(max(1, sampleRate)) / 10
        let inside = windowStartSequence.saturatingAdd(UInt64(max(1, sampleRate)) / 2)
        return candidates.contains { heard in
            guard heard.confirmations >= 2, heard.startSequence >= inside,
                  words.contains(where: { $0.startSequence >= heard.endSequence }) else { return false }
            return !words.contains { word in
                word.startSequence <= heard.endSequence.saturatingAdd(tolerance)
                    && heard.startSequence <= word.endSequence.saturatingAdd(tolerance)
            }
        }
    }

    private func sanitized(_ incoming: [TranscriptObservationWord]) -> [TranscriptObservationWord] {
        incoming.compactMap { word in
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, word.endSequence >= word.startSequence else { return nil }
            return TranscriptObservationWord(
                text: text,
                startSequence: word.startSequence,
                endSequence: word.endSequence,
                confidence: word.confidence
            )
        }
    }

    /// The part of a window where no word can be new: audio heard in many windows
    /// before, now about to slide out. FastConformer places these words up to a few
    /// frames later than it did while they were well inside the window, and stretches the
    /// last one over the silence after it, so there a settled word heard again may no
    /// longer overlap its settled copy ("para para todos", "along? Along?"). Only once
    /// the window holds enough audio for its start to be old.
    static func leftEdgeEnd(windowStart: UInt64, audioEndSequence: UInt64, sampleRate: Int32) -> UInt64? {
        let rate = UInt64(max(1, sampleRate))
        guard audioEndSequence >= windowStart.saturatingAdd(rate * 3) else { return nil }
        return windowStart.saturatingAdd(rate * 3 / 2)
    }

    /// How far a settled word may drift at the window's left edge and still be itself.
    private func leftEdgeSlack(sampleRate: Int32) -> UInt64 {
        UInt64(max(1, sampleRate)) / 4
    }

    private func suffixAfterCommitted(
        in incoming: [TranscriptObservationWord],
        sampleRate: Int32,
        leftEdgeEnd: UInt64? = nil
    ) -> [TranscriptObservationWord] {
        guard let boundary = committed.last else { return incoming }
        let edgeSlack = leftEdgeSlack(sampleRate: sampleRate)
        /// At the left edge a word counts as overlapping a settled one within the slack.
        func isAtLeftEdge(_ word: TranscriptObservationWord) -> Bool {
            leftEdgeEnd.map { word.startSequence < $0 } ?? false
        }
        let overlapAllowance = UInt64(max(1, sampleRate)) / 20
        let threshold = boundary.endSequence > overlapAllowance
            ? boundary.endSequence - overlapAllowance : 0
        let boundaryMidpoint = Self.midpoint(boundary.startSequence, boundary.endSequence)
        let tolerance = sequenceTolerance(sampleRate: sampleRate)
        let provisionalMatches = Self.commonSubsequenceMatches(
            old: candidates,
            new: incoming,
            tolerance: tolerance
        )
        let provisionalIndices = Set(provisionalMatches.compactMap { match -> Int? in
            let word = incoming[match.new]
            guard Self.alignmentKey(word.text) == boundary.alignmentKey else { return match.new }
            let candidate = candidates[match.old]
            let wordMidpoint = Self.midpoint(word.startSequence, word.endSequence)
            let candidateDistance = Self.sequenceDistance(
                Self.midpoint(candidate.startSequence, candidate.endSequence), wordMidpoint
            )
            let boundaryDistance = Self.sequenceDistance(boundaryMidpoint, wordMidpoint)
            return candidateDistance < boundaryDistance ? match.new : nil
        })
        let repeatedCommittedIndex = incoming.indices
            .filter { index in
                guard !provisionalIndices.contains(index) else { return false }
                let word = incoming[index]
                let wordMidpoint = Self.midpoint(word.startSequence, word.endSequence)
                let hasFollowingSuffix = provisionalIndices.contains { $0 > index }
                guard Self.alignmentKey(word.text) == boundary.alignmentKey else { return false }
                if isAtLeftEdge(word) {
                    return boundary.startSequence < word.endSequence.saturatingAdd(edgeSlack)
                        && word.startSequence < boundary.endSequence.saturatingAdd(edgeSlack)
                }
                return boundary.startSequence < word.endSequence
                    && word.startSequence < boundary.endSequence
                    && (wordMidpoint <= boundary.endSequence || hasFollowingSuffix)
            }
            .min {
                Self.sequenceDistance(Self.midpoint(incoming[$0].startSequence, incoming[$0].endSequence), boundaryMidpoint)
                    < Self.sequenceDistance(Self.midpoint(incoming[$1].startSequence, incoming[$1].endSequence), boundaryMidpoint)
            }

        let repeatedTailIndices = repeatedCommittedTail(
            in: incoming, sampleRate: sampleRate, isAtLeftEdge: isAtLeftEdge, edgeSlack: edgeSlack
        )

        return incoming.enumerated().compactMap { index, word in
            guard index != repeatedCommittedIndex, !repeatedTailIndices.contains(index) else { return nil }
            if provisionalIndices.contains(index) { return word }
            return Self.midpoint(word.startSequence, word.endSequence) > threshold ? word : nil
        }
    }

    /// Incoming words that are settled words heard again, found as a run that follows the
    /// settled tail word for word. FastConformer models give short words a single 80 ms
    /// frame and place it a frame earlier or later from one window to the next, so a
    /// settled "del" came back beside itself, not over it, and was shown twice ("del
    /// del", 20 times in 60 Spanish clips). A run starts at a word that overlaps its
    /// settled copy, so a repetition the speaker makes, heard with nothing before it, is
    /// still a new word.
    private func repeatedCommittedTail(
        in incoming: [TranscriptObservationWord],
        sampleRate: Int32,
        isAtLeftEdge: (TranscriptObservationWord) -> Bool = { _ in false },
        edgeSlack: UInt64 = 0
    ) -> Set<Int> {
        let tail = Array(committed.suffix(6))
        guard tail.count > 1 else { return [] }
        let tolerance = sequenceTolerance(sampleRate: sampleRate)
        let matches = Self.commonSubsequenceMatches(
            oldCount: tail.count,
            newCount: incoming.count,
            matches: { oldIndex, newIndex in
                tail[oldIndex].alignmentKey == Self.alignmentKey(incoming[newIndex].text)
                    && tail[oldIndex].startSequence <= incoming[newIndex].endSequence.saturatingAdd(tolerance)
                    && incoming[newIndex].startSequence <= tail[oldIndex].endSequence.saturatingAdd(tolerance)
            },
            distance: { oldIndex, newIndex in
                Self.sequenceDistance(
                    Self.midpoint(tail[oldIndex].startSequence, tail[oldIndex].endSequence),
                    Self.midpoint(incoming[newIndex].startSequence, incoming[newIndex].endSequence)
                )
            }
        )
        var repeated: Set<Int> = []
        var previous: (new: Int, old: Int)?
        for match in matches.sorted(by: { $0.old < $1.old }) {
            let settled = tail[match.old]
            let word = incoming[match.new]
            let follows = previous.map { $0.old + 1 == match.old && $0.new + 1 == match.new } ?? false
            // The boundary word itself, when overlapping, is left to the rule above.
            let slack = isAtLeftEdge(word) ? edgeSlack : 0
            let overlaps = match.old < tail.count - 1
                && settled.startSequence < word.endSequence.saturatingAdd(slack)
                && word.startSequence < settled.endSequence.saturatingAdd(slack)
            if follows || overlaps {
                repeated.insert(match.new)
                previous = match
            } else {
                previous = nil
            }
        }
        return repeated
    }

    private mutating func reconcile(
        _ incoming: [TranscriptObservationWord],
        sampleRate: Int32
    ) -> [Candidate] {
        guard !incoming.isEmpty else { return [] }
        let matches = Self.commonSubsequenceMatches(
            old: candidates,
            new: incoming,
            tolerance: sequenceTolerance(sampleRate: sampleRate)
        )
        let oldByNew = Dictionary(uniqueKeysWithValues: matches.map { ($0.new, $0.old) })
        let matchedOld = Set(matches.map(\.old))
        // A word written where an unmatched word was, or where one was dropped as
        // undecided, is another form of the same place: the hearings there carry over,
        // so a place the recogniser rewords every window is judged on all of them.
        func place(of word: TranscriptObservationWord) -> (votes: [String: Candidate.Vote], heard: Int)? {
            func covers(_ start: UInt64, _ end: UInt64) -> Bool {
                let middle = Self.midpoint(word.startSequence, word.endSequence)
                let theirs = Self.midpoint(start, end)
                return (start...max(start, end)).contains(middle)
                    || (word.startSequence...max(word.startSequence, word.endSequence)).contains(theirs)
            }
            if let old = candidates.indices.first(where: { !matchedOld.contains($0) && covers(candidates[$0].startSequence, candidates[$0].endSequence) }) {
                return (candidates[old].votes, candidates[old].heard)
            }
            if let dropped = droppedPlaces.first(where: { covers($0.startSequence, $0.endSequence) }) {
                return (dropped.votes, dropped.heard)
            }
            return nil
        }

        return incoming.enumerated().map { index, word in
            let alignmentKey = Self.alignmentKey(word.text)
            let confirmationKey = Self.confirmationKey(word.text)
            if let oldIndex = oldByNew[index] {
                let previous = candidates[oldIndex]
                var votes = previous.votes
                votes[confirmationKey] = Self.vote(votes[confirmationKey], hearing: word)
                return Candidate(
                    id: previous.id,
                    text: word.text,
                    alignmentKey: alignmentKey,
                    confirmationKey: confirmationKey,
                    startSequence: word.startSequence,
                    endSequence: word.endSequence,
                    confidence: word.confidence,
                    confirmations: previous.confirmationKey == confirmationKey
                        ? previous.confirmations + 1 : 1,
                    votes: votes,
                    heard: previous.heard + 1
                )
            }
            defer { nextID &+= 1 }
            let inherited = place(of: word)
            var votes = inherited?.votes ?? [:]
            votes[confirmationKey] = Self.vote(votes[confirmationKey], hearing: word)
            return Candidate(
                id: nextID,
                text: word.text,
                alignmentKey: alignmentKey,
                confirmationKey: confirmationKey,
                startSequence: word.startSequence,
                endSequence: word.endSequence,
                confidence: word.confidence,
                confirmations: 1,
                votes: votes,
                heard: (inherited?.heard ?? 0) + 1
            )
        }
    }

    /// Whether the form's mean confidence reaches the policy's floor; a form heard
    /// without confidence passes.
    private func isConfidentEnough(_ candidate: Candidate) -> Bool {
        isConfidentEnough(candidate.meanConfidence)
    }

    private func isConfidentEnough(_ confidence: Float?) -> Bool {
        guard policy.minimumConfidence > 0, let confidence else { return true }
        return confidence >= policy.minimumConfidence
    }

    /// One more hearing of a form, its confidence added when the engine gives one.
    private static func vote(_ previous: Candidate.Vote?, hearing word: TranscriptObservationWord) -> Candidate.Vote {
        Candidate.Vote(
            text: word.text,
            count: (previous?.count ?? 0) + 1,
            confidenceSum: (previous?.confidenceSum ?? 0) + (word.confidence ?? 0),
            confidenceCount: (previous?.confidenceCount ?? 0) + (word.confidence == nil ? 0 : 1)
        )
    }

    private mutating func refreshVisibleCandidates(
        audioEndSequence: UInt64,
        sampleRate: Int32
    ) {
        guard !candidates.isEmpty else {
            visibleCandidates = visibleCandidates.filter { candidate in
                let misses = (missingObservations[candidate.id] ?? 0) + 1
                missingObservations[candidate.id] = misses
                if misses >= policy.replacementEvidenceRequired {
                    pendingReplacements[candidate.id] = nil
                    missingObservations[candidate.id] = nil
                    return false
                }
                return true
            }
            return
        }
        let tolerance = sequenceTolerance(sampleRate: sampleRate)
        var pairs = Self.candidateMatches(old: visibleCandidates, new: candidates, tolerance: tolerance)
        var usedOld = Set(pairs.map(\.old))
        var usedNew = Set(pairs.map(\.new))

        // Protect lexical matches first, then use time to pair a genuinely revised word.
        for oldIndex in visibleCandidates.indices where !usedOld.contains(oldIndex) {
            let old = visibleCandidates[oldIndex]
            let nearest = candidates.indices
                .filter { !usedNew.contains($0) }
                .filter { index in
                    let new = candidates[index]
                    return old.startSequence <= new.endSequence.saturatingAdd(tolerance)
                        && new.startSequence <= old.endSequence.saturatingAdd(tolerance)
                }
                .min {
                    Self.sequenceDistance(
                        Self.midpoint(old.startSequence, old.endSequence),
                        Self.midpoint(candidates[$0].startSequence, candidates[$0].endSequence)
                    ) < Self.sequenceDistance(
                        Self.midpoint(old.startSequence, old.endSequence),
                        Self.midpoint(candidates[$1].startSequence, candidates[$1].endSequence)
                    )
                }
            if let nearest {
                pairs.append((new: nearest, old: oldIndex))
                usedOld.insert(oldIndex)
                usedNew.insert(nearest)
            }
        }

        let oldByNew = Dictionary(uniqueKeysWithValues: pairs.map { ($0.new, $0.old) })
        var output: [Candidate] = []
        for (newIndex, candidate) in candidates.enumerated() {
            if let oldIndex = oldByNew[newIndex] {
                output.append(resolveVisible(visibleCandidates[oldIndex], with: candidate))
            } else if isEligibleToAppear(
                candidate,
                audioEndSequence: audioEndSequence,
                sampleRate: sampleRate
            ) {
                output.append(candidate)
            }
        }

        for oldIndex in visibleCandidates.indices where !usedOld.contains(oldIndex) {
            let old = visibleCandidates[oldIndex]
            let misses = (missingObservations[old.id] ?? 0) + 1
            missingObservations[old.id] = misses
            if misses < policy.replacementEvidenceRequired { output.append(old) }
        }
        output.sort {
            if $0.startSequence == $1.startSequence { return $0.endSequence < $1.endSequence }
            return $0.startSequence < $1.startSequence
        }
        let survivingIDs = Set(output.map(\.id))
        pendingReplacements = pendingReplacements.filter { survivingIDs.contains($0.key) }
        missingObservations = missingObservations.filter { survivingIDs.contains($0.key) }
        visibleCandidates = output
    }

    private mutating func resolveVisible(_ visible: Candidate, with candidate: Candidate) -> Candidate {
        missingObservations[visible.id] = nil
        guard visible.confirmationKey != candidate.confirmationKey else {
            pendingReplacements[visible.id] = nil
            return candidate.replacingID(with: visible.id)
        }
        let previous = pendingReplacements[visible.id]
        let observations = previous?.confirmationKey == candidate.confirmationKey
            ? (previous?.observations ?? 0) + 1 : 1
        pendingReplacements[visible.id] = PendingReplacement(
            confirmationKey: candidate.confirmationKey,
            observations: observations
        )
        guard observations >= policy.replacementEvidenceRequired else { return visible }
        pendingReplacements[visible.id] = nil
        return candidate.replacingID(with: visible.id)
    }

    private func isEligibleToAppear(
        _ candidate: Candidate,
        audioEndSequence: UInt64,
        sampleRate: Int32
    ) -> Bool {
        guard sampleRate > 0,
              candidate.confirmations >= policy.initialEvidenceRequired,
              isConfidentEnough(candidate) else { return false }
        return candidate.endSequence <= audioEndSequence
    }

    /// A word still undecided this long after it ends is decided. Every window since
    /// has held it well inside, so nothing better will be heard. Without this, a word
    /// the recogniser keeps rewording ("reaccionària", "redsonària", "reaccionaria")
    /// never reaches confirmation, holds back every word after it, and all of them are
    /// lost when the window moves past: on 87 ParlamentParla clips that was 3-4% of all
    /// words, in runs of three or more.
    ///
    /// The form heard most often is the one committed, and only when it was heard
    /// `overdueEvidenceRequired` times; a word no two windows agreed on is dropped
    /// instead. Committing it "as last heard" was how invented words reached the screen
    /// in a crowd: in noise the recogniser writes a different word every window, and
    /// after 2.5 s the last of them was settled as if it had been confirmed.
    public static let maximumUndecidedSeconds: TimeInterval = 2.5
    /// Words dropped because no form of them was heard often enough. For diagnostics.
    public private(set) var overdueDrops = 0

    private mutating func commitEligibleWords(audioEndSequence: UInt64, sampleRate: Int32) {
        guard sampleRate > 0 else { return }
        let lag = UInt64(Double(sampleRate) * policy.commitLagSeconds)
        let stableThrough = audioEndSequence > lag ? audioEndSequence - lag : 0
        let overdueAge = UInt64(Double(sampleRate) * Self.maximumUndecidedSeconds)
        var promotions: [(candidate: Candidate, visibleIndex: Int?, overdue: Bool)] = []
        var droppedIDs: Set<UInt64> = []
        var decided = 0
        var usedVisibleIndices: Set<Int> = []
        // A visible word that is some other candidate's own form is never borrowed.
        let candidateIDs = Set(candidates.map(\.id))
        for heard in candidates {
            let confirmed = heard.confirmations >= commitConfirmationsRequired
                && heard.endSequence <= stableThrough
                && isConfidentEnough(heard)
            let overdue = audioEndSequence >= heard.endSequence.saturatingAdd(overdueAge)
            guard confirmed || overdue else { break }
            var candidate = heard
            if !confirmed {
                let majority = heard.majority
                if majority.count < policy.overdueEvidenceRequired
                    || Double(majority.count) < policy.overdueMajorityShare * Double(heard.heard)
                    || !isConfidentEnough(majority.meanConfidence) {
                    // Heard once only: one more window may agree, so the words after it
                    // wait with it, as they would for any undecided word. Heard more and
                    // still undecided, it goes.
                    guard heard.heard >= min(policy.overdueEvidenceRequired, policy.overdueHearingsToJudge) else { break }
                    droppedIDs.insert(heard.id)
                    droppedPlaces.append((heard.startSequence, heard.endSequence, heard.votes, heard.heard))
                    decided += 1
                    continue
                }
                candidate = heard.replacingText(with: majority.text)
            }
            // The word on screen at that place keeps its identity, even when an overdue
            // commit settles it with different text. The candidate's own visible form
            // comes first, so one identity is never both settled and on screen.
            let visibleIndex = visibleCandidates.indices.first(where: { index in
                !usedVisibleIndices.contains(index) && visibleCandidates[index].id == candidate.id
            }) ?? visibleCandidates.indices.first(where: { index in
                !usedVisibleIndices.contains(index)
                    && !candidateIDs.contains(visibleCandidates[index].id)
                    && (overdue || visibleCandidates[index].confirmationKey == candidate.confirmationKey)
                    && visibleCandidates[index].startSequence <= candidate.endSequence
                    && candidate.startSequence <= visibleCandidates[index].endSequence
            })
            if visibleIndex == nil, !overdue { break }
            if let visibleIndex { usedVisibleIndices.insert(visibleIndex) }
            promotions.append((candidate, visibleIndex, !confirmed))
            decided += 1
        }
        guard decided > 0 else { return }
        var settledIDs = Set(committed.map(\.displayWord.id))
        for promotion in promotions {
            if promotion.overdue { overdueCommits += 1 }
            var id = promotion.visibleIndex.map { visibleCandidates[$0].id } ?? promotion.candidate.id
            if settledIDs.contains(id) {
                // Never two words with one identity; a fresh one costs only a fade-in.
                id = nextID
                nextID &+= 1
            }
            settledIDs.insert(id)
            appendCommitted(promotion.candidate.replacingID(with: id))
            pendingReplacements[id] = nil
            missingObservations[id] = nil
        }
        overdueDrops += droppedIDs.count
        candidates.removeFirst(decided)
        for index in usedVisibleIndices.sorted(by: >) {
            visibleCandidates.remove(at: index)
        }
        visibleCandidates.removeAll { settledIDs.contains($0.id) || droppedIDs.contains($0.id) }
        for id in droppedIDs {
            pendingReplacements[id] = nil
            missingObservations[id] = nil
        }
    }

    private mutating func appendCommitted(_ candidate: Candidate) {
        let word = StableTranscriptWord(
            id: candidate.id,
            text: candidate.text,
            isCommitted: true,
            anchor: nextAnchor,
            startSequence: candidate.startSequence,
            endSequence: candidate.endSequence,
            confidence: candidate.meanConfidence ?? candidate.confidence
        )
        nextAnchor &+= 1
        committed.append(CommittedRecord(
            displayWord: word,
            alignmentKey: candidate.alignmentKey,
            confirmationKey: candidate.confirmationKey,
            startSequence: candidate.startSequence,
            endSequence: candidate.endSequence
        ))
        if committed.count > retainedCommittedLimit {
            committed.removeFirst(committed.count - retainedCommittedLimit)
        }
        droppedPlaces.removeAll { $0.endSequence <= candidate.startSequence }
    }

    private func sequenceTolerance(sampleRate: Int32) -> UInt64 {
        UInt64(max(1, sampleRate)) / 2
    }

    private static func midpoint(_ start: UInt64, _ end: UInt64) -> UInt64 {
        start &+ (end - start) / 2
    }

    private static func candidateMatches(
        old: [Candidate],
        new: [Candidate],
        tolerance: UInt64
    ) -> [(new: Int, old: Int)] {
        commonSubsequenceMatches(
            oldCount: old.count,
            newCount: new.count,
            matches: { oldIndex, newIndex in
                old[oldIndex].alignmentKey == new[newIndex].alignmentKey
                    && old[oldIndex].startSequence <= new[newIndex].endSequence.saturatingAdd(tolerance)
                    && new[newIndex].startSequence <= old[oldIndex].endSequence.saturatingAdd(tolerance)
            },
            distance: { oldIndex, newIndex in
                sequenceDistance(
                    midpoint(old[oldIndex].startSequence, old[oldIndex].endSequence),
                    midpoint(new[newIndex].startSequence, new[newIndex].endSequence)
                )
            }
        )
    }

    private static func commonSubsequenceMatches(
        old: [Candidate],
        new: [TranscriptObservationWord],
        tolerance: UInt64
    ) -> [(new: Int, old: Int)] {
        commonSubsequenceMatches(
            oldCount: old.count,
            newCount: new.count,
            matches: { oldIndex, newIndex in
                old[oldIndex].alignmentKey == alignmentKey(new[newIndex].text)
                    && old[oldIndex].startSequence <= new[newIndex].endSequence.saturatingAdd(tolerance)
                    && new[newIndex].startSequence <= old[oldIndex].endSequence.saturatingAdd(tolerance)
            },
            distance: { oldIndex, newIndex in
                sequenceDistance(
                    midpoint(old[oldIndex].startSequence, old[oldIndex].endSequence),
                    midpoint(new[newIndex].startSequence, new[newIndex].endSequence)
                )
            }
        )
    }

    private static func commonSubsequenceMatches(
        oldCount: Int,
        newCount: Int,
        matches: (Int, Int) -> Bool,
        distance: (Int, Int) -> UInt64
    ) -> [(new: Int, old: Int)] {
        guard oldCount > 0, newCount > 0 else { return [] }
        let columns = newCount + 1
        var table = [MatchScore](repeating: MatchScore(), count: (oldCount + 1) * columns)
        for oldIndex in stride(from: oldCount - 1, through: 0, by: -1) {
            for newIndex in stride(from: newCount - 1, through: 0, by: -1) {
                let index = oldIndex * columns + newIndex
                let skipOld = table[(oldIndex + 1) * columns + newIndex]
                let skipNew = table[oldIndex * columns + newIndex + 1]
                var best = skipOld.preferred(over: skipNew) ? skipOld : skipNew
                if matches(oldIndex, newIndex) {
                    let matched = table[(oldIndex + 1) * columns + newIndex + 1]
                        .adding(distance(oldIndex, newIndex))
                    if matched.preferred(over: best) || matched == best { best = matched }
                }
                table[index] = best
            }
        }
        var result: [(new: Int, old: Int)] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldCount, newIndex < newCount {
            let matched = table[(oldIndex + 1) * columns + newIndex + 1]
                .adding(distance(oldIndex, newIndex))
            if matches(oldIndex, newIndex), matched == table[oldIndex * columns + newIndex] {
                result.append((newIndex, oldIndex))
                oldIndex += 1
                newIndex += 1
            } else if table[(oldIndex + 1) * columns + newIndex]
                .preferred(over: table[oldIndex * columns + newIndex + 1]) {
                oldIndex += 1
            } else {
                newIndex += 1
            }
        }
        return result
    }

    /// Permissive identity key: visual identity survives punctuation/case/diacritic drift.
    private static func alignmentKey(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Exact evidence key: Catalan diacritics are meaningful and confirm independently.
    private static func confirmationKey(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters)
            .folding(options: [.caseInsensitive], locale: .current)
    }

    private static func sequenceDistance(_ first: UInt64, _ second: UInt64) -> UInt64 {
        first >= second ? first - second : second - first
    }
}

private extension UInt64 {
    func saturatingAdd(_ other: UInt64) -> UInt64 {
        let (value, overflow) = addingReportingOverflow(other)
        return overflow ? .max : value
    }
}
