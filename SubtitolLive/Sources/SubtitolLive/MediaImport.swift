@preconcurrency import AVFoundation
import Combine
import CoreGraphics
import Foundation
import QuartzCore
import SubtitolCore
import SubtitolEngine
import SubtitolPunctuation
import SubtitolSpeakers
import UniformTypeIdentifiers

/// A video or a recording the reader brought in, being turned into subtitles.
///
/// The sound is read out of the file (every audio track mixed to mono, 16 kHz), the
/// chosen language's models are loaded for this job alone, and `FileTranscriber` runs on
/// a thread of its own. The reading pane follows the text as it settles, and the
/// session it ends with is the one the export card and the share buttons send.
@MainActor
final class MediaImport: ObservableObject, Identifiable {
    enum Phase: Equatable {
        /// Waiting for the reader to confirm the language.
        case choosing
        /// Reading the sound and loading the models.
        case preparing
        case transcribing
        case finished
        case failed(String)
    }

    let id = UUID()
    /// The file itself. Access to it is held from `init` until the job is gone.
    let source: URL
    /// The file's name without its extension: the subtitles take it.
    /// Photos hands its films over under an identifier ("5CCF9539-….mov"); those are
    /// named after the day they were filmed once the file's metadata is read.
    @Published private(set) var title: String
    @Published private(set) var phase: Phase = .choosing
    @Published private(set) var duration: TimeInterval?
    @Published private(set) var thumbnail: CGImage?
    @Published private(set) var hasVideo = true
    /// 0...1 of the recording transcribed, as last reported. Views show
    /// `displayedFraction(at:)`, which moves on between reports.
    @Published private(set) var fraction: Double = 0
    /// Seconds still to go, once the pace is known.
    @Published private(set) var remaining: TimeInterval?
    /// The settled text for the reading pane, revealed a word at a time at the pace the
    /// recogniser reads: a window's words arrive together, but appear one by one.
    @Published private(set) var transcript = ReadableTranscriptSnapshot()
    @Published private(set) var session = SessionTranscript()
    @Published var languageID: String?
    /// The written `.srt`, once finished.
    @Published private(set) var subtitlesURL: URL?
    /// The subtitles as lines to review, once finished; corrections are kept here.
    @Published private(set) var document: SubtitleDocument?
    /// Corrections made in the editor so far.
    @Published private(set) var isEdited = false
    /// Bumped by every correction, so the reading pane takes the new text as a new text.
    @Published private(set) var revision = 0
    /// The correction last saved, copied or sent somewhere.
    @Published private(set) var exportedRevision = 0
    /// The correction last kept on the device (`CorrectionStore`).
    @Published private(set) var savedRevision = 0
    /// Corrections kept from an earlier time with this same video, to go on from.
    @Published private(set) var savedCorrections: SavedCorrections?
    /// The video's name in the store of corrections, once its content has been read.
    private var correctionsKey: String?

    /// Corrections that live only in the app: neither exported nor kept on the device
    /// (keeping them failed), so closing it would lose them.
    var hasUnexportedEdits: Bool { isEdited && revision != exportedRevision && revision != savedRevision }

    /// The subtitles as they are now have left the app (saved, copied or shared).
    func markExported() {
        exportedRevision = revision
    }

    /// Loudness of the stretch being transcribed, 0...1, for the decorative field.
    nonisolated let level = MediaImportLevel()

    /// The newest formatted words, of which `transcript` shows those revealed so far.
    private var arrived = ReadableTranscriptSnapshot()
    private var revealedAnchor: UInt64 = 0
    private var revealCredit = 0.0
    private var revealTask: Task<Void, Never>?
    /// When the last report came, and the average gap and step between reports.
    private var lastReport: Date?
    private var reportInterval: TimeInterval = 0.5
    private var reportStep: Double = 0.05

    private let accessesSecurityScope: Bool
    let deletesSourceWhenDone: Bool
    private var work: Task<Void, Never>?
    private let cancellation = CancellationFlag()
    private var startedAt: Date?

