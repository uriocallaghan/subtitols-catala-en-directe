import Foundation

/// How the phone's voice orb (Seda) answers the microphone.
///
/// Two envelopes read the same level. `pulse` follows syllables (fast attack, short
/// release) and stirs the inside on every stressed sound; `presence` follows speaking
/// itself (slow attack, long release) and deepens the turbulence and speeds the silk
/// while someone talks, then lets them settle over a second of silence. The outline
/// never changes: the orb is a still circle that boils inside. The cycle angle only ever moves forward, so the silk never
/// rewinds.
///
/// A second clock, `flow`, stirs the inside like molten glass: it never stops, so the
/// orb is alive even in silence, and a voice churns it several times faster and deeper.
public struct OrbMotionDynamics: Sendable {
    /// The design's cycle: 399.4 s at motion 0.4, one turn every ~17 minutes at rest.
    /// A faster rest (one turn in two minutes, with a quicker liquid) was tried on
    /// 2026-09-27 and found far too busy: at rest the orb only drifts.
    public static let restCyclesPerSecond = 0.4 / 399.4
    /// While speaking the silk turns up to this many times faster.
    public static let maximumSpeedMultiplier = 70.0
    public static let noiseGate = 0.03
    public static let pulseAttackSeconds = 0.035
    public static let pulseReleaseSeconds = 0.22
    public static let presenceAttackSeconds = 0.30
    public static let presenceReleaseSeconds = 1.40
    /// One turn of the liquid's phase at rest. The shader stirs at whole multiples of
    /// it, up to 5×, so the slowest current turns in 16 s and the fastest in about 3.
    public static let restFlowSecondsPerTurn = 16.0
    /// While speaking the liquid churns up to this many times faster.
    public static let maximumFlowMultiplier = 6.0
    public static let maximumDeltaTime = 1.0 / 12.0

    /// Cycle angle in turns, kept in 0..<1; every term of the shader has a whole-number
    /// frequency in it, so wrapping is seamless.
    public private(set) var theta: Double
    public private(set) var pulse: Double = 0
    public private(set) var presence: Double = 0
    /// The liquid's phase in turns, kept in 0..<1 like `theta`.
    public private(set) var flow: Double = 0

    public init(theta: Double = 0.5) {
        self.theta = theta.isFinite ? theta - floor(theta) : 0
    }

    /// Shader parameters for one frame, on top of the design's rest values.
    public struct Frame: Equatable, Sendable {
        public var theta: Double
        /// Phase of the liquid inside, in turns.
        public var flow: Double
        /// How far the liquid folds over itself: calm at rest, churning while speaking.
        public var churn: Double
        public var level: Double
        public var size: Double
        public var deform: Double
        public var deformDetail: Double
        public var turbulence: Double
        public var crest: Double
        public var balance: Double
    }

    /// `listening` is false when nothing is being recorded: the orb then rests, whatever
    /// the microphone hears.
    public mutating func advance(deltaTime: Double, voiceLevel: Float, listening: Bool) -> Frame {
        let elapsed = deltaTime.isFinite && deltaTime > 0 ? min(deltaTime, Self.maximumDeltaTime) : 0
        let target = listening ? Self.normalized(voiceLevel) : 0
        pulse = Self.follow(pulse, target, elapsed, Self.pulseAttackSeconds, Self.pulseReleaseSeconds)
        presence = Self.follow(presence, target, elapsed, Self.presenceAttackSeconds, Self.presenceReleaseSeconds)

        let speed = 1 + (Self.maximumSpeedMultiplier - 1) * (0.75 * presence + 0.25 * pulse)
        theta += Self.restCyclesPerSecond * speed * elapsed
        theta -= floor(theta)
        let flowSpeed = 1 + (Self.maximumFlowMultiplier - 1) * (0.6 * presence + 0.4 * pulse)
        flow += flowSpeed * elapsed / Self.restFlowSecondsPerTurn
        flow -= floor(flow)

        // The outline never moves: the orb stays a perfect circle and all of its life
        // is inside, where the liquid churns faster and deeper with the voice.
        return Frame(
            theta: theta,
            flow: flow,
            churn: 0.8 + 0.8 * presence + 0.5 * pulse,
            level: pulse,
            size: 0.86,
            deform: 0,
            deformDetail: 0,
            turbulence: 1 + 0.8 * presence + 0.3 * pulse,
            crest: 1 + 0.4 * pulse,
            balance: 0.32 + 0.22 * pulse
        )
    }

    private static func follow(
        _ value: Double,
        _ target: Double,
        _ elapsed: Double,
        _ attack: Double,
        _ release: Double
    ) -> Double {
        let constant = target > value ? attack : release
        let next = value + (target - value) * (1 - exp(-elapsed / constant))
        return min(1, max(0, next))
    }

    /// Speech sits near the bottom of the RMS scale; the same perceptual curve as the
    /// Mac's field, so a normal voice reaches most of the range.
    static func normalized(_ level: Float) -> Double {
        let value = Double(level)
        guard value.isFinite, value > noiseGate else { return 0 }
        let linear = min(1, (value - noiseGate) / (1 - noiseGate))
        return min(1, pow(linear, 0.4) * 1.5)
    }
}
