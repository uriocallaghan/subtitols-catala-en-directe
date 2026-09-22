@preconcurrency import AVFoundation
import Darwin
import Foundation
import SubtitolCore
import SubtitolEngine

struct LiveRecognitionUpdate: Sendable {
    /// A complete ASR observation on the capture sample clock. The MainActor-owned
    /// stabilizer decides which prefix is safe to publish; the coordinator never merges
    /// overlapping windows destructively.
    let words: [TranscriptObservationWord]
    let windowStartSequence: UInt64
    let audioEndSequence: UInt64
    let windowIncludesSessionStart: Bool
    let timingQuality: TranscriptTimingQuality
    let origin: RecognitionObservationOrigin
    let audioEndHostTime: UInt64
    let sampleRate: Int32
    let captureToSnapshotMilliseconds: Double
    let inferenceMilliseconds: Double
    let inferenceCompletedHostTime: UInt64
    let audioOverrunCount: UInt64
    let audioQuality: AudioQualityMetrics
}

enum RecognitionObservationOrigin: String, Sendable {
    case live
    case final
}

final class RecognitionCoordinator: @unchecked Sendable {
    private enum CoordinatorError: LocalizedError {
        case alreadyRecording

        var errorDescription: String? {
            "La captura de micròfon ja està activa."
        }
    }

    var onInterim: ((LiveRecognitionUpdate) -> Void)?
    var onFinal: ((LiveRecognitionUpdate) -> Void)?
    var onRecoverableError: ((String) -> Void)?
    var onFinalError: ((String) -> Void)?

    private let engine: ASREngine
    private let audioCapture: AudioCapture
    private let diagnosticCapture: DiagnosticCapture?
    private let stateQueue = DispatchQueue(
        label: "cat.subtitollive.scheduler",
        qos: .userInteractive
    )
    private let inferenceQueue = DispatchQueue(
        label: "cat.subtitollive.asr",
        qos: .userInteractive
    )

    private var scheduler: LatestAudioScheduler?
    private var sessionID = UUID()
    private var isRecording = false
    private var minimumHopSeconds = TranscriptionProfile.default.policy.minimumHopSeconds
    private var activity: NSObjectProtocol?

    init(engine: ASREngine, audioCapture: AudioCapture = AudioCapture()) {
        self.engine = engine
        self.audioCapture = audioCapture
        self.diagnosticCapture = DiagnosticCapture.configuredFromEnvironment()
    }

    func start(profile: TranscriptionProfile) throws {
        let activeSession = UUID()
        let accepted = stateQueue.sync {
            guard !isRecording else { return false }
            sessionID = activeSession
            scheduler = nil
            minimumHopSeconds = profile.policy.minimumHopSeconds
            isRecording = true
            return true
        }
        guard accepted else { throw CoordinatorError.alreadyRecording }

        _ = diagnosticCapture?.begin(profile: profile)

        audioCapture.onAudioAvailable = { [weak self] sequence, _, sampleRate in
            self?.stateQueue.async { [weak self] in
                self?.handleAudioAvailable(
                    sequence: sequence,
                    sampleRate: sampleRate,
                    session: activeSession
                )
            }
        }

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Subtítols Parakeet en directe"
        )

