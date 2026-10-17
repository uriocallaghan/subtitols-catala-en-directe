import Combine
import AVFoundation
import Darwin
import Foundation
import SubtitolCore
import SubtitolEngine
import SubtitolPunctuation
import SubtitolSpeakers

@MainActor
final class SubtitleController: ObservableObject, @unchecked Sendable {
    private static let profileDefaultsKey = "transcription.profile"
    /// Where builds with a choice of speech models kept it. Cleared on launch.
    private static let retiredModelDefaultsKey = "transcription.model"
    /// The chosen microphone; absent follows the system.
    private static let preferredInputUIDKey = "audio.inputDeviceUID"
    private static let preferredInputNameKey = "audio.inputDeviceName"

    enum State {
        /// No language is installed yet: nothing to load until the reader picks one.
        case needsLanguage
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
        detail: localized("Carregant l'idioma…")
    )
    @Published private(set) var transcriptionProfile: TranscriptionProfile
    /// The model loaded, or being loaded. `nil` only when the manifest is unusable.
    @Published private(set) var speechModel: SpeechModelDescriptor?
    /// The chosen microphone's UID; `nil` follows the system input.
    @Published private(set) var preferredInputUID: String? = UserDefaults.standard.string(forKey: SubtitleController.preferredInputUIDKey)
    /// The vocabulary of the day: names, places and terms the recogniser favours. Kept
    /// between launches; a change reaches the recogniser at once, listening or not.
    @Published private(set) var vocabulary: [String] = UserDefaults.standard.stringArray(forKey: SubtitleController.vocabularyKey) ?? []
    static let vocabularyKey = "vocabulary.phrases"
    /// Words the vocabulary may hold; past it the boost spreads too thin.
    static let vocabularyLimit = 40
    /// Its name, remembered so it can be shown while unplugged.
    @Published private(set) var preferredInputName: String? = UserDefaults.standard.string(forKey: SubtitleController.preferredInputNameKey)

    private let modelLoader = DispatchQueue(
        label: "cat.subtitollive.model-loader",
        qos: .userInitiated
    )
    /// The text of the current (or last) session, whole, for export. Changes along with
    /// `viewState`, so it is not published separately.
    private(set) var session = SessionTranscript()
    private var coordinator: RecognitionCoordinator?
    private var transcriptStabilizer: ReadableTranscriptStabilizer
    /// Punctuation, capitals and digits for everything shown. Always on; without the
    /// model the text is shown as recognised.
    private var transcriptFormatter: TranscriptFormatter
    private var punctuationModel: PunctuationModel?
    /// The language's numbers, capitals and other rules after recognition.
    let rules: LanguageRules
    /// The marks of a recogniser that writes its own; then no punctuation model runs.
    private var recognizerPunctuation: RecognizerPunctuation?
    /// `models[].id` of the language's speech model; `nil` takes the manifest default.
    private let modelID: String?
    /// What decides marks and capitals: the recogniser's own, the language's model once
    /// it has loaded, or, for a language with neither, none (text still settles).
    private var predictor: PunctuationPredicting? {
        recognizerPunctuation ?? punctuationModel
            ?? (punctuationDirectoryName == nil || punctuationUnavailable ? plainPunctuation : nil)
    }
    /// The language's punctuation model could not be found or loaded. Its words then
    /// settle without marks rather than wait, unseen, for a model that is not coming.
    private var punctuationUnavailable = false
    private let plainPunctuation = PlainPunctuation()
    /// Finds where another voice takes over, in any language; without it the text
    /// runs on across speakers.
    private var speakerModel: SpeakerSegmentationModel?
    private var wordLatencySamples: [Double] = []
    private var newestMeasuredWordHostTime: UInt64 = 0
    private var lastDisplayedWordLatency: Double?
    private var permissionRequestID: UUID?
    /// Folders searched before the app bundle: on the iPhone, the language pack the
    /// reader downloaded.
    private let modelDirectories: [URL]
    /// The language's punctuation folder; nil when the language has none yet, and its
    /// text is then shown as recognised.
    private let punctuationDirectoryName: String?

