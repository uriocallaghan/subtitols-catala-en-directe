import AppKit
import Combine
import CoreText
import ObjectiveC
import SubtitolCore
import SubtitolEngine
import SwiftUI

private final class WindowChromeView: NSView {
    private weak var configuredWindow: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []
    private var trafficLightPositioningIsScheduled = false

    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, configuredWindow !== window else { return }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        configuredWindow = window

        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.949, green: 0.949, blue: 0.949, alpha: 1)
        window.isOpaque = true
        window.invalidateShadow()

        trafficLightButtons(in: window).forEach { $0.isHidden = false }
        applyPointerAndTextPolicy(to: window)

        let notifications: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeScreenNotification,
        ]
        windowObservers = notifications.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleTrafficLightPositioning()
            }
        }
        scheduleTrafficLightPositioning()
    }

    override func layout() {
        super.layout()
        scheduleTrafficLightPositioning()
    }

    private func scheduleTrafficLightPositioning() {
        guard !trafficLightPositioningIsScheduled else { return }
        trafficLightPositioningIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.trafficLightPositioningIsScheduled = false
            self.positionTrafficLights()
            if let window = self.configuredWindow {
                self.applyPointerAndTextPolicy(to: window)
            }
        }
    }

    private func positionTrafficLights() {
        guard let window = configuredWindow else { return }
        let buttons = trafficLightButtons(in: window)
        let nativeFrameInset: CGFloat = 8
        let nativeButtonGap: CGFloat = 7
        var targetX = nativeFrameInset + AppVisualMetrics.trafficLightOffset.width

        for button in buttons {
            guard let superview = button.superview else { continue }
            let targetInWindow = CGRect(
                x: targetX,
                y: window.frame.height
                    - nativeFrameInset
                    - AppVisualMetrics.trafficLightOffset.height
                    - button.frame.height,
                width: button.frame.width,
                height: button.frame.height
            )
            let targetInSuperview = superview.convert(targetInWindow, from: nil)
            button.setFrameOrigin(targetInSuperview.origin)
            targetX += button.frame.width + nativeButtonGap
        }
    }

    private func trafficLightButtons(in window: NSWindow) -> [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap(window.standardWindowButton)
    }

    private func applyPointerAndTextPolicy(to window: NSWindow) {
        stripHintsAndSelection(from: window.contentView)
        if let themeFrame = window.contentView?.superview {
            stripHintsAndSelection(from: themeFrame)
        }
        for button in trafficLightButtons(in: window) {
            stripHints(from: button)
        }
    }

    private func stripHintsAndSelection(from view: NSView?) {
        guard let view else { return }
        stripHints(from: view)
        if let textView = view as? NSTextView {
            textView.isSelectable = false
            textView.isEditable = false
        }
        if let textField = view as? NSTextField {
            textField.isSelectable = false
            textField.isEditable = false
        }
        view.subviews.forEach { stripHintsAndSelection(from: $0) }
    }

    private func stripHints(from view: NSView) {
        view.toolTip = nil
        view.removeAllToolTips()
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowChromeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) { }
}

private enum ReadingFontRegistration {
    static func register() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

#if !SUBTITOL_STORE
/// Makes this app's window a little rounder than stock Mac chrome.
/// Content still fills the window, so the corners stay opaque.
/// Private AppKit methods: compiled only into the local build, never the store's.
private enum WindowCornerRadiusHook {
    private static var installed = false

    static func install(radius: CGFloat) {
        guard !installed else { return }
        installed = true
        guard let themeFrame = NSClassFromString("NSThemeFrame") else { return }
        replaceDoubleGetter(on: themeFrame, name: "_cornerRadius", radius: radius)
        replaceDoubleGetter(on: themeFrame, name: "_getCachedWindowCornerRadius", radius: radius)
        replaceDoubleGetter(on: themeFrame, name: "_bottomCornerRadius", radius: radius)
        replaceSizeGetter(on: themeFrame, name: "_topCornerSize", radius: radius)
        replaceSizeGetter(on: themeFrame, name: "_bottomCornerSize", radius: radius)
    }