        do {
            try audioCapture.start()
        } catch {
            audioCapture.onAudioAvailable = nil
            diagnosticCapture?.finishAndWait()
            stateQueue.sync { isRecording = false }
            endLatencyActivity()
            throw error
        }
    }

    func stop() {
        let finalSession = UUID()
        stateQueue.sync {
            sessionID = finalSession
            isRecording = false
            scheduler?.reset()
        }
        audioCapture.onAudioAvailable = nil
        let finalAudio = audioCapture.stopAndSnapshot(
            windowSeconds: LiveWindowPolicy.finalWindowSeconds
        )
        diagnosticCapture?.recordAudio(finalAudio)
        endLatencyActivity()

        stateQueue.async { [weak self] in
            guard let self else { return }
            guard finalAudio.realDuration >= 0.25 else {
                self.publish(
                    LiveRecognitionUpdate(
                        words: [],
                        windowStartSequence: finalAudio.sourceStartSequence,
                        audioEndSequence: finalAudio.sequence,
                        windowIncludesSessionStart: finalAudio.sourceStartSequence == 0,
                        timingQuality: .wordOffsets,
                        origin: .final,
                        audioEndHostTime: finalAudio.endHostTime,
                        sampleRate: finalAudio.sampleRate,
                        captureToSnapshotMilliseconds: 0,
                        inferenceMilliseconds: 0,
                        inferenceCompletedHostTime: mach_absolute_time(),
                        audioOverrunCount: finalAudio.overrunCount,
                        audioQuality: finalAudio.qualityMetrics
                    ),
                    session: finalSession,
                    final: true
                )
                return
            }
            self.runFinal(audio: finalAudio, session: finalSession)
        }
    }

    func voiceLevel() -> Float {
        audioCapture.currentVoiceLevel()
    }

    func discardPendingVoicePeak() {
        audioCapture.discardPendingVoicePeak()
    }

    func shutdown() {
        audioCapture.onAudioAvailable = nil
        let diagnosticTail = audioCapture.stopAndSnapshot(
            windowSeconds: LiveWindowPolicy.finalWindowSeconds
        )
        diagnosticCapture?.recordAudio(diagnosticTail)
        diagnosticCapture?.finishAndWait()
        endLatencyActivity()
        stateQueue.sync {
            sessionID = UUID()
            isRecording = false
            scheduler?.reset()
        }
        inferenceQueue.sync { }
        stateQueue.sync { }
    }

    private func handleAudioAvailable(sequence: UInt64, sampleRate: Int32, session: UUID) {
        guard sessionID == session, isRecording, sampleRate > 0 else { return }

        if scheduler == nil {
            let hop = UInt64(Double(sampleRate) * minimumHopSeconds)
            scheduler = LatestAudioScheduler(minimumHopSamples: hop)
        }

        let duration = Double(sequence) / Double(sampleRate)
        guard duration >= LiveWindowPolicy.minimumAudioSeconds,
              scheduler?.noteAudio(sequence: sequence) != nil else { return }
        runLive(session: session)
    }

    private func runLive(session: UUID) {
        let position = audioCapture.currentPosition()
        guard position.sampleRate > 0 else { return }
        let audio = audioCapture.snapshot(
            windowSeconds: LiveWindowPolicy.liveWindowSeconds,
            padToWindow: true
        )
        diagnosticCapture?.recordAudio(audio)
        scheduler?.alignInFlightSnapshot(sequence: audio.sequence)
        let snapshotReadyHostTime = mach_absolute_time()
        let captureToSnapshotMilliseconds = hostDeltaMilliseconds(
            from: audio.endHostTime,
            to: snapshotReadyHostTime
        )

        inferenceQueue.async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.engine.transcribe(
                    samples: audio.samples,
                    sampleRate: audio.sampleRate
                )
                let inferenceCompletedHostTime = mach_absolute_time()
                self.stateQueue.async { [weak self] in
                    self?.handleLiveResult(
                        result,
                        audio: audio,
                        captureToSnapshotMilliseconds: captureToSnapshotMilliseconds,
                        inferenceCompletedHostTime: inferenceCompletedHostTime,
                        session: session
                    )
                }
            } catch {
                self.stateQueue.async { [weak self] in
                    self?.handleLiveFailure(error, session: session)
                }
            }
        }
    }

    private func handleLiveResult(
        _ result: ASREngine.Transcription,
        audio: CapturedAudio,
        captureToSnapshotMilliseconds: Double,
        inferenceCompletedHostTime: UInt64,
        session: UUID
    ) {
        guard sessionID == session, isRecording else { return }

        let adjustedWords = wordsRemovingLeadingPadding(result.words, audio: audio)
        let observation = observations(
            from: adjustedWords,
            fallbackText: result.text,
            audio: audio
        )
        publish(
            LiveRecognitionUpdate(
                words: observation.words,
                windowStartSequence: audio.sourceStartSequence,
                audioEndSequence: audio.sequence,
                windowIncludesSessionStart: audio.sourceStartSequence == 0,
                timingQuality: observation.timingQuality,
                origin: .live,
                audioEndHostTime: audio.endHostTime,
                sampleRate: audio.sampleRate,
                captureToSnapshotMilliseconds: captureToSnapshotMilliseconds,
                inferenceMilliseconds: result.inferenceMilliseconds,
                inferenceCompletedHostTime: inferenceCompletedHostTime,
                audioOverrunCount: audio.overrunCount,
                audioQuality: audio.qualityMetrics
            ),
            session: session,
            final: false
        )

        scheduleNewestAudioAfterCompletion(session: session)
    }

    private func handleLiveFailure(_ error: Error, session: UUID) {
        guard sessionID == session, isRecording else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onRecoverableError?(error.localizedDescription)
        }
        scheduleNewestAudioAfterCompletion(session: session)
    }

    private func scheduleNewestAudioAfterCompletion(session: UUID) {
        let latest = audioCapture.currentPosition().sequence
        if scheduler?.complete(latestSequence: latest) != nil,
           sessionID == session,
           isRecording {
            runLive(session: session)
        }
    }

    private func runFinal(audio: CapturedAudio, session: UUID) {
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.engine.transcribe(
                    samples: audio.samples,
                    sampleRate: audio.sampleRate
                )
                self.stateQueue.async { [weak self] in
                    self?.handleFinalResult(result, audio: audio, session: session)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let isCurrent = self.stateQueue.sync {
                        self.sessionID == session && !self.isRecording
                    }
                    guard isCurrent else { return }
                    self.onFinalError?(error.localizedDescription)
                }
            }
        }
    }

    private func handleFinalResult(
        _ result: ASREngine.Transcription,
        audio: CapturedAudio,
        session: UUID
    ) {
        guard sessionID == session, !isRecording else { return }

        let adjustedWords = wordsRemovingLeadingPadding(result.words, audio: audio)
        let observation = observations(
            from: adjustedWords,
            fallbackText: result.text,
            audio: audio
        )

        publish(
            LiveRecognitionUpdate(
                words: observation.words,
                windowStartSequence: audio.sourceStartSequence,
                audioEndSequence: audio.sequence,
                windowIncludesSessionStart: audio.sourceStartSequence == 0,
                timingQuality: observation.timingQuality,
                origin: .final,
                audioEndHostTime: audio.endHostTime,
                sampleRate: audio.sampleRate,
                captureToSnapshotMilliseconds: 0,
                inferenceMilliseconds: result.inferenceMilliseconds,
                inferenceCompletedHostTime: mach_absolute_time(),
                audioOverrunCount: audio.overrunCount,
                audioQuality: audio.qualityMetrics
            ),
            session: session,
            final: true
        )
    }

    private func wordsRemovingLeadingPadding(
        _ words: [RecognizedWord],
        audio: CapturedAudio
    ) -> [RecognizedWord] {
        let padding = audio.leadingPaddingMilliseconds
        return words.compactMap { word in
            let end = word.endMilliseconds - padding
            guard end > 0, end > max(0, word.startMilliseconds - padding) else { return nil }
            return RecognizedWord(
                text: word.text,
                startMilliseconds: max(0, word.startMilliseconds - padding),
                endMilliseconds: end,
                confidence: word.confidence
            )
        }
    }

    private func publish(
        _ update: LiveRecognitionUpdate,
        session: UUID,
        final: Bool
    ) {
        diagnosticCapture?.record(update: update)
        if final { diagnosticCapture?.finishAndWait() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let isCurrent = self.stateQueue.sync {
                self.sessionID == session && (final ? !self.isRecording : self.isRecording)
            }
            guard isCurrent else { return }
            if final {
                self.onFinal?(update)
            } else {
                self.onInterim?(update)
            }
        }
    }

    private func samples(for milliseconds: Int32, sampleRate: Int32) -> UInt64 {
        guard milliseconds > 0, sampleRate > 0 else { return 0 }
        return UInt64(milliseconds) * UInt64(sampleRate) / 1_000
    }

    private struct ObservationBatch {
        let words: [TranscriptObservationWord]
        let timingQuality: TranscriptTimingQuality
    }

    private func observations(
        from words: [RecognizedWord],
        fallbackText: String,
        audio: CapturedAudio
    ) -> ObservationBatch {
        let timed: [TranscriptObservationWord] = words.compactMap {
            word -> TranscriptObservationWord? in
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, word.endMilliseconds > word.startMilliseconds else {
                return nil
            }
            let start = min(
                audio.sourceStartSequence
                    &+ samples(for: word.startMilliseconds, sampleRate: audio.sampleRate),
                audio.sequence
            )
            let end = min(
                audio.sourceStartSequence
                    &+ samples(for: word.endMilliseconds, sampleRate: audio.sampleRate),
                audio.sequence
            )
            guard end > start else { return nil }
            return TranscriptObservationWord(
                text: text,
                startSequence: start,
                endSequence: max(start, end),
                confidence: word.confidence
            )
        }
        guard timed.isEmpty else {
            let spansAreTrustworthy = TranscriptTimingQuality.spansAreTrustworthy(
                timed.map { (start: $0.startSequence, end: $0.endSequence) }
            )
            return ObservationBatch(
                words: timed,
                timingQuality: spansAreTrustworthy
                    ? TranscriptTimingQuality.classify(
                        transcriptText: fallbackText,
                        timedWordTexts: timed.map(\.text)
                    )
                    : .estimated
            )
        }

        // Word offsets are requested from the engine, but retain a deterministic fallback
        // for a decoder result that supplies text only. Even spacing preserves order and
        // still lets repeated observations stabilize without inventing view identities.
        let tokens = fallbackText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else {
            return ObservationBatch(words: [], timingQuality: .wordOffsets)
        }
        let span = audio.sequence - audio.sourceStartSequence
        let step = max(1, span / UInt64(tokens.count))
        let estimated = tokens.enumerated().map { index, text in
            let start = min(
                audio.sourceStartSequence + UInt64(index) * step,
                audio.sequence
            )
            let end = index == tokens.count - 1
                ? audio.sequence
                : min(start + step, audio.sequence)
            return TranscriptObservationWord(
                text: text,
                startSequence: start,
                endSequence: end,
                confidence: nil
            )
        }
        return ObservationBatch(words: estimated, timingQuality: .estimated)
    }

    private func hostDeltaMilliseconds(from start: UInt64, to end: UInt64) -> Double {
        guard start > 0, end >= start else { return 0 }
        return AVAudioTime.seconds(forHostTime: end - start) * 1_000
    }

    private func endLatencyActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
