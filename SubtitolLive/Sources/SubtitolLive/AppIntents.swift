import AppIntents
import Foundation
import SubtitolCore
import UniformTypeIdentifiers

// The app's actions in Shortcuts, on the iPhone and the Mac. Each one goes through
// `ShortcutHost`, which uses the same objects as the reader's taps.
//
// App Review: nothing listens in the background. The actions that listen or read a
// video bring the app to the screen first (`supportedModes = .foreground`), and the
// microphone is asked for by the app itself, as for a tap. Everything stays on the
// device, and no transcript is kept once the app quits (there is no history to read).
//
// The titles, descriptions and errors are Catalan keys of `Localizable.xcstrings`; the
// system shows them in the device's language.

// MARK: - Values

/// One of the app's languages. Shortcuts suggests the installed ones.
struct SpeechLanguageEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Idioma")
    static let defaultQuery = SpeechLanguageQuery()

    let id: String
    /// The language's own name ("català", "euskara").
    let name: String
    let isBeta: Bool

    init(_ language: SpeechLanguage) {
        id = language.id
        name = language.name
        isBeta = language.stage == .beta
    }

    var displayRepresentation: DisplayRepresentation {
        isBeta
            ? DisplayRepresentation(title: "\(name)", subtitle: "Nou")
            : DisplayRepresentation(title: "\(name)")
    }
}

struct SpeechLanguageQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [SpeechLanguageEntity.ID]) async throws -> [SpeechLanguageEntity] {
        let catalog = ShortcutHost.shared.catalog
        return identifiers.compactMap(catalog.language(id:)).map(SpeechLanguageEntity.init)
    }

    /// Only the languages on this device: the others must be downloaded in the app.
    @MainActor
    func suggestedEntities() async throws -> [SpeechLanguageEntity] {
        let host = ShortcutHost.shared
        return host.catalog.languages.filter(host.isInstalled).map(SpeechLanguageEntity.init)
    }
}

/// The files a transcript can be saved as, as in the app's export card.
enum TranscriptFormatOption: String, AppEnum {
    case text
    case markdown
    case subtitles

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Format")
    static let caseDisplayRepresentations: [TranscriptFormatOption: DisplayRepresentation] = [
        .text: DisplayRepresentation(title: "Text", subtitle: "Només el text, en paràgrafs"),
        .markdown: DisplayRepresentation(title: "Markdown", subtitle: "Amb títol, data i durada"),
        .subtitles: DisplayRepresentation(title: "Subtítols (.srt)", subtitle: "Paraula per paraula, amb el seu temps"),
    ]

}

extension TranscriptExportFormat {
    init(_ option: TranscriptFormatOption) {
        switch option {
        case .text: self = .text
        case .markdown: self = .markdown
        case .subtitles: self = .subtitles
        }
    }
}

extension IntentFile {
    /// A written transcript, typed so the next action knows what it holds.
    init(transcript url: URL, format: TranscriptExportFormat) {
        self.init(fileURL: url, filename: url.lastPathComponent, type: format.contentType)
    }
}

// MARK: - Listening

struct StartTranscribingIntent: AppIntent {
    static let title: LocalizedStringResource = "Comença a subtitular"
    static let description = IntentDescription(
        "Obre duna i comença a posar per escrit el que se sent. Si tries un idioma, primer canvia a aquest idioma.",
        categoryName: "Transcripció en directe",
        searchKeywords: ["subtítols", "transcriure", "escoltar"]
    )
    /// Listening needs the app on screen: the reader sees it, and so does the system.
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Idioma", description: "Si no en tries cap, fa servir l'idioma que hi ha posat a l'app.")
    var language: SpeechLanguageEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Comença a subtitular en \(\.$language)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ShortcutHost.shared.startListening(languageID: language?.id)
        return .result()
    }
}

struct StopTranscribingIntent: AppIntent {
    static let title: LocalizedStringResource = "Atura la transcripció"
    static let description = IntentDescription(
        "Deixa d'escoltar, corregeix l'última frase i en retorna tot el text.",
        categoryName: "Transcripció en directe",
        searchKeywords: ["subtítols", "transcriure"]
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await ShortcutHost.shared.stopListening())
    }
}

// MARK: - The text

