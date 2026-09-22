import AppKit
import SubtitolCore
import SwiftUI

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

    @AppStorage("reading.fontSize") private var storedFontSize = Double(AppVisualMetrics.defaultFontSize)
    @AppStorage("reading.darkTheme") private var isDarkTheme = false
    @AppStorage("reading.ageGradient") private var prefersAgeGradient = false
    @AppStorage("reading.showsDecoration") private var showsDecoration = true

    @State private var increasesContrast = NSWorkspace.shared
        .accessibilityDisplayShouldIncreaseContrast
    @State private var showsShortcutHelp = false
    @State private var helpDismissal: Task<Void, Never>?

    private let designSize = CGSize(width: 1_280, height: 832)
    private let transcriptWidthRatio = 870.0 / 1_280.0

    /// The system setting wins over the app's own presentation toggle. Someone who has
    /// asked macOS for more contrast is not asking this app for a fade.
    private var showsAgeGradient: Bool { prefersAgeGradient && !increasesContrast }

    var body: some View {
        GeometryReader { proxy in
            let theme = ReadingTheme.resolved(isDark: isDarkTheme)
            let scale = min(
                proxy.size.width / designSize.width,
                proxy.size.height / designSize.height
            )
            let transcriptWidth = showsDecoration
                ? proxy.size.width * transcriptWidthRatio
                : proxy.size.width
            let outerInset = max(
                AppVisualMetrics.minimumPanelInset,
                AppVisualMetrics.referencePanelInset * scale
            )

            ZStack {
                HStack(spacing: 0) {
                    transcriptPane(theme: theme, height: proxy.size.height)
                        .frame(width: transcriptWidth)

                    if showsDecoration {
                        ProceduralShaderView(
                            voiceLevel: controller.voiceLevel,
                            discardPendingVoicePeak: controller.discardPendingVoicePeak,
                            isRecording: controller.isRecording
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .background(theme.canvas)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Button {
                    controller.toggleRecording()
                } label: {
                    Color.clear
                        .contentShape(
                            RecordingSurfaceShape(titleBarHeight: max(38, 44 * scale))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!controller.canToggle)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(
                    controller.canToggle ? controller.buttonTitle : controller.detail
                )
                .accessibilityHint(
                    controller.canToggle
                        ? "Activa o atura la transcripció en directe"
                        : "La transcripció encara no està disponible"
                )

                transcriptionProfileMenu(theme: theme)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, max(48, 54 * scale))
                    .padding(.trailing, max(18, 24 * scale))
                    .zIndex(2)

                shortcutCommands
            }
            .overlay(alignment: .top) { shortcutHelp(theme: theme) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(outerInset)
            .textSelection(.disabled)
        }
        .background(ReadingTheme.resolved(isDark: isDarkTheme).canvas)
        .ignoresSafeArea()
        .textSelection(.disabled)
        .frame(minWidth: 820, minHeight: 540)
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
            )
        ) { _ in
            increasesContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        }
    }

    private func transcriptionProfileMenu(theme: ReadingTheme) -> some View {
        Menu {
            ForEach(TranscriptionProfile.allCases, id: \.self) { profile in
                Button {
                    controller.selectTranscriptionProfile(profile)
                } label: {
                    if controller.transcriptionProfile == profile {
                        Label(profile.displayName, systemImage: "checkmark")
                    } else {
                        Text(profile.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(controller.transcriptionProfile.displayName)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.ink.opacity(0.72))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(theme.paper.opacity(0.92), in: Capsule())
            .overlay(Capsule().strokeBorder(theme.ink.opacity(0.12)))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!controller.canSelectTranscriptionProfile)
        .accessibilityLabel("Perfil de transcripció")
        .accessibilityValue(controller.transcriptionProfile.displayName)
        .accessibilityHint("Es pot canviar només quan la gravació està aturada")
    }

    private func transcriptPane(theme: ReadingTheme, height: CGFloat) -> some View {
        let verticalInset = max(72, 147 * min(1, height / designSize.height))
        let resolvedFontSize = fontSize(paneHeight: height - verticalInset * 2)
        let bottomInset = AppVisualMetrics.transcriptBottomInset(
            baseInset: verticalInset,
            fontSize: resolvedFontSize
        )
        return FixedFocusTranscriptView(
            committedWords: controller.committedWords,
            provisionalWords: controller.provisionalWords,
            fallbackText: controller.displayText,
            fontSize: resolvedFontSize,
            theme: theme,
            isLive: controller.isRecording,
            ageGradient: showsAgeGradient
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.horizontal, max(42, 70 * min(1, height / designSize.height)))
        .padding(.top, verticalInset)
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

    // MARK: - Keyboard

    private var shortcutCommands: some View {
        ZStack {
            command("Augmenta la mida del text", key: "+") { adjustFontSize(by: 1) }
            command("Augmenta la mida del text", key: "=") { adjustFontSize(by: 1) }
            command("Redueix la mida del text", key: "-") { adjustFontSize(by: -1) }
            command("Restableix la mida del text", key: "0") {
                storedFontSize = Double(AppVisualMetrics.defaultFontSize)
            }
            command("Alterna el tema fosc", key: "d") { isDarkTheme.toggle() }
            command("Alterna el degradat per antiguitat", key: "g") {
                prefersAgeGradient.toggle()
            }
            command("Alterna el panell decoratiu", key: "\\") { showsDecoration.toggle() }
            command("Mostra les dreceres de teclat", key: "/") { revealShortcutHelp() }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
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
                shortcutRow("Espai", "Comença o atura")
                shortcutRow("⌘ + / ⌘ −", "Mida del text")
                shortcutRow("⌘ 0", "Restableix la mida")
                shortcutRow("⌘ D", "Tema fosc")
                shortcutRow("⌘ G", "Degradat per antiguitat")
                shortcutRow("⌘ \\", "Panell decoratiu")
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
