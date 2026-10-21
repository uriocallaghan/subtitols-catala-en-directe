import AppKit
import SubtitolCore
import SwiftUI
import UniformTypeIdentifiers

/// The recording surface stops below the title bar, leaving a full-width strip at the
/// top that belongs to the window: the traffic lights live there, and dragging it moves
/// the window. Without that gap the invisible button swallowed every drag and the window
/// could not be repositioned at all.
private struct RecordingSurfaceShape: Shape {
    let titleBarHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let top = min(titleBarHeight, rect.height)
        return Path(
            CGRect(x: 0, y: top, width: rect.width, height: max(0, rect.height - top))
        )
    }
}

struct ContentView: View {
    @ObservedObject var controller: SubtitleController
    @EnvironmentObject private var imports: ImportCenter
    @EnvironmentObject private var packs: LanguagePackStore
    @ObservedObject private var shortcuts = ShortcutHost.shared
    @ObservedObject private var library = TranscriptLibrary.shared

    @AppStorage("reading.fontSize") private var storedFontSize = Double(AppVisualMetrics.defaultFontSize)
    @AppStorage("reading.darkTheme") private var isDarkTheme = false
    @AppStorage("reading.ageGradient") private var prefersAgeGradient = false
    @AppStorage("reading.showsDecoration") private var showsDecoration = true
    @AppStorage("reading.typeface") private var typeface: ReadingTypeface = .default
    /// Set once the first run is over. Debug runs replay it with `-onboarding.done NO`.
    @AppStorage("onboarding.done") private var onboarded = false
    /// The first run's last level is cleared: the band boils for a moment.
    @State private var onboardingCelebrates = false

    /// 0 light, 1 dark. Follows `isDarkTheme` through `themeMotion`; every themed colour
    /// is read from here, so no surface ever snaps between themes.
    @State private var themeDarkness: Double?

    @State private var expandedBarItem: SettingsBarItem?
    @State private var showsExport = false
    /// The export card rises above the bar (Exporta after a stop) rather than under the
    /// top right glyphs (⌘ E).
    @State private var exportFromBar = false

    /// The session on screen, kept in the folder the moment listening stopped. While it
    /// is set the bar offers Descarta, Exporta and Desa.
    @State private var keptID: UUID?
    /// A new reading pane each time the text on screen is put away.
    @State private var paneGeneration = 0
    @State private var departure: PaneDeparture = .fade
    /// The words put away, held on screen while they leave (`PaneLeaving`).
    @State private var leavingWords: LeavingWords?
    @State private var leaveProgress: CGFloat = 0
    /// Transcriptions that have landed in the folder, for its bounce.
    @State private var arrivals = 0
    /// Where the folder glyph and the live text are in the window, for the text's flight.
    @State private var folderCenter: CGPoint?
    @State private var liveTextFrame: CGRect = .zero
    /// The kept transcriptions, over the whole window like the subtitle editor.
    @State private var showsLibrary = false
    @State private var librarySelection: UUID?
    /// Bumped by ⌘ E while the library is open: its page's card answers.
    @State private var libraryExportRequests = 0
    @AppStorage("export.format") private var exportFormat: TranscriptExportFormat = .text
    /// While recording, the bar steps aside once the pointer has rested for a moment, so
    /// nothing sits over the live text. Any pointer movement brings it straight back.
    @State private var barIsResting = false
    @State private var barIsHovered = false
    @State private var barRestTask: Task<Void, Never>?

    @State private var increasesContrast = NSWorkspace.shared
        .accessibilityDisplayShouldIncreaseContrast
    @State private var showsShortcutHelp = false
    @State private var helpDismissal: Task<Void, Never>?

    private let designSize = CGSize(width: 1_280, height: 832)
    private static let panelMotion = Animation.spring(response: 0.55, dampingFraction: 0.9)
    private static let themeMotion = Animation.easeInOut(duration: 0.2)
    private let transcriptWidthRatio = 870.0 / 1_280.0

    /// The system setting wins over the app's own presentation toggle. Someone who has
    /// asked macOS for more contrast is not asking this app for a fade.
    private var showsAgeGradient: Bool { prefersAgeGradient && !increasesContrast }

    var body: some View {
        ThemeBlend(darkness: themeDarkness ?? (isDarkTheme ? 1 : 0)) { darkness in
            themedBody(darkness: darkness)
        }
        .focusedSceneValue(\.windowCommands, windowCommands)
        .onChange(of: imports.pendingArrival?.id) { _, id in
            if id != nil { askAboutPendingArrival() }
        }
        .onChange(of: isDarkTheme, initial: true) { _, isDark in
            let target: Double = isDark ? 1 : 0
            guard themeDarkness != nil else {
                themeDarkness = target
                return
            }
            withAnimation(Self.themeMotion) { themeDarkness = target }
        }
    }

