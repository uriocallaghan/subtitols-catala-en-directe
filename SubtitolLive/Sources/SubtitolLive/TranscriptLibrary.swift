import SubtitolCore
import SwiftUI

/// The transcriptions kept on the device, behind the folder glyph (iPhone and Mac).
///
/// Every session that stops with words is kept at once (`keep`), so nothing is lost
/// whatever the reader taps next; Desa then only puts it away, Descarta removes it.
/// Files are written off the main thread, edits a moment after the last keystroke.
@MainActor
final class TranscriptLibrary: ObservableObject {
    static let shared = TranscriptLibrary()

    /// Newest first.
    @Published private(set) var listings: [SavedTranscriptListing] = []
    @Published private(set) var isLoaded = false

    private let store: TranscriptStore
    private let queue = DispatchQueue(label: "com.uriocallaghan.duna.transcripts", qos: .utility)
    private var cache: [UUID: SavedTranscript] = [:]
    private var writes: [UUID: Task<Void, Never>] = [:]

    /// The shader's orange, for what lands in the folder.
    static let accent = Color(red: 1, green: 0.39, blue: 0)

    /// Application Support is the reader's own data, kept in the device's backups.
    nonisolated static var defaultRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        // Outside a sandbox, Application Support is shared by every app.
        return support.appendingPathComponent("Subtítol Live/Transcripts", isDirectory: true)
        #else
        return support.appendingPathComponent("Transcripts", isDirectory: true)
        #endif
    }

    init(store: TranscriptStore = TranscriptStore(root: TranscriptLibrary.defaultRoot)) {
        self.store = store
        queue.async { [store] in
            let loaded = store.listings()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Anything kept before the list had loaded joins it, and the index with it.
                let added = self.listings.filter { new in !loaded.contains { $0.id == new.id } }
                self.listings = TranscriptStore.sorted(loaded + added)
                self.isLoaded = true
                if !added.isEmpty { self.writeIndex() }
            }
        }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "seedTranscripts") { seedSamples() }
        #endif
    }

    func contains(_ id: UUID) -> Bool {
        listings.contains { $0.id == id }
    }

    /// Keeps a stopped session and returns its id.
    @discardableResult
    func keep(_ session: SessionTranscript, languageID: String?) -> UUID {
        let transcript = SavedTranscript(session: session, languageID: languageID)
        cache[transcript.id] = transcript
        listings.insert(transcript.listing, at: 0)
        write(transcript)
        return transcript.id
    }

    func transcript(_ id: UUID) -> SavedTranscript? {
        if let cached = cache[id] { return cached }
        let loaded = store.load(id)
        cache[id] = loaded
        return loaded
    }

    /// Takes a change at once into the list, and onto the device a moment after the last one.
    func update(_ transcript: SavedTranscript) {
        guard let index = listings.firstIndex(where: { $0.id == transcript.id }) else { return }
        var changed = transcript
        changed.modifiedAt = Date()
        cache[changed.id] = changed
        listings[index] = changed.listing
        writes[changed.id]?.cancel()
        writes[changed.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.write(changed)
        }
    }

    func remove(_ id: UUID) {
        writes[id]?.cancel()
        writes[id] = nil
        cache[id] = nil
        listings.removeAll { $0.id == id }
        let index = listings
        queue.async { [store] in store.remove(id, index: index) }
    }

    /// Writes every change still waiting (the app going to the background).
    func flush() {
        for (id, task) in writes {
            task.cancel()
            if let transcript = cache[id] { write(transcript) }
        }
        writes.removeAll()
    }

    private func write(_ transcript: SavedTranscript) {
        writes[transcript.id] = nil
        let index = listings
        queue.async { [store] in try? store.save(transcript, index: index) }
    }

    private func writeIndex() {
        let index = listings
        queue.async { [store] in try? store.writeIndex(index) }
    }

    #if DEBUG
    /// Screenshot runs: `-seedTranscripts YES` fills an empty library with sample text.
    private func seedSamples() {
        queue.async { [store] in
            guard store.listings().isEmpty else { return }
            let samples: [(String, String, String, TimeInterval)] = [
                ("Bon dia a tothom i benvinguts a la sessió d'avui.", "Classe d'història", "Avui parlarem de com es van construir les primeres ciutats de la Mediterrània, i de per què el comerç hi va tenir un paper tan important.", 0),
                ("La reunió comença amb el pressupost de l'any que ve.", "", "Hem revisat les xifres del primer trimestre i hi ha tres punts que caldrà decidir abans de divendres.", 2 * 3_600),
                ("Gràcies per venir.", "Assemblea del barri", "El primer punt de l'ordre del dia és la plaça: els veïns demanen més ombra i més bancs.", 26 * 3_600),
                ("Avui farem una recepta molt senzilla de coca de recapte.", "", "Necessitarem farina, aigua, oli, sal i llevat, i les verdures escalivades del dia abans.", 5 * 86_400),
                ("El riu baixava ple després de la pluja de la nit.", "Conte per dormir", "La Martina es va acostar a la vora i va veure una barca petita, pintada de taronja, que ningú no vigilava.", 40 * 86_400),
            ]
            var index: [SavedTranscriptListing] = []
            for (first, summary, rest, ago) in samples {
                let text = first + " " + rest
                var start: TimeInterval = 0
                let words = text.split(separator: " ").map { token -> SessionTranscript.Word in
                    defer { start += 0.42 }
                    return SessionTranscript.Word(text: String(token), start: start, end: start + 0.36)
                }
                let session = SessionTranscript(words: words, duration: start + 1, startedAt: Date().addingTimeInterval(-ago - 60))
                var saved = SavedTranscript(session: session, languageID: "ca")
                saved.summary = summary
                index.append(saved.listing)
                try? store.save(saved, index: index)
            }
            let loaded = store.listings()
            DispatchQueue.main.async { [weak self] in self?.listings = loaded }
        }
    }
    #endif
}

