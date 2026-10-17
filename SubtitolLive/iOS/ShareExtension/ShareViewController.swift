import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "duna" in the share menu of a video (Photos, Files, any app that shares a film or a
/// recording). The extension only hands the file over: it copies it into the app group's
/// inbox and asks the reader to open duna, which takes it from there (only widgets may
/// open their app). Recognition needs far more memory than an extension may use.
final class ShareViewController: UIViewController {
    private let state = HandoverState()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let host = UIHostingController(rootView: HandoverCard(state: state))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await handOver() }
    }

    private func handOver() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        let types: [UTType] = [.movie, .audio]
        guard let provider = providers.first(where: { provider in types.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) } }),
              let type = types.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else {
            state.failed = true
            try? await Task.sleep(for: .seconds(1.6))
            extensionContext?.cancelRequest(withError: CocoaError(.fileReadUnsupportedScheme))
            return
        }
        do {
            _ = try await deposit(from: provider, type: type)
            state.done = true
            try? await Task.sleep(for: .seconds(2.4))
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            state.failed = true
            try? await Task.sleep(for: .seconds(1.6))
            extensionContext?.cancelRequest(withError: error)
        }
    }

    /// The file is only readable inside the callback, so it is copied there.
    private func deposit(from provider: NSItemProvider, type: UTType) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                do {
                    continuation.resume(returning: try SharedInbox.deposit(copyOf: url))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@MainActor
final class HandoverState: ObservableObject {
    @Published var done = false
    @Published var failed = false
}

/// A small card while the file is copied: the film glyph, then a check.
private struct HandoverCard: View {
    @ObservedObject var state: HandoverState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.primary.opacity(0.06))
                Image(systemName: state.failed ? "exclamationmark" : state.done ? "checkmark" : "film")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.7))
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 64, height: 64)
            Text(state.failed
                 ? String(localized: "Aquest fitxer no té so.")
                 : state.done
                    ? String(localized: "Desat. Obre duna per fer-ne els subtítols.")
                    : String(localized: "Desant…"))
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
        }
        .padding(28)
        .frame(maxWidth: 280)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.regularMaterial))
        .scaleEffect(appeared || reduceMotion ? 1 : 0.9)
        .opacity(appeared ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: appeared)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.done)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.failed)
        .onAppear { appeared = true }
    }
}
