@preconcurrency import AVFoundation
import Darwin
import Foundation
import SubtitolCore

struct AudioQualityMetrics: Codable, Sendable {
    let rms: Float
    let peak: Float
    let clippedSampleCount: Int
    let discontinuityCount: UInt64

    var energySpeechDetected: Bool { rms >= 0.01 }
}

struct CapturedAudio: Sendable {
    let samples: [Float]
    let sampleRate: Int32
    let sequence: UInt64
    let sourceStartSequence: UInt64
    let leadingPaddingSampleCount: Int
    let realSampleCount: Int
    let endHostTime: UInt64
    let overrunCount: UInt64
    let qualityMetrics: AudioQualityMetrics

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / Double(sampleRate)
    }

    var realDuration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(realSampleCount) / Double(sampleRate)
    }

    var leadingPaddingMilliseconds: Int32 {
        guard sampleRate > 0 else { return 0 }
        return Int32(Double(leadingPaddingSampleCount) / Double(sampleRate) * 1_000)
    }

    func hostTime(forSequence targetSequence: UInt64) -> UInt64 {
        guard sampleRate > 0, targetSequence < sequence else { return endHostTime }
        let secondsBehind = Double(sequence - targetSequence) / Double(sampleRate)
        let ticksBehind = AVAudioTime.hostTime(forSeconds: secondsBehind)
        return endHostTime > ticksBehind ? endHostTime - ticksBehind : 0
    }
}

final class AudioCapture {
    static let rollingWindowSeconds: TimeInterval = 6

    /// Speech sits around 0.02-0.2 RMS, so this maps a normal voice across most of 0...1.
    private static let voiceGain: Float = 6

