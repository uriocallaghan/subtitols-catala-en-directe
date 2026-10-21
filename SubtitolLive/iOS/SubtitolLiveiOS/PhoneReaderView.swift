import PhotosUI
import SubtitolCore
import SwiftUI
import UniformTypeIdentifiers

/// Sizes of the "Versió final" design (402 × 874 pt), scaled to the phone in hand.
enum PhoneMetrics {
    /// The orb band under the status bar: 282 pt on the design's 874 pt phone.
    static let orbBandRatio: CGFloat = 282 / 874
    static let orbBandRange: ClosedRange<CGFloat> = 200...320
    /// Reading margins: the design's 12 above, and 16 at the sides.
    static let readingTopPadding: CGFloat = 12
    /// Half the design's 32 at the sides: on a phone the column is worth more than the air.
    static let readingSidePadding: CGFloat = 16
    /// Clear air between the last reading row and the top of the bar.
    static let readingGapAboveBar: CGFloat = 22
    static let barHeight: CGFloat = 56
    static let barBottomGap: CGFloat = 12

    static let defaultFontSize: CGFloat = 32
    static let minimumFontSize: CGFloat = 24
    static let maximumFontSize: CGFloat = 56
    static let fontSizeStep: CGFloat = 4

    static func clampedFontSize(_ size: CGFloat) -> CGFloat {
        min(maximumFontSize, max(minimumFontSize, size))
    }

    /// The largest the reading text is ever drawn, whatever the two settings multiply to.
    static let largestReadingSize: CGFloat = 96

    /// How much the phone's own text size (Settings › Accessibility › Larger Text) enlarges
    /// the reading text. The reader's size from the bar is kept and multiplied, so the
    /// default phone size changes nothing, and the largest sizes double it. Smaller phone
    /// sizes do not shrink it: the bar's own size is the one that makes text smaller.
    static func readingScale(for typeSize: DynamicTypeSize) -> CGFloat {
        switch typeSize {
        case .xSmall, .small, .medium, .large: 1
        case .xLarge: 1.1
        case .xxLarge: 1.2
        case .xxxLarge: 1.35
        case .accessibility1: 1.6
        case .accessibility2: 1.8
        default: 2
        }
    }

    static func readingSize(_ chosen: CGFloat, typeSize: DynamicTypeSize) -> CGFloat {
        min(largestReadingSize, chosen * readingScale(for: typeSize))
    }

    /// Height of the orb band for the whole screen `proxy` sits in. The first-run screen
    /// and the reading screen share it, so the orb stays put between them.
    /// The orb's radius as a share of its band's height: the shader draws it at
    /// 0.73 × size (0.86) of half the band.
    static let orbRadiusRatio: CGFloat = 0.73 * 0.86 / 2
    /// Clear air between the bottom of the orb and the top of the reading pane.
    static let readingGapBelowOrb: CGFloat = 6

    /// Where the reading pane starts, measured from the bottom of the orb band. The orb
    /// is a circle centred in its band, so the band's lower corners are empty: the pane
    /// reaches up into them, to just under the orb, and its fade starts there.
    static func readingTop(orbHeight: CGFloat) -> CGFloat {
        guard orbHeight > 0 else { return readingTopPadding }
        let emptyBelowOrb = orbHeight * (0.5 - orbRadiusRatio)
        return readingGapBelowOrb - emptyBelowOrb
    }

    static func orbHeight(in proxy: GeometryProxy) -> CGFloat {
        let screen = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
        return min(orbBandRange.upperBound, max(orbBandRange.lowerBound, screen * orbBandRatio))
    }
}

/// Automatic follows the phone; the reader can pin either theme.
enum PhoneTheme: String, CaseIterable {
    case automatic
    case light
    case dark

    var title: String {
        switch self {
        case .automatic: localized("Auto")
        case .light: localized("Clar")
        case .dark: localized("Fosc")
        }
    }

