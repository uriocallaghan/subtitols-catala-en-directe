import CoreGraphics
import SubtitolCore
import SwiftUI

// The card that turns a video into subtitles, shared by the Mac and the iPhone. Each
// platform supplies how the finished file leaves the app.

/// The gallery glyph (`photo.on.rectangle`) beside the share glyph: light grey, no frame. While a video is being
/// transcribed a thin ring round it fills with the progress, so the work stays in view
/// with the card closed.
struct ImportButton: View {
    let ink: Color
    var size: CGFloat = 16
    /// 0...1 while a job runs; `nil` otherwise.
    var progress: Double?
    var isFinished = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ImportGlyphLabel(ink: ink, size: size, progress: progress, isFinished: isFinished, isHovered: isHovered)
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { isHovered = hovering }
        }
        .accessibilityLabel(localized("Subtítols d'un vídeo"))
        .accessibilityValue(progress.map { localized("\(Int(($0 * 100).rounded())) %") } ?? "")
        .accessibilityInputLabels([localized("Importa un vídeo"), localized("Subtítols d'un vídeo"), localized("Vídeo")])
        .accessibilityHint(localized("Tria un vídeo i en fa els subtítols en aquest dispositiu"))
    }
}

/// The glyph itself, for a button or a menu's label.
struct ImportGlyphLabel: View {
    let ink: Color
    var size: CGFloat = 16
    var progress: Double?
    var isFinished = false
    var isHovered = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let progress {
                Circle()
                    .stroke(ink.opacity(0.1), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(ink.opacity(0.55), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.35), value: progress)
            }
            Image(systemName: isFinished ? "captions.bubble" : "photo.on.rectangle")
                .font(.system(size: size * (progress == nil ? 1 : 0.78), weight: .regular))
                .foregroundStyle(ink.opacity(isHovered || progress != nil ? 0.62 : 0.34))
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: size * 1.9, height: size * 1.9)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.8), value: progress == nil)
    }
}

/// Choose the video's language, watch it being transcribed, then send the subtitles.
///
/// One card for the whole journey: its body cross-fades and resizes from one step to
/// the next on a single spring, the language knob travels like the settings bar's, and
/// the progress bar fills continuously. Under Reduce Motion the steps cross-fade.
struct ImportPanel: View {
    @ObservedObject var job: MediaImport
    @ObservedObject var packs: LanguagePackStore
    let palette: SettingsBarPalette
    /// How the finished subtitles leave the app. `perform` receives the file's format.
    let finishedActions: [ExportAction]
    /// Adds the system share button (AirDrop, Messages, Mail…) for the finished file.
    var sharesFile = true
    /// The share button leads on the iPhone, where the sheet is how everything is sent.
    var shareIsPrimary = false
    /// The Mac draws the panel as a floating card; on the iPhone the sheet is the card.
    var drawsCard = true
    /// Opens the finished subtitles in the editor.
    var onReview: (() -> Void)?
    let onAnotherVideo: () -> Void
    let onClose: () -> Void

