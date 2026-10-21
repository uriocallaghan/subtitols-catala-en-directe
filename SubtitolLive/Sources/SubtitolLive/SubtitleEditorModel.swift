@preconcurrency import AVFoundation
import Combine
import CoreGraphics
import Foundation
import SubtitolCore
#if os(iOS)
import Photos
import UIKit
#endif

/// The time the video is at, published on its own at frame rate so only the views that
/// follow the voice (the line being said, the scrubber, the caption preview) redraw.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: TimeInterval = 0
}

/// Reviewing a video's subtitles: the film plays, the lines follow it like a song's
/// lyrics, and a line tapped is heard again while it is corrected.
///
/// Every correction goes straight back to the job (`MediaImport.applyEdits`), so the
/// `.srt`, the text exports and the reading pane carry it, and is kept on a history the
/// reader can step back through. The burnt-in copy is written from the same lines.
@MainActor
final class SubtitleEditorModel: ObservableObject, Identifiable {
    enum VideoExport: Equatable {
        case idle
        case rendering(Double)
        case finished(URL)
        case failed(String)
    }

    let id = UUID()
    let job: MediaImport
    let player: AVPlayer
    let clock = PlaybackClock()

    @Published private(set) var document: SubtitleDocument
    /// The line being said, or the last one said.
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval
    /// The picture as shown (rotation applied); `nil` for a recording without one.
    @Published private(set) var pictureSize: CGSize?
    @Published private(set) var editingLineID: Int?
    @Published var draft = ""
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var renderer: CaptionRenderer
    @Published private(set) var videoExport: VideoExport = .idle
    /// Where the finished copy stands with the photo library (iPhone): it goes there by
    /// itself as soon as it is made, so nobody has to find a button for it.
    @Published private(set) var photos: PhotosSave = .idle

    enum PhotosSave: Equatable {
        case idle
        case saving
        case saved
        /// The copy itself stays ready; `denied` means only Settings can let it in.
        case failed(String, denied: Bool)
    }

    /// How the captions look, as chosen in the editor; remembered for the next video.
    @Published private(set) var style: CaptionStyle
    /// The captions as the preview over the film draws them: the line being typed
    /// shows its draft there before it is kept.
    @Published private(set) var previewRenderer: CaptionRenderer
    /// The reader is dragging the captions across the film.
    @Published private(set) var isPlacingCaption = false

    /// A line the recogniser missed, being written into the silence after a line.
    struct Insertion: Equatable {
        /// Stands in for a line id while it is typed; never one of the document's.
        static let lineID = -1
        let after: Int?
        let span: ClosedRange<TimeInterval>
    }
    @Published private(set) var insertion: Insertion?

    /// Find and replace: the bar is open, what is looked for and what replaces it.
    @Published private(set) var isFinding = false
    @Published var query = "" {
        didSet { if query != oldValue { refreshMatches(keepingPlace: false) } }
    }
    @Published var replacement = ""
    @Published private(set) var matches: [SubtitleDocument.Match] = []
    /// The match last shown, among `matches`.
    @Published private(set) var matchIndex: Int?
    /// The words each line has that match, for the lines to light them.
    @Published private(set) var matchedWords: [Int: Set<Int>] = [:]
    /// How many places the last "replace all" changed, until the search changes.
    @Published private(set) var replacedCount: Int?
    /// Asks the screen to open its export card (the Mac's File › Export while the
    /// editor is open).
    @Published private(set) var exportRequest = 0
    /// Asks the lines to bring `focusLineID` into view, even while the reader scrolls.
    @Published private(set) var focusRequest = 0
    private(set) var focusLineID: Int?
    private var undoStack: [SubtitleDocument] = []
    private var redoStack: [SubtitleDocument] = []
    private var timeObserver: Any?
    private var statusWatch: AnyCancellable?
    /// While a line is replayed, playback stops here.
    private var stopAt: TimeInterval?
    /// Counts the reader's play and pause requests: a seek that lands after another
    /// request (a pause, a delete, closing) must not start playing.
    private var playRequest = 0
    private var exportTask: Task<Void, Never>?
    /// Counts the copies started, so progress from one stopped cannot reach the next.
    private var exportGeneration = 0
    #if os(iOS)
    /// A copy stopped because the app went to the background, started again on return.
    private var resumesExportOnReturn = false
    private var lifecycleWatch: [AnyCancellable] = []
    #endif