    var symbol: String {
        switch self {
        case .automatic: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
}

/// The reading screen: the voice orb on top, the rising transcript below it, the
/// settings bar floating at the bottom.
struct PhoneReaderView: View {
    @ObservedObject var controller: SubtitleController
    @EnvironmentObject private var packs: LanguagePackStore
    @EnvironmentObject private var imports: ImportCenter
    @ObservedObject private var shortcuts = ShortcutHost.shared
    @ObservedObject private var library = TranscriptLibrary.shared

    @AppStorage("phone.fontSize") private var fontSize = Double(PhoneMetrics.defaultFontSize)
    @AppStorage("phone.theme") private var theme: PhoneTheme = .automatic
    @AppStorage("phone.ageGradient") private var prefersAgeGradient = true
    @AppStorage("phone.showsOrb") private var showsOrb = true
    @AppStorage("reading.typeface") private var typeface: ReadingTypeface = .default
    /// The two top glyphs on Liquid Glass (trial of 2026-10-20; `-phone.glassGlyphs NO`
    /// shows them bare, as before).
    @AppStorage("phone.glassGlyphs") private var glassGlyphs = true

    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The interface language: its change re-renders the words below.
    @Environment(\.locale) private var locale

    @State private var themeDarkness: Double?
    @State private var expandedItem: PhoneBarItem?
    @State private var sheet: PhoneSheet?
    @AppStorage("export.format") private var exportFormat: TranscriptExportFormat = .text
    @State private var exportHeight: CGFloat = 560
    @State private var importHeight: CGFloat = 520
    @State private var choosesFromPhotos = false
    /// What waits on the reader's answer to leaving a video with corrections not exported.
    @State private var discardThen: (() -> Void)?
    @State private var choosesFromFiles = false
    @State private var photo: PhotosPickerItem?
    /// The orb follows the voices of the video being transcribed, when there is one.
    @State private var orbSource = OrbLevelSource()
    /// The session on screen, kept in the folder the moment listening stopped. While it
    /// is set the bar offers Descarta, Exporta and Desa.
    @State private var keptID: UUID?
    /// A new reading pane each time the text on screen is put away, so the old one can
    /// leave by its own way (`departure`) while the prompt fades in.
    @State private var paneGeneration = 0
    @State private var departure: PaneDeparture = .fade
    /// The words put away, held on screen while they leave (the controller has already
    /// let them go, and may be listening again).
    @State private var leavingWords: LeavingWords?
    /// How far the words have gone on their way out (`PaneLeaving`).
    @State private var leaveProgress: CGFloat = 0
    /// Transcriptions that have landed in the folder, for its bounce.
    @State private var arrivals = 0
    @Environment(\.scenePhase) private var scenePhase

    private static let themeMotion = Animation.easeInOut(duration: 0.35)
    private static let orbMotion = Animation.spring(response: 0.55, dampingFraction: 0.9)

    private var isDark: Bool {
        switch theme {
        case .automatic: systemScheme == .dark
        case .light: false
        case .dark: true
        }
    }

    /// Someone who asked the phone for more contrast is not asking for a fade.
    private var showsAgeGradient: Bool { prefersAgeGradient && contrast != .increased }

    var body: some View {
        sessionHandling(
            ThemeBlend(darkness: themeDarkness ?? (isDark ? 1 : 0)) { darkness in
                screen(darkness: darkness)
            }
        )
        .onChange(of: isDark, initial: true) { _, dark in
            let target: Double = dark ? 1 : 0
            guard themeDarkness != nil else {
                themeDarkness = target
                return
            }
            withAnimation(Self.themeMotion) { themeDarkness = target }
        }
        #if DEBUG
        // `-autoRecord YES` starts listening once the model is ready, in the session of
        // the language `-autoInstall` chose (switching language builds a new one).
        .task(id: ObjectIdentifier(controller)) {
            guard UserDefaults.standard.bool(forKey: "autoRecord") else { return }
            if let wanted = UserDefaults.standard.string(forKey: "autoInstall"), controller.rules.id != wanted { return }
            while !controller.canToggle { try? await Task.sleep(for: .milliseconds(200)) }
            controller.toggleRecording()
            // `-autoStop S` stops after S seconds of listening, to show what follows a stop.
            let stopAfter = UserDefaults.standard.double(forKey: "autoStop")
            guard stopAfter > 0 else { return }
            try? await Task.sleep(for: .seconds(stopAfter))
            if controller.isRecording { controller.toggleRecording() }
        }
        .task {
            // Screenshot runs: `-openPanel display`, `-autoRecord YES`.
            if let raw = UserDefaults.standard.string(forKey: "openPanel") {
                try? await Task.sleep(for: .milliseconds(600))
                withAnimation(PhoneSettingsBar.motion) { expandedItem = PhoneBarItem(debugName: raw) }
            }
            if let raw = UserDefaults.standard.string(forKey: "openSheet"), raw != PhoneSheet.export.rawValue {
                try? await Task.sleep(for: .milliseconds(600))
                sheet = PhoneSheet(rawValue: raw)
            }
            if UserDefaults.standard.string(forKey: "openSheet") == PhoneSheet.export.rawValue {
                // Export needs text: waits for a session with some words (`-autoRecord YES`).
                while controller.session.wordCount < 12 { try? await Task.sleep(for: .milliseconds(300)) }
                sheet = .export
            }
        }
        #endif
        .onChange(of: controller.isRecording || imports.current?.isWorking == true, initial: true) { _, busy in
            // The screen stays on while listening, like a video, and while a video is
            // being transcribed, which pauses when the phone locks.
            UIApplication.shared.isIdleTimerDisabled = busy
        }
        .onChange(of: imports.current?.id, initial: true) { _, _ in orbSource.level = imports.current?.level }
        // One speech model at a time on the phone: the live one steps aside while a
        // video is transcribed, and comes back when it is done or put away.
        .onChange(of: imports.current?.isWorking == true, initial: true) { _, working in
            if working { controller.suspendForVideo() } else { controller.resumeAfterVideo() }
        }
        // A shortcut starting to listen clears the screen, as a tap on it would.
        .onChange(of: shortcuts.clearRequests) { _, _ in
            close()
            sheet = nil
        }
        // A video arriving (from here, Files, the share menu or a shortcut) opens its card.
        .onChange(of: imports.arrivals) { _, _ in
            if imports.current != nil { open(.importVideo) }
        }
        // A video's subtitles, once done, open straight in the editor to review them.
        .onChange(of: imports.current?.phase) { _, phase in
            guard phase == .finished, let job = imports.current, !job.session.isEmpty, imports.editor == nil else { return }
            openEditor()
        }
        .onChange(of: sheet) { _, sheet in
            if sheet == nil { imports.showsPanel = false }
            // A card closed before anything was done is a change of mind: the video goes.
            if sheet == nil, imports.current?.phase == .choosing {
                withAnimation(.easeInOut(duration: 0.45)) { imports.dismiss() }
            }
        }
        .photosPicker(isPresented: $choosesFromPhotos, selection: $photo, matching: .videos, preferredItemEncoding: .current)
        // A video arriving (Photos, Files, Open in, the share menu) over corrections not
        // exported waits for the same question.
        .onChange(of: imports.pendingArrival?.id) { _, id in
            guard id != nil else { return }
            discardThen = { withAnimation(.easeInOut(duration: 0.45)) { imports.openPendingArrival() } }
        }
        .alert(
            localized("Vols deixar aquest vídeo?"),
            isPresented: Binding(get: { discardThen != nil }, set: { if !$0 { discardThen = nil } })
        ) {
            Button(localized("Cancel·la"), role: .cancel) {
                discardThen = nil
                imports.dropPendingArrival()
            }
            Button(localized("Deixa'l"), role: .destructive) {
                let next = discardThen
                discardThen = nil
                next?()
            }
        } message: {
            Text(localized("Les correccions dels subtítols que no has exportat es perdran."))
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await importFromPhotos(item) }
        }
        .fileImporter(isPresented: $choosesFromFiles, allowedContentTypes: ImportCenter.contentTypes) { result in
            guard case .success(let url) = result else { return }
            imports.open(url, languageID: packs.selectedLanguageID)
        }
        .preferredColorScheme(theme == .automatic ? nil : (theme == .dark ? .dark : .light))
        // A large sheet, not a full screen: the status bar keeps its own strip above the
        // card, and a swipe down puts the editor away like any other card.
        .sheet(item: Binding(get: { imports.editor }, set: { if $0 == nil { imports.closeEditor() } })) { editor in
            editorScreen(editor)
                .presentationDetents([.large])
                .presentationCornerRadius(28)
                .presentationBackground(ReadingTheme.resolved(isDark: isDark).paper)
                .presentationDragIndicator(.hidden)
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .languages:
                // Opaque: through the glass the transcript behind read as a second text.
                LanguageSetupView(mode: .manage)
                    .presentationDetents([.large])
                    .presentationCornerRadius(28)
                    .presentationBackground(ReadingTheme.resolved(isDark: isDark).paper)
            case .microphone:
                // Half height: the text keeps running above while choosing.
                MicrophoneView(controller: controller)
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(28)
                    .presentationBackground(ReadingTheme.resolved(isDark: isDark).paper)
            case .vocabulary:
                // Half height too: the keyboard takes the rest, and the text runs on above.
                VocabularyView(controller: controller, isDark: isDark)
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(28)
                    .presentationBackground(ReadingTheme.resolved(isDark: isDark).paper)
            case .about:
                AboutView()
                    .presentationDetents([.large])
                    .presentationCornerRadius(28)
            case .export:
                exportSheet
            case .importVideo:
                importSheet
            case .library:
                TranscriptLibraryView(library: library, isDark: isDark)
                    .presentationDetents([.large])
                    .presentationCornerRadius(28)
                    .presentationBackground(ReadingTheme.resolved(isDark: isDark).paper)
                    .preferredColorScheme(theme == .automatic ? nil : (theme == .dark ? .dark : .light))
            }
        }
    }

