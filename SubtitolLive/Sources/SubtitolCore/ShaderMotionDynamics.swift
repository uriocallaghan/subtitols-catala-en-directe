import Foundation

/// Deterministic motion state shared by the renderer and its tests.
///
/// The microphone only changes how quickly the phase advances. It never changes the
/// palette, contrast, scale, or any other visual dimension.
public struct ShaderMotionDynamics: Sendable {
    public static let idleSpeed = 0.16
    public static let maximumSpeedMultiplier = 24.0
    public static let noiseGate = 0.03
    public static let attackSeconds = 0.020
    public static let releaseSeconds = 0.240
    public static let maximumDeltaTime = 1.0 / 12.0

    public private(set) var phase: Double
    public private(set) var voiceResponse: Double

    public var speedMultiplier: Double {
        1 + voiceResponse * (Self.maximumSpeedMultiplier - 1)
    }

    public init(phase: Double = 0, voiceResponse: Double = 0) {
        self.phase = phase.isFinite ? phase : 0
        self.voiceResponse = min(1, max(0, voiceResponse.isFinite ? voiceResponse : 0))
    }

    /// Advances the phase without ever trying to catch up after a scheduling gap.
    /// Hidden windows pause the renderer, and a delayed visible frame consumes at most
    /// one idle-frame interval, avoiding a large discontinuity when drawing resumes.
    @discardableResult
    public mutating func advance(deltaTime: Double, voiceLevel: Float) -> Double {
        guard deltaTime.isFinite, deltaTime > 0 else { return phase }

        let elapsed = min(deltaTime, Self.maximumDeltaTime)
        let target = Self.normalizedVoiceLevel(voiceLevel)
        let timeConstant = target > voiceResponse
            ? Self.attackSeconds
            : Self.releaseSeconds
        let blend = 1 - exp(-elapsed / timeConstant)
        voiceResponse += (target - voiceResponse) * blend
        voiceResponse = min(1, max(0, voiceResponse))

        phase += Self.idleSpeed * speedMultiplier * elapsed
        return phase
    }

    private static func normalizedVoiceLevel(_ level: Float) -> Double {
        let value = Double(level)
        guard value.isFinite, value > noiseGate else { return 0 }
        let linearLevel = min(1, max(0, (value - noiseGate) / (1 - noiseGate)))

        // A microphone's useful speech range sits close to the bottom of its RMS scale.
        // Expanding that region makes conversational speech visibly responsive while the
        // gate still prevents room noise from driving the field.
        return pow(linearLevel, 0.4)
    }
}
