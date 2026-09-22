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

    public init(
        committedWords: [StableTranscriptWord] = [],
        provisionalWords: [StableTranscriptWord] = [],
        latestCommittedEndSequence: UInt64? = nil,
        latestVisibleEndSequence: UInt64? = nil
    ) {
        self.committedWords = committedWords
        self.provisionalWords = provisionalWords
        self.latestCommittedEndSequence = latestCommittedEndSequence
        self.latestVisibleEndSequence = latestVisibleEndSequence
    }

    public var words: [StableTranscriptWord] { committedWords + provisionalWords }
    public var text: String { words.map(\.text).joined(separator: " ") }
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
        let confirmations: Int

        func replacingID(with id: UInt64) -> Candidate {
            Candidate(
                id: id,
                text: text,
                alignmentKey: alignmentKey,
                confirmationKey: confirmationKey,
                startSequence: startSequence,
                endSequence: endSequence,
                confidence: confidence,
                confirmations: confirmations
            )
        }

        func displayWord(anchor: UInt64) -> StableTranscriptWord {
            StableTranscriptWord(id: id, text: text, isCommitted: false, anchor: anchor)
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

    public let stabilityLagSeconds: TimeInterval
    public let confirmationsRequired: Int
    public let provisionalLimit: Int
    public let retainedCommittedLimit: Int
    public let policy: TranscriptStabilityPolicy

    private let commitConfirmationsRequired: Int
    private var committed: [CommittedRecord] = []
    private var candidates: [Candidate] = []
    private var visibleCandidates: [Candidate] = []
    private var pendingReplacements: [UInt64: PendingReplacement] = [:]
    private var missingObservations: [UInt64: Int] = [:]
    private var nextID: UInt64 = 1
    private var nextAnchor: UInt64 = 1
    private var emptyObservationStreak = 0
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

    public mutating func reset() {
        committed.removeAll(keepingCapacity: true)
        candidates.removeAll(keepingCapacity: true)
        visibleCandidates.removeAll(keepingCapacity: true)
        pendingReplacements.removeAll(keepingCapacity: true)
        missingObservations.removeAll(keepingCapacity: true)
        nextID = 1
        nextAnchor = 1
        emptyObservationStreak = 0
        finalCorrectionDisposition = .notFinalized
    }

    @discardableResult
    public mutating func observe(
        _ incoming: [TranscriptObservationWord],
        audioEndSequence: UInt64,
        sampleRate: Int32
    ) -> ReadableTranscriptSnapshot {
        let words = sanitized(incoming)
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
        let suffix = suffixAfterCommitted(in: words, sampleRate: sampleRate)
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
                confirmations: policy.initialEvidenceRequired
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
                ?? committed.last?.endSequence
        )
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

    private func suffixAfterCommitted(
        in incoming: [TranscriptObservationWord],
        sampleRate: Int32
    ) -> [TranscriptObservationWord] {
        guard let boundary = committed.last else { return incoming }
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
                return Self.alignmentKey(word.text) == boundary.alignmentKey
                    && boundary.startSequence < word.endSequence
                    && word.startSequence < boundary.endSequence
                    && (wordMidpoint <= boundary.endSequence || hasFollowingSuffix)
            }
            .min {
                Self.sequenceDistance(Self.midpoint(incoming[$0].startSequence, incoming[$0].endSequence), boundaryMidpoint)
                    < Self.sequenceDistance(Self.midpoint(incoming[$1].startSequence, incoming[$1].endSequence), boundaryMidpoint)
            }

        return incoming.enumerated().compactMap { index, word in
            guard index != repeatedCommittedIndex else { return nil }
            if provisionalIndices.contains(index) { return word }
            return Self.midpoint(word.startSequence, word.endSequence) > threshold ? word : nil
        }
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

        return incoming.enumerated().map { index, word in
            let alignmentKey = Self.alignmentKey(word.text)
            let confirmationKey = Self.confirmationKey(word.text)
            if let oldIndex = oldByNew[index] {
                let previous = candidates[oldIndex]
                return Candidate(
                    id: previous.id,
                    text: word.text,
                    alignmentKey: alignmentKey,
                    confirmationKey: confirmationKey,
                    startSequence: word.startSequence,
                    endSequence: word.endSequence,
                    confidence: word.confidence,
                    confirmations: previous.confirmationKey == confirmationKey
                        ? previous.confirmations + 1 : 1
                )
            }
            defer { nextID &+= 1 }
            return Candidate(
                id: nextID,
                text: word.text,
                alignmentKey: alignmentKey,
                confirmationKey: confirmationKey,
                startSequence: word.startSequence,
                endSequence: word.endSequence,
                confidence: word.confidence,
                confirmations: 1
            )
        }
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
              candidate.confirmations >= policy.initialEvidenceRequired else { return false }
        return candidate.endSequence <= audioEndSequence
    }

    private mutating func commitEligibleWords(audioEndSequence: UInt64, sampleRate: Int32) {
        guard sampleRate > 0 else { return }
        let lag = UInt64(Double(sampleRate) * policy.commitLagSeconds)
        let stableThrough = audioEndSequence > lag ? audioEndSequence - lag : 0
        var promotions: [(candidate: Candidate, visibleIndex: Int)] = []
        var usedVisibleIndices: Set<Int> = []
        for candidate in candidates {
            guard candidate.confirmations >= commitConfirmationsRequired,
                  candidate.endSequence <= stableThrough,
                  let visibleIndex = visibleCandidates.indices.first(where: { index in
                      !usedVisibleIndices.contains(index)
                          && visibleCandidates[index].confirmationKey == candidate.confirmationKey
                          && visibleCandidates[index].startSequence <= candidate.endSequence
                          && candidate.startSequence <= visibleCandidates[index].endSequence
                  }) else { break }
            usedVisibleIndices.insert(visibleIndex)
            promotions.append((candidate, visibleIndex))
        }
        guard !promotions.isEmpty else { return }
        for promotion in promotions {
            let visibleID = visibleCandidates[promotion.visibleIndex].id
            appendCommitted(promotion.candidate.replacingID(with: visibleID))
            pendingReplacements[visibleID] = nil
            missingObservations[visibleID] = nil
        }
        candidates.removeFirst(promotions.count)
        for index in usedVisibleIndices.sorted(by: >) {
            visibleCandidates.remove(at: index)
        }
    }

    private mutating func appendCommitted(_ candidate: Candidate) {
        let word = StableTranscriptWord(
            id: candidate.id,
            text: candidate.text,
            isCommitted: true,
            anchor: nextAnchor
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