    /// `ownsSource`: the file is a copy made for this job (from Photos, or handed over by
    /// the share extension) and is removed with it.
    init(source: URL, ownsSource: Bool = false, languageID: String?) {
        self.source = source
        self.title = source.deletingPathExtension().lastPathComponent
        self.languageID = languageID
        deletesSourceWhenDone = ownsSource
        accessesSecurityScope = source.startAccessingSecurityScopedResource()
        Task { await loadDetails() }
    }

    deinit {
        cancellation.cancel()
        if accessesSecurityScope { source.stopAccessingSecurityScopedResource() }
        if deletesSourceWhenDone {
            // The copy sits in a folder of its own; both go.
            let folder = source.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: source)
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    var isWorking: Bool { phase == .preparing || phase == .transcribing }

    private func loadDetails() async {
        let source = source
        let found = await Task.detached(priority: .userInitiated) { () -> (String, SavedCorrections?)? in
            guard let key = try? CorrectionStore.key(for: source) else { return nil }
            return (key, MediaImport.correctionStore.load(key: key))
        }.value
        if let found {
            correctionsKey = found.0
            if phase == .choosing { savedCorrections = found.1 }
        }
        let asset = AVURLAsset(url: source)
        if Self.isIdentifier(title) {
            let date = try? await asset.load(.creationDate)?.load(.dateValue)
            title = Self.title(filmedOn: date)
        }
        if let time = try? await asset.load(.duration), time.isNumeric {
            duration = time.seconds
        }
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        hasVideo = !videoTracks.isEmpty
        guard hasVideo else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let at = CMTime(seconds: min(1, (duration ?? 0) / 3), preferredTimescale: 600)
        if let image = try? await generator.image(at: at).image {
            thumbnail = image
        }
    }

    /// Transcribes the file in `language`, whose pack must be installed.
    func start(language: SpeechLanguage, packs: LanguagePackStore) {
        guard phase == .choosing || isFailed, packs.state(of: language) == .installed else { return }
        savedCorrections = nil
        languageID = language.id
        phase = .preparing
        fraction = 0
        remaining = nil
        let directories = packs.modelDirectories(for: language)
        guard let descriptor = packs.models?.model(id: language.model),
              let modelURL = ModelLocator.model(descriptor, in: directories) else {
            phase = .failed(localized("No s'ha trobat el model d'aquest idioma. Torna'l a baixar."))
            return
        }
        let job = FileTranscriptionJob(
            source: source,
            modelURL: modelURL,
            descriptor: descriptor,
            rules: LanguageRules.forLanguage(language.id),
            punctuationURL: language.punctuation.flatMap { ModelLocator.folder(named: $0, in: directories) },
            speakersURL: ModelLocator.folder(named: "veus-segmentacio", in: directories),
            cancellation: cancellation,
            level: level
        )
        let report: @Sendable (FileTranscriptionJob.Update) -> Void = { [weak self] update in
            Task { @MainActor in self?.apply(update) }
        }
        work = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try job.run(report)
                await self?.finish(with: result)
            } catch FileTranscriber.TranscriptionError.cancelled {
                return
            } catch {
                let message = error.localizedDescription
                await self?.fail(message)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    func cancel() {
        cancellation.cancel()
        work?.cancel()
    }

    /// Held while the app is away; it picks up where it was.
    @Published private(set) var isPaused = false

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        cancellation.setPaused(paused)
    }

    private func apply(_ update: FileTranscriptionJob.Update) {
        guard isWorking else { return }
        switch update {
        case .transcribing:
            phase = .transcribing
            startedAt = Date()
        case .progress(let progress):
            let now = Date()
            if let lastReport {
                // Smoothed, so one slow window does not jerk the estimates.
                reportInterval = reportInterval * 0.7 + now.timeIntervalSince(lastReport) * 0.3
                reportStep = reportStep * 0.7 + max(0, progress.fraction - fraction) * 0.3
            } else if let startedAt {
                reportInterval = max(0.1, now.timeIntervalSince(startedAt))
                reportStep = progress.fraction
            }
            lastReport = now
            fraction = progress.fraction
            session = progress.session
            arrived = progress.snapshot
            startRevealing()
            if let startedAt, progress.fraction > 0.04 {
                let elapsed = now.timeIntervalSince(startedAt)
                remaining = max(0, elapsed / progress.fraction - elapsed)
            }
        }
    }

    /// The progress as it should be drawn at `date`: it keeps moving between reports at
    /// the pace they have been coming, never passing where the next one is expected.
    func displayedFraction(at date: Date) -> Double {
        guard isWorking else { return phase == .finished ? 1 : fraction }
        guard let lastReport, reportInterval > 0 else { return fraction }
        let elapsed = date.timeIntervalSince(lastReport)
        let ahead = min(elapsed / reportInterval, 0.92) * reportStep
        return min(0.995, fraction + ahead)
    }

    /// Seconds to go at `date`, counting down between reports.
    func displayedRemaining(at date: Date) -> TimeInterval? {
        guard let remaining, let lastReport else { return nil }
        return max(0, remaining - date.timeIntervalSince(lastReport))
    }

    /// Reveals arrived words on the display's clock: fast enough to empty the backlog by
    /// the time the next window is expected, and never more than a few per frame.
    private func startRevealing() {
        guard revealTask == nil else { return }
        revealTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                guard self.revealStep() else {
                    self.revealTask = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    /// One frame of revealing; false once everything arrived is shown.
    private func revealStep() -> Bool {
        let settled = isWorking ? arrived.committedWords : arrived.words
        let hidden = settled.filter { $0.anchor > revealedAnchor }
        guard !hidden.isEmpty else {
            if !isWorking { transcript = arrived }
            return false
        }
        let window = isWorking ? max(0.25, reportInterval * 0.9) : 0.6
        revealCredit += Double(hidden.count) / window / 30
        let count = min(hidden.count, Int(revealCredit))
        guard count > 0 else { return true }
        revealCredit -= Double(count)
        revealedAnchor = hidden[count - 1].anchor
        let shown = arrived.committedWords.filter { $0.anchor <= revealedAnchor }
        transcript = ReadableTranscriptSnapshot(
            committedWords: shown,
            provisionalWords: isWorking ? [] : arrived.provisionalWords.filter { $0.anchor <= revealedAnchor },
            latestCommittedEndSequence: shown.last?.endSequence,
            latestVisibleEndSequence: shown.last?.endSequence,
            audioEndSequence: arrived.audioEndSequence,
            sampleRate: arrived.sampleRate,
            lastHeardEndSequence: arrived.lastHeardEndSequence
        )
        return true
    }

    private func finish(with result: FileTranscriptionJob.Output) {
        guard isWorking else { return }
        session = result.session
        // The last words finish arriving at the same pace, then the text is complete.
        arrived = result.snapshot
        fraction = 1
        remaining = 0
        document = SubtitleDocument(session: result.session)
        subtitlesURL = try? write(.subtitles)
        level.set(0)
        phase = .finished
        startRevealing()
    }

    /// Takes the editor's corrections: the exports, the `.srt` already written and the
    /// reading pane all carry them from now on, and they are kept on the device.
    func applyEdits(_ edited: SubtitleDocument) {
        guard phase == .finished else { return }
        show(edited)
        isEdited = true
        revision += 1
        keepCorrections()
    }

    /// The corrected lines as the job's text, `.srt` and reading pane.
    private func show(_ document: SubtitleDocument) {
        self.document = document
        session = document.session
        refreshSubtitlesFile()
        revealTask?.cancel()
        revealTask = nil
        arrived = Self.snapshot(of: document)
        transcript = arrived
        revealedAnchor = arrived.committedWords.last?.anchor ?? 0
    }

    /// Goes on from the corrections kept the last time this video was here, without
    /// hearing it again.
    func resume() {
        guard phase == .choosing, let saved = savedCorrections else { return }
        savedCorrections = nil
        if let id = saved.languageID { languageID = id }
        fraction = 1
        remaining = 0
        phase = .finished
        show(saved.document)
        isEdited = true
        revision += 1
        savedRevision = revision
    }

    /// Forgets the corrections kept for this video (the reader chose to start again).
    func forgetSavedCorrections() {
        guard let key = correctionsKey else { return }
        savedCorrections = nil
        let store = Self.correctionStore
        Self.correctionQueue.async { store.remove(key: key) }
    }

    /// Writes the corrections to the device, one write after another in order, so the
    /// newest always wins.
    private func keepCorrections() {
        guard let key = correctionsKey, let document else { return }
        let corrections = SavedCorrections(title: title, languageID: languageID, document: document)
        let revision = revision
        let store = Self.correctionStore
        Self.correctionQueue.async { [weak self] in
            let kept = (try? store.save(corrections, key: key)) != nil
            Task { @MainActor in
                guard kept, let self, self.revision == revision else { return }
                self.savedRevision = revision
            }
        }
    }

    /// `Application Support/…/Corrections`: user data, so it stays in backups.
    nonisolated static let correctionStore: CorrectionStore = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        // Outside a sandbox, Application Support is shared by every app.
        return CorrectionStore(root: support.appendingPathComponent("Subtítol Live/Corrections", isDirectory: true))
        #else
        return CorrectionStore(root: support.appendingPathComponent("Corrections", isDirectory: true))
        #endif
    }()
    private nonisolated static let correctionQueue = DispatchQueue(label: "duna.corrections", qos: .utility)

    /// The video's text in `format`. Its `.srt` holds as many words to a cue as the
    /// burnt-in captions (`CaptionStyle.saved.wordsPerCue`), corrections included.
    func rendered(_ format: TranscriptExportFormat) -> String {
        if format == .subtitles, let document {
            return document.subRip(wordsPerCue: CaptionStyle.saved.wordsPerCue)
        }
        return TranscriptExport.render(session, as: format)
    }

    /// The video's text in a file of its own named after it, ready to share.
    func write(_ format: TranscriptExportFormat) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Subtitols-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Self.filename(title, format: format))
        try rendered(format).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Writes the `.srt` already handed out again, after a correction or a new choice
    /// of words per cue.
    func refreshSubtitlesFile() {
        guard phase == .finished else { return }
        if let subtitlesURL {
            try? rendered(.subtitles).write(to: subtitlesURL, atomically: true, encoding: .utf8)
        } else {
            subtitlesURL = try? write(.subtitles)
        }
    }

    /// The corrected lines as the reading pane takes them.
    static func snapshot(of document: SubtitleDocument) -> ReadableTranscriptSnapshot {
        let rate: Int32 = 16_000
        func sequence(_ seconds: TimeInterval) -> UInt64 { UInt64(max(0, seconds) * Double(rate)) }
        var words: [StableTranscriptWord] = []
        for line in document.lines {
            for (index, word) in line.words.enumerated() {
                let position = UInt64(words.count + 1)
                words.append(StableTranscriptWord(
                    id: position,
                    text: word.text,
                    isCommitted: true,
                    anchor: position,
                    startSequence: sequence(word.start),
                    endSequence: sequence(word.end),
                    startsParagraph: index == 0 && line.startsParagraph,
                    startsLine: index == 0 && line.startsLine
                ))
            }
        }
        let end = words.last?.endSequence
        return ReadableTranscriptSnapshot(
            committedWords: words,
            latestCommittedEndSequence: end,
            latestVisibleEndSequence: end,
            audioEndSequence: max(end ?? 0, sequence(document.duration)),
            sampleRate: rate,
            lastHeardEndSequence: end
        )
    }

    private func fail(_ message: String) {
        guard isWorking else { return }
        level.set(0)
        phase = .failed(message)
    }

    /// The subtitles in a folder of their own, named after the video, ready to share.
    static func write(_ session: SessionTranscript, named title: String, format: TranscriptExportFormat = .subtitles) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Subtitols-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(filename(title, format: format))
        try TranscriptExport.render(session, as: format).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A name that is only an identifier, as Photos gives its files.
    static func isIdentifier(_ name: String) -> Bool {
        UUID(uuidString: name) != nil
            || name.range(of: "^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", options: .regularExpression) != nil
    }

    /// "Vídeo 2026-09-24 18.47": sorts by date and has no characters a file system or
    /// AirDrop refuse.
    static func title(filmedOn date: Date?) -> String {
        guard let date else { return localized("Vídeo") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "\(localized("Vídeo")) \(formatter.string(from: date))"
    }

    /// "Entrevista.srt"; slashes and colons, which a file system or AirDrop refuse, go.
    static func filename(_ title: String, format: TranscriptExportFormat) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cleaned.isEmpty ? "Subtítols" : cleaned).\(format.fileExtension)"
    }
}

