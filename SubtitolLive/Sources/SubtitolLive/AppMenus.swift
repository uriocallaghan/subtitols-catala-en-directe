#if os(macOS)
import AppKit
import SubtitolCore
import SwiftUI

/// What the menu bar can ask of the window in front: its cards, its export and its video
/// import live in `ContentView`'s state, so the window hands the menus these actions.
struct WindowCommands {
    /// The first run is over and the reading pane is the window's.
    var isReady: Bool
    var canToggleRecording: Bool
    var toggleRecording: () -> Void
    var hasText: Bool
    var openExport: () -> Void
    var save: (TranscriptExportFormat) -> Void
    var copy: (TranscriptExportFormat) -> Void
    var canImportVideo: Bool
    var chooseVideo: () -> Void
    var canReviewSubtitles: Bool
    var reviewSubtitles: () -> Void
    /// The subtitle editor, while it is open: Edit works on its text.
    var editor: SubtitleEditorModel?
    /// The kept transcriptions are open: Edit works on the text being written.
    var editsText: Bool
    var canOpenLibrary: Bool
    var openLibrary: () -> Void
    /// Opens one of the settings bar's panels, as clicking it would.
    var openPanel: (SettingsBarItem) -> Void
    var showShortcuts: () -> Void
}

private struct WindowCommandsKey: FocusedValueKey {
    typealias Value = WindowCommands
}

extension FocusedValues {
    var windowCommands: WindowCommands? {
        get { self[WindowCommandsKey.self] }
        set { self[WindowCommandsKey.self] = newValue }
    }
}

/// The menu bar: every setting of the bar and every action of the window, where a Mac
/// user looks for them, with the shortcuts the window already answers to.
///
/// The system's own menus and items (the application menu, Window, Full Screen) follow
/// the interface language through `InterfaceLanguageMenus`; the items here are the
/// app's own strings.
struct SubtitolCommands: Commands {
    let session: LanguageSession
    let imports: ImportCenter
    let inputs: AudioInputDeviceList

    @FocusedValue(\.windowCommands) private var window

    @AppStorage("reading.fontSize") private var fontSize = Double(AppVisualMetrics.defaultFontSize)
    @AppStorage("reading.darkTheme") private var isDarkTheme = false
    @AppStorage("reading.ageGradient") private var prefersAgeGradient = false
    @AppStorage("reading.showsDecoration") private var showsDecoration = true
    @AppStorage("reading.typeface") private var typeface: ReadingTypeface = .default
    /// Read so the menus are rebuilt in a newly chosen interface language.
    @AppStorage(InterfaceLanguage.defaultsKey) private var interfaceLanguage: String?

