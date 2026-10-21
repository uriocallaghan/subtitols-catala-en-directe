@preconcurrency import AVFoundation
import Darwin
import Foundation
import SubtitolCore
import SubtitolEngine
import SubtitolSpeakers

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
    /// Pauses heard in the audio up to `audioEndSequence`.
    let silences: SilenceMap
    /// Where another voice took over; `nil` without the detector.
    let speakers: SpeakerChangeMap?
}

enum RecognitionObservationOrigin: String, Sendable {
    case live
    case final
}

final class RecognitionCoordinator: @unchecked Sendable {
    private enum CoordinatorError: LocalizedError {
        case alreadyRecording

        var errorDescription: String? {
            localized("La captura de micròfon ja està activa.")
        }
    }

    var onInterim: ((LiveRecognitionUpdate) -> Void)?
    var onFinal: ((LiveRecognitionUpdate) -> Void)?
    var onRecoverableError: ((String) -> Void)?
    /// Every microphone went away while listening and none came back.
    var onInputLost: (() -> Void)?
    var onFinalError: ((String) -> Void)?

    private let engine: ASREngine
    private let audioCapture: AudioCapture
    private let diagnosticCapture: DiagnosticCapture?
    private let modelIdentifier: String
    private let liveWindowSeconds: TimeInterval
    private let stateQueue = DispatchQueue(
        label: "cat.subtitollive.scheduler",
        qos: .userInteractive
    )
    private let inferenceQueue = DispatchQueue(
        label: "cat.subtitollive.asr",
        qos: .userInteractive
    )
    private let speakerQueue = DispatchQueue(
        label: "cat.subtitollive.speakers",
        qos: .userInitiated
    )

    private var scheduler: LatestAudioScheduler?
    private var sessionID = UUID()
    private var isRecording = false
    private var minimumHopSeconds = TranscriptionProfile.default.policy.minimumHopSeconds
    /// Owned by `stateQueue`, fed with every snapshot so pauses are measured once.
    private var silenceTracker = SilenceTracker()
    /// Owned by `stateQueue`, like the silence tracker; its model runs on `speakerQueue`.
    private var speakerTracker = SpeakerTurnTracker()
    private var speakerModel: SpeakerSegmentationModel?
    private var speakerAnalysisInFlight = false
    private var activity: NSObjectProtocol?

    init(
        engine: ASREngine,
        modelIdentifier: String,
        liveWindowSeconds: TimeInterval = LiveWindowPolicy.liveWindowSeconds,
        audioCapture: AudioCapture? = nil
    ) {
        self.engine = engine
        self.modelIdentifier = modelIdentifier
        self.liveWindowSeconds = liveWindowSeconds
        self.audioCapture = audioCapture ?? AudioCapture(
            rollingWindowSeconds: max(liveWindowSeconds, LiveWindowPolicy.finalWindowSeconds)
        )
        self.diagnosticCapture = DiagnosticCapture.configuredFromEnvironment()
        self.audioCapture.onInputLost = { [weak self] in self?.onInputLost?() }
    }

    /// The microphone to listen with; `nil` follows the system input. Takes effect at
    /// once, keeping the text, when already listening.
    func setPreferredInput(uid: String?) {
        audioCapture.preferredInputUID = uid
    }

    /// Names and terms the recogniser should favour, from the next window on. Takes
    /// effect while listening too.
    func setBoostedPhrases(_ phrases: [String]) {
        engine.setBoostedPhrases(phrases)
    }