/// How the kept transcriptions are dated in the list and on their page.
enum TranscriptDates {
    struct Group {
        let title: String
        var items: [SavedTranscriptListing]
    }

    /// Today, yesterday, the week, the month, then by month, as Notes groups them.
    static func groups(_ listings: [SavedTranscriptListing], now: Date = Date()) -> [Group] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let monthFormatter = DateFormatter()
        monthFormatter.locale = InterfaceLanguage.locale
        monthFormatter.setLocalizedDateFormatFromTemplate("MMMMy")
        var groups: [Group] = []
        for listing in listings {
            let day = calendar.startOfDay(for: listing.createdAt)
            let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            let title: String
            switch days {
            case ..<1: title = localized("Avui")
            case 1: title = localized("Ahir")
            case 2..<7: title = localized("Aquesta setmana")
            case 7..<30: title = localized("Aquest mes")
            default:
                let month = monthFormatter.string(from: listing.createdAt)
                title = month.prefix(1).uppercased(with: InterfaceLanguage.locale) + month.dropFirst()
            }
            if groups.last?.title == title {
                groups[groups.count - 1].items.append(listing)
            } else {
                groups.append(Group(title: title, items: [listing]))
            }
        }
        return groups
    }

    /// The time today, the weekday this week, the date before.
    static func rowDate(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = InterfaceLanguage.locale
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: formatter.setLocalizedDateFormatFromTemplate("jmm")
        case 1..<7: formatter.setLocalizedDateFormatFromTemplate("EEEE")
        default: formatter.dateStyle = .short
        }
        return formatter.string(from: date)
    }

    /// "dilluns, 20 d'octubre de 2026 · 18:42"
    static func dateLine(_ date: Date) -> String {
        let day = DateFormatter()
        day.locale = InterfaceLanguage.locale
        day.setLocalizedDateFormatFromTemplate("EEEEdMMMMy")
        let time = DateFormatter()
        time.locale = InterfaceLanguage.locale
        time.setLocalizedDateFormatFromTemplate("jmm")
        return "\(day.string(from: date)) · \(time.string(from: date))"
    }
}

/// A transcription as it stood when the export opened, with each format made once: the
/// panel asks for its preview on every frame of its animations.
struct NoteExport: Identifiable {
    let transcript: SavedTranscript
    let session: SessionTranscript
    private let files: [TranscriptExportFormat: String]

    var id: UUID { transcript.id }

    init(transcript: SavedTranscript) {
        self.transcript = transcript
        session = transcript.session
        var files: [TranscriptExportFormat: String] = [:]
        for format in TranscriptExportFormat.allCases { files[format] = transcript.render(format) }
        self.files = files
    }

    func rendered(_ format: TranscriptExportFormat) -> String {
        files[format] ?? ""
    }
}

// MARK: - The folder glyph

/// The reading screen's top right: the kept transcriptions. When one arrives the folder
/// fills with the shader's orange for a moment and gives a small bounce.
struct LibraryButton: View {
    let ink: Color
    var size: CGFloat = 18
    /// Bumped each time a transcription lands in the folder.
    let arrivals: Int
    /// How strong the glyph is at rest (stronger on glass).
    var restingOpacity = 0.34
    /// The button's square side: 44 on its own, a knob inside a bar's well.
    var side: CGFloat = 44
    let action: () -> Void

