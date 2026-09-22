import AppKit
import CoreText
import ObjectiveC
import SubtitolCore
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
        guard let url = Bundle.main.url(
            forResource: "Inter_18pt-Medium",
            withExtension: "ttf",
            subdirectory: "Fonts"
        ) else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

/// Makes this app's window a little rounder than stock Mac chrome.
/// Content still fills the window, so the corners stay opaque.
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: SubtitleController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        ReadingFontRegistration.register()
        WindowCornerRadiusHook.install(radius: AppVisualMetrics.panelCornerRadius)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.shutdown()
        return .terminateNow
    }
}

@main
struct SubtitolLiveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = SubtitleController()

    var body: some Scene {
        WindowGroup("Subtítol Live") {
            ContentView(controller: controller)
                .ignoresSafeArea()
                .textSelection(.disabled)
                .background(WindowChromeConfigurator())
                .onAppear {
                    appDelegate.controller = controller
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_280, height: 860)
    }
}