    /// What follows a stop: keeping the session, the question before discarding it, and
    /// writing the folder's last edits when the app leaves the screen.
    private func sessionHandling(_ content: some View) -> some View {
        content
            .onChange(of: controller.state) { old, new in
                sessionStateChanged(from: old, to: new)
            }
            // A new language is a new controller, with nothing on screen.
            .onChange(of: ObjectIdentifier(controller)) { _, _ in
                keptID = nil
                departure = .fade
            }
            // The session on screen, deleted from the folder, has nothing left to keep.
            .onChange(of: library.listings.map(\.id)) { _, ids in
                guard let keptID, !ids.contains(keptID) else { return }
                withAnimation(PhoneSettingsBar.motion) { self.keptID = nil }
                departure = .fade
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { library.flush() }
            }
            .sensoryFeedback(.success, trigger: arrivals)
    }

    private func screen(darkness: Double) -> some View {
        let readingTheme = ReadingTheme.blended(darkness: darkness)
        return GeometryReader { proxy in
            let orbHeight = showsOrb ? PhoneMetrics.orbHeight(in: proxy) : 0
            let barClearance = PhoneMetrics.barHeight + PhoneMetrics.barBottomGap + PhoneMetrics.readingGapAboveBar
            ZStack(alignment: .bottom) {
                readingTheme.paper.ignoresSafeArea()

                VStack(spacing: 0) {
                    orbBand(height: orbHeight, theme: readingTheme)
                    readingPane(theme: readingTheme, lift: orbHeight + PhoneMetrics.readingTop(orbHeight: orbHeight))
                    .padding(.top, PhoneMetrics.readingTop(orbHeight: orbHeight))
                    .padding(.horizontal, PhoneMetrics.readingSidePadding)
                    .padding(.bottom, barClearance)
                }
                // The whole screen starts and stops, as on the Mac; a drag on the text
                // scrolls it instead.
                .contentShape(Rectangle())
                .onTapGesture { surfaceTapped() }

                PhoneSettingsBar(
                    controller: controller,
                    expanded: $expandedItem,
                    fontSize: $fontSize,
                    typeface: $typeface,
                    theme: $theme,
                    prefersAgeGradient: $prefersAgeGradient,
                    showsOrb: Binding(
                        get: { showsOrb },
                        set: { value in withAnimation(Self.orbMotion) { showsOrb = value } }
                    ),
                    languageName: packs.selectedLanguage?.name ?? "—",
                    languageIsBeta: packs.selectedLanguage?.stage == .beta,
                    themeDarkness: darkness,
                    maxWidth: proxy.size.width - 32,
                    onLanguages: { open(.languages) },
                    onMicrophone: { open(.microphone) },
                    onVocabulary: { open(.vocabulary) },
                    onAbout: { open(.about) },
                    sessionActions: showsSessionActions
                        ? SessionActions(
                            consideringDiscard: { considering in
                                // The text leaves by the way it will take, set before it goes.
                                departure = considering ? .discard : .save
                            },
                            discard: discardKept,
                            export: { open(.export) },
                            save: { putAway(.save) }
                        )
                        : nil
                )
                .padding(.bottom, PhoneMetrics.barBottomGap)
            }
            // Top left, clear of the orb: the gallery glyph that makes a video's subtitles.
            .overlay(alignment: .topLeading) {
                importGlyph(ink: readingTheme.ink)
                    .modifier(GlassGlyph(isOn: glassGlyphs))
                    .padding(.leading, 18)
                    .padding(.top, 12)
            }
            // Top right: the folder of kept transcriptions, where Desa sends the text.
            .overlay(alignment: .topTrailing) {
                LibraryButton(ink: readingTheme.ink, size: 18, arrivals: arrivals, restingOpacity: glyphOpacity) { open(.library) }
                    .modifier(GlassGlyph(isOn: glassGlyphs))
                    .padding(.trailing, 18)
                    .padding(.top, 12)
            }
        }
    }