    static let motion = Animation.spring(response: 0.42, dampingFraction: 0.86)
    /// The settings bar's springs, which the language rows share.
    static let rows = Animation.spring(response: 0.3, dampingFraction: 0.84)
    static let selection = Animation.spring(response: 0.24, dampingFraction: 0.82)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Namespace private var namespace
    @State private var chosenLanguageID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Group {
                switch job.phase {
                case .choosing:
                    choosing.transition(stepTransition)
                case .preparing, .transcribing:
                    working.transition(stepTransition)
                case .finished:
                    finished.transition(stepTransition)
                case .failed(let message):
                    failed(message).transition(stepTransition)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(drawsCard ? 18 : 20)
        .background {
            if drawsCard {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(palette.hairline)
                    )
                    .shadow(color: palette.shadow, radius: 28, y: 14)
                    .shadow(color: palette.shadow.opacity(0.5), radius: 2, y: 1)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : Self.motion, value: job.phase)
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : Self.motion, value: job.savedCorrections == nil)
        .animation(Self.rows, value: packs.states)
        .task { await packs.refreshSizes() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Subtítols d'un vídeo"))
    }

    private var stepTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 10)).combined(with: .scale(scale: 0.97, anchor: .top)),
                removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
            )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title)
                    .scaledFont(size: 15, weight: .semibold, relativeTo: .headline)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detailLine)
                    .scaledFont(size: 12, relativeTo: .subheadline)
                    .monospacedDigit()
                    .foregroundStyle(palette.ink.opacity(0.56))
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: job.isWorking ? "chevron.down" : "xmark")
                    .scaledFont(size: 12, weight: .semibold, relativeTo: .footnote)
                    .foregroundStyle(palette.ink.opacity(0.6))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(palette.well))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.trailing, -7)
            // While working, closing only tucks the card away; the job goes on.
            .accessibilityLabel(job.isWorking ? localized("Amaga") : localized("Tanca"))
        }
    }

    private var detailLine: String {
        let duration = job.duration.map(TranscriptExport.durationLabel)
        switch job.phase {
        case .finished:
            return localized("\(job.session.wordCount) paraules · \(duration ?? "—")")
        default:
            let kind = job.hasVideo ? localized("Vídeo") : localized("Àudio")
            return [kind, duration].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// A still from the film, or a sound glyph for a recording.
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.well)
            if let image = job.thumbnail {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: job.hasVideo ? "film" : "waveform")
                    .scaledFont(size: 16, weight: .medium, relativeTo: .body)
                    .foregroundStyle(palette.ink.opacity(0.42))
            }
        }
        .frame(width: 64, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.ink.opacity(0.06))
        )
        .animation(.easeInOut(duration: 0.35), value: job.thumbnail != nil)
        .accessibilityHidden(true)
    }

    // MARK: - Choosing the language

    private var selectedLanguageID: String? {
        chosenLanguageID ?? job.languageID ?? packs.selectedLanguageID
    }

    private var selectedLanguage: SpeechLanguage? {
        selectedLanguageID.flatMap(packs.catalog.language(id:))
    }

    private var choosing: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let saved = job.savedCorrections {
                resumeChoice(saved)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(job.savedCorrections == nil ? localized("En quin idioma parlen?") : localized("O torna a començar: en quin idioma parlen?"))
                    .scaledFont(size: 12, weight: .semibold, relativeTo: .footnote)
                    .foregroundStyle(palette.ink.opacity(0.52))
                    .padding(.leading, 4)
                    .fixedSize(horizontal: false, vertical: true)
                languageList
            }
            let canStart = selectedLanguage.map { packs.state(of: $0) == .installed } ?? false
            let start = {
                guard let language = selectedLanguage else { return }
                job.start(language: language, packs: packs)
            }
            if job.savedCorrections == nil {
                primaryButton(title: localized("Fes els subtítols"), symbol: "captions.bubble", enabled: canStart, action: start)
            } else {
                secondaryButton(title: localized("Torna a fer els subtítols"), symbol: "captions.bubble", action: start)
                    .disabled(!canStart)
                    .opacity(canStart ? 1 : 0.4)
            }
            Text(localized("Es fa tot en aquest dispositiu. El vídeo no en surt."))
                .scaledFont(size: 12, relativeTo: .footnote)
                .foregroundStyle(palette.ink.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
        }
    }

    /// The corrections kept from the last time this video was here: go on from them
    /// (nothing is heard again), or forget them.
    private func resumeChoice(_ saved: SavedCorrections) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.bubble")
                    .scaledFont(size: 15, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(palette.ink.opacity(0.75))
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized("Ja havies corregit aquest vídeo"))
                        .scaledFont(size: 14, weight: .semibold, relativeTo: .body)
                        .foregroundStyle(palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(savedDetail(saved))
                        .scaledFont(size: 12, relativeTo: .footnote)
                        .monospacedDigit()
                        .foregroundStyle(palette.ink.opacity(0.52))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Self.motion) { job.forgetSavedCorrections() }
                } label: {
                    Image(systemName: "trash")
                        .scaledFont(size: 12, weight: .semibold, relativeTo: .footnote)
                        .foregroundStyle(palette.ink.opacity(0.5))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(palette.surface.opacity(0.7)))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.top, -8)
                .padding(.trailing, -8)
                .help(localized("Oblida les correccions"))
                .accessibilityLabel(localized("Oblida les correccions"))
            }
            primaryButton(title: localized("Continua on ho vas deixar"), symbol: "pencil.line", enabled: true) {
                withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : Self.motion) { job.resume() }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(palette.well))
    }

    /// "48 paraules · 17 d’oct. 2026, 22:05".
    private func savedDetail(_ saved: SavedCorrections) -> String {
        let when = saved.savedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
        return "\(localized("\(saved.document.wordCount) paraules")) · \(when)"
    }

    private var languageList: some View {
        VStack(spacing: 2) {
            ForEach(packs.catalog.languages) { language in
                languageRow(language)
            }
        }
        // The knob lies under every row, so on its way it never covers a row's text.
        .background {
            if let selectedLanguageID {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(palette.knob)
                    .shadow(color: palette.shadow.opacity(0.7), radius: 5, y: 2)
                    .outlinedWithoutColour(RoundedRectangle(cornerRadius: 15, style: .continuous), ink: palette.ink)
                    .matchedGeometryEffect(id: selectedLanguageID, in: namespace, isSource: false)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(palette.well))
    }

    private func languageRow(_ language: SpeechLanguage) -> some View {
        let state = packs.state(of: language)
        let isSelected = language.id == selectedLanguageID
        return Button {
            choose(language)
        } label: {
            HStack(spacing: 12) {
                LanguageCircle(languageID: language.id, look: figureLook(state: state, isSelected: isSelected), palette: palette)
                    .frame(width: 15, height: 15)
                    .frame(width: 26, height: 26)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? LanguageCircle.orange.opacity(0.09) : palette.surface.opacity(0.6))
                    }
                HStack(spacing: 6) {
                    Text(language.name)
                        .scaledFont(size: 14, weight: .semibold, relativeTo: .body)
                        .foregroundStyle(palette.ink.opacity(isSelected ? 1 : state == .installed ? 0.72 : 0.5))
                    if language.stage == .beta {
                        BetaBadge(text: localized("Nou"), palette: palette, size: 10)
                    }
                }
                Spacer(minLength: 4)
                languageTrailing(language, state: state, isSelected: isSelected)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 42)
            .matchedGeometryEffect(id: language.id, in: namespace, isSource: true)
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!language.isPackStaged && state != .installed)
        .accessibilityLabel(language.stage == .beta ? localized("\(language.name), nou") : language.name)
        .accessibilityValue(caption(language, state: state))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The language's figure: in colour when installed, filling while it downloads.
    private func figureLook(state: LanguagePackStore.PackState, isSelected: Bool) -> LanguageCircle.Look {
        switch state {
        case .installed: isSelected ? .active : .installed
        case .downloading(let fraction): .downloading(fraction)
        case .notInstalled, .failed: .available
        }
    }

    @ViewBuilder
    private func languageTrailing(_ language: SpeechLanguage, state: LanguagePackStore.PackState, isSelected: Bool) -> some View {
        switch state {
        case .installed:
            Image(systemName: "checkmark")
                .scaledFont(size: 11, weight: .bold, relativeTo: .footnote)
                .foregroundStyle(palette.ink.opacity(0.8))
                .opacity(isSelected ? 1 : 0)
                .scaleEffect(isSelected ? 1 : 0.5)
        case .downloading(let fraction):
            HStack(spacing: 6) {
                Text(verbatim: "\(Int((fraction * 100).rounded())) %")
                    .scaledFont(size: 11, weight: .semibold, relativeTo: .footnote)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                ZStack {
                    Circle().stroke(palette.ink.opacity(0.12), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: max(0.03, fraction))
                        .stroke(palette.ink.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: fraction)
                }
                .frame(width: 16, height: 16)
            }
            .foregroundStyle(palette.ink.opacity(0.6))
        case .notInstalled, .failed:
            HStack(spacing: 5) {
                Text(caption(language, state: state))
                    .scaledFont(size: 11, weight: .semibold, relativeTo: .footnote)
                if language.isPackStaged {
                    Image(systemName: "arrow.down.circle")
                        .scaledFont(size: 13, weight: .medium, relativeTo: .footnote)
                }
            }
            .foregroundStyle(palette.ink.opacity(0.5))
        }
    }

    private func caption(_ language: SpeechLanguage, state: LanguagePackStore.PackState) -> String {
        switch state {
        case .installed: return localized("Instal·lat")
        case .notInstalled:
            return language.isPackStaged ? Self.size(packs.downloadSize(of: language)) : localized("Aviat")
        case .downloading(let fraction): return localized("Baixant… \(Int((fraction * 100).rounded())) %")
        case .failed: return localized("Torna-hi")
        }
    }

    /// Choosing a language that is not on the device yet starts its download; it is
    /// selected either way, so the button is ready the moment the download ends.
    private func choose(_ language: SpeechLanguage) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Self.selection) {
            chosenLanguageID = language.id
        }
        job.languageID = language.id
        switch packs.state(of: language) {
        case .notInstalled, .failed:
            Task { await packs.install(language) }
        default:
            break
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Working

    private var working: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Redrawn every frame: the figures and the bar keep moving between reports.
            TimelineView(.animation(minimumInterval: 1 / 30, paused: job.isPaused)) { context in
                let shown = job.displayedFraction(at: context.date)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: "\(Int((shown * 100).rounded(.down))) %")
                            .scaledFont(size: 28, weight: .semibold, relativeTo: .title)
                            .monospacedDigit()
                            .foregroundStyle(palette.ink)
                            .contentTransition(.numericText(value: shown))
                        Spacer()
                        Text(workingLine(at: context.date))
                            .scaledFont(size: 12, weight: .medium, relativeTo: .footnote)
                            .monospacedDigit()
                            .foregroundStyle(palette.ink.opacity(0.52))
                            .contentTransition(.numericText())
                    }
                    ImportProgressBar(fraction: job.phase == .preparing ? nil : shown, palette: palette)
                }
            }
            secondaryButton(title: localized("Atura"), symbol: "stop.fill") {
                job.cancel()
                onClose()
            }
        }
    }

    private func workingLine(at date: Date) -> String {
        if job.isPaused { return localized("En pausa") }
        if job.phase == .preparing { return localized("Preparant el so…") }
        let language = selectedLanguage?.name ?? ""
        guard let remaining = job.displayedRemaining(at: date), job.fraction > 0.04 else { return language }
        let seconds = max(1, Int(remaining.rounded(.up)))
        let label = seconds >= 60
            ? localized("Queden \(seconds / 60) min \(seconds % 60) s")
            : localized("Queden \(seconds) s")
        return "\(language) · \(label)"
    }

    // MARK: - Finished

    private var finished: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .scaledFont(size: 14, weight: .bold, relativeTo: .body)
                    .foregroundStyle(palette.surface)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(palette.ink))
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                VStack(alignment: .leading, spacing: 1) {
                    Text(localized("Subtítols a punt"))
                        .scaledFont(size: 15, weight: .semibold, relativeTo: .body)
                        .foregroundStyle(palette.ink)
                    if let url = job.subtitlesURL {
                        Text(url.lastPathComponent)
                            .scaledFont(size: 12, relativeTo: .footnote)
                            .foregroundStyle(palette.ink.opacity(0.52))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.well))

            // The main way out takes the whole width; the others share a row under it.
            // Reviewing leads when there is text to review: the file can wait.
            if let onReview, !job.session.isEmpty {
                VStack(spacing: 8) {
                    primaryButton(title: localized("Revisa i corregeix"), symbol: "text.bubble", enabled: true, action: onReview)
                    HStack(spacing: 8) {
                        ForEach(finishedActions) { action in
                            Button {
                                action.perform(.subtitles)
                            } label: {
                                buttonLabel(title: action.title, symbol: action.symbol, isPrimary: false)
                            }
                            .buttonStyle(PressableButtonStyle())
                            .accessibilityLabel(action.title)
                        }
                        if sharesFile, let url = job.subtitlesURL {
                            if finishedActions.isEmpty {
                                shareButton(url, isPrimary: false)
                            } else {
                                // Beside other buttons the share glyph alone says enough.
                                ShareLink(item: url) {
                                    Image(systemName: "square.and.arrow.up")
                                        .scaledFont(size: 14, weight: .semibold, relativeTo: .body)
                                        .foregroundStyle(palette.ink)
                                        .frame(width: 46, height: 46)
                                        .background(Circle().fill(palette.well))
                                        .contentShape(Circle())
                                }
                                .buttonStyle(PressableButtonStyle())
                                .accessibilityLabel(localized("Comparteix els subtítols"))
                            }
                        }
                    }
                }
            } else {
            VStack(spacing: 8) {
                if sharesFile, shareIsPrimary, let url = job.subtitlesURL {
                    shareButton(url, isPrimary: true)
                }
                ForEach(finishedActions.filter(\.isPrimary)) { action in
                    actionButton(action)
                }
                HStack(spacing: 8) {
                    ForEach(finishedActions.filter { !$0.isPrimary }) { action in
                        actionButton(action)
                    }
                    if sharesFile, !shareIsPrimary, let url = job.subtitlesURL {
                        shareButton(url, isPrimary: false)
                    }
                }
            }
            }

            Button(action: onAnotherVideo) {
                Text(localized("Un altre vídeo…"))
                    .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                    .foregroundStyle(palette.ink.opacity(0.56))
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    private func shareButton(_ url: URL, isPrimary: Bool) -> some View {
        ShareLink(item: url) {
            buttonLabel(title: localized("Comparteix"), symbol: "square.and.arrow.up", isPrimary: isPrimary)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(localized("Comparteix els subtítols"))
    }

    private func actionButton(_ action: ExportAction) -> some View {
        Button {
            action.perform(.subtitles)
        } label: {
            buttonLabel(title: action.title, symbol: action.symbol, isPrimary: action.isPrimary)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(action.title)
    }

    // MARK: - Failed

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(message)
                .scaledFont(size: 14, relativeTo: .body)
                .foregroundStyle(palette.ink.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            primaryButton(title: localized("Torna-ho a provar"), symbol: "arrow.clockwise", enabled: true) {
                guard let language = selectedLanguage else { return }
                job.start(language: language, packs: packs)
            }
        }
    }

    // MARK: - Buttons

    private func primaryButton(title: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            buttonLabel(title: title, symbol: symbol, isPrimary: true)
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!enabled)
        .animation(.easeInOut(duration: 0.2), value: enabled)
    }

    private func secondaryButton(title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            buttonLabel(title: title, symbol: symbol, isPrimary: false)
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func buttonLabel(title: String, symbol: String, isPrimary: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .scaledFont(size: 14, weight: .semibold, relativeTo: .body)
            Text(title)
                .scaledFont(size: 15, weight: .semibold, relativeTo: .body)
                .fixedSize()
        }
        .foregroundStyle(isPrimary ? palette.surface : palette.ink)
        .frame(maxWidth: .infinity, minHeight: 46)
        .background(Capsule(style: .continuous).fill(isPrimary ? palette.ink : palette.well))
        .contentShape(Capsule(style: .continuous))
    }
}

/// A thin track that fills with the progress; before the pace is known (`nil`) a short
/// segment sweeps along it instead of standing still.
struct ImportProgressBar: View {
    let fraction: Double?
    let palette: SettingsBarPalette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(palette.well)
                if let fraction {
                    Capsule(style: .continuous)
                        .fill(palette.ink.opacity(0.82))
                        .frame(width: max(proxy.size.height, proxy.size.width * fraction))
                        .transition(.opacity)
                } else {
                    TimelineView(.animation(paused: reduceMotion)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        let width = proxy.size.width * 0.28
                        Capsule(style: .continuous)
                            .fill(palette.ink.opacity(reduceMotion ? 0.3 : 0.55))
                            .frame(width: width)
                            .offset(x: reduceMotion ? 0 : (proxy.size.width + width) * phase - width)
                    }
                    .transition(.opacity)
                }
            }
            .clipShape(Capsule(style: .continuous))
        }
        .frame(height: 6)
        .animation(.easeInOut(duration: 0.3), value: fraction == nil)
        .accessibilityElement()
        .accessibilityLabel(localized("Progrés"))
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) %" } ?? localized("Preparant"))
    }
}