    private func themedBody(darkness: Double) -> some View {
        GeometryReader { proxy in
            let theme = ReadingTheme.blended(darkness: darkness)
            let scale = min(
                proxy.size.width / designSize.width,
                proxy.size.height / designSize.height
            )
            let transcriptWidth = showsDecoration || !onboarded
                ? proxy.size.width * transcriptWidthRatio
                : proxy.size.width
            let outerInset = max(
                AppVisualMetrics.minimumPanelInset,
                AppVisualMetrics.referencePanelInset * scale
            )

            ZStack {
                HStack(spacing: 0) {
                    ZStack {
                        if onboarded {
                            readingPane(theme: theme, height: proxy.size.height)
                                .transition(.opacity)
                        } else {
                            MacOnboardingView(
                                theme: theme,
                                palette: .blended(darkness: darkness),
                                celebrating: $onboardingCelebrates
                            ) {
                                withAnimation(.easeInOut(duration: 0.8)) { onboarded = true }
                            }
                            .transition(.opacity)
                        }
                    }
                        .frame(width: transcriptWidth)
                        // Only the panel slides; the text takes its new width at once.
                        .transaction(value: showsDecoration) { $0.disablesAnimations = true }

                    if showsDecoration || !onboarded {
                        DecorationField(controller: controller, job: imports.current, excited: onboardingCelebrates)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.move(edge: .trailing))
                    }
                }
                .background(theme.canvas)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Under the editor, VoiceOver reads only the editor.
                .accessibilityHidden(imports.editor != nil || showsLibrary)
                // The panel slides out past the right edge and back in, rather than
                // blinking; the clip keeps it from sliding over the window's inset.
                .clipped()
                .animation(Self.panelMotion, value: showsDecoration)

                Button {
                    // With a panel open, the first click outside only closes it.
                    if showsExport {
                        closeExport()
                    } else if imports.showsPanel {
                        closeImportPanel()
                    } else if let job = imports.current {
                        // A finished or unstarted video gives the pane back to listening;
                        // one being transcribed keeps it.
                        if !job.isWorking { dismissVideo() }
                    } else if expandedBarItem != nil {
                        withAnimation(SettingsBar.motion) { expandedBarItem = nil }
                    } else if controller.state == .needsLanguage {
                        withAnimation(SettingsBar.motion) { expandedBarItem = .language }
                    } else if keptID != nil, controller.state == .ready {
                        // The stopped session goes to the folder, where it was already
                        // kept, and the next one starts.
                        putAway(.save, thenListen: true)
                    } else {
                        controller.toggleRecording()
                    }
                } label: {
                    Color.clear
                        .contentShape(
                            RecordingSurfaceShape(titleBarHeight: max(38, 44 * scale))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!controller.canToggle && controller.state != .needsLanguage && imports.current == nil && !imports.showsPanel)
                .accessibilityLabel(
                    controller.canToggle ? controller.buttonTitle : controller.detail
                )
                .accessibilityHint(
                    controller.canToggle
                        ? localized("Activa o atura la transcripció en directe")
                        : localized("La transcripció encara no està disponible")
                )
                // During the first run the pane belongs to the onboarding.
                .allowsHitTesting(onboarded)
                .accessibilityHidden(!onboarded || imports.editor != nil)

                Group {
                    // The cards (export, a video's) rise above the bars.
                    VStack(spacing: 12) {
                        if showsExport {
                            exportCard(palette: .blended(darkness: darkness))
                                .frame(width: 372)
                                .transition(barCardTransition)
                        }
                        if imports.showsPanel, let job = imports.current {
                            importCard(job, palette: .blended(darkness: darkness))
                                .frame(width: 372)
                                .transition(barCardTransition)
                        }
                        settingsBar(themeDarkness: darkness)
                    }
                    // The two bars, as one piece, centred on the window.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, max(14, 22 * scale))
                    .accessibilityHidden(imports.editor != nil || showsLibrary)
                    .animation(.spring(response: 0.38, dampingFraction: 0.86), value: imports.showsPanel)
                    // Above the clicks that close a card, while one is open.
                    .zIndex(showsExport || imports.showsPanel ? 4 : 2)

                    exportLayer(theme: theme, darkness: darkness, transcriptWidth: transcriptWidth, scale: scale)
                        .accessibilityHidden(imports.editor != nil || showsLibrary)
                        .zIndex(3)

                    shortcutCommands

                    if let editor = imports.editor {
                        SubtitleEditorView(
                            model: editor,
                            theme: theme,
                            palette: .blended(darkness: darkness),
                            typeface: typeface,
                            textActions: [
                                ExportAction(title: localized("Copia"), symbol: "doc.on.doc", confirmation: localized("Copiat")) { format in
                                    copyExport(format)
                                },
                                ExportAction(title: localized("Desa…"), symbol: "arrow.down.doc", isPrimary: true) { format in
                                    saveExport(format)
                                },
                            ],
                            exportFormat: $exportFormat,
                            videoActions: { url in
                                [
                                    ExportAction(title: localized("Desa…"), symbol: "arrow.down.doc", isPrimary: true) { _ in
                                        saveVideo(url, job: editor.job)
                                    },
                                    ExportAction(title: localized("AirDrop"), symbol: "airplayaudio") { _ in
                                        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [url])
                                    },
                                ]
                            },
                            leadingInset: max(0, 78 - outerInset),
                            onClose: closeEditor
                        )
                        .transition(editorTransition)
                        .zIndex(5)
                    }

                    if showsLibrary {
                        MacTranscriptLibraryView(
                            library: library,
                            theme: theme,
                            palette: .blended(darkness: darkness),
                            leadingInset: max(0, 78 - outerInset),
                            selection: $librarySelection,
                            exportRequests: libraryExportRequests,
                            onClose: closeLibrary
                        )
                        .transition(editorTransition)
                        .zIndex(6)
                    }
                }
                // The bar waits for the first run to finish, then rises in.
                .opacity(onboarded ? 1 : 0)
                .offset(y: onboarded ? 0 : 24)
                .allowsHitTesting(onboarded)
                .accessibilityHidden(!onboarded)
                .animation(.spring(response: 0.7, dampingFraction: 0.9).delay(onboarded ? 0.35 : 0), value: onboarded)
                .animation(Self.panelMotion, value: imports.editor?.id)
                .animation(Self.panelMotion, value: showsLibrary)
            }
            .overlay(alignment: .top) { shortcutHelp(theme: theme) }
            .onContinuousHover { phase in
                if case .active = phase { notePointerActivity() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(.named(Self.windowSpace))
            .padding(outerInset)
            .textSelection(.disabled)
        }
        .background(ReadingTheme.blended(darkness: darkness).canvas)
        .ignoresSafeArea()
        .textSelection(.disabled)
        // Wide enough for the expanded settings bar and the side bar beside it.
        .frame(minWidth: 940, minHeight: 540)
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
            )
        ) { _ in
            increasesContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        }
        #if DEBUG
        // Test runs: `-autoRecord YES` starts listening once the model is ready (with
        // `SUBTITOL_REPLAY_AUDIO`, a recording plays through the capture path).
        .task(id: ObjectIdentifier(controller)) {
            guard UserDefaults.standard.bool(forKey: "autoRecord") else { return }
            while !controller.canToggle { try? await Task.sleep(for: .milliseconds(200)) }
            controller.toggleRecording()
            // `-autoStop S` stops after S seconds of listening, to show what follows a stop.
            let stopAfter = UserDefaults.standard.double(forKey: "autoStop")
            guard stopAfter > 0 else { return }
            try? await Task.sleep(for: .seconds(stopAfter))
            if controller.isRecording { controller.toggleRecording() }
        }
        .task {
            // `-openLibrary YES` opens the kept transcriptions after launch.
            guard UserDefaults.standard.bool(forKey: "openLibrary") else { return }
            try? await Task.sleep(for: .milliseconds(1_200))
            openLibrary()
        }
        #endif
        #if DEBUG
        // Test runs: `-importFile PATH` opens a video; with `-importLanguage xx` that
        // language is installed if needed and the transcription starts. `-clicks
        // "x,y@seconds;…"` clicks the window (points from its top left) at those times,
        // without taking the pointer or the focus.
        .task {
            let defaults = UserDefaults.standard
            if let path = defaults.string(forKey: "importFile") {
                try? await Task.sleep(for: .milliseconds(900))
                openVideo(URL(fileURLWithPath: path))
                // `-importResume YES` goes on from the corrections kept for the video.
                if defaults.bool(forKey: "importResume"), let job = imports.current {
                    for _ in 0..<50 where job.savedCorrections == nil { try? await Task.sleep(for: .milliseconds(100)) }
                    job.resume()
                } else if let id = defaults.string(forKey: "importLanguage"),
                   let language = packs.catalog.language(id: id), let job = imports.current {
                    try? await Task.sleep(for: .milliseconds(1_500))
                    if packs.state(of: language) != .installed { await packs.install(language) }
                    job.languageID = id
                    try? await Task.sleep(for: .milliseconds(700))
                    job.start(language: language, packs: packs)
                }
            }
        }
        .task {
            guard let script = UserDefaults.standard.string(forKey: "clicks") else { return }
            let started = Date()
            for step in script.split(separator: ";") {
                let parts = step.split(separator: "@")
                let point = parts.first?.split(separator: ",").compactMap { Double($0) } ?? []
                guard parts.count == 2, point.count == 2, let at = Double(parts[1]) else { continue }
                let wait = at - Date().timeIntervalSince(started)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { continue }
                let location = NSPoint(x: point[0], y: window.contentLayoutRect.height - point[1])
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                    ) {
                        window.sendEvent(event)
                    }
                    try? await Task.sleep(for: .milliseconds(60))
                }
            }
        }
        #endif
        // With no language on the Mac yet, the list of languages is the first thing shown,
        // unless a video's card is open: it lists the languages itself.
        .task(id: ObjectIdentifier(controller)) {
            guard onboarded, controller.state == .needsLanguage else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !imports.showsPanel else { return }
            withAnimation(SettingsBar.motion) { expandedBarItem = .language }
        }
        // A film dropped anywhere on the window is a video to transcribe.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: Self.isMedia) else { return false }
            openVideo(url)
            return true
        }
        // A shortcut starting to listen clears the pane, as a click on it would.
        .onChange(of: shortcuts.clearRequests) { _, _ in
            closeExport()
            withAnimation(SettingsBar.motion) { expandedBarItem = nil }
        }
        .onChange(of: imports.showsPanel) { _, shows in
            if shows {
                closeExport()
                withAnimation(SettingsBar.motion) { expandedBarItem = nil }
            }
        }
        // A video's subtitles, once done, open straight in the editor to review them.
        .onChange(of: imports.current?.phase) { _, phase in
            guard phase == .finished, let job = imports.current, !job.session.isEmpty else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                guard imports.current === job, job.phase == .finished, imports.editor == nil else { return }
                openEditor()
            }
        }
        .onChange(of: controller.isRecording) { _, isRecording in
            if isRecording {
                withAnimation(SettingsBar.motion) { expandedBarItem = nil }
                scheduleBarRest()
            } else {
                wakeBar()
            }
        }
        .modifier(SessionKeeping(
            controller: controller,
            library: library,
            keptID: $keptID,
            departure: $departure,
            onKept: {
                closeExport()
                withAnimation(SettingsBar.motion) { expandedBarItem = nil }
            }
        ))
    }

    // MARK: - Settings bar

    /// The settings bar and, 8 pt to its right, the bar of the video and the kept
    /// transcriptions: centred together, as one piece.
    private func settingsBar(themeDarkness: Double) -> some View {
        HStack(spacing: Self.sideBarGap) {
            SettingsBar(
                controller: controller,
                expanded: $expandedBarItem,
                fontSize: $storedFontSize,
                typeface: $typeface,
                isDarkTheme: $isDarkTheme,
                prefersAgeGradient: $prefersAgeGradient,
                showsDecoration: $showsDecoration,
                themeDarkness: themeDarkness,
                // A panel opened from the menus shows over the choices until it closes.
                sessionActions: showsSessionActions && expandedBarItem == nil
                    ? SessionActions(
                        consideringDiscard: { considering in
                            // The text leaves by the way it will take, set before it goes.
                            if keptID != nil { departure = considering ? .discard : .save }
                        },
                        discard: discardKept,
                        export: { showsExport ? closeExport() : openExport(fromBar: true) },
                        save: { putAway(.save) }
                    )
                    : nil
            )
            sideBar(palette: .blended(darkness: themeDarkness))
        }
        .onHover { barIsHovered = $0 }
        .opacity(barIsResting ? 0 : 1)
        .scaleEffect(barIsResting ? 0.94 : 1, anchor: .bottom)
        .offset(y: barIsResting ? 18 : 0)
        .blur(radius: barIsResting ? 10 : 0)
        .allowsHitTesting(!barIsResting)
        .accessibilityHidden(barIsResting)
    }

    private func notePointerActivity() {
        wakeBar()
        if controller.isRecording { scheduleBarRest() }
    }

    private func wakeBar() {
        barRestTask?.cancel()
        barRestTask = nil
        guard barIsResting else { return }
        withAnimation(.spring(response: 0.46, dampingFraction: 0.82)) { barIsResting = false }
    }

    private func scheduleBarRest() {
        barRestTask?.cancel()
        barRestTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled,
                  controller.isRecording,
                  expandedBarItem == nil,
                  !barIsHovered
            else { return }
            withAnimation(.easeInOut(duration: 0.7)) { barIsResting = true }
        }
    }

    /// The live transcript, or, once a video is being transcribed, the video's text. The
    /// two cross-fade: they are different texts, not one text changing.
    @ViewBuilder
    private func readingPane(theme: ReadingTheme, height: CGFloat) -> some View {
        ZStack {
            if let job = imports.current, job.phase != .choosing || job.session.wordCount > 0 {
                ImportedTranscript(job: job) { committed, provisional, fallback, isLive in
                    transcriptPane(
                        theme: theme,
                        height: height,
                        committed: committed,
                        provisional: provisional,
                        fallback: fallback,
                        isLive: isLive,
                        language: job.languageID
                    )
                }
                .id("\(job.id)-\(job.revision)")
                .transition(.opacity)
            } else {
                transcriptPane(
                    theme: theme,
                    height: height,
                    committed: leavingWords?.committedWords ?? controller.committedWords,
                    provisional: leavingWords?.provisionalWords ?? controller.provisionalWords,
                    fallback: leavingWords == nil ? controller.displayText : "",
                    isLive: leavingWords == nil && controller.isRecording,
                    language: controller.rules.id,
                    leaves: true
                )
                .modifier(ArrivingPane(delay: paneGeneration == 0 ? nil : 0.04))
                .id(paneGeneration)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: imports.current?.id)
    }

    private func transcriptPane(
        theme: ReadingTheme,
        height: CGFloat,
        committed: [StableTranscriptWord],
        provisional: [StableTranscriptWord],
        fallback: String,
        isLive: Bool,
        language: String?,
        leaves: Bool = false
    ) -> some View {
        let verticalInset = max(72, 147 * min(1, height / designSize.height))
        let sideInset = max(42, 70 * min(1, height / designSize.height))
        let resolvedFontSize = fontSize(paneHeight: height - verticalInset * 2)
        let bottomInset = AppVisualMetrics.transcriptBottomInset(
            baseInset: verticalInset,
            fontSize: resolvedFontSize
        )
        return FixedFocusTranscriptView(
            committedWords: committed,
            provisionalWords: provisional,
            fallbackText: fallback,
            fontSize: resolvedFontSize,
            typeface: typeface,
            theme: theme,
            isLive: isLive,
            ageGradient: showsAgeGradient,
            speechLanguage: language
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        // Kept, the text shrinks about the pane's top right corner into the folder glyph
        // above it; discarded, it dissolves where it stands.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.windowSpace)) } action: { frame in
            if leaves { liveTextFrame = frame }
        }
        // Kept, the text shrinks about its lower right corner into the folder glyph in the
        // bar beside the main one.
        .modifier(PaneLeaving(
            departure: leaves && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? departure : .fade,
            towards: flightToFolder,
            progress: leaves ? leaveProgress : 0,
            anchor: .bottomTrailing
        ))
        .padding(.horizontal, sideInset)
        .padding(.top, AppVisualMetrics.transcriptTopInset)
        .padding(.bottom, bottomInset)
        .background(theme.paper)
    }

    /// The reader's chosen size, held back only far enough that a readable block survives
    /// above the live strip. The bottom lines belong to text the recognizer can still
    /// rewrite, so the floor has to clear the reserve and leave lines to actually read.
    private func fontSize(paneHeight: CGFloat) -> CGFloat {
        let preferred = AppVisualMetrics.clampedFontSize(CGFloat(storedFontSize))
        guard paneHeight > 0 else { return preferred }
        let minimumRows = CGFloat(RollUpTranscriptLayout.baseReserve + 3)
        let ceiling = paneHeight / (minimumRows * AppVisualMetrics.lineHeightRatio)
        return max(AppVisualMetrics.minimumFontSize, min(preferred, ceiling))
    }

    // MARK: - Export

    /// The share glyph sits in the title-bar strip, level with the traffic lights, at the
    /// reading pane's top right, with the gallery glyph that imports a video just before
    /// it; each card opens under its glyph and grows out of it.
    @ViewBuilder
    private func exportLayer(theme: ReadingTheme, darkness: Double, transcriptWidth: CGFloat, scale: CGFloat) -> some View {
        let palette = SettingsBarPalette.blended(darkness: darkness)
        ZStack(alignment: .topLeading) {
            if showsExport || imports.showsPanel {
                // Clicks outside the card close it rather than starting a recording.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { showsExport ? closeExport() : closeImportPanel() }
                    .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Side bar

    private static let sideBarGap: CGFloat = 8

    /// The bar's twin, a few points to its right: the video glyph (with the job's
    /// progress) and the folder of kept transcriptions, each in a well like the bar's.
    private func sideBar(palette: SettingsBarPalette) -> some View {
        HStack(spacing: 5) {
            ImportGlyph(center: imports, ink: palette.ink, size: 12.5, side: 32, restingOpacity: 0.62) {
                toggleImportPanel()
            }
            .padding(3)
            .background(Circle().fill(palette.well))
            .accessibilityLabel(localized("Subtítols d'un vídeo"))
            LibraryButton(ink: palette.ink, size: 12.5, arrivals: arrivals, restingOpacity: 0.62, side: 32) { openLibrary() }
                .padding(3)
                .background(Circle().fill(palette.well))
                .onGeometryChange(for: CGPoint.self) { proxy in
                    let frame = proxy.frame(in: .named(Self.windowSpace))
                    return CGPoint(x: frame.midX, y: frame.midY)
                } action: { folderCenter = $0 }
        }
        .padding(5)
        .background {
            Capsule(style: .continuous)
                .fill(palette.surface)
                .overlay(Capsule(style: .continuous).strokeBorder(palette.hairline))
                .shadow(color: palette.shadow, radius: 18, y: 8)
                .shadow(color: palette.shadow.opacity(0.5), radius: 2, y: 1)
        }
        // Gaps between wells belong to the bar, not to the recording surface beneath.
        .contentShape(Capsule(style: .continuous))
        .onTapGesture { }
        .fixedSize()
    }

    static let windowSpace = "duna.window"

    /// A video's card: language, progress, then its subtitles.
    private func importCard(_ job: MediaImport, palette: SettingsBarPalette) -> some View {
        ImportPanel(
            job: job,
            packs: packs,
            palette: palette,
            finishedActions: [
                ExportAction(title: localized("AirDrop"), symbol: "airplayaudio", isPrimary: true) { _ in
                    sendByAirDrop(job)
                },
                ExportAction(title: localized("Desa…"), symbol: "arrow.down.doc") { _ in
                    saveSubtitles(job)
                },
            ],
            onReview: openEditor,
            onAnotherVideo: chooseVideo,
            onClose: closeImportPanel
        )
    }

    /// Choose a format, see the file, copy it or save it.
    private func exportCard(palette: SettingsBarPalette) -> some View {
        ExportPanel(
            session: exportedSession,
            palette: palette,
            typeface: typeface,
            storedFormat: $exportFormat,
            actions: [
                ExportAction(title: localized("Copia"), symbol: "doc.on.doc", confirmation: localized("Copiat")) { format in
                    copyExport(format)
                },
                ExportAction(title: localized("Desa…"), symbol: "arrow.down.doc", isPrimary: true) { format in
                    saveExport(format)
                },
            ],
            render: exportedText,
            onClose: closeExport
        )
    }

    private var barCardTransition: AnyTransition {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.9, anchor: .bottom))
                .combined(with: .offset(y: 8)),
            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom))
        )
    }

    /// What the export card sends: the video's text once it is done, else the session.
    private var exportedSession: SessionTranscript {
        if let job = imports.current, job.phase == .finished { return job.session }
        return controller.session
    }

    // MARK: - Video import

    static func isMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return ImportCenter.contentTypes.contains { type.conforms(to: $0) }
    }

    private func toggleImportPanel() {
        if imports.current == nil {
            chooseVideo()
        } else if imports.showsPanel {
            closeImportPanel()
        } else {
            closeExport()
            withAnimation(SettingsBar.motion) { expandedBarItem = nil }
            imports.showsPanel = true
        }
    }

    private func closeImportPanel() {
        guard let job = imports.current else { return }
        // A card closed before anything was done is a change of mind: the video goes.
        if job.phase == .choosing {
            withAnimation(Self.panelMotion) { imports.dismiss() }
        } else {
            imports.showsPanel = false
        }
    }

    /// The system's file picker, for films and recordings.
    private func chooseVideo() {
        guard imports.current?.isWorking != true else { return }
        if imports.hasUnexportedEdits() {
            dismissVideo { chooseVideo() }
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImportCenter.contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = localized("Tria un vídeo o un àudio per fer-ne els subtítols")
        panel.prompt = localized("Tria")
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            openVideo(url)
        }
    }

    private func openVideo(_ url: URL) {
        guard !controller.isRecording, controller.state != .transcribing else { return }
        closeExport()
        withAnimation(SettingsBar.motion) { expandedBarItem = nil }
        imports.open(url, languageID: packs.selectedLanguageID)
    }

    private func sendByAirDrop(_ job: MediaImport) {
        guard let url = job.subtitlesURL, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        service.perform(withItems: [url])
    }

    /// Beside the video by default, named after it.
    private func saveSubtitles(_ job: MediaImport) {
        let subtitles = job.rendered(.subtitles)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MediaImport.filename(job.title, format: .subtitles)
        panel.allowedContentTypes = [TranscriptExportFormat.subtitles.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        // Beside the video, unless the video is the job's own temporary copy (Photos, a
        // shortcut): that folder goes at the next launch.
        if !job.deletesSourceWhenDone { panel.directoryURL = job.source.deletingLastPathComponent() }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try subtitles.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    // MARK: - Subtitle editor

    private func openEditor() {
        closeExport()
        withAnimation(SettingsBar.motion) { expandedBarItem = nil }
        withAnimation(Self.panelMotion) { imports.openEditor() }
    }

    private func closeEditor() {
        withAnimation(Self.panelMotion) { imports.closeEditor() }
    }

    /// The burnt-in copy, beside the video by default.
    private func saveVideo(_ file: URL, job: MediaImport) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.lastPathComponent
        panel.allowedContentTypes = [file.pathExtension.lowercased() == "mp4" ? .mpeg4Movie : .quickTimeMovie]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if !job.deletesSourceWhenDone { panel.directoryURL = job.source.deletingLastPathComponent() }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try FileManager.default.copyItem(at: file, to: url)
                job.markExported()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    private var editorTransition: AnyTransition {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.98)),
            removal: .opacity.combined(with: .scale(scale: 0.99))
        )
    }

    private var exportTransition: AnyTransition {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.86, anchor: .topTrailing))
                .combined(with: .offset(y: -8)),
            removal: .opacity
                .combined(with: .scale(scale: 0.94, anchor: .topTrailing))
        )
    }

    private func openExport() {
        openExport(fromBar: true)
    }

    private func openExport(fromBar: Bool) {
        // Over the editor or the library, their own card answers.
        if let editor = imports.editor {
            editor.requestExport()
            return
        }
        if showsLibrary {
            libraryExportRequests += 1
            return
        }
        guard !exportedSession.isEmpty else { return }
        withAnimation(SettingsBar.motion) { expandedBarItem = nil }
        closeImportPanel()
        if showsExport { closeExport() }
        exportFromBar = fromBar
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { showsExport = true }
    }

    private func closeExport() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { showsExport = false }
    }

    private func copyExport(_ format: TranscriptExportFormat) {
        if showsLibrary {
            guard let id = librarySelection, let transcript = library.transcript(id) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(transcript.render(format), forType: .string)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(exportedText(format), forType: .string)
        imports.current?.markExported()
    }

    /// The text the export card sends: a finished video's own (its `.srt` grouped like
    /// its captions), else the session's.
    private func exportedText(_ format: TranscriptExportFormat) -> String {
        if let job = imports.current, job.phase == .finished { return job.rendered(format) }
        return TranscriptExport.render(controller.session, as: format)
    }

    private func saveExport(_ format: TranscriptExportFormat) {
        if showsLibrary {
            guard let id = librarySelection, let transcript = library.transcript(id) else { return }
            MacTranscriptLibraryView.save(transcript, as: format, text: transcript.render(format))
            return
        }
        let session = exportedSession
        let text = exportedText(format)
        let panel = NSSavePanel()
        if let job = imports.current, job.phase == .finished {
            panel.nameFieldStringValue = MediaImport.filename(job.title, format: format)
        } else {
            panel.nameFieldStringValue = TranscriptExport.filename(for: session, format: format)
        }
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                imports.current?.markExported()
                closeExport()
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    // MARK: - Keyboard

    private var shortcutCommands: some View {
        ZStack {
            // While the vocabulary card is open a space belongs to the term being typed.
            Button(localized("Comença o atura")) { toggleRecordingFromKeyboard() }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!controller.canToggle || imports.current?.isWorking == true || imports.editor != nil
                          || expandedBarItem == .vocabulary || showsLibrary)
            if showsLibrary {
                // The library answers Esc itself.
            } else if showsExport {
                Button(localized("Tanca l'exportació")) { closeExport() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
            } else if expandedBarItem != nil {
                Button(localized("Tanca el panell")) {
                    withAnimation(SettingsBar.motion) { expandedBarItem = nil }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            // The menu bar answers the other shortcuts (`SubtitolCommands`); ⌘ = is the
            // unshifted ⌘ + that keyboards type.
            command(localized("Augmenta la mida del text"), key: "=") { adjustFontSize(by: 1) }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }

    /// The window's actions, for the menu bar.
    private var windowCommands: WindowCommands {
        let videoIsWorking = imports.current?.isWorking == true
        return WindowCommands(
            isReady: onboarded,
            canToggleRecording: onboarded && controller.canToggle && !videoIsWorking && imports.editor == nil,
            toggleRecording: toggleRecordingFromKeyboard,
            hasText: onboarded && (showsLibrary ? librarySelection != nil : !exportedSession.isEmpty),
            openExport: openExport,
            save: saveExport,
            copy: copyExport,
            canImportVideo: onboarded && !videoIsWorking && !controller.isRecording
                && controller.state != .transcribing,
            chooseVideo: chooseVideo,
            canReviewSubtitles: onboarded && imports.current?.phase == .finished && imports.current?.session.isEmpty == false,
            reviewSubtitles: openEditor,
            editor: imports.editor,
            editsText: showsLibrary,
            canOpenLibrary: onboarded && imports.editor == nil,
            openLibrary: { showsLibrary ? closeLibrary() : openLibrary() },
            openPanel: openBarPanel,
            showShortcuts: revealShortcutHelp
        )
    }

    /// Opens a panel of the settings bar, bringing the bar back if it had stepped aside.
    private func openBarPanel(_ item: SettingsBarItem) {
        guard onboarded else { return }
        closeExport()
        closeImportPanel()
        wakeBar()
        withAnimation(SettingsBar.motion) { expandedBarItem = item }
    }

    /// Space starts listening; over a video's text it first gives the pane back.
    private func toggleRecordingFromKeyboard() {
        if let job = imports.current, !job.isWorking {
            dismissVideo { controller.toggleRecording() }
            return
        }
        if keptID != nil, controller.state == .ready {
            putAway(.save, thenListen: true)
            return
        }
        controller.toggleRecording()
    }

    // MARK: - Kept transcriptions

    /// From the live text's lower right corner to the folder glyph.
    private var flightToFolder: CGSize {
        guard let folderCenter, liveTextFrame != .zero else { return CGSize(width: 0, height: 80) }
        return CGSize(width: folderCenter.x - liveTextFrame.maxX, height: folderCenter.y - liveTextFrame.maxY)
    }

    /// Descarta · Exporta · Desa, while a stopped session is on screen.
    private var showsSessionActions: Bool {
        keptID != nil && controller.state == .ready && imports.current == nil && onboarded
    }

    /// The text on screen leaves (for the folder, or dissolving when discarded); once it
    /// has gone a new pane fades in with the prompt, or with the next session.
    private func putAway(_ kind: PaneDeparture, thenListen: Bool = false) {
        guard keptID != nil else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        departure = kind
        closeExport()
        leavingWords = LeavingWords(
            committedWords: controller.committedWords,
            provisionalWords: controller.provisionalWords
        )
        controller.clearTranscript()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.22) : SettingsBar.motion) { keptID = nil }
        let paneMotion: Animation = reduceMotion
            ? .easeInOut(duration: 0.3)
            : (kind == .discard ? .easeIn(duration: 0.36) : .spring(response: 0.62, dampingFraction: 0.94))
        withAnimation(paneMotion) {
            leaveProgress = 1
        } completion: {
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) {
                leavingWords = nil
                leaveProgress = 0
                paneGeneration += 1
                if keptID == nil { departure = .fade }
            }
        }
        if kind == .save {
            // The folder answers as the text reaches it.
            Task {
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 120 : 380))
                arrivals += 1
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
        }
        if thenListen { controller.toggleRecording() }
    }

    private func discardKept() {
        guard let keptID else { return }
        putAway(.discard)
        library.remove(keptID)
    }

    private func openLibrary() {
        guard onboarded, imports.editor == nil else { return }
        closeExport()
        closeImportPanel()
        withAnimation(SettingsBar.motion) { expandedBarItem = nil }
        // The session just kept opens first, else the last one read.
        if let keptID { librarySelection = keptID }
        withAnimation(Self.panelMotion) { showsLibrary = true }
    }

    private func closeLibrary() {
        library.flush()
        NSApp.keyWindow?.makeFirstResponder(nil)
        withAnimation(Self.panelMotion) { showsLibrary = false }
    }

    /// Gives the pane back to listening; a video whose corrections have not left the app
    /// asks first, since they would be lost.
    /// A file arrived (dropped, Open With, the Dock, the Share menu) over a video whose
    /// corrections have not left the app: leave them, or keep them and let the file go.
    private func askAboutPendingArrival() {
        guard imports.pendingArrival != nil,
              let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
        let alert = NSAlert()
        alert.messageText = localized("Vols deixar aquest vídeo?")
        alert.informativeText = localized("Les correccions dels subtítols que no has exportat es perdran.")
        alert.addButton(withTitle: localized("Cancel·la"))
        alert.addButton(withTitle: localized("Deixa'l"))
        alert.buttons.last?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn {
                withAnimation(Self.panelMotion) { imports.openPendingArrival() }
            } else {
                imports.dropPendingArrival()
            }
        }
    }

    private func dismissVideo(then next: @escaping () -> Void = {}) {
        guard imports.hasUnexportedEdits(),
              let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else {
            withAnimation(Self.panelMotion) { imports.dismiss() }
            next()
            return
        }
        let alert = NSAlert()
        alert.messageText = localized("Vols deixar aquest vídeo?")
        alert.informativeText = localized("Les correccions dels subtítols que no has exportat es perdran.")
        alert.addButton(withTitle: localized("Cancel·la"))
        alert.addButton(withTitle: localized("Deixa'l"))
        alert.buttons.last?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            withAnimation(Self.panelMotion) { imports.dismiss() }
            next()
        }
    }

    private func command(
        _ label: String,
        key: Character,
        action: @escaping () -> Void
    ) -> some View {
        Button(label, action: action)
            .buttonStyle(.plain)
            .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
    }

    private func adjustFontSize(by steps: Int) {
        let next = CGFloat(storedFontSize) + AppVisualMetrics.fontSizeStep * CGFloat(steps)
        storedFontSize = Double(AppVisualMetrics.clampedFontSize(next))
    }

    private func revealShortcutHelp() {
        helpDismissal?.cancel()
        showsShortcutHelp = true
        helpDismissal = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            showsShortcutHelp = false
        }
    }

    /// Shown on demand rather than pinned to the window: the reading surface stays free
    /// of chrome, but the shortcuts are not invisible either.
    @ViewBuilder
    private func shortcutHelp(theme: ReadingTheme) -> some View {
        if showsShortcutHelp {
            VStack(alignment: .leading, spacing: 6) {
                shortcutRow(localized("Espai"), localized("Comença o atura"))
                shortcutRow("⌘ + / ⌘ −", localized("Mida del text"))
                shortcutRow("⌘ 0", localized("Restableix la mida"))
                shortcutRow("⌘ D", localized("Tema fosc"))
                shortcutRow("⌘ G", localized("Degradat per antiguitat"))
                shortcutRow("⌘ \\", localized("Panell decoratiu"))
                shortcutRow("⌘ E", localized("Exporta el text"))
                shortcutRow("⇧ ⌘ T", localized("Transcripcions"))
                shortcutRow("⌘ O", localized("Subtítols d'un vídeo"))
                shortcutRow("⌘ S", localized("Desa el text"))
                shortcutRow("⌘ C", localized("Copia el text"))
                shortcutRow("⌘ ,", localized("Ajustos"))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(theme.ink)
            .padding(16)
            .background(theme.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.ink.opacity(0.12))
            )
            .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
            .padding(.top, 52)
            .transition(.opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func shortcutRow(_ key: String, _ description: String) -> some View {
        HStack(spacing: 12) {
            Text(key)
                .frame(width: 78, alignment: .leading)
                .monospaced()
            Text(description)
        }
    }
}

/// The gallery glyph, following the job's progress.
private struct ImportGlyph: View {
    @ObservedObject var center: ImportCenter
    let ink: Color
    var size: CGFloat = 15
    var side: CGFloat = 44
    var restingOpacity = 0.34
    let action: () -> Void

    var body: some View {
        if let job = center.current {
            JobGlyph(job: job, ink: ink, size: size, side: side, restingOpacity: restingOpacity, action: action)
        } else {
            ImportButton(ink: ink, size: size, restingOpacity: restingOpacity, side: side, action: action)
        }
    }

    private struct JobGlyph: View {
        @ObservedObject var job: MediaImport
        let ink: Color
        let size: CGFloat
        let side: CGFloat
        let restingOpacity: Double
        let action: () -> Void

        var body: some View {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !job.isWorking || job.isPaused)) { context in
                ImportButton(
                    ink: ink,
                    size: size,
                    progress: job.isWorking ? (job.phase == .preparing ? 0 : job.displayedFraction(at: context.date)) : nil,
                    isFinished: job.phase == .finished,
                    restingOpacity: restingOpacity,
                    side: side,
                    action: action
                )
            }
        }
    }
}