    func start(profile: TranscriptionProfile) throws {
        let activeSession = UUID()
        let accepted = stateQueue.sync {
            guard !isRecording else { return false }
            sessionID = activeSession
            scheduler = nil
            silenceTracker.reset()
            speakerTracker.reset()
            speakerAnalysisInFlight = false
            minimumHopSeconds = profile.policy.minimumHopSeconds
            isRecording = true
            return true
        }
        guard accepted else { throw CoordinatorError.alreadyRecording }

        _ = diagnosticCapture?.begin(profile: profile, modelIdentifier: modelIdentifier)

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
            reason: "Subtítols en directe"
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

    /// The voice change detector, when its model has loaded; `nil` turns it off.
    func setSpeakerModel(_ model: SpeakerSegmentationModel?) {
        stateQueue.async { [weak self] in
            self?.speakerModel = model
        }
    }

    /// Switches profile without interrupting capture.
    func updateProfile(_ profile: TranscriptionProfile) {
        stateQueue.async { [weak self] in
            self?.minimumHopSeconds = profile.policy.minimumHopSeconds
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
            let silences = self.measureSilences(in: finalAudio)
            let speakers = self.speakerModel == nil ? nil : self.speakerTracker.map
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
                        audioQuality: finalAudio.qualityMetrics,
                        silences: silences,
                        speakers: speakers
                    ),
                    session: finalSession,
                    final: true
                )
                return
            }
            self.runFinal(audio: finalAudio, silences: silences, speakers: speakers, session: finalSession)
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

        let hop = UInt64(Double(sampleRate) * minimumHopSeconds)
        if scheduler == nil {
            scheduler = LatestAudioScheduler(minimumHopSamples: hop)
        } else if scheduler?.minimumHopSamples != max(1, hop) {
            scheduler?.setMinimumHopSamples(hop)
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
            windowSeconds: liveWindowSeconds,
            padToWindow: true
        )
        diagnosticCapture?.recordAudio(audio)
        let silences = measureSilences(in: audio)
        followSpeakers(in: audio, session: session)
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
                        silences: silences,
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

    /// Call on `stateQueue`.
    private func measureSilences(in audio: CapturedAudio) -> SilenceMap {
        silenceTracker.append(
            audio.samples.suffix(audio.realSampleCount),
            endSequence: audio.sequence,
            sampleRate: audio.sampleRate
        )
        return silenceTracker.map
    }

    /// Call on `stateQueue`. Feeds the voice change detector and starts an analysis
    /// when one is due and none is running; the changes it confirms reach the
    /// following updates.
    private func followSpeakers(in audio: CapturedAudio, session: UUID) {
        guard let model = speakerModel else { return }
        speakerTracker.append(
            audio.samples.suffix(audio.realSampleCount),
            endSequence: audio.sequence,
            sampleRate: audio.sampleRate
        )
        if !speakerAnalysisInFlight, let window = speakerTracker.nextWindow() {
            speakerAnalysisInFlight = true
            speakerQueue.async { [weak self] in
                let classes = model.frameClasses(window.samples)
                self?.stateQueue.async { [weak self] in
                    guard let self, self.sessionID == session else { return }
                    self.speakerAnalysisInFlight = false
                    if let classes { self.speakerTracker.ingest(frameClasses: classes, of: window) }
                }
            }
        }
    }

    private func handleLiveResult(
        _ result: ASREngine.Transcription,
        audio: CapturedAudio,
        silences: SilenceMap,
        captureToSnapshotMilliseconds: Double,
        inferenceCompletedHostTime: UInt64,
        session: UUID
    ) {
        guard sessionID == session, isRecording else { return }

        let observation = voicedObservations(result, audio: audio)
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
                audioQuality: audio.qualityMetrics,
                silences: silences,
                // The newest changes, confirmed while the recogniser was running.
                speakers: speakerModel == nil ? nil : speakerTracker.map
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

    private func runFinal(audio: CapturedAudio, silences: SilenceMap, speakers: SpeakerChangeMap?, session: UUID) {
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.engine.transcribe(
                    samples: audio.samples,
                    sampleRate: audio.sampleRate
                )
                self.stateQueue.async { [weak self] in
                    self?.handleFinalResult(result, audio: audio, silences: silences, speakers: speakers, session: session)
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
        silences: SilenceMap,
        speakers: SpeakerChangeMap?,
        session: UUID
    ) {
        guard sessionID == session, !isRecording else { return }

        let observation = voicedObservations(result, audio: audio)

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
                audioQuality: audio.qualityMetrics,
                silences: silences,
                speakers: speakers
            ),
            session: session,
            final: true
        )
    }

