import CoreText
import SubtitolCore
import SwiftUI
import UniformTypeIdentifiers

// The export button and panel, shared by the Mac and the iPhone. Each platform
// supplies what the panel's buttons do.

extension TranscriptExportFormat {
    var title: String {
        switch self {
        case .text: localized("Text")
        case .markdown: "Markdown"
        case .subtitles: localized("Subtítols")
        }
    }

    var caption: String {
        switch self {
        case .text: localized("Només el text, en paràgrafs")
        case .markdown: localized("Amb títol, data i durada")
        case .subtitles: localized("Paraula per paraula, amb el seu temps")
        }
    }

    var contentType: UTType {
        switch self {
        case .text: .plainText
        case .markdown: UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
        case .subtitles: UTType(filenameExtension: "srt", conformingTo: .plainText) ?? .plainText
        }
    }

    var symbolName: String {
        switch self {
        case .text: "doc.plaintext"
        case .markdown: "number"
        case .subtitles: "captions.bubble"
        }
    }
}

/// One of the panel's buttons. The primary one is filled with ink.
struct ExportAction: Identifiable {
    let title: String
    let symbol: String
    var isPrimary = false
    /// Shown in place of the title for a moment after the action, for actions that
    /// leave nothing else on screen (a copy).
    var confirmation: String?
    let perform: (TranscriptExportFormat) -> Void

    var id: String { title }
}

/// The share glyph that opens the panel: light grey, no frame, and only there when the
/// session has text to export.
struct ExportButton: View {
    let ink: Color
    var size: CGFloat = 16
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(ink.opacity(isHovered ? 0.62 : 0.34))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { isHovered = hovering }
        }
        .accessibilityShowsLargeContentViewer {
            Label(localized("Exporta"), systemImage: "square.and.arrow.up")
        }
        .accessibilityLabel(localized("Exporta el text"))
        .accessibilityInputLabels([localized("Exporta"), localized("Comparteix"), localized("Exporta el text")])
        .accessibilityHint(localized("Desa o envia el text d'aquesta sessió"))
    }
}

/// Choose a format, see the start of the file it makes, then save or send it.
///
/// The format list moves like the settings bar: a lifted knob travels to the chosen row
/// by `matchedGeometryEffect`, and the preview cross-fades to the new file. Under
/// Reduce Motion the knob cross-fades instead of travelling.
struct ExportPanel: View {
    let session: SessionTranscript
    let palette: SettingsBarPalette
    /// The reader's typeface: the preview is set in it, like the transcript.
    let typeface: ReadingTypeface
    /// The remembered format. The panel animates its own copy: a change that reaches the
    /// view through `@AppStorage` arrives outside the animation and would snap.
    @Binding var storedFormat: TranscriptExportFormat
    let actions: [ExportAction]
    /// A line under the buttons, for what the reader should know about where files go.
    var footnote: String?
    /// The text of each format when it is not the session's own (a video's `.srt`
    /// follows its captions' words per cue).
    var render: ((TranscriptExportFormat) -> String)?
    /// The Mac draws the panel as a floating card; on the iPhone the sheet is the card.
    var drawsCard = true
    /// Off inside a card that has its own title and margins (the subtitle editor's export).
    var showsHeader = true
    /// What the `.srt` holds, when it is not a word per cue (a video's follows its captions).
    var subtitlesCaption: String?
    let onClose: () -> Void