    init(job: MediaImport) {
        self.job = job
        let document = job.document ?? SubtitleDocument(session: job.session)
        self.document = document
        let style = CaptionStyle.saved
        self.style = style
        let renderer = CaptionRenderer(document: document, style: style)
        self.renderer = renderer
        previewRenderer = renderer
        duration = job.duration ?? document.duration
        player = AVPlayer(url: job.source)
        player.actionAtItemEnd = .pause
        #if os(iOS)
        // The phone was last set up to listen; the film has to be heard.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        statusWatch = player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                MainActor.assumeIsolated { self?.isPlaying = status != .paused }
            }
        Task { await loadPicture() }
        tick(0)
        #if os(iOS)
        // iOS takes the GPU from an app in the background, and the copy would fail: it
        // stops there and starts again when the reader comes back.
        lifecycleWatch = [
            NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.pauseExportForBackground() } },
            NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.resumeExportAfterBackground() } },
        ]
        #endif
    }

    deinit {
        exportTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        player.pause()
    }

    /// The editor is closing: the film stops, a copy being made stops, and on the iPhone
    /// the sound goes back to how the app found it.
    func close() {
        commit()
        pause()
        stopAt = nil
        cancelVideoExport()
        #if os(iOS)
        resumesExportOnReturn = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func loadPicture() async {
        let asset = AVURLAsset(url: job.source)
        if let time = try? await asset.load(.duration), time.isNumeric, time.seconds > 0 {
            duration = time.seconds
        }
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) else {
            pictureSize = nil
            return
        }
        let shown = CGRect(origin: .zero, size: natural).applying(transform)
        pictureSize = CGSize(width: abs(shown.width), height: abs(shown.height))
    }

    // MARK: - Playing

    private func tick(_ time: TimeInterval) {
        guard time.isFinite else { return }
        clock.time = time
        let index = document.lineIndex(at: time + 0.04)
        if index != currentIndex { currentIndex = index }
        if let stopAt, time >= stopAt {
            self.stopAt = nil
            player.pause()
        }
    }

    /// Stops the film, and any replay still waiting for its seek.
    private func pause() {
        playRequest += 1
        stopAt = nil
        player.pause()
    }

    func togglePlayback() {
        if isPlaying {
            pause()
            return
        }
        // While a line is being corrected, play hears it again.
        if editingLineID != nil {
            replayEditing()
            return
        }
        stopAt = nil
        if clock.time >= duration - 0.05 { seek(to: 0) }
        player.play()
    }

    func seek(to time: TimeInterval, exact: Bool = true) {
        let clamped = max(0, min(duration, time))
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        let tolerance = exact ? CMTime.zero : CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance)
        tick(clamped)
    }

    /// Plays one line from just before its first word to just after its last.
    func play(_ line: SubtitleDocument.Line) {
        play(from: line.start - 0.15, to: line.end + 0.3)
    }

    /// Plays from `start` and stops at `end`. The stop is armed once the seek has landed,
    /// so a tick still reporting the old place cannot stop it at once.
    private func play(from start: TimeInterval, to end: TimeInterval) {
        stopAt = nil
        playRequest += 1
        let request = playRequest
        let clamped = max(0, min(duration, start))
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        tick(clamped)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor in
                guard let self, self.playRequest == request else { return }
                self.stopAt = end
                self.player.play()
            }
        }
    }

    /// Hears the line being corrected again, or the silence a missing line goes into.
    func replayEditing() {
        if let insertion, editingLineID == Insertion.lineID {
            play(from: insertion.span.lowerBound - 0.4, to: insertion.span.upperBound + 0.2)
        } else if let id = editingLineID, let line = document.line(id: id) {
            play(line)
        }
    }

    // MARK: - Correcting

    func edit(_ id: Int) {
        if editingLineID == id { return }
        commit()
        guard let line = document.line(id: id) else { return }
        draft = line.text
        editingLineID = id
        play(line)
    }

    /// The draft as a line's text: a line break is never part of a subtitle.
    private var draftText: String {
        draft.replacingOccurrences(of: "\n", with: " ")
    }

    /// Keeps the draft as the line's text; an empty draft removes the line. A missing
    /// line being written is added, unless it was left empty.
    func commit() {
        guard let id = editingLineID else { return }
        editingLineID = nil
        let text = draftText
        if id == Insertion.lineID, let insertion {
            self.insertion = nil
            change { $0.insertLine(text, after: insertion.after, span: insertion.span) != nil }
            return
        }
        change { $0.setText(text, ofLine: id) }
    }

    func cancelEditing() {
        editingLineID = nil
        insertion = nil
        previewRenderer = renderer
    }

    /// Keeps this line and goes on to correct the next one.
    func commitAndEditNext() {
        guard let id = editingLineID else { return }
        let next: Int?
        if id == Insertion.lineID {
            let after = insertion?.after
            let index = after.flatMap { document.index(of: $0) }.map { $0 + 1 } ?? 0
            next = index < document.lines.count ? document.lines[index].id : nil
        } else if let index = document.index(of: id) {
            next = index + 1 < document.lines.count ? document.lines[index + 1].id : nil
        } else {
            next = nil
        }
        commit()
        if let next { edit(next) }
    }

    /// Removes the line being corrected.
    func deleteEditing() {
        guard let id = editingLineID else { return }
        if id == Insertion.lineID {
            cancelEditing()
            return
        }
        editingLineID = nil
        pause()
        change { $0.removeLine(id: id) }
    }

    /// Cuts the line being corrected in two where the cursor is (between the words it
    /// sits by), or where it reads best when the cursor is at either end. The draft is
    /// kept first; both are one step to undo.
    func splitEditing(atCharacter offset: Int?) {
        guard let id = editingLineID, id != Insertion.lineID else { return }
        let text = draftText
        let characters = Array(text)
        var wordIndex: Int?
        if let offset, offset > 0, offset < characters.count {
            let before = characters[..<offset]
            let wordsBefore = String(before).split(whereSeparator: \.isWhitespace).count
            // A cursor inside a word cuts before that word.
            let insideWord = !(before.last?.isWhitespace ?? true) && !characters[offset].isWhitespace
            wordIndex = wordsBefore - (insideWord ? 1 : 0)
        }
        editingLineID = nil
        pause()
        change { document in
            let corrected = document.setText(text, ofLine: id)
            guard let line = document.line(id: id) else { return corrected }
            let cut = wordIndex.flatMap { $0 > 0 && $0 < line.words.count ? $0 : nil }
                ?? document.naturalSplit(ofLine: id)
            let split = cut.flatMap { document.split(lineID: id, beforeWord: $0) } != nil
            return corrected || split
        }
    }

    /// Whether the line being corrected has a line after it to join.
    var canMergeEditing: Bool {
        guard let id = editingLineID, let index = document.index(of: id) else { return false }
        return index + 1 < document.lines.count
    }

    /// Joins the next line onto the one being corrected, and goes on correcting it.
    func mergeEditingWithNext() {
        guard let id = editingLineID, canMergeEditing else { return }
        let text = draftText
        editingLineID = nil
        change { document in
            let corrected = document.setText(text, ofLine: id)
            return document.mergeWithNext(lineID: id) || corrected
        }
        guard let line = document.line(id: id) else { return }
        draft = line.text
        editingLineID = id
    }

    /// Whether a missing line fits in the silence after the line being corrected.
    var canInsertAfterEditing: Bool {
        guard let id = editingLineID, id != Insertion.lineID, let gap = document.gap(after: id) else { return false }
        return gap.upperBound - gap.lowerBound >= SubtitleDocument.minimumInsertSeconds
    }

    /// Opens a new line in the silence after the line being corrected, for words the
    /// recogniser missed, and plays that silence.
    func insertAfterEditing() {
        guard canInsertAfterEditing, let id = editingLineID, let gap = document.gap(after: id) else { return }
        commit()
        guard document.line(id: id) != nil else { return }
        insertion = Insertion(after: id, span: gap)
        draft = ""
        editingLineID = Insertion.lineID
        replayEditing()
    }

    /// One undoable change to the document.
    private func change(_ body: (inout SubtitleDocument) -> Bool) {
        var edited = document
        guard body(&edited), edited != document else {
            previewRenderer = renderer
            return
        }
        undoStack.append(document)
        redoStack.removeAll()
        apply(edited)
    }

    func undo() {
        commit()
        replacedCount = nil
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        apply(previous)
    }

    func redo() {
        commit()
        replacedCount = nil
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        apply(next)
    }

    private func apply(_ edited: SubtitleDocument) {
        document = edited
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        renderer = CaptionRenderer(document: edited, style: style)
        previewRenderer = renderer
        currentIndex = edited.lineIndex(at: clock.time + 0.04)
        job.applyEdits(edited)
        refreshMatches(keepingPlace: true)
        restartStaleExport()
    }

    func requestExport() {
        exportRequest += 1
    }

    // MARK: - Find and replace

    func showFind() {
        commit()
        isFinding = true
        refreshMatches(keepingPlace: false)
    }

    func hideFind() {
        isFinding = false
        matches = []
        matchedWords = [:]
        matchIndex = nil
    }

    /// Goes to the next (or previous) place the search is said: the film waits there
    /// and the lines bring it into view.
    func showMatch(step: Int) {
        guard !matches.isEmpty else { return }
        let next: Int
        if let matchIndex {
            next = (matchIndex + step + matches.count) % matches.count
        } else {
            // The first one from where the film is.
            let after = matches.firstIndex { match in
                (document.line(id: match.lineID)?.start ?? 0) >= clock.time - 0.05
            }
            next = step >= 0 ? (after ?? 0) : ((after ?? matches.count) - 1 + matches.count) % matches.count
        }
        matchIndex = next
        let match = matches[next]
        guard let line = document.line(id: match.lineID) else { return }
        pause()
        stopAt = nil
        seek(to: line.words[match.words.lowerBound].start)
        focusLineID = line.id
        focusRequest += 1
    }

    /// Replaces every place the search is said; one step to undo.
    func replaceAllMatches() {
        commit()
        let query = query
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        var count = 0
        change { document in
            count = document.replaceAll(query, with: replacement)
            return count > 0
        }
        replacedCount = count
    }

    private func refreshMatches(keepingPlace: Bool) {
        if !keepingPlace { replacedCount = nil }
        guard isFinding else { return }
        let found = document.matches(of: query)
        if found != matches {
            matches = found
            var words: [Int: Set<Int>] = [:]
            for match in found { words[match.lineID, default: []].formUnion(match.words) }
            matchedWords = words
        }
        if let matchIndex, keepingPlace, matchIndex < matches.count { return }
        matchIndex = nil
    }

    /// A copy made before a change no longer matches the subtitles; one being made
    /// starts again with it.
    private func restartStaleExport() {
        switch videoExport {
        case .finished, .failed: videoExport = .idle
        case .rendering:
            cancelVideoExport()
            exportVideo()
        case .idle: break
        }
    }

    // MARK: - Caption style

    func setCaptionWords(_ words: Int) {
        var next = style
        next.wordsPerCue = min(3, max(0, words))
        updateStyle(next)
        // The `.srt` follows: it is the same captions in a file.
        job.refreshSubtitlesFile()
    }

    /// One step of the − and + buttons.
    func stepCaptionSize(by steps: Int) {
        setCaptionScale(style.scale + CGFloat(steps) * CaptionStyle.scaleStep)
    }

    func setCaptionScale(_ scale: CGFloat) {
        var next = style
        next.scale = scale
        updateStyle(next)
    }

    func setCaptionFont(_ font: CaptionFont) {
        var next = style
        next.font = font
        updateStyle(next)
    }

    func setCaptionShadow(_ on: Bool) {
        var next = style
        next.shadow = on
        updateStyle(next)
    }

    func setCaptionStroke(_ on: Bool) {
        var next = style
        next.stroke = on
        updateStyle(next)
    }

    /// Moves the captions while the reader drags them; `finished` keeps the place.
    /// Only the place changes, so the drawn captions are reused and the drag stays fluid.
    func placeCaption(at position: CGPoint?, finished: Bool) {
        if isPlacingCaption == finished { isPlacingCaption = !finished }
        let position = position.map { CGPoint(x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y))) }
        if position != style.position {
            let previewIsDraft = previewRenderer !== renderer
            style.position = position
            renderer = renderer.placed(at: position)
            previewRenderer = previewIsDraft ? previewRenderer.placed(at: position) : renderer
        }
        if finished {
            style.save()
            restartStaleExport()
        }
    }

    /// The text of the caption shown now (or the nearest one), as shares of the
    /// picture: what a drag picks up.
    func captionTextFrame(in pictureSize: CGSize) -> CGRect? {
        guard pictureSize.width > 0, pictureSize.height > 0,
              let frame = previewRenderer.textFrame(at: clock.time, pictureSize: pictureSize) else { return nil }
        return CGRect(
            x: frame.minX / pictureSize.width,
            y: frame.minY / pictureSize.height,
            width: frame.width / pictureSize.width,
            height: frame.height / pictureSize.height
        )
    }

    /// Shows the line being typed in the preview as it is typed.
    func previewDraft() {
        guard let id = editingLineID else { return }
        var drafted = document
        if id == Insertion.lineID, let insertion {
            drafted.insertLine(draftText, after: insertion.after, span: insertion.span)
        } else {
            drafted.setText(draftText, ofLine: id)
        }
        previewRenderer = CaptionRenderer(document: drafted, style: style)
    }

    private func updateStyle(_ next: CaptionStyle, saving: Bool = true) {
        if saving { next.save() }
        guard next != style else { return }
        style = next
        renderer = CaptionRenderer(document: document, style: next)
        previewRenderer = renderer
        if saving { restartStaleExport() }
    }

    // MARK: - Burnt-in copy

    var canExportVideo: Bool { job.hasVideo && pictureSize != nil && !document.isEmpty }

    /// Writes the video again with the subtitles in the picture, beside the job's files.
    func exportVideo() {
        commit()
        guard canExportVideo else { return }
        if case .rendering = videoExport { return }
        pause()
        photos = .idle
        videoExport = .rendering(0)
        let source = job.source
        let renderer = CaptionRenderer(document: document, style: style)
        let destination: URL
        do {
            destination = try Self.destination(for: job)
        } catch {
            videoExport = .failed(error.localizedDescription)
            return
        }
        exportGeneration += 1
        let generation = exportGeneration
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.showProgress(fraction, generation: generation) }
        }
        exportTask = Task { [weak self] in
            do {
                try await CaptionedVideoExport.export(source: source, renderer: renderer, to: destination, progress: report)
                try Task.checkCancellation()
                guard let self, self.exportGeneration == generation else { return }
                self.videoExport = .finished(destination)
                #if os(iOS)
                self.saveToPhotos()
                #endif
            } catch {
                try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
                guard let self, !Task.isCancelled, self.exportGeneration == generation else { return }
                self.videoExport = .failed(localized("No s'ha pogut fer el vídeo. Torna-ho a provar."))
            }
        }
    }

    private func showProgress(_ fraction: Double, generation: Int) {
        guard generation == exportGeneration, case .rendering(let shown) = videoExport, fraction > shown else { return }
        videoExport = .rendering(fraction)
    }

    func cancelVideoExport() {
        exportTask?.cancel()
        exportTask = nil
        exportGeneration += 1
        videoExport = .idle
    }

    /// Closing the card forgets a failure; a finished copy stays, ready to save or send,
    /// until the subtitles change.
    func dismissVideoExport() {
        if case .failed = videoExport { videoExport = .idle }
    }

    #if os(iOS)
    private func pauseExportForBackground() {
        guard case .rendering = videoExport else { return }
        cancelVideoExport()
        resumesExportOnReturn = true
    }

    private func resumeExportAfterBackground() {
        guard resumesExportOnReturn else { return }
        resumesExportOnReturn = false
        exportVideo()
    }
    #endif

    /// "Entrevista amb subtítols.mov", in a folder of its own among the files the app
    /// clears at its next launch; an MP4 stays an MP4.
    private static func destination(for job: MediaImport) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Subtitols-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileExtension = job.source.pathExtension.lowercased() == "mp4" ? "mp4" : "mov"
        return folder.appendingPathComponent(videoFilename(job.title, fileExtension: fileExtension))
    }

    static func videoFilename(_ title: String, fileExtension: String) -> String {
        let named = localized("\(title) amb subtítols")
        let cleaned = named.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cleaned).\(fileExtension)"
    }

    #if os(iOS)
    /// Adds the finished copy to the photo library, asking only for permission to add.
    /// Runs by itself when the copy is made; the card's button only retries a failure.
    func saveToPhotos() {
        guard case .finished(let url) = videoExport else { return }
        if photos == .saving || photos == .saved { return }
        photos = .saving
        let generation = exportGeneration
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard generation == exportGeneration else { return }
            guard status == .authorized || status == .limited else {
                photos = .failed(localized("Per desar el vídeo, permet que duna afegeixi fotos a Configuració."), denied: true)
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
                guard generation == exportGeneration else { return }
                photos = .saved
                job.markExported()
                UIAccessibility.post(notification: .announcement, argument: localized("Desat a Fotos"))
            } catch {
                guard generation == exportGeneration else { return }
                photos = .failed(localized("No s'ha pogut desar el vídeo a Fotos. Torna-ho a provar."), denied: false)
            }
        }
    }
    #endif
}
