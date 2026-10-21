import CoreHaptics

/// The feel of the text-size track: a fine gear under the finger.
///
/// Dragging runs over faint ticks, four between every size, so the track has a grain
/// you can feel; each size lands with a soft wooden "tok" and a fainter echo, a little
/// fuller as the text grows; the two ends answer with a muffled bump instead of another
/// tick. Everything is low and soft rather than sharp: the point is a pleasant texture,
/// not an alert. Phones without a haptic engine simply stay silent.
@MainActor
final class DetentHaptics {
    static let shared = DetentHaptics()

    private var engine: CHHapticEngine?
    private var isRunning = false

    private init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics,
              let engine = try? CHHapticEngine() else { return }
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = true
        engine.stoppedHandler = { [weak self] _ in
            Task { @MainActor in self?.isRunning = false }
        }
        engine.resetHandler = { [weak self] in
            Task { @MainActor in self?.isRunning = false }
        }
        self.engine = engine
    }

    /// Wakes the engine as the finger lands, so the first tick is not late.
    func grab() {
        play([Self.tap(intensity: 0.2, sharpness: 0.3)])
    }

    /// A fine tick between two sizes.
    func grain() {
        play([Self.tap(intensity: 0.11, sharpness: 0.55)])
    }

    /// A new size. `fraction` is how far along the track it sits, 0 to 1.
    func detent(fraction: Double) {
        let body = 0.34 + 0.3 * min(1, max(0, fraction))
        play([
            Self.tap(intensity: body, sharpness: 0.16),
            Self.tap(intensity: body * 0.3, sharpness: 0.06, at: 0.022),
        ])
    }

    /// Pushing past the smallest or largest size.
    func boundary() {
        play([
            CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.42),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.02),
                    CHHapticEventParameter(parameterID: .attackTime, value: 0),
                    CHHapticEventParameter(parameterID: .decayTime, value: 0.06),
                    CHHapticEventParameter(parameterID: .sustained, value: 0),
                ],
                relativeTime: 0,
                duration: 0.07
            ),
        ])
    }

    /// The knob settling on its size as the finger lifts.
    func settle() {
        play([Self.tap(intensity: 0.22, sharpness: 0.12)])
    }

    private static func tap(intensity: Double, sharpness: Double, at time: TimeInterval = 0) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(intensity)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(sharpness)),
            ],
            relativeTime: time
        )
    }

    private func play(_ events: [CHHapticEvent]) {
        guard let engine else { return }
        if !isRunning {
            do {
                try engine.start()
                isRunning = true
            } catch {
                return
            }
        }
        guard let pattern = try? CHHapticPattern(events: events, parameters: []),
              let player = try? engine.makePlayer(with: pattern) else { return }
        try? player.start(atTime: CHHapticTimeImmediate)
    }
}
