#if canImport(AppKit)
import AppKit
import AVFoundation
import SubtitolCore
import SwiftUI

/// The Mac's first run: the iPhone's three levels (the app's language, the language to
/// download, the microphone) in the reading pane, beside the shader band that stays where
/// the reader keeps it. Clearing the microphone throws the confetti, the band boils for a
/// moment, and the pane cross-fades into the reader (`ContentView`).
///
/// The pieces are the iPhone's (`OnboardingPieces.swift`); only the layout is the Mac's:
/// one centred column, the action under the text, Return for the main action and Escape
/// to go back.
struct MacOnboardingView: View {
    let theme: ReadingTheme
    let palette: SettingsBarPalette
    /// The band boils while this is set: the last level has just been cleared.
    @Binding var celebrating: Bool
    let onFinish: () -> Void

    @EnvironmentObject private var packs: LanguagePackStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(InterfaceLanguage.defaultsKey) private var interfaceLanguage = InterfaceLanguage.current

    @State private var step: OnboardingStep = .welcome
    @State private var cleared: Set<OnboardingStep> = []
    @State private var speechLanguage: String?
    @State private var speechLanguagePicked = false
    @State private var microphone: Microphone = .unknown
    @State private var forward = true
    @State private var burst = 0
    @State private var waitingForLanguage = false
    /// Set after a while of waiting, so a download that hangs never leaves the reader stuck.
    @State private var waitedLong = false
    @State private var finishing = false

    enum Microphone { case unknown, granted, denied }

