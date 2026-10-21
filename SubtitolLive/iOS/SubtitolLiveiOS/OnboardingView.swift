import AVFoundation
import SubtitolCore
import SwiftUI

/// The first run, played as three small levels: the app's language, the language to
/// download, and the microphone. The typeface is not asked: Inter by default, changed
/// later from the bar.
///
/// Three dots along the top take the project's orange as each level is cleared, with a
/// tap of haptics. Granting the microphone clears the last one: confetti flies over the
/// orb and the reader opens. Every screen arrives slowly, piece by piece. The language
/// download starts on the second level and runs while the reader goes on (a pill under
/// the track shows it).
struct OnboardingView: View {
    typealias Step = OnboardingStep

    /// The recognition session, once a language is installed and chosen.
    let controller: SubtitleController?
    let onFinish: () -> Void

    @EnvironmentObject private var packs: LanguagePackStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("app.interfaceLanguage") private var interfaceLanguage = OnboardingCopy.deviceLanguage

    @State private var step: Step = .welcome
    @State private var cleared: Set<Step> = []
    @State private var speechLanguage: String?
    /// Until the reader picks a language to read, it follows the app's language.
    @State private var speechLanguagePicked = false
    @State private var microphone: Microphone = .unknown
    /// Which way the last move went, so screens slide the right way.
    @State private var forward = true
    /// The microphone is granted: the confetti is flying and the reader opens next.
    @State private var celebrating = false
    @State private var burst = 0
    /// Celebrated, but the language is still downloading: open the reader once it is ready.
    @State private var waitingForLanguage = false
    /// Set after a while of waiting, so a download that hangs never leaves the reader stuck.
    @State private var waitedLong = false
    /// The orb is on its way to where the reading screen keeps its own, and the rest has
    /// faded: the two screens then cross with the orbs on top of each other.
    @State private var handingOff = false
    /// Where the reading screen's orb band starts (the safe area's top) and how tall it is.
    @State private var screenTop: CGFloat = 0
    @State private var readerBand: CGFloat = 282
    /// The onboarding orb's own frame, on screen.
    @State private var orbFrame: CGRect = .zero
    private static let orbBand: CGFloat = 250

    enum Microphone { case unknown, granted, denied }