/// Stops or holds a job from the main thread; the job's thread checks it before every
/// window. On the iPhone a job is held while the app is in the background, where the
/// GPU is not the app's to use.
final class CancellationFlag: @unchecked Sendable {
    private let condition = NSCondition()
    private var cancelled = false
    private var paused = false

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    func setPaused(_ value: Bool) {
        condition.lock()
        paused = value
        condition.broadcast()
        condition.unlock()
    }

    var isCancelled: Bool {
        condition.lock(); defer { condition.unlock() }
        return cancelled
    }

    /// Waits while held, then says whether the job should stop.
    func shouldStop() -> Bool {
        condition.lock(); defer { condition.unlock() }
        while paused && !cancelled { condition.wait() }
        return cancelled
    }
}

/// The loudness of the audio a job is transcribing, read at frame rate by the
/// decorative field so it moves with the film's voices.
final class MediaImportLevel: @unchecked Sendable {
    private let lock = NSLock()
    private var levels: [Float] = []
    private var startedAt: CFTimeInterval = 0
    private var stepSeconds: Double = 0.05
    private var value: Float = 0

    func set(_ level: Float) {
        lock.lock(); levels = []; value = level; lock.unlock()
    }

    /// Plays `levels` (one per `step` seconds of audio) over `duration` seconds of wall
    /// time: the window's voices, sped up to the pace the recogniser reads them.
    func play(_ levels: [Float], over duration: Double) {
        lock.lock()
        self.levels = levels
        stepSeconds = levels.isEmpty ? 0.05 : max(0.01, duration / Double(levels.count))
        startedAt = CACurrentMediaTime()
        lock.unlock()
    }