    /// `languageID` `nil`: no language installed; the controller waits in
    /// `.needsLanguage` and loads nothing.
    init(
        languageID: String? = "ca",
        modelID: String? = nil,
        modelDirectories: [URL] = [],
        punctuationDirectoryName: String? = "catala-puntuacio"
    ) {
        self.modelDirectories = modelDirectories
        self.punctuationDirectoryName = punctuationDirectoryName
        self.modelID = modelID
        rules = LanguageRules.forLanguage(languageID ?? "")
        transcriptFormatter = TranscriptFormatter(rules: rules)
        let stored = UserDefaults.standard.string(forKey: Self.profileDefaultsKey)
        let profile = stored.flatMap(TranscriptionProfile.init(rawValue:)) ?? .default
        transcriptionProfile = profile
        transcriptStabilizer = ReadableTranscriptStabilizer(policy: profile)
        UserDefaults.standard.removeObject(forKey: Self.retiredModelDefaultsKey)
        guard languageID != nil else {
            viewState = ViewState(mode: .needsLanguage, transcript: .init(), latency: "— ms", detail: localized("Cap idioma instal·lat"))
            return
        }
        loadPunctuationModel()
        loadSpeakerModel()
        loadSpeechModel()
    }

    var state: State { viewState.mode }
    var transcript: String { viewState.transcript.text }
    var words: [StableTranscriptWord] { viewState.transcript.words }
    var committedWords: [StableTranscriptWord] { viewState.transcript.committedWords }
    var provisionalWords: [StableTranscriptWord] { viewState.transcript.provisionalWords }
    var latency: String { viewState.latency }
    var detail: String { viewState.detail }
    var isRecording: Bool { state == .recording }
    /// A failed start counts too: the tap or click loads the language again (`retryAfterFailure`).
    var canToggle: Bool { state == .ready || state == .recording || state == .failed }
    var canSelectTranscriptionProfile: Bool { state == .ready || state == .recording }
    var buttonTitle: String {
        if state == .failed { return localized("Torna-ho a provar") }
        return isRecording ? localized("Atura") : localized("Comença")
    }

    func selectTranscriptionProfile(_ profile: TranscriptionProfile) {
        guard canSelectTranscriptionProfile, profile != transcriptionProfile else { return }
        transcriptionProfile = profile
        UserDefaults.standard.set(profile.rawValue, forKey: Self.profileDefaultsKey)
        if state == .recording {
            // Keep listening and keep the text: only the thresholds change.
            transcriptStabilizer.adopt(profile)
            coordinator?.updateProfile(profile)
            return
        }
        transcriptStabilizer = ReadableTranscriptStabilizer(policy: profile)
        var next = viewState
        next.detail = "Perfil \(profile.displayName) · \(modelName) · \(speechModel.map(Self.contextLabel) ?? "context —")"
        viewState = next
    }