    /// The sheet fits its panel exactly. At the largest text sizes the panel can be taller
    /// than the phone, so it opens full height and scrolls.
    @ViewBuilder
    private var exportSheet: some View {
        let palette = SettingsBarPalette.resolved(isDark: isDark)
        if typeSize.isAccessibilitySize {
            ScrollView { exportPanel(palette: palette) }
                .scrollBounceBehavior(.basedOnSize)
                .presentationDetents([.large])
                .presentationCornerRadius(28)
                .presentationBackground(palette.surface)
        } else {
            exportPanel(palette: palette)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { exportHeight = $0 }
                .frame(maxHeight: .infinity, alignment: .top)
                .presentationDetents([.height(exportHeight)])
                .presentationCornerRadius(28)
                .presentationBackground(palette.surface)
        }
    }

    private func exportPanel(palette: SettingsBarPalette) -> some View {
        let session = exportedSession
        return ExportPanel(
            session: session,
            palette: palette,
            typeface: typeface,
            storedFormat: $exportFormat,
            actions: [
                ExportAction(title: localized("Notes"), symbol: "note.text") { _ in
                    ShareSheet.present(items: [TranscriptExport.note(session)])
                },
                ExportAction(title: localized("Envia"), symbol: "square.and.arrow.up", isPrimary: true) { format in
                    if let job = imports.current, job.phase == .finished,
                       let url = try? job.write(format) {
                        ShareSheet.present(items: [url])
                    } else {
                        ShareSheet.presentFile(for: session, format: format)
                    }
                },
            ],
            footnote: localized("Amb AirDrop, el fitxer arriba a la carpeta Baixades del Mac."),
            render: { format in
                if let job = imports.current, job.phase == .finished { return job.rendered(format) }
                return TranscriptExport.render(session, as: format)
            },
            drawsCard: false,
            onClose: { sheet = nil }
        )
    }

