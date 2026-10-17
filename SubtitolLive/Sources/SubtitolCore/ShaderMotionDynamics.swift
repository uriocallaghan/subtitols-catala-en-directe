import Foundation

/// Deterministic motion state shared by the renderer and its tests.
///
/// The microphone only changes how quickly the phase advances. It never changes the
/// palette, contrast, scale, or any other visual dimension.
public struct ShaderMotionDynamics: Sendable {
    public static let idleSpeed = 0.16
    public static let maximumSpeedMultiplier = 40.0
    public static let noiseGate = 0.03
    /// Boost applied after the perceptual curve so ordinary speech lands high in the range.
    public static let voiceGain = 1.5
    public static let attackSeconds = 0.045
    /// Long enough to bridge the gaps between syllables and words, so speaking reads as
    /// one sustained fast state instead of a flicker, and silence as a clear glide down.
    public static let releaseSeconds = 0.500
    /// Second smoothing stage on the speed itself: the acceleration has no corners.
    public static let speedSmoothingSeconds = 0.100
    public static let maximumDeltaTime = 1.0 / 12.0

    public private(set) var phase: Double
    /// Speech envelope that follows the microphone level.
    public private(set) var voiceEnvelope: Double
    /// Smoothed envelope that drives the speed.
    public private(set) var voiceResponse: Double

    public var speedMultiplier: Double {
        1 + voiceResponse * (Self.maximumSpeedMultiplier - 1)
    }

    public init(phase: Double = 0, voiceResponse: Double = 0) {
        self.phase = phase.isFinite ? phase : 0
        let response = min(1, max(0, voiceResponse.isFinite ? voiceResponse : 0))
        self.voiceEnvelope = response
        self.voiceResponse = response
    }

    /// Advances the phase without ever trying to catch up after a scheduling gap.
    /// Hidden windows pause the renderer, and a delayed visible frame consumes at most
    /// one idle-frame interval, avoiding a large discontinuity when drawing resumes.
    @discardableResult
    public mutating func advance(deltaTime: Double, voiceLevel: Float) -> Double {
        guard deltaTime.isFinite, deltaTime > 0 else { return phase }

        let elapsed = min(deltaTime, Self.maximumDeltaTime)
        let target = Self.normalizedVoiceLevel(voiceLevel)
        let timeConstant = target > voiceEnvelope
            ? Self.attackSeconds
            : Self.releaseSeconds
        voiceEnvelope += (target - voiceEnvelope) * (1 - exp(-elapsed / timeConstant))
        voiceEnvelope = min(1, max(0, voiceEnvelope))

        let smoothing = 1 - exp(-elapsed / Self.speedSmoothingSeconds)
        voiceResponse += (voiceEnvelope - voiceResponse) * smoothing
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
        return min(1, pow(linearLevel, 0.4) * voiceGain)
    }
}