struct GetTranscriptTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Obté el text de la transcripció"
    static let description = IntentDescription(
        "El text que mostra duna: el que està escoltant, l'última transcripció o els subtítols d'un vídeo acabat. Quan l'app es tanca, el text no es guarda.",
        categoryName: "Text",
        searchKeywords: ["text", "transcripció", "copia"]
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let session = try await ShortcutHost.shared.shownTranscript().session
        return .result(value: TranscriptExport.plainText(session).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct SaveTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Desa la transcripció en un fitxer"
    static let description = IntentDescription(
        "La transcripció que mostra duna, com a text, Markdown o subtítols .srt.",
        categoryName: "Text",
        searchKeywords: ["exporta", "fitxer", "srt", "markdown"]
    )

    @Parameter(title: "Format", default: .text)
    var format: TranscriptFormatOption

    static var parameterSummary: some ParameterSummary {
        Summary("Desa la transcripció com a \(\.$format)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let url = try await ShortcutHost.shared.exportShownTranscript(as: TranscriptExportFormat(format))
        return .result(value: IntentFile(transcript: url, format: TranscriptExportFormat(format)))
    }
}

// MARK: - Language

struct SetLanguageIntent: AppIntent {
    static let title: LocalizedStringResource = "Canvia l'idioma"
    static let description = IntentDescription(
        "Posa l'idioma que duna escolta. Només es pot triar entre els idiomes instal·lats.",
        categoryName: "Idioma",
        searchKeywords: ["idioma", "llengua"]
    )

    @Parameter(title: "Idioma")
    var language: SpeechLanguageEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Canvia l'idioma a \(\.$language)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try ShortcutHost.shared.selectLanguage(id: language.id)
        return .result()
    }
}

// MARK: - Videos

/// Shortcuts gives every action 30 seconds, progress or not ("timed out after 30.00
/// seconds" in its log), and a video takes minutes: so this one opens the app on the
/// video and returns once the work has begun, as a video chosen in the app does. The
/// card shows the progress, and once finished the subtitles are sent from it, or taken
/// by "Desa la transcripció en un fitxer".
struct TranscribeFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Crea subtítols d'un vídeo o àudio"
    static let description = IntentDescription(
        "Obre duna i hi comença a fer els subtítols del fitxer, al mateix dispositiu. L'app en mostra el progrés; quan acaba, «Desa la transcripció en un fitxer» els dona com a fitxer.",
        categoryName: "Vídeos",
        searchKeywords: ["vídeo", "àudio", "srt", "subtítols", "transcriu"]
    )
    /// A video is read on the device's graphics chip, which is the app's only on screen.
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Vídeo o àudio", supportedContentTypes: [.movie, .audio])
    var file: IntentFile

    @Parameter(title: "Idioma", description: "Si no en tries cap, fa servir l'idioma que hi ha posat a l'app.")
    var language: SpeechLanguageEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Crea subtítols de \(\.$file) en \(\.$language)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // The 30 seconds count from here, copy included.
        let deadline = Date.now + ShortcutHost.actionBudget
        // A film can be gigabytes: copied off the main thread, so the screen keeps moving.
        let file = file
        let copy = try await Task.detached(priority: .userInitiated) { try Self.copy(file) }.value
        try await ShortcutHost.shared.startTranscribing(file: copy, languageID: language?.id, until: deadline)
        return .result()
    }

    /// The job works on a copy of its own, removed with it, as for a video from Photos.
    private nonisolated static func copy(_ file: IntentFile) throws -> URL {
        let folder = try ImportCenter.makeCopyFolder()
        // Shortcuts often hands the name over without its extension ("Entrevista"), and
        // AVFoundation cannot open a file whose type it cannot tell from its name.
        var name = file.filename.isEmpty ? localized("Vídeo") : file.filename
        if (name as NSString).pathExtension.isEmpty {
            let fileExtension = file.fileURL.map(\.pathExtension).flatMap { $0.isEmpty ? nil : $0 }
                ?? file.type?.preferredFilenameExtension
                ?? "mov"
            name += ".\(fileExtension)"
        }
        let copy = folder.appendingPathComponent(name)
        do {
            if let source = file.fileURL {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                try FileManager.default.copyItem(at: source, to: copy)
            } else {
                try file.data.write(to: copy)
            }
        } catch {
            ImportCenter.removeCopy(copy)
            throw ShortcutError.unreadableFile
        }
        return copy
    }
}