    @ViewBuilder
    private func orbBand(height: CGFloat, theme: ReadingTheme) -> some View {
        ZStack {
            if showsOrb {
                SedaOrbView(
                    voiceLevel: { [weak c = controller, orbSource] in orbSource.current() ?? c?.voiceLevel() ?? 0 },
                    isListening: controller.isRecording || imports.current?.isWorking == true,
                    background: theme.paper
                )
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel(controller.isRecording ? localized("Atura la transcripció") : localized("Comença a transcriure"))
        .accessibilityInputLabels(controller.isRecording ? [localized("Atura"), localized("Orbe")] : [localized("Comença"), localized("Orbe")])
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { surfaceTapped() }
        .accessibilityHidden(!showsOrb)
    }

    /// With a setting open, the first tap only closes it, as on the Mac. Over a video's
    /// text, a tap shows its card while it is being transcribed, and afterwards gives the
    /// screen back to listening.
    /// Gives the screen back to listening; a video whose corrections have not left the
    /// app asks first, since they would be lost.
    private func dismissVideo() {
        let leave = { withAnimation(.easeInOut(duration: 0.45)) { imports.dismiss() } }
        if imports.hasUnexportedEdits() { discardThen = leave } else { leave() }
    }

    private func surfaceTapped() {
        if expandedItem != nil {
            close()
            return
        }
        if let job = imports.current {
            if job.isWorking {
                open(.importVideo)
            } else {
                dismissVideo()
            }
            return
        }
        // A tap with a stopped session on screen starts the next one: the last one goes
        // to the folder, where it was already kept.
        if keptID != nil, controller.state == .ready {
            putAway(.save, thenListen: true)
            return
        }
        guard controller.canToggle else { return }
        controller.toggleRecording()
    }

    // MARK: - After a stop

    /// The bar's Descarta · Exporta · Desa, while a stopped session is on screen.
    private var showsSessionActions: Bool {
        keptID != nil && controller.state == .ready && imports.current == nil
    }

    /// A session that stops with words is kept at once, so nothing is lost whatever the
    /// reader taps next; the bar then offers what to do with it.
    private func sessionStateChanged(from old: SubtitleController.State, to new: SubtitleController.State) {
        if new == .requestingPermission || new == .recording, keptID != nil {
            withAnimation(PhoneSettingsBar.motion) { keptID = nil }
            departure = .fade
        }
        guard old == .transcribing, new != .transcribing, imports.current == nil,
              !controller.session.isEmpty else { return }
        let id = library.keep(controller.session, languageID: controller.rules.id)
        guard new == .ready else { return }
        close()
        departure = .save
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : PhoneSettingsBar.motion) { keptID = id }
    }

    /// The text on screen leaves (for the folder, or dissolving when discarded), the
    /// prompt fades in where it was, and the bar gives its settings back.
    private func putAway(_ kind: PaneDeparture, thenListen: Bool = false) {
        guard keptID != nil else { return }
        departure = kind
        // The pane keeps showing the words while it leaves; once they have gone, a new
        // pane fades in with the prompt (or with the next session, already listening).
        leavingWords = LeavingWords(
            committedWords: controller.committedWords,
            provisionalWords: controller.provisionalWords
        )
        controller.clearTranscript()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.22) : PhoneSettingsBar.motion) { keptID = nil }
        let paneMotion: Animation = reduceMotion
            ? .easeInOut(duration: 0.3)
            : (kind == .discard ? .easeIn(duration: 0.36) : .spring(response: 0.6, dampingFraction: 0.94))
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
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 120 : 360))
                arrivals += 1
            }
        }
        if thenListen { controller.toggleRecording() }
    }

    private func discardKept() {
        guard let keptID else { return }
        putAway(.discard)
        library.remove(keptID)
    }

    // MARK: - Video import

    /// What the export sheet sends: the video's text once it is done, else the session.
    private var exportedSession: SessionTranscript {
        if let job = imports.current, job.phase == .finished { return job.session }
        return controller.session
    }


    @ViewBuilder
    private func readingPane(theme: ReadingTheme, lift: CGFloat) -> some View {
        let size = PhoneMetrics.readingSize(CGFloat(fontSize), typeSize: typeSize)
        ZStack {
            if let job = imports.current, job.phase != .choosing {
                JobTranscript(job: job) { job in
                    FixedFocusTranscriptView(
                        committedWords: job.transcript.committedWords,
                        provisionalWords: job.transcript.provisionalWords,
                        fallbackText: importFallback(job),
                        fontSize: size,
                        typeface: typeface,
                        theme: theme,
                        isLive: job.isWorking,
                        ageGradient: showsAgeGradient,
                        fade: .phone,
                        scrollsBack: true,
                        speechLanguage: job.languageID
                    )
                }
                .id("\(job.id)-\(job.revision)")
                .transition(.opacity)
            } else {
                FixedFocusTranscriptView(
                    committedWords: leavingWords?.committedWords ?? controller.committedWords,
                    provisionalWords: leavingWords?.provisionalWords ?? controller.provisionalWords,
                    fallbackText: leavingWords == nil ? fallbackText : "",
                    fontSize: size,
                    typeface: typeface,
                    theme: theme,
                    isLive: leavingWords == nil && controller.isRecording,
                    ageGradient: showsAgeGradient,
                    fade: .phone,
                    scrollsBack: true,
                    speechLanguage: controller.rules.id
                )
                .modifier(PaneLeaving(departure: reduceMotion ? .fade : departure, towards: CGSize(width: -26, height: -lift), progress: leaveProgress))
                .modifier(ArrivingPane(delay: paneGeneration == 0 ? nil : 0.04))
                .id(paneGeneration)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: imports.current?.id)
        .animation(.easeInOut(duration: 0.45), value: imports.current?.phase == .choosing)
    }

    private func importFallback(_ job: MediaImport) -> String {
        switch job.phase {
        case .choosing, .preparing: localized("Preparant el so…")
        case .transcribing: job.isPaused ? localized("Continua quan tornis a l'app.") : localized("Escoltant el vídeo…")
        case .finished: localized("Aquest vídeo no té veus.")
        case .failed(let message): message
        }
    }

    /// With no video yet, a menu of where to take one from; with one, its card.
    @ViewBuilder
    private func importGlyph(ink: Color) -> some View {
        if let job = imports.current {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !job.isWorking || job.isPaused)) { context in
                ImportButton(
                    ink: ink,
                    size: 18,
                    progress: job.isWorking ? (job.phase == .preparing ? 0 : job.displayedFraction(at: context.date)) : nil,
                    isFinished: job.phase == .finished,
                    restingOpacity: glyphOpacity
                ) { open(.importVideo) }
            }
        } else {
            Menu {
                Button { choosesFromPhotos = true } label: {
                    Label(localized("Fototeca"), systemImage: "photo.on.rectangle")
                }
                Button { choosesFromFiles = true } label: {
                    Label(localized("Fitxers"), systemImage: "folder")
                }
            } label: {
                ImportGlyphLabel(ink: ink, size: 18, restingOpacity: glyphOpacity)
            }
            .disabled(controller.isRecording || controller.state == .transcribing)
            .accessibilityLabel(localized("Subtítols d'un vídeo"))
            .accessibilityHint(localized("Tria un vídeo i en fa els subtítols en aquest dispositiu"))
        }
    }

    /// On glass the glyphs take the system's own strength; bare, they stay a quiet grey.
    private var glyphOpacity: Double { glassGlyphs ? 0.8 : 0.34 }

    /// Photos hands over a copy, which the job removes when it is done with it.
    private func importFromPhotos(_ item: PhotosPickerItem) async {
        guard let movie = try? await item.loadTransferable(type: ImportedMovie.self) else { return }
        imports.open(movie.url, ownsSource: true, languageID: packs.selectedLanguageID)
    }

    /// Fits its card, like the export sheet.
    @ViewBuilder
    private var importSheet: some View {
        let palette = SettingsBarPalette.resolved(isDark: isDark)
        if let job = imports.current {
            let panel = ImportPanel(
                job: job,
                packs: packs,
                palette: palette,
                finishedActions: [],
                shareIsPrimary: true,
                drawsCard: false,
                onReview: openEditor,
                onAnotherVideo: {
                    sheet = nil
                    let another = {
                        withAnimation(.easeInOut(duration: 0.45)) { imports.dismiss() }
                        Task {
                            try? await Task.sleep(for: .milliseconds(450))
                            choosesFromPhotos = true
                        }
                    }
                    if imports.hasUnexportedEdits() { discardThen = another } else { another() }
                },
                onClose: { sheet = nil }
            )
            .onAppear { imports.showsPanel = true }
            if typeSize.isAccessibilitySize {
                ScrollView { panel }
                    .scrollBounceBehavior(.basedOnSize)
                    .presentationDetents([.large])
                    .presentationCornerRadius(28)
                    .presentationBackground(palette.surface)
            } else {
                panel
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        withAnimation(ImportPanel.motion) { importHeight = height }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .presentationDetents([.height(importHeight)])
                    .presentationCornerRadius(28)
                    .presentationBackground(palette.surface)
                    // The text arriving above stays bright, not dimmed behind the card.
                    .presentationBackgroundInteraction(.enabled)
            }
        }
    }

    // MARK: - Subtitle editor

    /// The card steps down first; the editor rises once it has gone.
    private func openEditor() {
        sheet = nil
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            imports.openEditor()
        }
    }

    private func editorScreen(_ editor: SubtitleEditorModel) -> some View {
        let palette = SettingsBarPalette.resolved(isDark: isDark)
        let session = editor.job.session
        return SubtitleEditorView(
            model: editor,
            theme: ReadingTheme.resolved(isDark: isDark),
            palette: palette,
            typeface: typeface,
            isCompact: true,
            textActions: [
                ExportAction(title: localized("Notes"), symbol: "note.text") { _ in
                    ShareSheet.present(items: [TranscriptExport.note(editor.job.session)]) { editor.job.markExported() }
                },
                ExportAction(title: localized("Envia"), symbol: "square.and.arrow.up", isPrimary: true) { format in
                    if let url = try? editor.job.write(format) {
                        ShareSheet.present(items: [url]) { editor.job.markExported() }
                    } else {
                        ShareSheet.presentFile(for: session, format: format)
                    }
                },
            ],
            exportFormat: $exportFormat,
            onClose: { imports.closeEditor() }
        )
        .preferredColorScheme(theme == .automatic ? nil : (theme == .dark ? .dark : .light))
    }

    private var fallbackText: String {
        controller.state == .failed ? controller.detail : controller.displayText
    }

    private func open(_ destination: PhoneSheet) {
        close()
        sheet = destination
    }

    private func close() {
        guard expandedItem != nil else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : PhoneSettingsBar.motion) {
            expandedItem = nil
        }
    }
}