    func current() -> Float {
        lock.lock(); defer { lock.unlock() }
        guard !levels.isEmpty else { return value }
        let index = Int((CACurrentMediaTime() - startedAt) / stepSeconds)
        value = levels[min(levels.count - 1, max(0, index))]
        return value
    }
}

/// The job itself, off the main thread: decode, load, transcribe.
struct FileTranscriptionJob: Sendable {
    enum Update: Sendable {
        case transcribing
        case progress(FileTranscriber.Progress)
    }

    struct Output: Sendable {
        let session: SessionTranscript
        let snapshot: ReadableTranscriptSnapshot
    }

    enum JobError: LocalizedError {
        case noSound
        case unreadable

        var errorDescription: String? {
            switch self {
            case .noSound: localized("Aquest fitxer no té so.")
            case .unreadable: localized("No s'ha pogut llegir el so d'aquest fitxer.")
            }
        }
    }

    let source: URL
    let modelURL: URL
    let descriptor: SpeechModelDescriptor
    let rules: LanguageRules
    let punctuationURL: URL?
    let speakersURL: URL?
    let cancellation: CancellationFlag
    let level: MediaImportLevel

    func run(_ report: @escaping @Sendable (Update) -> Void) throws -> Output {
        let recording = try Self.decode(source, cancellation: cancellation)
        guard !cancellation.isCancelled else { throw FileTranscriber.TranscriptionError.cancelled }
        let engine = try ASREngine(modelURL: modelURL, repairsCatalanElisions: rules.id == "ca")
        let punctuation = descriptor.writesPunctuation ? nil : punctuationURL.flatMap { try? PunctuationModel(directory: $0) }
        let speakers = speakersURL.flatMap { try? SpeakerSegmentationModel(directory: $0) }
        let predictor: PunctuationPredicting? = punctuation ?? (punctuationURL == nil ? PlainPunctuation() : nil)
        report(.transcribing)

        let transcriber = FileTranscriber(rules: rules)
        var lastSnapshot = ReadableTranscriptSnapshot()
        let level = self.level
        let result = try transcriber.transcribe(
            recording,
            recognize: { samples, _ in
                let started = CACurrentMediaTime()
                let words = try engine.transcribe(samples: samples, sampleRate: recording.sampleRate).words
                level.play(Self.levels(samples, sampleRate: recording.sampleRate), over: max(0.1, CACurrentMediaTime() - started))
                return words
            },
            predictor: predictor,
            recognizerMarks: descriptor.writesPunctuation ? RecognizerPunctuation() : nil,
            speakers: speakers.map { model in { model.frameClasses($0) } },
            isCancelled: { cancellation.shouldStop() },
            progress: { progress in
                lastSnapshot = progress.snapshot
                report(.progress(progress))
            }
        )
        return Output(session: result.session, snapshot: lastSnapshot)
    }

