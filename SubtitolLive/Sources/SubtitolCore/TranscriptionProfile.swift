import Foundation

/// A session-scoped compromise between display latency and visual stability.
public enum TranscriptionProfile: String, CaseIterable, Codable, Sendable {
    case reliable
    case balanced
    case immediate

    public static let `default`: Self = .reliable

    public var displayName: String {
        switch self {
        case .reliable: "Fiable"
        case .balanced: "Equilibrat"
        case .immediate: "Immediat"
        }
    }

    public var policy: TranscriptStabilityPolicy {
        switch self {
        case .reliable:
            TranscriptStabilityPolicy(
                minimumHopSeconds: 0.300,
                initialEvidenceRequired: 3,
                replacementEvidenceRequired: 3,
                minimumWordAgeSeconds: 0.650,
                commitEvidenceRequired: 3,
                commitLagSeconds: 0.650
            )
        case .balanced:
            TranscriptStabilityPolicy(
                minimumHopSeconds: 0.240,
                initialEvidenceRequired: 2,
                replacementEvidenceRequired: 2,
                minimumWordAgeSeconds: 0.350,
                commitEvidenceRequired: 2,
                commitLagSeconds: 0.350
            )
        case .immediate:
            TranscriptStabilityPolicy(
                minimumHopSeconds: 0.180,
                initialEvidenceRequired: 1,
                replacementEvidenceRequired: 1,
                minimumWordAgeSeconds: 0,
                commitEvidenceRequired: 2,
                commitLagSeconds: 0.350
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

    public init(
        minimumHopSeconds: TimeInterval,
        initialEvidenceRequired: Int,
        replacementEvidenceRequired: Int,
        minimumWordAgeSeconds: TimeInterval,
        commitEvidenceRequired: Int,
        commitLagSeconds: TimeInterval
    ) {
        self.minimumHopSeconds = max(0, minimumHopSeconds)
        self.initialEvidenceRequired = max(1, initialEvidenceRequired)
        self.replacementEvidenceRequired = max(1, replacementEvidenceRequired)
        self.minimumWordAgeSeconds = max(0, minimumWordAgeSeconds)
        self.commitEvidenceRequired = max(1, commitEvidenceRequired)
        self.commitLagSeconds = max(self.minimumWordAgeSeconds, commitLagSeconds)
    }
}