/// Follows a video's transcription for the reading pane.
private struct ImportedTranscript<Content: View>: View {
    @ObservedObject var job: MediaImport
    let content: ([StableTranscriptWord], [StableTranscriptWord], String, Bool) -> Content

    var body: some View {
        content(
            job.transcript.committedWords,
            job.transcript.provisionalWords,
            fallback,
            job.isWorking
        )
    }

    private var fallback: String {
        switch job.phase {
        case .choosing, .preparing: localized("Preparant el so…")
        case .transcribing: localized("Escoltant el vídeo…")
        case .finished: localized("Aquest vídeo no té veus.")
        case .failed(let message): message
        }
    }
}

/// The decorative field: it moves with the microphone, or with the voices of the video
/// being transcribed. One field throughout, so it never restarts when its source changes.
private struct DecorationField: View {
    @ObservedObject var controller: SubtitleController
    let job: MediaImport?
    /// The first run's last level is cleared: the band boils as if someone spoke.
    var excited = false
    @State private var source = DecorationLevelSource()

    var body: some View {
        ProceduralShaderView(
            voiceLevel: { [source] in source.level() },
            discardPendingVoicePeak: { [source] in source.discardPendingVoicePeak() },
            isRecording: controller.isRecording || isWorking || excited
        )
        .onAppear { source.controller = controller; source.job = job?.level }
        .onChange(of: ObjectIdentifier(controller)) { _, _ in source.controller = controller }
        .onChange(of: job?.id) { _, _ in source.job = job?.level }
        .background { if let job { WorkWatcher(job: job, isWorking: $isWorking) } }
    }