    /// Every word on screen, in the interface language.
    private var t: OnboardingCopy { .for(interfaceLanguage) }
    private var theme: ReadingTheme { scheme == .dark ? .dark : .light }
    private var palette: SettingsBarPalette { .resolved(isDark: scheme == .dark) }
    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: 0.62, dampingFraction: 0.88)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                theme.paper.ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar
                        .opacity(handingOff ? 0 : 1)
                    ZStack {
                        screen(for: step)
                            .id(step)
                            .transition(stepTransition)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .onAppear { measure(proxy) }
            .onChange(of: proxy.size) { _, _ in measure(proxy) }
        }
        .sensoryFeedback(.success, trigger: cleared.count)
        .onAppear(perform: prepare)
        #if DEBUG
        .task {
            // Screenshot runs: `-onboardingStep 0…2` opens that level directly.
            if let raw = UserDefaults.standard.object(forKey: "onboardingStep") as? Int ?? Int(UserDefaults.standard.string(forKey: "onboardingStep") ?? ""),
               let target = Step(rawValue: raw) {
                cleared = Set(Step.allCases.filter { $0 < target })
                step = target
            }
            // Recordings of the switch: `-interfaceLanguageTour YES` picks each interface
            // language in turn, as a tap on its chip would.
            if UserDefaults.standard.bool(forKey: "interfaceLanguageTour") {
                for item in Self.interfaceLanguages.dropFirst() + Self.interfaceLanguages.prefix(1) {
                    try? await Task.sleep(for: .seconds(2))
                    chooseInterfaceLanguage(item.id)
                }
            }
        }
        #endif
    }

    private func measure(_ proxy: GeometryProxy) {
        screenTop = proxy.frame(in: .global).minY
        readerBand = PhoneMetrics.orbHeight(in: proxy)
    }

    private func prepare() {
        if speechLanguage == nil {
            speechLanguage = packs.selectedLanguageID
                ?? packs.catalog.language(id: interfaceLanguage)?.id
                ?? packs.suggestedLanguage?.id
                ?? packs.catalog.languages.first?.id
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .denied, .restricted: microphone = .denied
        default: microphone = .unknown
        }
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let rise: CGFloat = forward ? 28 : -28
        return .asymmetric(
            insertion: .modifier(active: StepFade(offset: rise, blur: 8, opacity: 0), identity: StepFade(offset: 0, blur: 0, opacity: 1)),
            removal: .modifier(active: StepFade(offset: -rise * 0.6, blur: 8, opacity: 0), identity: StepFade(offset: 0, blur: 0, opacity: 1))
        )
    }

    private func advance(clearing current: Step) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { _ = cleared.insert(current) }
        guard let next = Step(rawValue: current.rawValue + 1) else { return }
        forward = true
        Task {
            // Let the node land its burst before the next level arrives.
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 150 : 420))
            withAnimation(motion) { step = next }
        }
    }

    private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        forward = false
        withAnimation(motion) { step = previous }
    }

    // MARK: Top

    private var topBar: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.ink.opacity(0.7))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .opacity(step == .welcome ? 0 : 1)
                .disabled(step == .welcome)
                .accessibilityShowsLargeContentViewer {
                    Label(t.back, systemImage: "chevron.left")
                }
                .accessibilityLabel(t.back)

                Spacer()
                OnboardingLevelTrack(current: step, cleared: cleared, palette: palette, label: t.step(step.rawValue + 1, Step.allCases.count))
                Spacer()

                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 10)

            downloadPill
                .frame(height: 30)
        }
        .padding(.top, 6)
        .animation(motion, value: step)
    }

    @ViewBuilder
    private var downloadPill: some View {
        if let id = speechLanguage, let language = packs.catalog.language(id: id), step > .language {
            OnboardingDownloadPill(language: language, state: packs.state(of: language), copy: t, palette: palette)
        }
    }

    // MARK: Screens

    @ViewBuilder
    private func screen(for step: Step) -> some View {
        switch step {
        case .welcome: welcome
        case .language: languageChoice
        case .microphone: microphoneStep
        }
    }

    private static let interfaceLanguages = OnboardingCopy.languages

    private var welcome: some View {
        Page(footer: {
            OnboardingButton(title: t.start, palette: palette) { advance(clearing: .welcome) }
        }) {
            GreetingLettering(languageIDs: greetingOrder)
                .frame(height: 96)
                .frame(maxWidth: .infinity)
                .padding(.top, 34)
                .padding(.bottom, 44)
                .modifier(SlowEntrance(index: 0))
            OnboardingHeading(
                title: t.welcomeTitle,
                subtitle: t.welcomeBody,
                theme: theme
            )
            .modifier(SlowEntrance(index: 1))
            // Two across, or one per row once the names are too large to share a row.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 8) {
                ForEach(Array(Self.interfaceLanguages.enumerated()), id: \.element.id) { index, item in
                    ChoiceChip(
                        languageID: item.id,
                        title: item.name,
                        isSelected: interfaceLanguage == item.id,
                        palette: palette,
                        theme: theme
                    ) {
                        chooseInterfaceLanguage(item.id)
                    }
                    .modifier(SlowEntrance(index: 2 + index))
                }
            }
            .padding(.top, 22)
            .sensoryFeedback(.selection, trigger: interfaceLanguage)
        }
    }

    /// Every word on screen changes inside the chip's spring, so the new language
    /// cross-fades in instead of snapping.
    private func chooseInterfaceLanguage(_ id: String) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
            interfaceLanguage = id
            if !speechLanguagePicked, packs.catalog.language(id: id) != nil {
                speechLanguage = id
            }
        }
    }

    /// The chosen language greets first.
    private var greetingOrder: [String] {
        let ids = Self.interfaceLanguages.map(\.id)
        guard let start = ids.firstIndex(of: interfaceLanguage) else { return ids }
        return Array(ids[start...] + ids[..<start])
    }

    private var languageChoice: some View {
        let chosen = speechLanguage.flatMap(packs.catalog.language(id:))
        let state = chosen.map { packs.state(of: $0) } ?? .notInstalled
        let isInstalled = state == .installed
        // The language downloads here, and the onboarding goes on only once it is on the phone.
        let progress: Double? = if case .downloading(let fraction) = state { fraction } else { nil }
        let failed = if case .failed = state { true } else { false }
        // Inside the app already (English on the iPhone): the screen only chooses.
        let chosenIsBundled = chosen.map(packs.isBundled) ?? false
        return Page(footer: {
            VStack(spacing: 6) {
                OnboardingButton(
                    title: isInstalled ? t.continue
                        : progress.map { t.downloadingPercent(Int(($0 * 100).rounded())) }
                        ?? (failed ? t.tryAgain : "\(t.download) · \(chosen.map { Self.size(packs.downloadSize(of: $0)) } ?? "")"),
                    palette: palette,
                    isEnabled: chosen != nil,
                    symbol: isInstalled || progress != nil ? nil : (failed ? "arrow.clockwise" : "arrow.down"),
                    progress: progress
                ) {
                    guard let chosen else { return }
                    if isInstalled {
                        packs.select(chosen)
                        advance(clearing: .language)
                    } else {
                        Task {
                            await packs.install(chosen)
                            if packs.state(of: chosen) == .installed { packs.select(chosen) }
                        }
                    }
                }
                // Only when the download fails (no connection, the App Store unreachable):
                // the reader can still go on and download the language later.
                if failed {
                    OnboardingTextButton(title: t.continueWithout, palette: palette) {
                        advance(clearing: .language)
                    }
                    .transition(.opacity)
                }
            }
            .animation(motion, value: failed)
        }) {
            OnboardingHeading(
                title: chosenIsBundled ? t.chooseTitle : t.downloadTitle,
                subtitle: failed ? chosen.map { packs.failureText(of: $0, general: t.downloadFailed) } ?? t.downloadFailed
                    : chosenIsBundled ? (packs.allBundled ? t.chooseBodyAll : t.chooseBody) : t.downloadBody,
                theme: theme
            )
            .padding(.top, 28)
            .modifier(SlowEntrance(index: 0))
            VStack(spacing: 6) {
                ForEach(Array(packs.catalog.languages.enumerated()), id: \.element.id) { index, language in
                    SpeechLanguageCard(
                        language: language,
                        size: packs.isBundled(language) ? t.included : Self.size(packs.downloadSize(of: language)),
                        localName: language.id == interfaceLanguage ? nil : t.languageNames[language.id],
                        isInstalled: packs.state(of: language) == .installed,
                        isSelected: speechLanguage == language.id,
                        palette: palette,
                        theme: theme
                    ) {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                            speechLanguage = language.id
                            speechLanguagePicked = true
                        }
                    }
                    // The choice holds while its language downloads.
                    .disabled(progress != nil && speechLanguage != language.id)
                    .opacity(progress != nil && speechLanguage != language.id ? 0.45 : 1)
                    .animation(motion, value: progress != nil)
                    .modifier(SlowEntrance(index: 1 + index))
                }
            }
            .padding(.top, 22)
            .sensoryFeedback(.selection, trigger: speechLanguage)
        }
        .task { await packs.refreshSizes() }
    }

    private var microphoneStep: some View {
        Page(unclipped: celebrating || handingOff, footer: {
            VStack(spacing: 6) {
                switch microphone {
                case .granted where showsWayOut:
                    if let language = waitingLanguage, !isDownloading(language) {
                        OnboardingButton(title: t.tryAgain, palette: palette, symbol: "arrow.clockwise") {
                            retry(language)
                        }
                    }
                    OnboardingTextButton(title: t.continueWithout, palette: palette) { onFinish() }
                case .granted:
                    OnboardingButton(title: t.continue, palette: palette) { celebrate() }
                        .opacity(celebrating ? 0 : 1)
                        .disabled(celebrating)
                case .unknown:
                    OnboardingButton(title: t.micAllow, palette: palette, symbol: "mic.fill") { askForMicrophone() }
                case .denied:
                    OnboardingButton(title: t.openSettings, palette: palette, symbol: "gear") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    OnboardingTextButton(title: t.notNow, palette: palette) { onFinish() }
                }
            }
            .animation(motion, value: celebrating)
            .animation(motion, value: showsWayOut)
            .opacity(handingOff ? 0 : 1)
        }) {
            ZStack {
                SedaOrbView(voiceLevel: { 0 }, isListening: celebrating, background: theme.paper)
                    .frame(height: Self.orbBand)
                    .padding(.horizontal, -16)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        if !handingOff { orbFrame = frame }
                    }
                    // On the way out the orb rises and grows into the reading screen's own.
                    .scaleEffect(handingOff ? readerBand / Self.orbBand : 1)
                    .offset(y: handingOff ? screenTop + readerBand / 2 - orbFrame.midY : 0)
                    .accessibilityHidden(true)
                Confetti(trigger: burst)
                    .allowsHitTesting(false)
            }
            .padding(.top, 10)
            .modifier(SlowEntrance(index: 0))
            .zIndex(1)
            OnboardingHeading(
                title: microphone == .granted ? t.micGranted : t.micTitle,
                subtitle: microphone == .denied ? t.micDenied : (waitingForLanguage ? waitingText : t.micBody),
                theme: theme
            )
            .animation(motion, value: microphone)
            .opacity(handingOff ? 0 : 1)
            .modifier(SlowEntrance(index: 1))
        }
        .onChange(of: isReady) { _, ready in
            if ready, waitingForLanguage { handOff() }
        }
    }

    /// The reader can open: a language is installed, chosen, and its session exists.
    private var isReady: Bool {
        controller != nil && packs.selectedLanguageID != nil && packs.selectedLanguageID == speechLanguage
    }

    /// The last level cleared: every dot turns orange, the confetti flies over the orb,
    /// and a moment later the reader takes over (or as soon as the language is ready).
    private func celebrate() {
        guard !celebrating else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
            celebrating = true
            _ = cleared.insert(.microphone)
        }
        burst += 1
        Task {
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.8 : 1.8))
            if isReady {
                handOff()
            } else {
                withAnimation(motion) { waitingForLanguage = true }
                try? await Task.sleep(for: .seconds(20))
                withAnimation(motion) { waitedLong = true }
            }
        }
    }

    /// The language being waited for.
    private var waitingLanguage: SpeechLanguage? {
        speechLanguage.flatMap(packs.catalog.language(id:))
    }

    private func isDownloading(_ language: SpeechLanguage) -> Bool {
        if case .downloading = packs.state(of: language) { return true }
        return false
    }

    /// Waiting, and the download failed, never started, or is taking long.
    private var showsWayOut: Bool {
        guard waitingForLanguage, let language = waitingLanguage else { return false }
        switch packs.state(of: language) {
        case .failed, .notInstalled: return true
        case .downloading: return waitedLong
        case .installed: return false
        }
    }

    private func retry(_ language: SpeechLanguage) {
        Task {
            await packs.install(language)
            if packs.state(of: language) == .installed { packs.select(language) }
        }
    }

    private func askForMicrophone() {
        AudioCapture.requestPermission { granted in
            Task { @MainActor in
                withAnimation(motion) { microphone = granted ? .granted : .denied }
                if granted { celebrate() }
            }
        }
    }

    /// Everything but the orb fades while the orb takes the reading screen's place; the
    /// screens then cross with the two orbs one on the other.
    private func handOff() {
        guard !handingOff else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: 0.85, dampingFraction: 0.9)) {
            handingOff = true
        }
        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 300 : 800))
            onFinish()
        }
    }

    private var waitingText: String {
        guard let language = speechLanguage.flatMap(packs.catalog.language(id:)) else { return t.notDownloaded }
        switch packs.state(of: language) {
        case .downloading(let fraction): return t.stillDownloading(Int((fraction * 100).rounded()))
        case .failed: return t.downloadFailed
        case .notInstalled: return t.notDownloaded
        case .installed: return t.preparingLanguage
        }
    }

    private static func size(_ bytes: Int64) -> String {
        // In the interface language ("193,7 MB", "193.7 MB"), not the phone's region.
        bytes.formatted(.byteCount(style: .file, allowedUnits: [.mb, .gb]).locale(InterfaceLanguage.locale))
    }
}

// MARK: - Pieces

/// A screen: its content scrolls, its main action stays at the bottom.
private struct Page<Content: View, Footer: View>: View {
    /// Lets the content draw past the page's top edge: the confetti and the orb on its way
    /// to the reading screen. Otherwise a page taller than the screen (long text, the
    /// largest text sizes) would scroll over the level track and the status bar.
    var unclipped = false
    @ViewBuilder let footer: () -> Footer
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            // The orb leaves through the top on its way to the reading screen.
            .scrollClipDisabled(unclipped)
            footer()
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .modifier(SlowEntrance(index: 6))
                // A page taller than the screen (the largest text sizes) runs on under
                // the footer, which stands on the page's paper with a short fade above it.
                .padding(.top, 8)
                .background(alignment: .top) {
                    let paper = (scheme == .dark ? ReadingTheme.dark : .light).paper
                    paper
                        .overlay(alignment: .top) {
                            LinearGradient(colors: [paper.opacity(0), paper], startPoint: .top, endPoint: .bottom)
                                .frame(height: 16)
                                .offset(y: -16)
                        }
                        .ignoresSafeArea(edges: .bottom)
                }
        }
    }
}