    /// Chooses the microphone by UID, or the system input with `nil`. Remembered
    /// across launches; while listening the switch happens without stopping.
    /// Adds a term to the vocabulary (trimmed, once, up to `vocabularyLimit`).
    @discardableResult
    func addVocabularyTerm(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, vocabulary.count < Self.vocabularyLimit,
              !vocabulary.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return false }
        setVocabulary(vocabulary + [trimmed])
        return true
    }

    func removeVocabularyTerm(_ term: String) {
        setVocabulary(vocabulary.filter { $0 != term })
    }

    func clearVocabulary() {
        setVocabulary([])
    }

    private func setVocabulary(_ terms: [String]) {
        vocabulary = terms
        UserDefaults.standard.set(terms, forKey: Self.vocabularyKey)
        coordinator?.setBoostedPhrases(terms)
    }

    func selectInput(uid: String?, name: String?) {
        guard uid != preferredInputUID else { return }
        preferredInputUID = uid
        preferredInputName = uid == nil ? nil : name
        UserDefaults.standard.set(uid, forKey: Self.preferredInputUIDKey)
        UserDefaults.standard.set(preferredInputName, forKey: Self.preferredInputNameKey)
        coordinator?.setPreferredInput(uid: uid)
    }

    private var modelName: String { speechModel?.displayName ?? "—" }

    private static func contextLabel(_ model: SpeechModelDescriptor) -> String {
        String(format: "context %.0f s", model.liveWindowSeconds)
    }

    /// Resolved when read, so it is always in the interface language.
    var displayText: String {
        if !transcript.isEmpty { return transcript }
        switch state {
        // Short lines: the language card opens beside it.
        case .needsLanguage: return localized("Tria\nun idioma.")
        case .loading: return localized("Carregant l'idioma…")
        case .ready: return Self.readyPrompt
        case .requestingPermission: return localized("Esperant permís per escoltar…")
        case .recording: return localized("T’escolto…")
        case .transcribing: return localized("Tancant la frase…")
        // What went wrong (the microphone hint, the error), since the next click retries.
        case .failed: return detail.isEmpty ? localized("No s’ha pogut iniciar la prova.") : detail
        }
    }

    #if os(iOS)
    private static var readyPrompt: String { localized("Toca la pantalla\nper començar a transcriure.") }
    private static var microphoneSettingsHint: String { localized("Cal permetre l'accés al micròfon a Configuració > duna > Micròfon.") }
    #else
    private static var readyPrompt: String { localized("Clica la pantalla\nper començar a transcriure.") }
    private static var microphoneSettingsHint: String { localized("Cal permetre l'accés al micròfon a Configuració del Sistema > Privacitat i seguretat > Micròfon.") }
    #endif

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
        if state == .failed {
            retryAfterFailure()
        } else if isRecording {
            stopAndTranscribe()
        } else {
            requestPermissionAndStart()
        }
    }

    /// A start that failed (the microphone refused, no input device, a model that did not
    /// load) is not the end of the session: the next tap loads the language again and the
    /// one after that starts listening. Before, `.failed` stayed on screen with the surface
    /// disabled until the language changed or the app was relaunched, which is what a
    /// reviewer sees as an app that "continues to display an error".
    private func retryAfterFailure() {
        guard state == .failed, !isShutDown, !isSuspended else { return }
        coordinator?.shutdown()
        coordinator = nil
        loadSpeechModel()
    }

    /// Frees the speech model while a video is transcribed with a model of its own: an
    /// iPhone cannot hold two (the second ran out of memory at the first window).
    private(set) var isSuspended = false

    func suspendForVideo() {
        guard !isSuspended, !isRecording, state != .transcribing, state != .needsLanguage else { return }
        isSuspended = true
        permissionRequestID = nil
        coordinator?.shutdown()
        coordinator = nil
        viewState = ViewState(mode: .loading, transcript: .init(), latency: "— ms", detail: localized("Carregant l'idioma…"))
    }

    /// Loads the speech model again once the video is done.
    func resumeAfterVideo() {
        guard isSuspended, !isShutDown else { return }
        isSuspended = false
        loadSpeechModel()
    }

    /// Set by `shutdown`: a model still loading then is released, never installed.
    private var isShutDown = false

    func shutdown() {
        isShutDown = true
        permissionRequestID = nil
        coordinator?.shutdown()
        coordinator = nil
        modelLoader.sync { }
    }

    private func loadPunctuationModel() {
        let directories = punctuationModelCandidates()
        guard !directories.isEmpty else {
            punctuationUnavailable = punctuationDirectoryName != nil
            return
        }
        modelLoader.async { [self] in
            // Loading compiles nothing at run time: the build ships the compiled model.
            // The first copy that loads wins; one that fails leaves the next to try.
            let model = directories.lazy.compactMap { try? PunctuationModel(directory: $0) }.first
            _ = model?.labels(for: ["bon", "dia", "a", "tothom"])
            DispatchQueue.main.async { [self] in
                self.punctuationModel = model
                self.punctuationUnavailable = model == nil
            }
        }
    }

    private func loadSpeakerModel() {
        guard let directory = ModelLocator.folder(named: "veus-segmentacio", in: modelDirectories) else { return }
        modelLoader.async { [self] in
            let model = try? SpeakerSegmentationModel(directory: directory)
            _ = model?.frameClasses([Float](repeating: 0, count: SpeakerTurnTracker.windowSamples))
            DispatchQueue.main.async { [self] in
                self.speakerModel = model
                self.coordinator?.setSpeakerModel(model)
            }
        }
    }

    /// The language pack's copy, then the app bundle's and development folders.
    private func punctuationModelCandidates() -> [URL] {
        guard let name = punctuationDirectoryName else { return [] }
        let candidates = modelDirectories.map { $0.appendingPathComponent(name) }
            + [ModelLocator.folder(named: name, in: [])].compactMap { $0 }
        var seen = Set<String>()
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func loadSpeechModel() {
        let model: SpeechModelDescriptor
        do {
            let catalog = try ModelIntegrityValidator.loadCatalog()
            model = modelID.flatMap(catalog.model(id:)) ?? catalog.defaultDescriptor
        } catch {
            fail(error.localizedDescription)
            return
        }
        speechModel = model
        recognizerPunctuation = model.writesPunctuation ? RecognizerPunctuation() : nil
        viewState = ViewState(
            mode: .loading,
            transcript: .init(),
            latency: "— ms",
            detail: localized("Carregant l'idioma…")
        )
        guard let modelURL = locateModel(model) else {
            fail(localized("No s'ha trobat el model \(model.displayName) al costat de l'app."))
            return
        }

        let repairsCatalanElisions = rules.id == "ca"
        modelLoader.async { [self] in
            do {
                try ModelIntegrityValidator.validate(modelURL: modelURL, against: model)
                let engine = try ASREngine(modelURL: modelURL, repairsCatalanElisions: repairsCatalanElisions)
                try engine.warmUp(windowSeconds: Set([model.liveWindowSeconds, LiveWindowPolicy.finalWindowSeconds]).sorted())
                let coordinator = RecognitionCoordinator(
                    engine: engine,
                    modelIdentifier: model.id,
                    liveWindowSeconds: model.liveWindowSeconds
                )
                DispatchQueue.main.async { [self] in
                    // Released for a video or shut down meanwhile: this model is not wanted now.
                    guard !self.isSuspended, !self.isShutDown else {
                        coordinator.shutdown()
                        return
                    }
                    self.install(coordinator)
                    self.viewState = ViewState(
                        mode: .ready,
                        transcript: .init(),
                        latency: "— ms",
                        detail: "Preparat · \(model.displayName) · \(Self.contextLabel(model))"
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
        coordinator.setBoostedPhrases(vocabulary)
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
        coordinator.onInputLost = { [weak self] in
            // Keep what was heard: close the sentence as if Stop had been pressed.
            guard let self, self.state == .recording else { return }
            self.stopAndTranscribe()
        }
        coordinator.setPreferredInput(uid: preferredInputUID)
        coordinator.setSpeakerModel(speakerModel)
        self.coordinator = coordinator
    }

    private func locateModel(_ model: SpeechModelDescriptor) -> URL? {
        ModelLocator.model(model, in: modelDirectories)
    }

    private func requestPermissionAndStart() {
        guard state == .ready else { return }
        let requestID = UUID()
        permissionRequestID = requestID
        viewState = ViewState(
            mode: .requestingPermission,
            transcript: viewState.transcript,
            latency: latency,
            detail: localized("Esperant el permís del micròfon…")
        )
        AudioCapture.requestPermission { [self] granted in
            DispatchQueue.main.async { [self] in
                guard self.permissionRequestID == requestID else { return }
                self.permissionRequestID = nil
                guard granted else {
                    self.fail(Self.microphoneSettingsHint)
                    return
                }
                guard let coordinator = self.coordinator else {
                    self.fail(localized("El model encara no està preparat."))
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
                    self.transcriptFormatter.reset()
                    self.recognizerPunctuation?.reset()
                    self.session.begin()
                    self.viewState = ViewState(
                        mode: .recording,
                        transcript: .init(),
                        latency: "— ms",
                        detail: String(
                            format: "Perfil %@ · %@ · hop %.0f ms · cua estable",
                            activeProfile.displayName,
                            self.modelName,
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
            fail(localized("El model encara no està preparat."))
            return
        }
        viewState = ViewState(
            mode: .transcribing,
            transcript: viewState.transcript,
            latency: latency,
            detail: localized("Corregint l'última frase…")
        )
        coordinator.stop()
    }

    private func applyInterim(_ update: LiveRecognitionUpdate) {
        guard state == .recording else { return }
        let words = recognizerPunctuation?.strip(
            update.words,
            windowStart: update.windowStartSequence,
            windowEnd: update.audioEndSequence,
            sampleRate: update.sampleRate,
            includesSessionStart: update.windowIncludesSessionStart
        ) ?? update.words
        let readable = transcriptStabilizer.observe(
            words,
            audioEndSequence: update.audioEndSequence,
            sampleRate: update.sampleRate,
            windowStartSequence: update.windowStartSequence
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
        let plain = transcriptFormatter.format(
            readable,
            silences: update.silences,
            speakers: update.speakers,
            predictor: predictor
        )
        let formatted = VocabularyCasing(vocabulary).apply(to: plain)
        session.observe(formatted)
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
            transcript: formatted,
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
        let words = recognizerPunctuation?.strip(
            update.words,
            windowStart: update.windowStartSequence,
            windowEnd: update.audioEndSequence,
            sampleRate: update.sampleRate,
            includesSessionStart: update.windowIncludesSessionStart,
            isFinal: true
        ) ?? update.words
        let readable = transcriptStabilizer.finalize(
            words,
            windowStartSequence: update.windowStartSequence,
            windowIncludesSessionStart: update.windowIncludesSessionStart,
            timingQuality: update.timingQuality,
            audioEndSequence: update.audioEndSequence,
            sampleRate: update.sampleRate
        )
        let correctionDetail = transcriptStabilizer.finalCorrectionDisposition == .corrected
            ? "Aturat · correcció final \(modelName)"
            : "Aturat · text estable conservat (timestamps no disponibles)"
        let plain = transcriptFormatter.format(
            readable,
            silences: update.silences,
            speakers: update.speakers,
            isFinal: true,
            predictor: predictor
        )
        let formatted = VocabularyCasing(vocabulary).apply(to: plain)
        session.observe(formatted)
        viewState = ViewState(
            mode: .ready,
            transcript: formatted,
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

/// Where a language's files are: the pack's folders first, then the app bundle, then,
/// in development runs, the paths the environment names.
enum ModelLocator {
    static func model(_ model: SpeechModelDescriptor, in directories: [URL]) -> URL? {
        let filename = model.filename
        for directory in directories {
            let url = directory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let resourceURL = Bundle.main.resourceURL?.appendingPathComponent(filename)
        if let resourceURL, FileManager.default.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }

        #if !SUBTITOL_STORE
        if let configuredPath = Bundle.main.object(
            forInfoDictionaryKey: "SubtitolModelPath"
        ) as? String,
           URL(fileURLWithPath: configuredPath).lastPathComponent == filename,
           FileManager.default.fileExists(atPath: configuredPath) {
            return URL(fileURLWithPath: configuredPath)
        }
        #endif

        // Development runs: SUBTITOL_MODEL names one file; SUBTITOL_MODELS_DIR a folder of them.
        if let path = DevelopmentOverrides.value(for: "SUBTITOL_MODEL"),
           URL(fileURLWithPath: path).lastPathComponent == filename,
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let directory = DevelopmentOverrides.value(for: "SUBTITOL_MODELS_DIR") {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// A model folder (`catala-puntuacio`, `veus-segmentacio`).
    static func folder(named name: String, in directories: [URL]) -> URL? {
        let candidates = directories.map { $0.appendingPathComponent(name) } + [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            DevelopmentOverrides.value(for: "SUBTITOL_MODELS_DIR").map {
                URL(fileURLWithPath: $0).appendingPathComponent(name)
            },
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