    private var t: OnboardingCopy { .for(interfaceLanguage) }
    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: 0.62, dampingFraction: 0.88)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.top, 44)
            ZStack {
                screen(for: step)
                    .id(step)
                    .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay { Confetti(trigger: burst).allowsHitTesting(false) }
        .opacity(finishing ? 0 : 1)
        .onAppear(perform: prepare)
        .onExitCommand { back() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from System Settings with the microphone turned on.
            if microphone == .denied, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                withAnimation(motion) { microphone = .granted }
            }
        }
        .onChange(of: isReady) { _, ready in
            if ready, waitingForLanguage { finish() }
        }
        #if DEBUG
        .task {
            // Screenshot runs: `-onboardingStep 0…2` opens that level directly.
            if let raw = Int(UserDefaults.standard.string(forKey: "onboardingStep") ?? ""),
               let target = OnboardingStep(rawValue: raw) {
                cleared = Set(OnboardingStep.allCases.filter { $0 < target })
                step = target
            }
        }
        #endif
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

    private func advance(clearing current: OnboardingStep) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { _ = cleared.insert(current) }
        guard let next = OnboardingStep(rawValue: current.rawValue + 1) else { return }
        forward = true
        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 150 : 420))
            withAnimation(motion) { step = next }
        }
    }

    private func back() {
        guard !celebrating, let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        forward = false
        withAnimation(motion) { step = previous }
    }

    // MARK: Top

    private var topBar: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.ink.opacity(0.7))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(palette.well))
                        .contentShape(Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .opacity(step == .welcome || celebrating ? 0 : 1)
                .disabled(step == .welcome || celebrating)
                .help(t.back)
                .accessibilityLabel(t.back)

                Spacer()
                OnboardingLevelTrack(current: step, cleared: cleared, palette: palette, label: t.step(step.rawValue + 1, OnboardingStep.allCases.count))
                Spacer()

                Color.clear.frame(width: 36, height: 36)
            }
            .padding(.horizontal, 28)

            Group {
                if let id = speechLanguage, let language = packs.catalog.language(id: id), step > .language {
                    OnboardingDownloadPill(language: language, state: packs.state(of: language), copy: t, palette: palette)
                }
            }
            .frame(height: 30)
        }
        .animation(motion, value: step)
    }

    // MARK: Screens

    @ViewBuilder
    private func screen(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome: welcome
        case .language: languageChoice
        case .microphone: microphoneStep
        }
    }

    /// One centred column: the text, then the main action under it.
    private func column<Content: View, Footer: View>(
        width: CGFloat = 520,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content()
                footer()
                    .padding(.top, 28)
                    .modifier(SlowEntrance(index: 7))
            }
            .frame(maxWidth: width)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.center)
    }

    private var welcome: some View {
        column {
            GreetingLettering(languageIDs: greetingOrder)
                .frame(height: 110)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 40)
                .modifier(SlowEntrance(index: 0))
            OnboardingHeading(title: t.welcomeTitle, subtitle: t.welcomeBody, theme: theme)
                .modifier(SlowEntrance(index: 1))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(Array(OnboardingCopy.languages.enumerated()), id: \.element.id) { index, item in
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
            .padding(.top, 24)
        } footer: {
            OnboardingButton(title: t.start, palette: palette) { advance(clearing: .welcome) }
                .keyboardShortcut(.defaultAction)
        }
    }

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
        let ids = OnboardingCopy.languages.map(\.id)
        guard let start = ids.firstIndex(of: interfaceLanguage) else { return ids }
        return Array(ids[start...] + ids[..<start])
    }

    private var languageChoice: some View {
        let chosen = speechLanguage.flatMap(packs.catalog.language(id:))
        let state = chosen.map { packs.state(of: $0) } ?? .notInstalled
        let isInstalled = state == .installed
        // The language downloads here, and the onboarding goes on only once it is on the Mac.
        let progress: Double? = if case .downloading(let fraction) = state { fraction } else { nil }
        let failed = if case .failed = state { true } else { false }
        // Inside the app already (every language on the Mac): the screen only chooses.
        let chosenIsBundled = chosen.map(packs.isBundled) ?? false
        return column {
            OnboardingHeading(
                title: chosenIsBundled ? t.chooseTitle : t.downloadTitle,
                subtitle: failed ? chosen.map { packs.failureText(of: $0, general: t.downloadFailed) } ?? t.downloadFailed
                    : chosenIsBundled ? (packs.allBundled ? t.chooseBodyAll : t.chooseBody) : t.downloadBody,
                theme: theme
            )
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
        } footer: {
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
                .keyboardShortcut(.defaultAction)
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
        }
        .task { await packs.refreshSizes() }
    }

    private var microphoneStep: some View {
        column(width: 460) {
            ZStack {
                Circle().fill(LanguageCircle.orange.opacity(0.1))
                Image(systemName: microphone == .granted ? "checkmark" : "mic.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(LanguageCircle.orange)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 84, height: 84)
            .scaleEffect(celebrating && !reduceMotion ? 1.12 : 1)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 36)
            .modifier(SlowEntrance(index: 0))
            OnboardingHeading(
                title: microphone == .granted ? t.micGranted : t.micTitle,
                subtitle: microphone == .denied ? t.micDenied : (waitingForLanguage ? waitingText : t.micBody),
                theme: theme
            )
            .animation(motion, value: microphone)
            .modifier(SlowEntrance(index: 1))
        } footer: {
            VStack(spacing: 6) {
                switch microphone {
                case .granted where showsWayOut:
                    if let language = waitingLanguage, !isDownloading(language) {
                        OnboardingButton(title: t.tryAgain, palette: palette, symbol: "arrow.clockwise") {
                            retry(language)
                        }
                    }
                    OnboardingTextButton(title: t.continueWithout, palette: palette) { finish() }
                case .granted:
                    OnboardingButton(title: t.continue, palette: palette) { celebrate() }
                        .keyboardShortcut(.defaultAction)
                        .opacity(celebrating ? 0 : 1)
                        .disabled(celebrating)
                case .unknown:
                    OnboardingButton(title: t.micAllow, palette: palette, symbol: "mic.fill") { askForMicrophone() }
                        .keyboardShortcut(.defaultAction)
                case .denied:
                    OnboardingButton(title: t.openSettings, palette: palette, symbol: "gear") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    OnboardingTextButton(title: t.notNow, palette: palette) { finish() }
                }
            }
            .animation(motion, value: celebrating)
            .animation(motion, value: showsWayOut)
        }
    }

    /// The reader can open: the chosen language is installed and in use.
    private var isReady: Bool {
        guard let speechLanguage, let language = packs.catalog.language(id: speechLanguage) else { return false }
        return packs.selectedLanguageID == speechLanguage && packs.state(of: language) == .installed
    }

    private func celebrate() {
        guard !celebrating else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
            celebrating = true
            _ = cleared.insert(.microphone)
        }
        burst += 1
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        Task {
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.8 : 1.8))
            if isReady {
                finish()
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

    /// The column fades; the reader then cross-fades in beside the same band.
    private func finish() {
        guard !finishing else { return }
        withAnimation(.easeInOut(duration: reduceMotion ? 0.3 : 0.5)) { finishing = true }
        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 300 : 450))
            celebrating = false
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
        bytes.formatted(.byteCount(style: .file, allowedUnits: [.mb, .gb]).locale(InterfaceLanguage.locale))
    }
}
#endif
