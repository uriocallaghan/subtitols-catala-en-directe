import Foundation

/// A session-scoped compromise between display latency and visual stability.
public enum TranscriptionProfile: String, CaseIterable, Codable, Sendable {
    case reliable
    case balanced
    case immediate

    public static let `default`: Self = .reliable

    public var displayName: String {
        switch self {
        case .reliable: localized("Fiable")
        case .balanced: localized("Equilibrat")
        case .immediate: localized("Immediat")
        }
    }

    /// The hop is the same for Fiable and Equilibrat: with 7 s of context a hypothesis
    /// every 300 ms is all the evidence the editor can use, and the GPU stays cooler.
    public var policy: TranscriptStabilityPolicy {
        switch self {
        case .reliable:
            TranscriptStabilityPolicy(
                minimumHopSeconds: 0.300,
                initialEvidenceRequired: 3,
                replacementEvidenceRequired: 3,
                minimumWordAgeSeconds: 0.650,
                commitEvidenceRequired: 3,
                commitLagSeconds: 0.650,
                overdueEvidenceRequired: TranscriptStabilityPolicy.never,
                overdueHearingsToJudge: 4,
                minimumConfidence: 0.5
            )
        case .balanced:
            TranscriptStabilityPolicy(
                minimumHopSeconds: 0.300,
                initialEvidenceRequired: 2,
                replacementEvidenceRequired: 2,
                minimumWordAgeSeconds: 0.350,
                commitEvidenceRequired: 3,
                commitLagSeconds: 0.650,
                overdueEvidenceRequired: TranscriptStabilityPolicy.never,
                overdueHearingsToJudge: 4,
                minimumConfidence: 0.5
            )
        case .immediate:
            TranscriptStabilityPolicy(
                minimumHopSeconds: 0.180,
                initialEvidenceRequired: 1,
                replacementEvidenceRequired: 1,
                minimumWordAgeSeconds: 0,
                commitEvidenceRequired: 2,
                commitLagSeconds: 0.350,
                overdueEvidenceRequired: 2,
                minimumConfidence: 0.4
            )
        }
    }
}

public struct TranscriptStabilityPolicy: Equatable, Sendable {
    public let minimumHopSeconds: TimeInterval
    public let initialEvidenceRequired: Int
    public let replacementEvidenceRequired: Int
    public let minimumWordAgeSeconds: TimeInterval
    public let commitEvidenceRequired: Int
    public let commitLagSeconds: TimeInterval
    /// Times a word's most frequent form must have been heard for the word to be
    /// settled once it has stayed undecided too long; with fewer, it is dropped.
    /// `never` settles no undecided word at all: on 87 ParlamentParla clips, the words
    /// settled that way were wrong 142 times and right 63 ("gardinet", "avestres",
    /// "miedo" for "la nostra escola"), and in a hall with an audience they were most
    /// of what the reader saw.
    public let overdueEvidenceRequired: Int
    public static let never = Int.max
    /// The share of the word's hearings its most frequent form must hold as well
    /// (0 asks nothing): a word heard eight ways in ten windows is noise, not a word.
    public let overdueMajorityShare: Double
    /// Hearings an overdue word needs before it is dropped for lack of agreement;
    /// until then it waits, and the words after it wait with it.
    public let overdueHearingsToJudge: Int
    /// Audio a word needs after it before a window's hearing of it counts. At the
    /// window's right edge the recogniser decodes a word with no future, and that
    /// first hearing is its worst.
    public let minimumRightContextSeconds: TimeInterval
    /// The recogniser's confidence (mean over the hearings of a form) a word needs to
    /// be shown or settled; under it the word waits unseen and is dropped once overdue.
    /// 0 asks nothing. A word heard without confidence passes. At 0.5, right words
    /// keep a median of 0.80 (clean) and 0.72 (a hall), wrong ones 0.69 and 0.59: on
    /// 87 ParlamentParla clips WER 7.52% → 7.31%, in the venue test's hall wrong words
    /// 9.8% → 8.0% of the words said, crowd inventions 11 → 7; 0.6 costs 3.5 points of
    /// clean recall for little more.
    public let minimumConfidence: Float

    public init(
        minimumHopSeconds: TimeInterval,
        initialEvidenceRequired: Int,
        replacementEvidenceRequired: Int,
        minimumWordAgeSeconds: TimeInterval,
        commitEvidenceRequired: Int,
        commitLagSeconds: TimeInterval,
        overdueEvidenceRequired: Int = 1,
        overdueMajorityShare: Double = 0,
        overdueHearingsToJudge: Int = 2,
        minimumRightContextSeconds: TimeInterval = 0,
        minimumConfidence: Float = 0
    ) {
        self.minimumHopSeconds = max(0, minimumHopSeconds)
        self.initialEvidenceRequired = max(1, initialEvidenceRequired)
        self.replacementEvidenceRequired = max(1, replacementEvidenceRequired)
        self.minimumWordAgeSeconds = max(0, minimumWordAgeSeconds)
        self.commitEvidenceRequired = max(1, commitEvidenceRequired)
        self.commitLagSeconds = max(self.minimumWordAgeSeconds, commitLagSeconds)
        self.overdueEvidenceRequired = max(1, overdueEvidenceRequired)
        self.overdueMajorityShare = min(1, max(0, overdueMajorityShare))
        self.overdueHearingsToJudge = max(1, overdueHearingsToJudge)
        self.minimumRightContextSeconds = max(0, minimumRightContextSeconds)
        self.minimumConfidence = min(1, max(0, minimumConfidence))
    }
}