    /// Sends an editing action to the text being typed; false when no text has the focus.
    private static func sendToText(_ action: Selector) -> Bool {
        guard NSApp.keyWindow?.firstResponder is NSText else { return false }
        return NSApp.sendAction(action, to: nil, from: nil)
    }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(localized("Ajustos…")) { window?.openPanel(.display) }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(window?.isReady != true)
        }

        // Arxiu
        CommandGroup(replacing: .saveItem) {
            Button(localized("Subtítols d'un vídeo…")) { window?.chooseVideo() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(window?.canImportVideo != true)
            Button(localized("Revisa els subtítols")) { window?.reviewSubtitles() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(window?.canReviewSubtitles != true || window?.editor != nil)
            Button(window?.editsText == true ? localized("Tanca les transcripcions") : localized("Transcripcions")) {
                window?.openLibrary()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(window?.canOpenLibrary != true)
            Divider()
            Button(localized("Exporta el text…")) { window?.openExport() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(window?.hasText != true)
            Button(localized("Desa el text…")) { window?.save(.text) }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(window?.hasText != true)
            Button(localized("Desa els subtítols (.srt)…")) { window?.save(.subtitles) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(window?.hasText != true)
            Divider()
            // The group this replaces held Close as well.
            Button(localized("Tanca la finestra")) { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
        }
        CommandGroup(replacing: .printItem) { }

        // Edició: the text on screen cannot be selected, so copying takes all of it.
        CommandGroup(replacing: .undoRedo) {
            if window?.editsText == true, window?.editor == nil {
                Button(localized("Desfés")) { _ = Self.sendToText(Selector(("undo:"))) }
                    .keyboardShortcut("z", modifiers: .command)
                Button(localized("Refés")) { _ = Self.sendToText(Selector(("redo:"))) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            if let editor = window?.editor {
                // Typing in a line undoes the typing; otherwise a whole correction.
                Button(localized("Desfés")) {
                    if !Self.sendToText(Selector(("undo:"))) { editor.undo() }
                }
                .keyboardShortcut("z", modifiers: .command)
                Button(localized("Refés")) {
                    if !Self.sendToText(Selector(("redo:"))) { editor.redo() }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }
        CommandGroup(replacing: .pasteboard) {
            if window?.editor != nil || window?.editsText == true {
                Button(localized("Retalla")) { _ = Self.sendToText(#selector(NSText.cut(_:))) }
                    .keyboardShortcut("x", modifiers: .command)
                Button(localized("Copia")) {
                    if !Self.sendToText(#selector(NSText.copy(_:))) { window?.copy(.text) }
                }
                .keyboardShortcut("c", modifiers: .command)
                Button(localized("Enganxa")) { _ = Self.sendToText(#selector(NSText.paste(_:))) }
                    .keyboardShortcut("v", modifiers: .command)
                Button(localized("Selecciona-ho tot")) { _ = Self.sendToText(#selector(NSText.selectAll(_:))) }
                    .keyboardShortcut("a", modifiers: .command)
                Divider()
            }
            if window?.editor == nil, window?.editsText != true {
                Button(localized("Copia el text")) { window?.copy(.text) }
                    .keyboardShortcut("c", modifiers: .command)
                    .disabled(window?.hasText != true)
            }
            Button(localized("Copia com a Markdown")) { window?.copy(.markdown) }
                .disabled(window?.hasText != true)
            Button(localized("Copia com a subtítols (.srt)")) { window?.copy(.subtitles) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(window?.hasText != true)
        }
        CommandGroup(replacing: .textEditing) {
            if let editor = window?.editor {
                Button(localized("Cerca i substitueix…")) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { editor.showFind() }
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }

        // Visualització
        CommandGroup(before: .toolbar) {
            Button(localized("Augmenta la mida del text")) { stepFontSize(by: 1) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(fontSize >= Double(AppVisualMetrics.maximumFontSize))
            Button(localized("Redueix la mida del text")) { stepFontSize(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(fontSize <= Double(AppVisualMetrics.minimumFontSize))
            Button(localized("Mida original")) { fontSize = Double(AppVisualMetrics.defaultFontSize) }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(fontSize == Double(AppVisualMetrics.defaultFontSize))
            Picker(localized("Tipografia"), selection: $typeface) {
                ForEach(ReadingTypeface.allCases, id: \.self) { face in
                    Text(face.fullName).tag(face)
                }
            }
            Divider()
            Toggle(localized("Tema fosc"), isOn: $isDarkTheme)
                .keyboardShortcut("d", modifiers: .command)
            Toggle(localized("Degradat per antiguitat"), isOn: $prefersAgeGradient)
                .keyboardShortcut("g", modifiers: .command)
            Toggle(localized("Panell decoratiu"), isOn: $showsDecoration)
                .keyboardShortcut("\\", modifiers: .command)
            Divider()
            Picker(localized("Idioma de la interfície"), selection: interfaceLanguageSelection) {
                ForEach(InterfaceLanguage.all, id: \.id) { language in
                    Text(language.name).tag(language.id)
                }
            }
            Divider()
        }

        CommandMenu(localized("Transcripció")) {
            TranscriptionMenu(session: session, imports: imports, inputs: inputs, window: window)
        }

        CommandGroup(replacing: .help) {
            Button(localized("Dreceres de teclat")) { window?.showShortcuts() }
                .keyboardShortcut("/", modifiers: .command)
                .disabled(window?.isReady != true)
            Divider()
            Link(localized("Suport de duna"), destination: AppLinks.support)
            Link(localized("Política de privacitat"), destination: AppLinks.privacy)
            Link(localized("Condicions d'ús"), destination: AppLinks.terms)
        }
    }

    private var interfaceLanguageSelection: Binding<String> {
        Binding(
            get: { interfaceLanguage ?? InterfaceLanguage.current },
            set: { interfaceLanguage = $0 }
        )
    }

    private func stepFontSize(by steps: Int) {
        let next = CGFloat(fontSize) + AppVisualMetrics.fontSizeStep * CGFloat(steps)
        fontSize = Double(AppVisualMetrics.clampedFontSize(next))
    }
}

/// Listening, the language of the voice, the microphone and the reliability profile.
/// A view of its own so it follows the controller, which the session replaces when the
/// language changes.
private struct TranscriptionMenu: View {
    @ObservedObject var session: LanguageSession
    @ObservedObject var imports: ImportCenter
    @ObservedObject var inputs: AudioInputDeviceList
    let window: WindowCommands?

    var body: some View {
        ControllerItems(
            controller: session.controller,
            packs: session.packs,
            inputs: inputs,
            videoIsWorking: imports.current?.isWorking == true,
            window: window
        )
    }

    private struct ControllerItems: View {
        @ObservedObject var controller: SubtitleController
        @ObservedObject var packs: LanguagePackStore
        @ObservedObject var inputs: AudioInputDeviceList
        let videoIsWorking: Bool
        let window: WindowCommands?

        var body: some View {
            // Space starts and stops too; it stays off the menu so it never takes a
            // space typed in a file name.
            Button(controller.state == .failed ? localized("Torna-ho a provar") : controller.isRecording ? localized("Atura") : localized("Comença a escoltar")) {
                window?.toggleRecording()
            }
            .disabled(window?.canToggleRecording != true)

            Divider()

            Picker(localized("Idioma de la veu"), selection: languageSelection) {
                ForEach(packs.catalog.languages.filter { packs.state(of: $0) == .installed }) { language in
                    Text(language.stage == .beta ? localized("\(language.name), nou") : language.name)
                        .tag(Optional(language.id))
                }
            }
            .disabled(controller.isRecording || controller.state == .transcribing || videoIsWorking)
            Button(localized("Baixa més idiomes…")) { window?.openPanel(.language) }
                .disabled(window?.isReady != true)

            Divider()

            Picker(localized("Micròfon"), selection: inputSelection) {
                Text(localized("Automàtic")).tag(Optional<String>.none)
                ForEach(inputs.devices) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
                if let uid = controller.preferredInputUID, !inputs.devices.contains(where: { $0.uid == uid }) {
                    Text(localized("\(controller.preferredInputName ?? localized("Micròfon")) (desconnectat)"))
                        .tag(Optional(uid))
                }
            }
            Button(localized("Prova el micròfon…")) { window?.openPanel(.input) }
                .disabled(window?.isReady != true)

            Divider()

            Picker(localized("Fiabilitat"), selection: profileSelection) {
                ForEach(TranscriptionProfile.allCases, id: \.self) { profile in
                    Text(profile.displayName).tag(profile)
                }
            }
            .disabled(!controller.canSelectTranscriptionProfile)
        }

        private var languageSelection: Binding<String?> {
            Binding(
                get: { packs.selectedLanguageID },
                set: { id in
                    guard let language = id.flatMap(packs.catalog.language(id:)) else { return }
                    packs.select(language)
                }
            )
        }

        private var inputSelection: Binding<String?> {
            Binding(
                get: { controller.preferredInputUID },
                set: { uid in
                    let name = inputs.devices.first { $0.uid == uid }?.name
                    controller.selectInput(uid: uid, name: name)
                }
            )
        }

        private var profileSelection: Binding<TranscriptionProfile> {
            Binding(
                get: { controller.transcriptionProfile },
                set: { controller.selectTranscriptionProfile($0) }
            )
        }
    }
}

/// AppKit and SwiftUI name their own menus and items (Arxiu, Finestra, Amaga…) in the
/// app's preferred language, which is the system's unless the app has one of its own.
/// Giving the app the interface language keeps the whole menu bar in one language.
/// Basque and Galician have no system translation, so Spanish stands in for those items.
enum InterfaceLanguageMenus {
    static func apply(_ code: String? = UserDefaults.standard.string(forKey: InterfaceLanguage.defaultsKey)) {
        let defaults = UserDefaults.standard
        // Nothing on screen can be dictated into or take symbols.
        defaults.set(true, forKey: "NSDisabledDictationMenuItem")
        defaults.set(true, forKey: "NSDisabledCharacterPaletteMenuItem")
        guard let code, InterfaceLanguage.codes.contains(code) else { return }
        defaults.set(["eu", "gl"].contains(code) ? [code, "es"] : [code], forKey: "AppleLanguages")
    }
}
#endif
