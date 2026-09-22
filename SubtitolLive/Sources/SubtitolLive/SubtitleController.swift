import Combine
import AVFoundation
import Darwin
import Foundation
import SubtitolCore
import SubtitolEngine

@MainActor
final class SubtitleController: ObservableObject, @unchecked Sendable {
    private static let requiredModelFilename = "catalan-parakeet-q8.gguf"
    private static let profileDefaultsKey = "transcription.profile"

    enum State {
        case loading
        case ready
        case requestingPermission
        case recording
        case transcribing
        case failed
    }

    struct ViewState {
        var mode: State
        var transcript: ReadableTranscriptSnapshot
        var latency: String
        var detail: String
    }

    @Published private(set) var viewState = ViewState(
        mode: .loading,
        transcript: .init(),
        latency: "— ms",
        detail: "Preparant el model català…"
    )
    @Published private(set) var transcriptionProfile: TranscriptionProfile

    private let modelLoader = DispatchQueue(
        label: "cat.subtitollive.model-loader",
        qos: .userInitiated
    )
    private var coordinator: RecognitionCoordinator?
    private var transcriptStabilizer: ReadableTranscriptStabilizer
    private var wordLatencySamples: [Double] = []
    private var newestMeasuredWordHostTime: UInt64 = 0
    private var lastDisplayedWordLatency: Double?
    private var permissionRequestID: UUID?

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.profileDefaultsKey)
        let profile = stored.flatMap(TranscriptionProfile.init(rawValue:)) ?? .default
        transcriptionProfile = profile
        transcriptStabilizer = ReadableTranscriptStabilizer(policy: profile)
        loadModel()
    }

    var state: State { viewState.mode }
    var transcript: String { viewState.transcript.text }
    var words: [StableTranscriptWord] { viewState.transcript.words }
    var committedWords: [StableTranscriptWord] { viewState.transcript.committedWords }
    var provisionalWords: [StableTranscriptWord] { viewState.transcript.provisionalWords }
    var latency: String { viewState.latency }
    var detail: String { viewState.detail }
    var isRecording: Bool { state == .recording }
    var canToggle: Bool { state == .ready || state == .recording }
    var canSelectTranscriptionProfile: Bool { state == .ready }
    var buttonTitle: String { isRecording ? "Atura" : "Comença" }

    func selectTranscriptionProfile(_ profile: TranscriptionProfile) {
        guard canSelectTranscriptionProfile else { return }
        transcriptionProfile = profile
        UserDefaults.standard.set(profile.rawValue, forKey: Self.profileDefaultsKey)
        transcriptStabilizer = ReadableTranscriptStabilizer(policy: profile)
        var next = viewState
        next.detail = "Perfil \(profile.displayName) · context 4 s · final 6 s · Metal"
        viewState = next
    }

    var displayText: String {
        if !transcript.isEmpty { return transcript }
        switch state {
        case .loading: return "Carregant el català…"
        case .ready: return "Quan parlis, el text apareixerà aquí."
        case .requestingPermission: return "Esperant permís per escoltar…"
        case .recording: return "T’escolto…"
        case .transcribing: return "Tancant la frase…"
        case .failed: return "No s’ha pogut iniciar la prova."
        }
    }

    /// Read on demand by the decorative field. Deliberately not published: at frame
    /// rate it would re-render the transcript along with it, for decoration.
    func voiceLevel() -> Float {
        coordinator?.voiceLevel() ?? 0
    }

    func discardPendingVoicePeak() {
        coordinator?.discardPendingVoicePeak()
    }

    func toggleRecording() {
        guard canToggle else { return }
        if isRecording {
            stopAndTranscribe()
        } else {
            requestPermissionAndStart()
        }
    }

    func shutdown() {
        permissionRequestID = nil
        coordinator?.shutdown()
        coordinator = nil
        modelLoader.sync { }
    }

    private func loadModel() {
        guard let modelURL = locateModel() else {
            fail("No s'ha trobat el model català al costat de l'app.")
            return
        }

        modelLoader.async { [self] in
            do {
                try ModelIntegrityValidator.validate(modelURL: modelURL)
                let engine = try ASREngine(modelURL: modelURL)
                try engine.warmUp()
                let coordinator = RecognitionCoordinator(engine: engine)
                DispatchQueue.main.async { [self] in
                    self.install(coordinator)
                    self.viewState = ViewState(
                        mode: .ready,
                        transcript: .init(),
                        latency: "— ms",
                        detail: "Preparat · context 4 s · final 6 s · Metal"
                    )
                }
            } catch {
                DispatchQueue.main.async { [self] in
                    fail(error.localizedDescription)
                }
            }
        }
    }

    private func install(_ coordinator: RecognitionCoordinator) {
        coordinator.onInterim = { [weak self] update in
            self?.applyInterim(update)
        }
        coordinator.onFinal = { [weak self] update in
            self?.applyFinal(update)
        }
        coordinator.onRecoverableError = { [weak self] message in
            guard let self, self.state == .recording else { return }
            var next = self.viewState
            next.detail = "Actualització provisional omesa · \(message)"
            self.viewState = next
        }
        coordinator.onFinalError = { [weak self] message in
            self?.fail(message)
        }
        self.coordinator = coordinator
    }

    private func locateModel() -> URL? {
        let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent(Self.requiredModelFilename)
        if let resourceURL, FileManager.default.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }

        if let configuredPath = Bundle.main.object(
            forInfoDictionaryKey: "SubtitolModelPath"
        ) as? String,
           URL(fileURLWithPath: configuredPath).lastPathComponent == Self.requiredModelFilename,
           FileManager.default.fileExists(atPath: configuredPath) {
            return URL(fileURLWithPath: configuredPath)
        }

        if let path = ProcessInfo.processInfo.environment["SUBTITOL_MODEL"],
           URL(fileURLWithPath: path).lastPathComponent == Self.requiredModelFilename,
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private func requestPermissionAndStart() {
        guard state == .ready else { return }
        let requestID = UUID()
        permissionRequestID = requestID
        viewState = ViewState(
            mode: .requestingPermission,
            transcript: viewState.transcript,
            latency: latency,
            detail: "Esperant el permís del micròfon…"
        )
        AudioCapture.requestPermission { [self] granted in
            DispatchQueue.main.async { [self] in
                guard self.permissionRequestID == requestID else { return }
                self.permissionRequestID = nil
                guard granted else {
                    self.fail("Cal permetre l'accés al micròfon a Configuració del Sistema > Privacitat i seguretat > Micròfon.")
                    return
                }
                guard let coordinator = self.coordinator else {
                    self.fail("El model encara no està preparat.")
                    return
                }
                do {
                    let activeProfile = self.transcriptionProfile
                    try coordinator.start(profile: activeProfile)
                    self.wordLatencySamples.removeAll(keepingCapacity: true)
                    self.newestMeasuredWordHostTime = 0
                    self.lastDisplayedWordLatency = nil
                    self.transcriptStabilizer = ReadableTranscriptStabilizer(
                        policy: activeProfile
                    )
                    self.viewState = ViewState(
                        mode: .recording,
                        transcript: .init(),
                        latency: "— ms",
                        detail: String(
                            format: "Perfil %@ · hop %.0f ms · cua estable · Metal",
                            activeProfile.displayName,
                            activeProfile.policy.minimumHopSeconds * 1_000
                        )
                    )
                } catch {
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    private func stopAndTranscribe() {
        guard let coordinator else {
            fail("El model encara no està preparat.")
            return
        }
        viewState = ViewState(
            mode: .transcribing,
            transcript: viewState.transcript,
            latency: latency,
            detail: "Corregint els últims 6 s reals…"
        )
        coordinator.stop()
    }

    private func applyInterim(_ update: LiveRecognitionUpdate) {
        guard state == .recording else { return }
        let readable = transcriptStabilizer.observe(
            update.words,
            audioEndSequence: update.audioEndSequence,
            sampleRate: update.sampleRate
        )
        let stableWordHostTime = readable.latestVisibleEndSequence.flatMap {
            hostTime(
                forSequence: $0,
                audioEndSequence: update.audioEndSequence,
                audioEndHostTime: update.audioEndHostTime,
                sampleRate: update.sampleRate
            )
        }
        let wordLatency = latencyMilliseconds(since: stableWordHostTime)
        if let wordLatency,
           let wordEndHostTime = stableWordHostTime,
           wordEndHostTime > newestMeasuredWordHostTime {
            newestMeasuredWordHostTime = wordEndHostTime
            wordLatencySamples.append(wordLatency)
            lastDisplayedWordLatency = wordLatency
            if wordLatencySamples.count > 120 {
                wordLatencySamples.removeFirst(wordLatencySamples.count - 120)
            }
        }
        let distribution = LatencyDistribution(samples: wordLatencySamples)
        let displayedLatency = lastDisplayedWordLatency.map {
            String(format: "%.0f ms", $0)
        } ?? "— ms"
        let mainActorMilliseconds = latencyMilliseconds(
            since: update.inferenceCompletedHostTime
        ) ?? 0
        let p95 = distribution.p95 ?? 0
        let rmsDecibels = 20 * log10(max(Double(update.audioQuality.rms), 0.000_001))
        viewState = ViewState(
            mode: .recording,
            transcript: readable,
            latency: displayedLatency,
            detail: String(
                format: "P95 %.0f · snap %.1f · infer %.0f · main %.1f ms · RMS %.0f dB · clip %d · drop %llu",
                p95,
                update.captureToSnapshotMilliseconds,
                update.inferenceMilliseconds,
                mainActorMilliseconds,
                rmsDecibels,
                update.audioQuality.clippedSampleCount,
                update.audioOverrunCount
            )
        )
    }

    private func applyFinal(_ update: LiveRecognitionUpdate) {
        guard state == .transcribing else { return }
        let readable = transcriptStabilizer.finalize(
            update.words,
            windowStartSequence: update.windowStartSequence,
            windowIncludesSessionStart: update.windowIncludesSessionStart,
            timingQuality: update.timingQuality,
            audioEndSequence: update.audioEndSequence,
            sampleRate: update.sampleRate
        )
        let correctionDetail = transcriptStabilizer.finalCorrectionDisposition == .corrected
            ? "Aturat · correcció final Parakeet"
            : "Aturat · text estable conservat (timestamps no disponibles)"
        viewState = ViewState(
            mode: .ready,
            transcript: readable,
            latency: String(format: "%.0f ms", update.inferenceMilliseconds),
            detail: correctionDetail
        )
    }

    private func latencyMilliseconds(since hostTime: UInt64?) -> Double? {
        guard let hostTime, hostTime > 0 else { return nil }
        let publishedAt = mach_absolute_time()
        guard publishedAt >= hostTime else { return nil }
        return AVAudioTime.seconds(forHostTime: publishedAt - hostTime) * 1_000
    }

    private func hostTime(
        forSequence sequence: UInt64,
        audioEndSequence: UInt64,
        audioEndHostTime: UInt64,
        sampleRate: Int32
    ) -> UInt64? {
        guard sampleRate > 0,
              audioEndHostTime > 0,
              sequence <= audioEndSequence else { return nil }
        let secondsBehind = Double(audioEndSequence - sequence) / Double(sampleRate)
        let ticksBehind = AVAudioTime.hostTime(forSeconds: secondsBehind)
        return audioEndHostTime > ticksBehind ? audioEndHostTime - ticksBehind : nil
    }

    private func fail(_ message: String) {
        permissionRequestID = nil
        coordinator?.shutdown()
        viewState = ViewState(
            mode: .failed,
            transcript: viewState.transcript,
            latency: latency,
            detail: message
        )
    }
}