    /// The loudness of every 50 ms, shaped like the microphone's level (×6, capped).
    static func levels(_ samples: [Float], sampleRate: Int32) -> [Float] {
        let step = max(1, Int(sampleRate) / 20)
        return stride(from: 0, to: samples.count, by: step).map { start in
            let slice = samples[start..<min(samples.count, start + step)]
            let rms = sqrt(slice.reduce(0) { $0 + $1 * $1 } / Float(max(1, slice.count)))
            return min(1, rms * 6)
        }
    }

    /// Every audio track, mixed to mono 16-bit at 16 kHz.
    static func decode(_ url: URL, cancellation: CancellationFlag) throws -> PCMRecording {
        let sampleRate: Int32 = 16_000
        let asset = AVURLAsset(url: url)
        let tracks = try blocking { try await asset.loadTracks(withMediaType: .audio) }
        guard !tracks.isEmpty else { throw JobError.noSound }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw JobError.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? JobError.unreadable }
        var samples = ContiguousArray<Int16>()
        if let seconds = try? blocking({ try await asset.load(.duration) }).seconds, seconds.isFinite {
            samples.reserveCapacity(Int(seconds * Double(sampleRate)) + 16_000)
        }
        while let buffer = output.copyNextSampleBuffer() {
            if cancellation.isCancelled {
                reader.cancelReading()
                throw FileTranscriber.TranscriptionError.cancelled
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Int16>.size
            guard count > 0 else { continue }
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            let status = samples.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 2, destination: bytes.baseAddress! + start * 2)
            }
            guard status == kCMBlockBufferNoErr else { throw JobError.unreadable }
        }
        guard reader.status == .completed else { throw reader.error ?? JobError.unreadable }
        guard !samples.isEmpty else { throw JobError.noSound }
        return PCMRecording(samples: samples, sampleRate: sampleRate)
    }

    /// Waits for an async AVFoundation property from this worker thread.
    private static func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>?
        Task.detached {
            do { result = .success(try await body()) } catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result!.get()
    }
}

