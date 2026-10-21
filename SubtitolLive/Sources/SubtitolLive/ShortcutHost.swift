import Foundation
import SubtitolCore
import SwiftUI

/// What the Shortcuts actions (`AppIntents.swift`) do inside the running app, on the Mac
/// and the iPhone alike. Each app hands over its language packs, its video center and a
/// way to reach the recognition session when it launches (`attach`).
///
/// The actions go through the same objects as the reader's taps, so the screen changes
/// exactly as it does for a tap, animations included. Nothing listens unless the app is
/// on screen: the actions that listen or read a video bring it forward first.
@MainActor
final class ShortcutHost: ObservableObject {
    static let shared = ShortcutHost()

    /// Bumped when an action is about to start listening: the reading screen closes its
    /// cards, sheets and settings, as a tap on it would.
    @Published private(set) var clearRequests = 0

    private var packs: LanguagePackStore?
    private var imports: ImportCenter?
    private var controller: () -> SubtitleController? = { nil }
    /// The Mac makes sure a window is on screen; the iPhone is brought forward by the system.
    private var bringForward: () -> Void = {}

    /// Shortcuts gives every action 30 seconds and then cancels it with a message of its
    /// own, so each wait ends earlier, with ours.
    nonisolated static let actionBudget: TimeInterval = 25
    /// Waiting for the last sentence to close after Stop.
    private static let closingTimeout: TimeInterval = 20

    func attach(
        packs: LanguagePackStore,
        imports: ImportCenter,
        controller: @escaping () -> SubtitleController?,
        bringForward: @escaping () -> Void = {}
    ) {
        self.packs = packs
        self.imports = imports
        self.controller = controller
        self.bringForward = bringForward
    }

    // MARK: - Languages

    var catalog: LanguageCatalog { packs?.catalog ?? LanguageCatalog(languages: []) }

    func isInstalled(_ language: SpeechLanguage) -> Bool {
        packs?.state(of: language) == .installed
    }

    /// Makes `id` the language in use. Refused while listening or reading a video, since
    /// the switch replaces the session and its text.
    func selectLanguage(id: String) throws {
        let (packs, imports) = try services()
        let language = try installedLanguage(id, in: packs)
        guard packs.selectedLanguageID != language.id else { return }
        if let controller = controller(), controller.isRecording || controller.state == .transcribing {
            throw ShortcutError.listening
        }
        if imports.current?.isWorking == true { throw ShortcutError.videoInProgress }
        packs.select(language)
    }

    // MARK: - Listening

