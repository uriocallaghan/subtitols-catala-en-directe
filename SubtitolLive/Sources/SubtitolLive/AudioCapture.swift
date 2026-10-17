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

/// Brings an input recorded at another rate to the session's rate. `nil` when the
/// rates already match.
private final class SampleRateConverter {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat

    init?(from input: AVAudioFormat, to sampleRate: Double) {
        guard sampleRate > 0, input.sampleRate != sampleRate,
              let output = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: sampleRate,
                  channels: input.channelCount,
                  interleaved: false
              ),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.converter = converter
        self.output = output
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if supplied {
                // Keeps the converter's filter state for the next buffer.
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, converted.frameLength > 0 else { return nil }
        return converted
    }
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
    /// Seconds of audio kept. Every window a snapshot asks for must fit, or its start
    /// would be silence instead of speech.
    let rollingWindowSeconds: TimeInterval

    init(rollingWindowSeconds: TimeInterval = LiveWindowPolicy.finalWindowSeconds) {
        self.rollingWindowSeconds = rollingWindowSeconds
    }

    /// Speech sits around 0.02-0.2 RMS, so this maps a normal voice across most of 0...1.
    private static let voiceGain: Float = 6

    enum CaptureError: LocalizedError {
        case unavailable
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .unavailable:
                #if os(iOS)
                localized("No s'ha pogut obrir el micròfon de l'iPhone.")
                #else
                localized("No s'ha pogut obrir el micròfon del Mac.")
                #endif
            case .unsupportedFormat:
                localized("El micròfon ha retornat un format d'àudio no compatible.")
            }
        }
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    /// The session's sample rate. Every input opened during a session is converted to
    /// it, so sequences and the ring stay continuous when the microphone changes.
    private var sessionSampleRate: Double = 0
    private var configurationObserver: NSObjectProtocol?
    private var pendingReopen: DispatchWorkItem?
    private var failedReopens = 0
    #if os(iOS)
    private var routeObserver: NSObjectProtocol?
    #else
    private var hardwareListener: AudioObjectPropertyListenerBlock?
    private var openedDeviceID: AudioDeviceID?
    #endif

    /// The microphone chosen in the settings (a Core Audio device UID on the Mac, an
    /// `AVAudioSessionPortDescription.uid` on the iPhone); `nil` follows the system.
    /// Changing it while listening switches over without stopping. Main thread only.
    var preferredInputUID: String? {
        didSet {
            guard preferredInputUID != oldValue, isRunning else { return }
            #if os(iOS)
            Self.applyPreferredInput(preferredInputUID)
            scheduleReopen(after: 0.1, onlyIfDeviceChanged: false)
            #else
            scheduleReopen(after: 0, onlyIfDeviceChanged: true)
            #endif
        }
    }

    /// Called on the main thread when no microphone can be opened any more.
    var onInputLost: (() -> Void)?
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
        #if DEBUG
        // A replayed recording needs no microphone, and the Simulator's permission
        // request never returns without the Mac's own.
        if ProcessInfo.processInfo.environment["SUBTITOL_REPLAY_AUDIO"] != nil {
            completion(true)
            return
        }
        #endif
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

        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["SUBTITOL_REPLAY_AUDIO"] {
            try startReplay(of: URL(fileURLWithPath: path))
            return
        }
        #endif
        #if os(iOS)
        try activateSession()
        #endif
        do {
            try openInput(startingSession: true)
        } catch {
            eraseAudioFromMemory()
            #if os(iOS)
            deactivateSession()
            #endif
            throw error
        }
        isRunning = true
        failedReopens = 0
        observeInputChanges()
    }

    /// Opens the current input. Starting a session fixes its sample
    /// rate; reopening converts the new input to that rate and carries on.
    private func openInput(startingSession: Bool) throws {
        #if os(macOS)
        let deviceID = AudioInputs.resolve(preferredUID: preferredInputUID)
        if var deviceID, let unit = engine.inputNode.audioUnit {
            // Failing here leaves the system input, which is still a microphone.
            _ = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        #endif
        let input = engine.inputNode
        #if os(macOS)
        // After a device is set, only the input side reports its real format; a tap
        // in the stale output format receives nothing.
        let format = input.inputFormat(forBus: 0)
        #else
        let format = input.outputFormat(forBus: 0)
        // Partway through a route change (headphones in or out) the node can still
        // report the old route's format while the hardware already runs at another rate.
        // A tap in that format raises an Objective-C exception Swift cannot catch, and
        // the app aborted (29 Sep, reopening after a route change). The formats are
        // compared first; a mismatch is retried by `reopenInput` until they agree.
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              hardware.sampleRate == format.sampleRate,
              AVAudioSession.sharedInstance().isInputAvailable else {
            throw CaptureError.unsupportedFormat
        }
        #endif
        guard format.sampleRate > 0,
              format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32 else {
            throw CaptureError.unsupportedFormat
        }

        if startingSession {
            sessionSampleRate = format.sampleRate
            resetRing(sampleRate: format.sampleRate)
        } else {
            // The new input keeps its own clock: its first buffer is not a gap.
            lock.lock()
            lastBufferSampleTime = nil
            lastBufferFrameCount = 0
            lock.unlock()
        }

        let converter = SampleRateConverter(from: format, to: sessionSampleRate)
        input.installTap(onBus: 0, bufferSize: 256, format: format) { [weak self] buffer, when in
            guard let self else { return }
            let sourceFrames = Int(buffer.frameLength)
            var buffer = buffer
            if let converter {
                guard let converted = converter.convert(buffer) else { return }
                buffer = converted
            }
            guard let channels = buffer.floatChannelData else { return }
            self.ingest(
                channels: channels,
                frameCount: Int(buffer.frameLength),
                channelCount: Int(buffer.format.channelCount),
                sampleRate: buffer.format.sampleRate,
                when: when,
                sourceFrameCount: sourceFrames
            )
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.unavailable
        }
        #if os(macOS)
        openedDeviceID = deviceID
        #endif
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            // The engine stops itself when its device goes away or changes format.
            self?.scheduleReopen(after: 0.1, onlyIfDeviceChanged: false)
        }
    }

    private func closeInput() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Unplugging headphones, plugging in a microphone or choosing another one reopens
    /// the input, so listening carries on with whatever is there now.
    private func observeInputChanges() {
        #if os(iOS)
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable, .override, .routeConfigurationChange:
                self?.scheduleReopen(after: 0.1, onlyIfDeviceChanged: false)
            default:
                break
            }
        }
        #else
        hardwareListener = AudioInputs.observeChanges { [weak self] in
            self?.scheduleReopen(after: 0.1, onlyIfDeviceChanged: true)
        }
        #endif
    }

    private func stopObservingInputChanges() {
        pendingReopen?.cancel()
        pendingReopen = nil
        #if os(iOS)
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }
        #else
        if let hardwareListener {
            AudioInputs.stopObserving(hardwareListener)
            self.hardwareListener = nil
        }
        #endif
    }

    /// Several notices arrive for one plug or unplug; they are folded into one reopen.
    private func scheduleReopen(after delay: TimeInterval, onlyIfDeviceChanged: Bool) {
        guard isRunning else { return }
        #if DEBUG
        guard replayTimer == nil else { return }
        #endif
        // A forced reopen already waiting stays forced.
        let force = !onlyIfDeviceChanged || (pendingReopen != nil && pendingForce)
        pendingReopen?.cancel()
        pendingForce = force
        let work = DispatchWorkItem { [weak self] in
            self?.reopenInput(force: force)
        }
        pendingReopen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private var pendingForce = false

    private func reopenInput(force: Bool) {
        pendingReopen = nil
        guard isRunning else { return }
        #if os(macOS)
        if !force, engine.isRunning,
           AudioInputs.resolve(preferredUID: preferredInputUID) == openedDeviceID {
            return
        }
        #else
        // A chosen microphone plugged back in takes over again.
        Self.applyPreferredInput(preferredInputUID)
        #endif
        closeInput()
        do {
            try openInput(startingSession: false)
            failedReopens = 0
        } catch {
            failedReopens += 1
            if failedReopens < 6 {
                scheduleReopen(after: 0.5, onlyIfDeviceChanged: false)
            } else {
                onInputLost?()
            }
        }
    }

    private func resetRing(sampleRate: Double) {
        let capacity = max(1, Int(sampleRate * rollingWindowSeconds))
        lock.lock()
        ringSamples = [Float](repeating: 0, count: capacity)
        writeIndex = 0
        storedSampleCount = 0
        totalSamplesCaptured = 0
        activeSampleRate = Int32(sampleRate.rounded())
        lastBufferEndHostTime = 0
        lastBufferSampleTime = nil
        lastBufferFrameCount = 0
        overrunCount = 0
        levelAccumulator.reset()
        lock.unlock()
    }

    private func ingest(
        channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        frameCount: Int,
        channelCount: Int,
        sampleRate: Double,
        when: AVAudioTime,
        sourceFrameCount: Int? = nil
    ) {
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
            // The input's own clock, which runs at its rate before any conversion.
            self.lastBufferFrameCount = AVAudioFramePosition(sourceFrameCount ?? frameCount)
        }
        if when.hostTime > 0 {
            self.lastBufferEndHostTime = when.hostTime + AVAudioTime.hostTime(
                forSeconds: Double(frameCount) / sampleRate
            )
        } else {
            self.lastBufferEndHostTime = mach_absolute_time()
        }
        let sequence = self.totalSamplesCaptured
        let hostTime = self.lastBufferEndHostTime
        let activeRate = self.activeSampleRate
        self.lock.unlock()

        self.onAudioAvailable?(sequence, hostTime, activeRate)
    }

    #if DEBUG
    private var replayTimer: DispatchSourceTimer?

    /// Development only: `SUBTITOL_REPLAY_AUDIO=<file>` plays a recording into the
    /// capture path at real-time pace instead of opening the microphone (the iOS
    /// Simulator cannot open the Mac's microphone without a system permission), then
    /// keeps feeding silence so the session runs on.
    private func startReplay(of url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CaptureError.unsupportedFormat
        }
        try file.read(into: buffer)
        guard let source = buffer.floatChannelData else { throw CaptureError.unsupportedFormat }
        let channelCount = Int(format.channelCount)
        let total = Int(buffer.frameLength)
        let sampleRate = format.sampleRate
        let chunk = max(1, Int(sampleRate * 0.02))
        resetRing(sampleRate: sampleRate)

        var position = 0
        let silence = (0..<channelCount).map { _ -> UnsafeMutablePointer<Float> in
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
            samples.initialize(repeating: 0, count: chunk)
            return samples
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "cat.subtitollive.replay"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let when = AVAudioTime(hostTime: mach_absolute_time())
            if position < total {
                let count = min(chunk, total - position)
                var pointers = (0..<channelCount).map { UnsafeMutablePointer(source[$0].advanced(by: position)) }
                pointers.withUnsafeMutableBufferPointer { channels in
                    self.ingest(channels: UnsafePointer(channels.baseAddress!), frameCount: count,
                                channelCount: channelCount, sampleRate: sampleRate, when: when)
                }
                position += count
            } else {
                var pointers = silence
                pointers.withUnsafeMutableBufferPointer { channels in
                    self.ingest(channels: UnsafePointer(channels.baseAddress!), frameCount: chunk,
                                channelCount: channelCount, sampleRate: sampleRate, when: when)
                }
            }
            // The decoded recording must outlive every tick that reads from it.
            withExtendedLifetime(buffer) {}
        }
        timer.setCancelHandler {
            silence.forEach { $0.deallocate() }
        }
        replayTimer = timer
        sessionSampleRate = sampleRate
        isRunning = true
        timer.resume()
    }
    #endif

    #if os(iOS)
    /// Recording only, in measurement mode: no automatic gain or voice processing, so
    /// the recogniser and the silence filter hear the same raw signal as on the Mac.
    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try Self.prepareSession()
            // iOS mutes haptics while recording unless asked; the text-size track and
            // the controls should still be felt while listening.
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            Self.applyPreferredInput(preferredInputUID)
            try session.setActive(true)
        } catch {
            throw CaptureError.unavailable
        }
    }

    /// The recording category. Also set before listening, so the microphone picker can
    /// see wired and Bluetooth inputs: `availableInputs` depends on the category.
    static func prepareSession() throws {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .record || session.mode != .measurement
              || !session.categoryOptions.contains(.allowBluetoothHFP) else { return }
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
    }

    /// Asks for the chosen microphone while it is connected; otherwise, and for `nil`,
    /// iOS picks (the last one connected). Does nothing when it is already in use, since
    /// each request is a route change of its own.
    static func applyPreferredInput(_ uid: String?) {
        let session = AVAudioSession.sharedInstance()
        let port = uid.flatMap { uid in session.availableInputs?.first { $0.uid == uid } }
        guard session.preferredInput?.uid != port?.uid else { return }
        try? session.setPreferredInput(port)
    }

    /// Hands the audio back, so music another app paused can resume.
    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    #endif

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
        #if DEBUG
        if let replayTimer {
            replayTimer.cancel()
            self.replayTimer = nil
            isRunning = false
            return
        }
        #endif
        stopObservingInputChanges()
        closeInput()
        isRunning = false
        failedReopens = 0
        #if os(iOS)
        deactivateSession()
        #endif
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