    /// Call on `stateQueue`. The observation without the words written where nobody
    /// spoke. Two judges: the voice detector, where it has listened (the recogniser
    /// invents words in applause, a crowd's murmur and a room's noise, which are loud,
    /// and in a reverberant hall real words fail the energy test), and otherwise the
    /// energy test. The text follows the words, so the text-only fallback cannot bring
    /// a dropped word back.
    private func voicedObservations(
        _ result: ASREngine.Transcription,
        audio: CapturedAudio
    ) -> ObservationBatch {
        let energyKept = SilentWordFilter.voicedIndices(
            result.words,
            samples: audio.samples,
            sampleRate: audio.sampleRate,
            leadingPaddingSamples: audio.samples.count - audio.realSampleCount
        )
        let speech = speakerModel == nil ? SpeechPresenceMap.empty : speakerTracker.speech
        // Each word keeps its index through the padding adjustment, so the two judges
        // agree on which word they are talking about.
        let adjusted = wordsRemovingLeadingPadding(result.words, audio: audio)
        let untouched = adjusted.count == result.words.count && energyKept.count == result.words.count
        let observation = observations(
            from: adjusted.map(\.word),
            transcriptText: untouched ? result.text : adjusted.map(\.word.text).joined(separator: " "),
            fallbackText: untouched ? result.text
                : adjusted.filter { energyKept.contains($0.index) }.map(\.word.text).joined(separator: " "),
            audio: audio
        )
        // The text-only fallback (no usable timings) already follows the energy test.
        guard !observation.sourceIndices.isEmpty else { return observation }
        let energyKeptHere = Set(observation.sourceIndices.indices.filter { energyKept.contains(adjusted[observation.sourceIndices[$0]].index) })
        let kept = speech.voicedWords(observation.words, energyKept: energyKeptHere)
        return ObservationBatch(words: kept, timingQuality: observation.timingQuality, sourceIndices: [])
    }

    private func wordsRemovingLeadingPadding(
        _ words: [RecognizedWord],
        audio: CapturedAudio
    ) -> [(word: RecognizedWord, index: Int)] {
        let padding = audio.leadingPaddingMilliseconds
        return words.enumerated().compactMap { index, word in
            let end = word.endMilliseconds - padding
            guard end > 0, end > max(0, word.startMilliseconds - padding) else { return nil }
            return (RecognizedWord(
                text: word.text,
                startMilliseconds: max(0, word.startMilliseconds - padding),
                endMilliseconds: end,
                confidence: word.confidence
            ), index)
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
        /// For each word, the index of the recognised word it came from; empty for the
        /// text-only fallback.
        var sourceIndices: [Int] = []
    }

    /// `transcriptText` is the recogniser's own text, to tell whether every word came
    /// with timings; `fallbackText` is what is shown when none did.
    private func observations(
        from words: [RecognizedWord],
        transcriptText: String,
        fallbackText: String,
        audio: CapturedAudio
    ) -> ObservationBatch {
        let timedWithSource: [(word: TranscriptObservationWord, index: Int)] = words.enumerated().compactMap {
            index, word -> (TranscriptObservationWord, Int)? in
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
            return (TranscriptObservationWord(
                text: text,
                startSequence: start,
                endSequence: max(start, end),
                confidence: word.confidence
            ), index)
        }
        let timed = timedWithSource.map(\.word)
        guard timed.isEmpty else {
            let spansAreTrustworthy = TranscriptTimingQuality.spansAreTrustworthy(
                timed.map { (start: $0.startSequence, end: $0.endSequence) }
            )
            return ObservationBatch(
                words: timed,
                timingQuality: spansAreTrustworthy
                    ? TranscriptTimingQuality.classify(
                        transcriptText: transcriptText,
                        timedWordTexts: timed.map(\.text)
                    )
                    : .estimated,
                sourceIndices: timedWithSource.map(\.index)
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