/// The video being turned into subtitles, if any, for the whole app: the window's card,
/// the files the system hands over (Open With, the Dock, the share menu) and the
/// reading pane all look here.
@MainActor
final class ImportCenter: ObservableObject {
    /// The job's own changes are passed on, so views that watch the center follow its
    /// phase and progress too.
    @Published private(set) var current: MediaImport? {
        didSet {
            // Phase and reported progress only: the text moves at frame rate, and the
            // views that show it watch the job itself.
            forwarding = current.map { job in
                job.$phase.map { _ in () }
                    .merge(with: job.$fraction.map { _ in () }, job.$subtitlesURL.map { _ in () }, job.$isPaused.map { _ in () }, job.$revision.map { _ in () })
                    .dropFirst(5)
                    .sink { [weak self] _ in self?.objectWillChange.send() }
            }
        }
    }
    private var forwarding: AnyCancellable?
    /// The card is open. Closing it while a job runs leaves the job running.
    @Published var showsPanel = false
    /// Bumped whenever a file arrives from outside, so the window can come forward.
    @Published private(set) var arrivals = 0
    /// The finished video's subtitles, open for review.
    @Published private(set) var editor: SubtitleEditorModel?

    /// A file that arrived while the video on screen had corrections not yet exported:
    /// it waits for the reader to say whether to leave those (each screen asks).
    struct PendingArrival: Identifiable {
        let id = UUID()
        let url: URL
        let ownsSource: Bool
        let languageID: String?
    }
    @Published private(set) var pendingArrival: PendingArrival?