    @State private var isWorking = false

    /// Mirrors the job's working state into the field without rebuilding it.
    private struct WorkWatcher: View {
        @ObservedObject var job: MediaImport
        @Binding var isWorking: Bool

        var body: some View {
            Color.clear
                .onChange(of: job.isWorking, initial: true) { _, working in isWorking = working }
                .onDisappear { isWorking = false }
        }
    }
}

@MainActor
private final class DecorationLevelSource {
    weak var controller: SubtitleController?
    var job: MediaImportLevel?

    func level() -> Float {
        if let job { return job.current() }
        return controller?.voiceLevel() ?? 0
    }

    func discardPendingVoicePeak() {
        if job == nil { controller?.discardPendingVoicePeak() }
    }
}

/// Keeps every live session that stops with words, the moment it stops, so nothing is
/// lost whatever the reader does next; the bar then offers what to do with it. Its own
/// modifier, so the window's long chain of handlers stays within the type checker.
private struct SessionKeeping: ViewModifier {
    @ObservedObject var controller: SubtitleController
    @ObservedObject var library: TranscriptLibrary
    @EnvironmentObject private var imports: ImportCenter
    @Binding var keptID: UUID?
    @Binding var departure: PaneDeparture
    let onKept: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: controller.state) { old, new in
                if new == .requestingPermission || new == .recording, keptID != nil {
                    withAnimation(SettingsBar.motion) { keptID = nil }
                    departure = .fade
                }
                guard old == .transcribing, new != .transcribing, imports.current == nil,
                      !controller.session.isEmpty else { return }
                let id = library.keep(controller.session, languageID: controller.rules.id)
                guard new == .ready else { return }
                onKept()
                departure = .save
                let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : SettingsBar.motion) { keptID = id }
            }
            // A new language is a new controller, with nothing on screen.
            .onChange(of: ObjectIdentifier(controller)) { _, _ in
                keptID = nil
                departure = .fade
            }
            // The session on screen, deleted from the library, has nothing left to keep.
            .onChange(of: library.listings.map(\.id)) { _, ids in
                guard let keptID, !ids.contains(keptID) else { return }
                withAnimation(SettingsBar.motion) { self.keptID = nil }
                departure = .fade
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                library.flush()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                library.flush()
            }
    }
}