    static let motion = Animation.spring(response: 0.3, dampingFraction: 0.84)
    private static let previewLines = 9
    private static let previewCharacters = 700

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The interface language: its change re-renders the words below.
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .footnote) private var previewSize: CGFloat = 13
    @ScaledMetric(relativeTo: .footnote) private var previewHeight: CGFloat = 132
    @Namespace private var namespace
    @State private var chosenFormat: TranscriptExportFormat?
    @State private var confirmed: String?
    @State private var confirmationReset: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsHeader { header }
            formatList
            preview
            buttons
            if let footnote {
                Text(footnote)
                    .scaledFont(size: 12, relativeTo: .footnote)
                    .foregroundStyle(palette.ink.opacity(0.52))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(showsHeader ? (drawsCard ? 18 : 20) : 0)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(showsHeader ? localized("Exporta la sessió") : localized("Arxiu .srt"))
        #if DEBUG
        .task {
            // Recordings of the knob: `-exportFormatTour YES` picks each format in turn.
            guard UserDefaults.standard.bool(forKey: "exportFormatTour") else { return }
            for option in TranscriptExportFormat.allCases.reversed() + TranscriptExportFormat.allCases {
                try? await Task.sleep(for: .seconds(1.5))
                choose(option)
            }
        }
        #endif
    }

    private var format: TranscriptExportFormat { chosenFormat ?? storedFormat }

    private func choose(_ option: TranscriptExportFormat) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Self.motion) { chosenFormat = option }
        storedFormat = option
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(localized("Exporta la sessió"))
                    .scaledFont(size: 17, weight: .semibold, relativeTo: .headline)
                    .foregroundStyle(palette.ink)
                Text(summary)
                    .scaledFont(size: 13, relativeTo: .subheadline)
                    .monospacedDigit()
                    .foregroundStyle(palette.ink.opacity(0.56))
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.2), value: session.wordCount)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .scaledFont(size: 12, weight: .semibold, relativeTo: .footnote)
                    .foregroundStyle(palette.ink.opacity(0.6))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(palette.well))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.top, -7)
            .padding(.trailing, -7)
            .accessibilityLabel(localized("Tanca"))
        }
    }

    private var summary: String {
        localized("\(session.wordCount) paraules · \(TranscriptExport.durationLabel(session.duration))")
    }

    private var formatList: some View {
        VStack(spacing: 2) {
            ForEach(TranscriptExportFormat.allCases) { option in
                formatRow(option)
            }
        }
        // The knob lies under every row, so on its way it never covers a row's text.
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(palette.knob)
                .shadow(color: palette.shadow.opacity(0.7), radius: 5, y: 2)
                .outlinedWithoutColour(RoundedRectangle(cornerRadius: 15, style: .continuous), ink: palette.ink)
                .matchedGeometryEffect(id: format, in: namespace, isSource: false)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(palette.well)
        )
    }

    private func formatRow(_ option: TranscriptExportFormat) -> some View {
        let isSelected = option == format
        return Button {
            choose(option)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: option.symbolName)
                    .scaledFont(size: 15, weight: .medium, relativeTo: .body)
                    .foregroundStyle(palette.ink.opacity(isSelected ? 0.9 : 0.5))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.title)
                        .scaledFont(size: 14, weight: .semibold, relativeTo: .body)
                        .foregroundStyle(palette.ink.opacity(isSelected ? 1 : 0.72))
                    Text(option == .subtitles ? (subtitlesCaption ?? option.caption) : option.caption)
                        .scaledFont(size: 12, relativeTo: .footnote)
                        .foregroundStyle(palette.ink.opacity(0.52))
                        // At the largest text sizes the caption wraps rather than shrinking out of reach.
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                        .minimumScaleFactor(typeSize.isAccessibilitySize ? 1 : 0.85)
                        .fixedSize(horizontal: false, vertical: typeSize.isAccessibilitySize)
                }
                Spacer(minLength: 4)
                Text(verbatim: ".\(option.fileExtension)")
                    .scaledFont(size: 12, weight: .medium, relativeTo: .footnote)
                    .foregroundStyle(palette.ink.opacity(isSelected ? 0.62 : 0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 50)
            .matchedGeometryEffect(id: option, in: namespace, isSource: true)
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(option.title), .\(option.fileExtension)"))
        .accessibilityInputLabels([option.title])
        .accessibilityValue(option.caption)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The top of the file itself, in the reader's typeface, fading out at the bottom.
    private var preview: some View {
        ZStack(alignment: .topLeading) {
            Text(previewText(for: format))
                .font(Font(previewFont))
                .lineSpacing(2)
                // Runs on past the bottom and fades there, rather than ending in "…".
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(palette.ink.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .id(format)
                .transition(.opacity)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .frame(height: previewHeight, alignment: .top)
        .frame(maxWidth: .infinity)
        .clipped()
        .mask(
            LinearGradient(
                stops: [.init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.ink.opacity(0.08))
        )
        .accessibilityLabel(localized("Previsualització"))
        .accessibilityValue(previewText(for: format))
    }

    /// The reader's face without contextual alternates: Inter draws "-->" as an arrow,
    /// and the preview shows the characters the file really has.
    private var previewFont: CTFont {
        let base = typeface.font(ofSize: previewSize) as CTFont
        let noAlternates = CTFontDescriptorCreateWithAttributes([
            kCTFontFeatureSettingsAttribute: [[
                kCTFontOpenTypeFeatureTag: "calt",
                kCTFontOpenTypeFeatureValue: 0,
            ]],
        ] as CFDictionary)
        return CTFontCreateCopyWithAttributes(base, previewSize, nil, noAlternates)
    }

    private func previewText(for format: TranscriptExportFormat) -> String {
        let text = render?(format) ?? TranscriptExport.render(session, as: format)
        let lines = text.prefix(Self.previewCharacters)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(Self.previewLines)
        return lines.joined(separator: "\n")
    }

    /// Side by side, or one over the other when the text is too large for a row.
    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(actions) { action in
                    actionButton(action)
                }
            }
            VStack(spacing: 8) {
                ForEach(actions) { action in
                    actionButton(action)
                }
            }
        }
    }

    private func actionButton(_ action: ExportAction) -> some View {
        let showsConfirmation = confirmed == action.id && action.confirmation != nil
        return Button {
            action.perform(format)
            guard action.confirmation != nil else { return }
            confirmationReset?.cancel()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { confirmed = action.id }
            confirmationReset = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.25)) { confirmed = nil }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: showsConfirmation ? "checkmark" : action.symbol)
                    .scaledFont(size: 14, weight: .semibold, relativeTo: .body)
                    .contentTransition(.symbolEffect(.replace))
                Text(showsConfirmation ? (action.confirmation ?? action.title) : action.title)
                    .scaledFont(size: 15, weight: .semibold, relativeTo: .body)
                    .fixedSize()
                    .contentTransition(.opacity)
            }
            .foregroundStyle(action.isPrimary ? palette.surface : palette.ink)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(
                Capsule(style: .continuous)
                    .fill(action.isPrimary ? palette.ink : palette.well)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(action.title)
    }
}