    private static func replaceDoubleGetter(on cls: AnyClass, name: String, radius: CGFloat) {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        let block: @convention(block) (AnyObject) -> CGFloat = { _ in radius }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func replaceSizeGetter(on cls: AnyClass, name: String, radius: CGFloat) {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        let size = CGSize(width: radius, height: radius)
        let block: @convention(block) (AnyObject) -> CGSize = { _ in size }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here rather than by the scene, so a file handed to the app reaches them
    /// even before the window exists.
    let session = LanguageSession()
    let imports = ImportCenter()
    let inputs = AudioInputDeviceList()

    func applicationWillFinishLaunching(_ notification: Notification) {
        ReadingFontRegistration.register()
        ImportCenter.removeLeftoverCopies()
        // Shortcuts actions: the same session and videos as the window, which they bring
        // forward before listening or reading a video.
        ShortcutHost.shared.attach(
            packs: session.packs,
            imports: imports,
            controller: { [session] in session.controller },
            bringForward: { [weak self] in
                self?.ensureWindow()
                NSApp.activate()
            }
        )
        // One window of text, never tabs: no tab items in View and Window.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Private AppKit methods: fine for the local build, not for App Review (2.5.1).
        #if !SUBTITOL_STORE
        WindowCornerRadiusHook.install(radius: AppVisualMetrics.panelCornerRadius)
        #endif
    }

    #if DEBUG
    /// Test runs started in the background (`open -g … --args -forceWindow YES`) get
    /// their window without taking the focus from whoever is using the Mac.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard UserDefaults.standard.bool(forKey: "forceWindow") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in ensureWindow() }
    }
    #endif

    /// A video from Open With, the Dock icon or the Share menu goes to the one window.
    /// An app launched to open a file gets no window from SwiftUI, so one is opened.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: ContentView.isMedia),
              !session.controller.isRecording else { return }
        imports.open(url, languageID: session.packs.selectedLanguageID)
        DispatchQueue.main.async { [self] in
            ensureWindow()
            NSApp.activate()
        }
    }

    /// Opens the window through the app's own File › New Window, as the reader would.
    private func ensureWindow() {
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        let items = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []
        guard let newWindow = items.first(where: { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command }),
              let action = newWindow.action else { return }
        NSApp.sendAction(action, to: newWindow.target, from: newWindow)
    }

    /// Every speech model is released before the process exits: ggml frees its Metal
    /// device in a C++ static destructor at `exit()` and aborts while a model still holds
    /// GPU memory. A video's model lives on the job's thread and a model still loading
    /// reaches the main queue, so the quit stops both and waits off the main thread.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Corrections live only while the app is open: quitting asks before losing them.
        if imports.hasUnexportedEdits() {
            let alert = NSAlert()
            alert.messageText = localized("Vols sortir sense exportar les correccions?")
            alert.informativeText = localized("Les correccions dels subtítols no s'han pogut desar en aquest Mac. Exporta el vídeo o els subtítols per conservar-les.")
            alert.addButton(withTitle: localized("Cancel·la"))
            alert.addButton(withTitle: localized("Surt"))
            alert.buttons.last?.hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        session.controller.shutdown()
        imports.current?.cancel()
        guard !ASREngine.waitUntilAllReleased(timeout: 0) else { return .terminateNow }
        DispatchQueue.global(qos: .userInitiated).async {
            // The job stops at its next window (under a second); the bound is a backstop.
            _ = ASREngine.waitUntilAllReleased(timeout: 10)
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}

/// The installed languages and one recognition session for the chosen one. Choosing
/// another language shuts the session down before the new one loads its model.
@MainActor
final class LanguageSession: ObservableObject {
    let packs = LanguagePackStore()
    @Published private(set) var controller: SubtitleController
    private var selection: AnyCancellable?

    init() {
        controller = Self.controller(for: packs.selectedLanguage, packs: packs)
        selection = packs.$selectedLanguageID
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                // `$selectedLanguageID` publishes before the property is set.
                DispatchQueue.main.async { self?.reload() }
            }
    }

    private func reload() {
        controller.shutdown()
        controller = Self.controller(for: packs.selectedLanguage, packs: packs)
    }

    private static func controller(for language: SpeechLanguage?, packs: LanguagePackStore) -> SubtitleController {
        guard let language else { return SubtitleController(languageID: nil) }
        return SubtitleController(
            languageID: language.id,
            modelID: language.model,
            modelDirectories: packs.modelDirectories(for: language),
            punctuationDirectoryName: language.punctuation
        )
    }
}

@main
struct SubtitolLiveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Before AppKit and SwiftUI build their menus.
        InterfaceLanguageMenus.apply()
    }

    var body: some Scene {
        WindowGroup("duna") {
            AppRoot(session: appDelegate.session, imports: appDelegate.imports)
                .ignoresSafeArea()
                .textSelection(.disabled)
                .background(WindowChromeConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_280, height: 860)
        .commands {
            SubtitolCommands(session: appDelegate.session, imports: appDelegate.imports, inputs: appDelegate.inputs)
        }
    }
}

/// Follows the language session, which rebuilds its controller for a new language.
private struct AppRoot: View {
    @ObservedObject var session: LanguageSession
    @ObservedObject var imports: ImportCenter
    /// Chosen on the onboarding's first screen; absent, the Mac follows the system.
    @AppStorage(InterfaceLanguage.defaultsKey) private var storedInterfaceLanguage: String?
    /// Follows the stored choice inside an animation, so the words cross-fade.
    @State private var interfaceLanguage = InterfaceLanguage.current

    var body: some View {
        ContentView(controller: session.controller)
            .environmentObject(session.packs)
            .environmentObject(imports)
            .environment(\.locale, Locale(identifier: interfaceLanguage))
            .onChange(of: storedInterfaceLanguage) { _, _ in
                let language = InterfaceLanguage.current
                InterfaceLanguageMenus.apply(language)
                guard language != interfaceLanguage else { return }
                withAnimation(.easeInOut(duration: 0.35)) { interfaceLanguage = language }
            }
    }
}
