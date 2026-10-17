import AppKit
import UniformTypeIdentifiers

/// "Subtítol Live" in the Mac's Share menu for a video or a recording. The extension
/// opens the app with the file, as "Open With" does; the language is chosen and the
/// subtitles made in the app's window.
final class ShareViewController: NSViewController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        // Nothing to show: the app's window comes forward with the video's card.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        Task { @MainActor in await handOver() }
    }

    private func handOver() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        for provider in providers {
            if let url = await fileURL(from: provider), Self.isMedia(url) {
                open(url)
                extensionContext?.completeRequest(returningItems: nil)
                return
            }
        }
        extensionContext?.cancelRequest(withError: CocoaError(.fileReadUnsupportedScheme))
    }

    private func fileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func isMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .audio)
    }

    /// The app that carries this extension: Contents/PlugIns/<extension>.appex, two
    /// folders up from Contents.
    private func open(_ file: URL) {
        let app = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration)
    }
}