    @State private var isLit = false
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: isLit ? "folder.fill" : "folder")
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(isLit ? TranscriptLibrary.accent : ink.opacity(isHovered ? max(0.62, restingOpacity) : restingOpacity))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce.up.byLayer, options: .nonRepeating, value: reduceMotion ? 0 : arrivals)
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { isHovered = hovering }
        }
        .onChange(of: arrivals) { _, _ in
            withAnimation(.easeOut(duration: 0.2)) { isLit = true }
            Task {
                try? await Task.sleep(for: .seconds(1.1))
                withAnimation(.easeInOut(duration: 0.6)) { isLit = false }
            }
        }
        .accessibilityShowsLargeContentViewer {
            Label(localized("Transcripcions"), systemImage: "folder")
        }
        .accessibilityLabel(localized("Transcripcions desades"))
        .accessibilityInputLabels([localized("Transcripcions"), localized("Carpeta"), localized("Desades")])
    }
}

/// The settings of a transcription's own bar (iPhone and Mac).
enum NoteBarItem: Hashable {
    case size
    case typeface

    var title: String {
        switch self {
        case .size: localized("Mida del text")
        case .typeface: localized("Tipografia")
        }
    }

    var closeTitle: String {
        switch self {
        case .size: localized("Tanca la mida del text")
        case .typeface: localized("Tanca la tipografia")
        }
    }
}

// MARK: - Putting the text on screen away

/// What the bar offers once listening has stopped: the session on screen was already
/// kept, so nothing is lost whatever the reader does next.
struct SessionActions {
    /// The question before discarding is showing (true) or was dismissed (false).
    let consideringDiscard: (Bool) -> Void
    /// Discarding was confirmed.
    let discard: () -> Void
    let export: () -> Void
    let save: () -> Void
}

enum SessionAction {
    case discard
    case export
    case save

    var title: String {
        switch self {
        case .discard: localized("Descarta")
        case .export: localized("Exporta")
        case .save: localized("Desa")
        }
    }

    var symbol: String {
        switch self {
        case .discard: "trash"
        case .export: "square.and.arrow.up"
        case .save: "checkmark"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .discard: localized("Descarta la transcripció")
        case .export: localized("Exporta el text")
        case .save: localized("Desa la transcripció")
        }
    }

    var spokenNames: [String] {
        switch self {
        case .discard: [localized("Descarta"), localized("Esborra"), accessibilityLabel]
        case .export: [localized("Exporta"), localized("Comparteix"), accessibilityLabel]
        case .save: [localized("Desa"), localized("Guarda"), accessibilityLabel]
        }
    }
}

enum PaneDeparture {
    case fade
    case save
    case discard
}

/// The words that were on screen when they were put away.
struct LeavingWords {
    let committedWords: [StableTranscriptWord]
    let provisionalWords: [StableTranscriptWord]
}

/// A new reading pane fades in after `delay`; the first one is simply there.
struct ArrivingPane: ViewModifier {
    let delay: Double?

    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .opacity(delay == nil || isShown ? 1 : 0)
            .onAppear {
                guard let delay else { return }
                withAnimation(.easeOut(duration: 0.4).delay(delay)) { isShown = true }
            }
    }
}

/// The reading pane on its way out. Kept, it shrinks about its top right corner into the
/// folder glyph (`towards` is how far that corner has to travel to reach it); discarded,
/// it sinks a little and blurs away where it stands.
struct PaneLeaving: ViewModifier {
    let departure: PaneDeparture
    let towards: CGSize
    let progress: CGFloat
    /// The corner the text shrinks about on its way to the folder.
    var anchor: UnitPoint = .topTrailing

    /// One chain of effects whatever the departure: switching between branches would
    /// make a new pane, which lays its text out again and shows nothing for a frame.
    func body(content: Content) -> some View {
        let save = departure == .save ? progress : 0
        let discard = departure == .discard ? progress : 0
        content
            .scaleEffect(1 - 0.92 * save - 0.04 * discard, anchor: departure == .save ? anchor : .center)
            .offset(x: towards.width * save, y: towards.height * save + 28 * discard)
            .opacity(departure == .save ? max(0, 1 - 1.5 * progress) : 1 - progress)
            .blur(radius: 3 * save + 12 * discard)
    }
}