    /// Whether the video's corrections exist only in the app; a line still being typed
    /// is kept first, so it counts too.
    func hasUnexportedEdits() -> Bool {
        editor?.commit()
        return current?.hasUnexportedEdits == true
    }

    /// The reader chose to leave the corrections for the file that arrived.
    func openPendingArrival() {
        guard let pending = pendingArrival else { return }
        pendingArrival = nil
        open(pending.url, ownsSource: pending.ownsSource, languageID: pending.languageID, discardingEdits: true)
    }

    /// The reader kept the corrections: the file that arrived goes.
    func dropPendingArrival() {
        guard let pending = pendingArrival else { return }
        pendingArrival = nil
        if pending.ownsSource { ImportCenter.removeCopy(pending.url) }
    }

    /// Opens the finished video's subtitles to review and correct them.
    func openEditor() {
        guard let current, current.phase == .finished, editor?.job !== current else { return }
        showsPanel = false
        editor = SubtitleEditorModel(job: current)
    }

    /// Keeps the line being corrected and closes the editor; the video stays.
    func closeEditor() {
        editor?.close()
        editor = nil
    }

    /// Starts over with `url`, unless a video is still being transcribed. A video whose
    /// corrections have not left the app is not replaced at once: the file waits in
    /// `pendingArrival` until the reader decides.
    @discardableResult
    func open(_ url: URL, ownsSource: Bool = false, languageID: String?, discardingEdits: Bool = false) -> Bool {
        if let current, current.isWorking {
            showsPanel = true
            if ownsSource { try? FileManager.default.removeItem(at: url) }
            return false
        }
        if !discardingEdits, hasUnexportedEdits() {
            dropPendingArrival()
            pendingArrival = PendingArrival(url: url, ownsSource: ownsSource, languageID: languageID)
            arrivals += 1
            return false
        }
        closeEditor()
        current = MediaImport(source: url, ownsSource: ownsSource, languageID: languageID)
        showsPanel = true
        arrivals += 1
        return true
    }

    /// Clears the finished or abandoned job; the reading pane goes back to listening.
    func dismiss() {
        closeEditor()
        current?.cancel()
        current = nil
        showsPanel = false
    }

    /// Everything a video import accepts: any film or sound AVFoundation can read.
    static let contentTypes: [UTType] = [.movie, .audio]

    /// Copies of videos (from Photos, the share menu or a shortcut) sit in a folder of
    /// their own named `Imports-…` in the temporary folder.
    nonisolated static func makeCopyFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Imports-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Removes a copy that never became a job, with its folder.
    nonisolated static func removeCopy(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    /// Copies are removed with their job; one that was running when the app was closed
    /// leaves its copy, which goes at the next launch.
    nonisolated static func removeLeftoverCopies() {
        let temporary = FileManager.default.temporaryDirectory
        let entries = (try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? []
        // With them go the files written for sharing (`Subtitols-…`, from the cards and
        // the Shortcuts actions), which nothing reads once the app has been closed.
        for entry in entries where entry.lastPathComponent.hasPrefix("Imports-") || entry.lastPathComponent.hasPrefix("Subtitols-") {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