enum PhoneSheet: String, Identifiable {
    case languages
    case microphone
    case vocabulary
    case about
    case export
    case importVideo
    case library

    var id: String { rawValue }
}

/// A top glyph on a disc of Liquid Glass that answers the finger, as the system's own
/// bar buttons do.
private struct GlassGlyph: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
        }
    }
}

/// A film from the photo library, copied where the app can read it.
struct ImportedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = try ImportCenter.makeCopyFolder().appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return ImportedMovie(url: copy)
        }
    }
}

/// Follows a video's text as it is revealed, word by word.
private struct JobTranscript<Content: View>: View {
    @ObservedObject var job: MediaImport
    let content: (MediaImport) -> Content

    var body: some View { content(job) }
}

/// Where the orb reads the video's loudness from, when a video is being transcribed.
final class OrbLevelSource: @unchecked Sendable {
    var level: MediaImportLevel?

    func current() -> Float? { level?.current() }
}

#if DEBUG
extension PhoneBarItem {
    init?(debugName: String) {
        switch debugName {
        case "profile": self = .profile
        case "size": self = .size
        case "typeface": self = .typeface
        case "display": self = .display
        default: return nil
        }
    }
}
#endif

/// The system share sheet, over whatever is on screen (the export sheet included).
/// AirDrop leads its first row, and Notes is among the apps.
@MainActor
enum ShareSheet {
    /// `shared` runs once the reader has actually sent or saved something.
    static func present(items: [Any], shared: (() -> Void)? = nil) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            if completed { shared?() }
        }
        top.present(controller, animated: true)
    }

    /// Writes the session to a file named for its date, so it lands with that name.
    static func presentFile(for session: SessionTranscript, format: TranscriptExportFormat) {
        presentFile(
            named: TranscriptExport.filename(for: session, format: format),
            contents: TranscriptExport.render(session, as: format)
        )
    }

    /// Writes `contents` to a file called `name`, so it lands with that name.
    static func presentFile(named name: String, contents: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return
        }
        present(items: [url])
    }
}