    enum CaptureError: LocalizedError {
        case unavailable
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "No s'ha pogut obrir el micròfon del Mac."
            case .unsupportedFormat:
                "El micròfon ha retornat un format d'àudio no compatible."
            }
        }
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var ringSamples: [Float] = []
    private var writeIndex = 0
    private var storedSampleCount = 0
    private var totalSamplesCaptured: UInt64 = 0
    private var activeSampleRate: Int32 = 0
    private var lastBufferEndHostTime: UInt64 = 0
    private var lastBufferSampleTime: AVAudioFramePosition?
    private var lastBufferFrameCount: AVAudioFramePosition = 0
    private var overrunCount: UInt64 = 0
    private var levelAccumulator = AudioLevelPeakAccumulator()
    private var isRunning = false
    private var audioAvailableHandler: (@Sendable (
        _ sequence: UInt64,
        _ hostTime: UInt64,
        _ sampleRate: Int32
    ) -> Void)?

    var onAudioAvailable: (@Sendable (
        _ sequence: UInt64,
        _ hostTime: UInt64,
        _ sampleRate: Int32
    ) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return audioAvailableHandler
        }
        set {
            lock.lock()
            audioAvailableHandler = newValue
            lock.unlock()
        }
    }

    static func requestPermission(_ completion: @escaping @Sendable (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        default:
            completion(false)
        }
    }

    func start() throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0,
              format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32 else {
            throw CaptureError.unsupportedFormat
        }

        let sampleRate = Int32(format.sampleRate.rounded())
        let capacity = max(1, Int(format.sampleRate * Self.rollingWindowSeconds))
        lock.lock()
        ringSamples = [Float](repeating: 0, count: capacity)
        writeIndex = 0
        storedSampleCount = 0
        totalSamplesCaptured = 0
        activeSampleRate = sampleRate
        lastBufferEndHostTime = 0
        lastBufferSampleTime = nil
        lastBufferFrameCount = 0
        overrunCount = 0
        levelAccumulator.reset()
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 256, format: format) { [weak self] buffer, when in
            guard let self, let channels = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard frameCount > 0, channelCount > 0 else { return }

            self.lock.lock()
            let capacity = self.ringSamples.count
            guard capacity > 0 else {
                self.lock.unlock()
                return
            }

            var write = self.writeIndex
            var stored = self.storedSampleCount
            var sumSquares: Float = 0
            for frame in 0..<frameCount {
                var mono = channels[0][frame]
                if channelCount > 1 {
                    for channel in 1..<channelCount {
                        mono += channels[channel][frame]
                    }
                    mono /= Float(channelCount)
                }
                self.ringSamples[write] = mono
                sumSquares += mono * mono
                write += 1
                if write == capacity { write = 0 }
                stored = min(stored + 1, capacity)
            }
            self.writeIndex = write
            self.storedSampleCount = stored

            let target = min(1, (sumSquares / Float(frameCount)).squareRoot() * Self.voiceGain)
            // Preserve a short peak until the next renderer read. The renderer owns the
            // perceptual attack/release envelope, so this adds no second smoothing delay.
            self.levelAccumulator.observe(target)
            self.totalSamplesCaptured &+= UInt64(frameCount)
            if when.isSampleTimeValid {
                if let previousSampleTime = self.lastBufferSampleTime {
                    let expected = previousSampleTime + self.lastBufferFrameCount
                    if when.sampleTime > expected {
                        self.overrunCount &+= 1
                    }
                }
                self.lastBufferSampleTime = when.sampleTime
                self.lastBufferFrameCount = AVAudioFramePosition(frameCount)
            }
            if when.hostTime > 0 {
                self.lastBufferEndHostTime = when.hostTime + AVAudioTime.hostTime(
                    forSeconds: Double(frameCount) / buffer.format.sampleRate
                )
            } else {
                self.lastBufferEndHostTime = mach_absolute_time()
            }
            let sequence = self.totalSamplesCaptured
            let hostTime = self.lastBufferEndHostTime
            let sampleRate = self.activeSampleRate
            self.lock.unlock()

            self.onAudioAvailable?(sequence, hostTime, sampleRate)
        }

        do {
            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            eraseAudioFromMemory()
            throw CaptureError.unavailable
        }
    }

    func currentVoiceLevel() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return levelAccumulator.consume()
    }

    func discardPendingVoicePeak() {
        lock.lock()
        levelAccumulator.discardPendingPeak()
        lock.unlock()
    }

    func snapshot(windowSeconds: TimeInterval, padToWindow: Bool) -> CapturedAudio {
        lock.lock()
        let requestedCount = max(1, Int(Double(activeSampleRate) * windowSeconds))
        let count = min(storedSampleCount, requestedCount)
        let outputCount = padToWindow ? requestedCount : count
        let leadingPadding = outputCount - count
        let capacity = ringSamples.count
        let sequence = totalSamplesCaptured
        let sourceStartSequence = sequence - UInt64(count)
        let sampleRate = activeSampleRate
        let endHostTime = lastBufferEndHostTime
        let overrunCount = overrunCount
        var ordered = [Float](repeating: 0, count: outputCount)

        if count > 0, capacity > 0 {
            let start = (writeIndex - count + capacity) % capacity
            let firstCount = min(count, capacity - start)
            ordered.withUnsafeMutableBufferPointer { destination in
                ringSamples.withUnsafeBufferPointer { source in
                    destination.baseAddress?.advanced(by: leadingPadding).update(
                        from: source.baseAddress!.advanced(by: start),
                        count: firstCount
                    )
                    let remaining = count - firstCount
                    if remaining > 0 {
                        destination.baseAddress?.advanced(by: leadingPadding + firstCount).update(
                            from: source.baseAddress!,
                            count: remaining
                        )
                    }
                }
            }
        }
        lock.unlock()

        var sumSquares: Double = 0
        var peak: Float = 0
        var clippedSampleCount = 0
        if count > 0 {
            for sample in ordered.suffix(count) {
                let magnitude = abs(sample)
                sumSquares += Double(sample * sample)
                peak = max(peak, magnitude)
                if magnitude >= 0.999 { clippedSampleCount += 1 }
            }
        }
        let rms = count > 0 ? Float(sqrt(sumSquares / Double(count))) : 0

        return CapturedAudio(
            samples: ordered,
            sampleRate: sampleRate,
            sequence: sequence,
            sourceStartSequence: sourceStartSequence,
            leadingPaddingSampleCount: leadingPadding,
            realSampleCount: count,
            endHostTime: endHostTime,
            overrunCount: overrunCount,
            qualityMetrics: AudioQualityMetrics(
                rms: rms,
                peak: peak,
                clippedSampleCount: clippedSampleCount,
                discontinuityCount: overrunCount
            )
        )
    }

    func currentPosition() -> (sequence: UInt64, sampleRate: Int32) {
        lock.lock()
        defer { lock.unlock() }
        return (totalSamplesCaptured, activeSampleRate)
    }

    func stopAndDiscard() {
        stopEngine()
        eraseAudioFromMemory()
    }

    func stopAndSnapshot(windowSeconds: TimeInterval) -> CapturedAudio {
        stopEngine()
        let captured = snapshot(windowSeconds: windowSeconds, padToWindow: false)
        eraseAudioFromMemory()
        return captured
    }

    private func stopEngine() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    private func eraseAudioFromMemory() {
        lock.lock()
        ringSamples.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: 0)
        }
        ringSamples.removeAll(keepingCapacity: false)
        writeIndex = 0
        storedSampleCount = 0
        totalSamplesCaptured = 0
        activeSampleRate = 0
        lastBufferEndHostTime = 0
        lastBufferSampleTime = nil
        lastBufferFrameCount = 0
        overrunCount = 0
        levelAccumulator.reset()
        lock.unlock()
    }
}