    /// Starts listening in `languageID` (the language in use when `nil`), once its model
    /// is loaded and the microphone allowed. Returns once the app is listening.
    ///
    /// If the system is still asking for the microphone when the time is up, the action
    /// ends without an error: the app starts listening once the reader answers.
    func startListening(languageID: String?, until deadline: Date = .now + actionBudget) async throws {
        let (packs, imports) = try services()
        guard Self.isOnboarded else { throw ShortcutError.setupNotFinished }
        let language = try installedLanguage(languageID, in: packs)
        if imports.current?.isWorking == true { throw ShortcutError.videoInProgress }
        // Corrections not yet exported would go with the video's text.
        if imports.editor != nil || imports.hasUnexportedEdits() { throw ShortcutError.editingSubtitles }

        bringForward()
        clearRequests += 1
        // A finished video's text gives the screen back to listening, as a tap does.
        if imports.current != nil {
            withAnimation(.easeInOut(duration: 0.45)) { imports.dismiss() }
        }
        if packs.selectedLanguageID != language.id {
            // Another language replaces the session: the sentence being heard closes first.
            _ = try await stopListening()
            packs.select(language)
        }

        while true {
            if let controller = controller(), controller.rules.id == language.id {
                switch controller.state {
                case .recording:
                    return
                case .ready:
                    controller.toggleRecording()
                case .requestingPermission:
                    // The reader is answering the system's question: listening starts
                    // with their yes, whether or not the action is still waiting.
                    if Date() >= deadline { return }
                case .failed:
                    throw ShortcutError.failed(controller.detail)
                case .needsLanguage:
                    throw ShortcutError.noLanguage
                case .loading, .transcribing:
                    break
                }
            }
            guard Date() < deadline else { throw ShortcutError.notReady }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Stops listening, waits for the last sentence's correction, and returns the text.
    func stopListening() async throws -> String {
        guard let controller = controller() else { return "" }
        if controller.isRecording { controller.toggleRecording() }
        let deadline = Date().addingTimeInterval(Self.closingTimeout)
        while controller.state == .transcribing, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        return TranscriptExport.plainText(controller.session)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - The text on screen

    /// What the share glyph would send: a finished video's subtitles, else the live
    /// session (the one being heard, or the last). Nothing is kept once the app quits.
    /// Right after Stop, it waits for the last sentence's correction.
    func shownTranscript() async throws -> (session: SessionTranscript, title: String?) {
        let (_, imports) = try services()
        if imports.current?.isWorking == true { throw ShortcutError.videoInProgress }
        if let controller = controller(), controller.state == .transcribing {
            let deadline = Date().addingTimeInterval(Self.closingTimeout)
            while controller.state == .transcribing, Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        if let job = imports.current, job.phase == .finished, !job.session.isEmpty {
            return (job.session, job.title)
        }
        guard let session = controller()?.session, !session.isEmpty else {
            throw ShortcutError.noTranscript
        }
        return (session, nil)
    }

    /// The transcript on screen, written as a file in `format`.
    func exportShownTranscript(as format: TranscriptExportFormat) async throws -> URL {
        let (session, title) = try await shownTranscript()
        if title != nil, let job = imports?.current, job.phase == .finished { return try job.write(format) }
        let name = title ?? (TranscriptExport.filename(for: session, format: format) as NSString).deletingPathExtension
        return try MediaImport.write(session, named: name, format: format)
    }

    // MARK: - Videos

    /// Starts transcribing `file`, a copy made for this job (removed with it), in the
    /// reading pane with its card open, exactly as a video chosen in the app. Returns once
    /// the sound has been read and recognition has begun, so a file that cannot be read
    /// is reported here; the rest goes on in the app.
    func startTranscribing(file: URL, languageID: String?, until deadline: Date = .now + actionBudget) async throws {
        let (packs, imports) = try services()
        let language: SpeechLanguage
        do {
            guard Self.isOnboarded else { throw ShortcutError.setupNotFinished }
            language = try installedLanguage(languageID, in: packs)
            if let controller = controller(), controller.isRecording || controller.state == .transcribing {
                throw ShortcutError.listening
            }
            if imports.current?.isWorking == true { throw ShortcutError.videoInProgress }
            if imports.editor != nil || imports.hasUnexportedEdits() { throw ShortcutError.editingSubtitles }
        } catch {
            ImportCenter.removeCopy(file)
            throw error
        }

        bringForward()
        if imports.current != nil { imports.dismiss() }
        guard imports.open(file, ownsSource: true, languageID: language.id), let job = imports.current else {
            ImportCenter.removeCopy(file)
            throw ShortcutError.videoInProgress
        }
        job.start(language: language, packs: packs)

        while imports.current === job, Date() < deadline {
            switch job.phase {
            case .failed(let message):
                throw ShortcutError.failed(message)
            case .transcribing, .finished:
                return
            case .choosing, .preparing:
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: -

    private static var isOnboarded: Bool {
        UserDefaults.standard.bool(forKey: "onboarding.done")
    }

    private func services() throws -> (LanguagePackStore, ImportCenter) {
        guard let packs, let imports else { throw ShortcutError.notReady }
        return (packs, imports)
    }

    /// `id`, or the language in use when `nil`; it must be on the device.
    private func installedLanguage(_ id: String?, in packs: LanguagePackStore) throws -> SpeechLanguage {
        guard let id = id ?? packs.selectedLanguageID else { throw ShortcutError.noLanguage }
        guard let language = packs.catalog.language(id: id) else { throw ShortcutError.noLanguage }
        guard packs.state(of: language) == .installed else {
            throw ShortcutError.notInstalled(language.name)
        }
        return language
    }
}

/// Why an action could not do what it was asked, in words for the reader.
///
/// The words are translated here, in the device's language, and handed over already
/// written: Shortcuts looks up an error's key in the process that runs the shortcut,
/// which answered in English on a phone set to Spanish.
enum ShortcutError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case setupNotFinished
    case noLanguage
    case notInstalled(String)
    case listening
    case videoInProgress
    case editingSubtitles
    case noTranscript
    case unreadableFile
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: message)
    }

    var message: String {
        switch self {
        case .notReady:
            String(localized: "duna no ha pogut preparar l'idioma a temps. Torna-ho a provar.")
        case .setupNotFinished:
            String(localized: "Obre duna i acaba de preparar-lo abans de fer servir aquesta drecera.")
        case .noLanguage:
            String(localized: "Encara no hi ha cap idioma instal·lat. Obre duna per baixar-ne un.")
        case .notInstalled(let name):
            String(localized: "L'idioma \(name) no està instal·lat. Obre duna per baixar-lo.")
        case .listening:
            String(localized: "duna està escoltant. Atura la transcripció primer.")
        case .videoInProgress:
            String(localized: "duna està fent els subtítols d'un vídeo. Espera que acabi.")
        case .editingSubtitles:
            String(localized: "Tanca l'editor de subtítols de duna, o exporta les correccions, primer.")
        case .noTranscript:
            String(localized: "Encara no hi ha cap transcripció. duna no en guarda cap quan es tanca.")
        case .unreadableFile:
            String(localized: "No s'ha pogut llegir aquest fitxer.")
        case .failed(let message):
            message
        }
    }
}
