import AppKit
import SubtitolCore
import SwiftUI

/// The Mac's kept transcriptions, a full-window layer like the subtitle editor's: the
/// list by day down the left, on the bar's grey with the chosen row lifted on its white
/// knob, and the chosen transcription on the right as a page whose title, description and
/// text are written in place. The page's bar sets its size and typeface and exports it,
/// in the reading bar's own material.
struct MacTranscriptLibraryView: View {
    @ObservedObject var library: TranscriptLibrary
    let theme: ReadingTheme
    let palette: SettingsBarPalette
    /// Room for the traffic lights before the list's title.
    var leadingInset: CGFloat = 0
    @Binding var selection: UUID?
    /// Bumped by ⌘E to open the page's export card.
    let exportRequests: Int
    let onClose: () -> Void

    @AppStorage("library.fontSize") private var fontSize = MacNoteBar.defaultSize
    @AppStorage("library.typeface") private var typeface: ReadingTypeface = .default
    @AppStorage("export.format") private var exportFormat: TranscriptExportFormat = .text
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The interface language: its change re-renders the words below.
    @Environment(\.locale) private var locale

    @State private var query = ""
    @State private var hovered: UUID?
    @State private var barItem: NoteBarItem?
    @State private var exporting: NoteExport?
    @Namespace private var namespace

    static let sidebarWidth: CGFloat = 300
    static let motion = Animation.spring(response: 0.34, dampingFraction: 0.88)
    private static let cardMotion = Animation.spring(response: 0.38, dampingFraction: 0.86)

    private var filtered: [SavedTranscriptListing] {
        library.listings.filter { $0.matches(query) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)
                .background(palette.well)
            Rectangle()
                .fill(theme.ink.opacity(0.07))
                .frame(width: 1)
            pageArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.paper)
        }
        .background(theme.paper)
        .overlay { escape }
        .onAppear(perform: keepSelectionValid)
        .onChange(of: library.listings.map(\.id)) { _, _ in keepSelectionValid() }
        .onChange(of: library.isLoaded) { _, _ in keepSelectionValid() }
        .onChange(of: selection) { _, _ in
            closeCard()
            if barItem != nil { withAnimation(SettingsBar.motion) { barItem = nil } }
        }
        .onChange(of: exportRequests) { _, _ in openExport() }
        // A setting opened in the bar takes the place of the card.
        .onChange(of: barItem) { _, item in
            if item != nil { closeCard() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Transcripcions"))
    }

    /// Esc closes what is open, one thing at a time, and then the layer.
    private var escape: some View {
        Button(localized("Tanca")) {
            if exporting != nil {
                closeCard()
            } else if barItem != nil {
                withAnimation(SettingsBar.motion) { barItem = nil }
            } else {
                onClose()
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A deleted or filtered-out transcription gives its place to the nearest one.
    private func keepSelectionValid() {
        guard library.isLoaded else { return }
        if let selection, library.contains(selection) { return }
        withAnimation(Self.motion) { selection = filtered.first?.id ?? library.listings.first?.id }
    }

    // MARK: - The list

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(localized("Transcripcions"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.ink)
                if !library.listings.isEmpty {
                    Text(verbatim: "\(library.listings.count)")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(theme.ink.opacity(0.42))
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
            }
            .animation(.easeOut(duration: 0.2), value: library.listings.count)
            .padding(.leading, max(16, leadingInset))
            .padding(.trailing, 16)
            .frame(height: 52)
            // The strip is the window's title bar: it still moves the window.
            .background(Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()))

            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(TranscriptDates.groups(filtered), id: \.title) { group in
                        Text(group.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.ink.opacity(0.46))
                            .padding(.horizontal, 12)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(group.items) { listing in
                            row(listing)
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                        }
                    }
                    if filtered.isEmpty, !library.listings.isEmpty {
                        Text(localized("Cap transcripció no diu «\(query)»."))
                            .font(.system(size: 12))
                            .foregroundStyle(theme.ink.opacity(0.5))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 28)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
                .animation(Self.motion, value: filtered.map(\.id))
            }
            .scrollIndicators(.never)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.ink.opacity(0.42))
            TextField("", text: $query, prompt: Text(localized("Cerca")).foregroundStyle(theme.ink.opacity(0.38)))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(theme.ink)
            if !query.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { query = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.ink.opacity(0.36))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
                .accessibilityLabel(localized("Esborra la cerca"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Capsule(style: .continuous).fill(palette.knob.opacity(palette.isDark ? 0.6 : 1)))
        .overlay(Capsule(style: .continuous).strokeBorder(palette.hairline))
        .animation(.easeOut(duration: 0.18), value: query.isEmpty)
    }

    private func row(_ listing: SavedTranscriptListing) -> some View {
        let isSelected = selection == listing.id
        let isHovered = hovered == listing.id && !isSelected
        return Button {
            withAnimation(Self.motion) { selection = listing.id }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(listing.displayTitle.isEmpty ? localized("Sense text") : listing.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(TranscriptDates.rowDate(listing.createdAt))
                        .foregroundStyle(theme.ink.opacity(0.64))
                        .monospacedDigit()
                    Text(listing.detailLine)
                        .foregroundStyle(theme.ink.opacity(0.48))
                        .lineLimit(1)
                }
                .font(.system(size: 12))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(palette.knob)
                        .shadow(color: palette.shadow, radius: 4, y: 1)
                        .outlinedWithoutColour(RoundedRectangle(cornerRadius: 12, style: .continuous), ink: palette.ink)
                        .matchedGeometryEffect(id: "library.selection", in: namespace)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(palette.knob.opacity(0.5))
                        .transition(.opacity)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) {
                if inside { hovered = listing.id } else if hovered == listing.id { hovered = nil }
            }
        }
        .contextMenu {
            Button(localized("Copia el text")) { copy(listing.id) }
            Divider()
            Button(localized("Elimina…"), role: .destructive) { confirmDeletion(listing) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - The page

    @ViewBuilder
    private var pageArea: some View {
        ZStack(alignment: .bottom) {
            if let selection, library.contains(selection) {
                MacTranscriptPage(
                    library: library,
                    id: selection,
                    theme: theme,
                    palette: palette,
                    fontSize: fontSize,
                    typeface: typeface,
                    onDelete: {
                        if let listing = library.listings.first(where: { $0.id == selection }) { confirmDeletion(listing) }
                    },
                    onClose: onClose
                )
                .id(selection)
                .transition(.opacity)

                if exporting != nil {
                    // A click beside the card closes it.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { closeCard() }
                }

                VStack(spacing: 12) {
                    if let exporting {
                        exportCard(exporting)
                            .frame(width: 372)
                            .transition(cardTransition)
                    }
                    MacNoteBar(
                        expanded: $barItem,
                        fontSize: $fontSize,
                        typeface: $typeface,
                        palette: palette,
                        onExport: { exporting == nil ? openExport() : closeCard() }
                    )
                }
                .padding(.bottom, 22)
            } else if library.isLoaded {
                emptyPage
                    .transition(.opacity)
                closeButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 6)
                    .padding(.trailing, 10)
            }
        }
        .animation(Self.motion, value: selection)
        .animation(Self.cardMotion, value: exporting?.id)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.ink.opacity(0.6))
                .frame(width: 30, height: 30)
                .background(Circle().fill(palette.well))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(localized("Tanca"))
        .accessibilityLabel(localized("Tanca les transcripcions"))
    }

    /// Nothing kept yet, or the search left nothing to show.
    private var emptyPage: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(theme.ink.opacity(0.4))
                .frame(width: 72, height: 72)
                .background(Circle().fill(palette.well))
            VStack(spacing: 5) {
                Text(localized("Encara no hi ha cap transcripció"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.ink)
                Text(localized("Quan aturis una transcripció, la trobaràs aquí."))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.ink.opacity(0.56))
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(library.listings.isEmpty ? 1 : 0)
    }

    // MARK: - Export

    private var cardTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)).combined(with: .offset(y: 8)),
                removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom))
            )
    }

    private func openExport() {
        guard let selection, let transcript = library.transcript(selection) else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        if barItem != nil { withAnimation(SettingsBar.motion) { barItem = nil } }
        exporting = NoteExport(transcript: transcript)
    }

    private func closeCard() {
        guard exporting != nil else { return }
        exporting = nil
    }

    private func exportCard(_ export: NoteExport) -> some View {
        ExportPanel(
            session: export.session,
            palette: palette,
            typeface: typeface,
            storedFormat: $exportFormat,
            actions: [
                ExportAction(title: localized("Copia"), symbol: "doc.on.doc", confirmation: localized("Copiat")) { format in
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(export.rendered(format), forType: .string)
                },
                ExportAction(title: localized("Desa…"), symbol: "arrow.down.doc", isPrimary: true) { format in
                    Self.save(export.transcript, as: format, text: export.rendered(format)) { closeCard() }
                },
            ],
            render: export.rendered,
            onClose: closeCard
        )
    }

    // MARK: - Actions

    private func copy(_ id: UUID) {
        guard let transcript = library.transcript(id) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcript.render(.text).trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
    }

    private func confirmDeletion(_ listing: SavedTranscriptListing) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
        let alert = NSAlert()
        alert.messageText = localized("Vols eliminar aquesta transcripció?")
        alert.informativeText = localized("«\(listing.displayTitle)» s'esborrarà d'aquest Mac.")
        alert.addButton(withTitle: localized("Cancel·la"))
        alert.addButton(withTitle: localized("Elimina"))
        alert.buttons.last?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            withAnimation(Self.motion) { library.remove(listing.id) }
        }
    }

    /// Named after the transcription's title, in the folder the reader picks.
    static func save(_ transcript: SavedTranscript, as format: TranscriptExportFormat, text: String, then done: @escaping () -> Void = {}) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = transcript.filename(for: format)
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                done()
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }
}

/// One kept transcription as a page, set to a reading measure in the middle of its pane:
/// the date, the title and the description to write, how long it lasted, then the text,
/// which scrolls under them and is corrected in place.
private struct MacTranscriptPage: View {
    @ObservedObject var library: TranscriptLibrary
    let id: UUID
    let theme: ReadingTheme
    let palette: SettingsBarPalette
    let fontSize: Double
    let typeface: ReadingTypeface
    let onDelete: () -> Void
    let onClose: () -> Void

    @EnvironmentObject private var packs: LanguagePackStore
    @State private var transcript: SavedTranscript?
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case title
        case summary
        case text
    }

    /// The longest comfortable line for the text, whatever the window's width.
    private static let measure: CGFloat = 720

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let transcript {
                page(transcript)
                    .frame(maxWidth: Self.measure + 2 * 48)
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            if transcript == nil { transcript = library.transcript(id) }
        }
        .onDisappear { library.flush() }
    }

    /// The title-bar strip of the page: it moves the window, and holds delete and close.
    private var toolbar: some View {
        HStack(spacing: 2) {
            Spacer(minLength: 0)
            glyphButton("trash", label: localized("Elimina la transcripció"), action: onDelete)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.ink.opacity(0.6))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(palette.well))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .help(localized("Tanca"))
            .accessibilityLabel(localized("Tanca les transcripcions"))
        }
        .padding(.top, 4)
        .padding(.trailing, 10)
        .frame(height: 52)
        .background(Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()))
    }

    private func glyphButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        GlyphButton(symbol: symbol, ink: theme.ink, action: action)
            .help(label)
            .accessibilityLabel(label)
    }

    private func page(_ transcript: SavedTranscript) -> some View {
        let listing = transcript.listing
        let size = CGFloat(fontSize)
        return VStack(alignment: .leading, spacing: 0) {
            Text(TranscriptDates.dateLine(transcript.createdAt))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.ink.opacity(0.46))
                .padding(.bottom, 8)

            TextField(
                "",
                text: binding(\.title),
                prompt: Text(listing.automaticTitle.isEmpty ? localized("Títol") : listing.automaticTitle)
                    .foregroundStyle(theme.ink.opacity(0.26))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(theme.ink)
            .focused($focus, equals: .title)
            .onSubmit { focus = .summary }
            .accessibilityLabel(localized("Títol"))

            TextField(
                "",
                text: binding(\.summary),
                prompt: Text(localized("Afegeix una descripció")).foregroundStyle(theme.ink.opacity(0.3))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .foregroundStyle(theme.ink.opacity(0.66))
            .focused($focus, equals: .summary)
            .onSubmit { focus = .text }
            .padding(.top, 6)
            .accessibilityLabel(localized("Descripció"))

            meta(listing)
                .padding(.top, 14)

            Rectangle()
                .fill(theme.ink.opacity(0.08))
                .frame(height: 1)
                .padding(.top, 20)

            TextEditor(text: binding(\.text))
                .font(Font(typeface.font(ofSize: size) as CTFont))
                .lineSpacing(size * 0.34)
                .foregroundStyle(theme.ink.opacity(0.9))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($focus, equals: .text)
                // The text view keeps a few points either side of its lines; the words
                // line up with the title above.
                .padding(.horizontal, -5)
                .animation(.spring(response: 0.3, dampingFraction: 0.86), value: fontSize)
                .accessibilityLabel(localized("Text de la transcripció"))
                // Lines scrolled away fade out above the bar.
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 36)
                    }
                }
                .padding(.top, 10)
                // The text ends above the bar, never behind it.
                .padding(.bottom, 92)
        }
        .tint(TranscriptLibrary.accent)
        .padding(.horizontal, 48)
        .padding(.top, 8)
    }

    /// The language, the length and the words, quietly, on one line.
    private func meta(_ listing: SavedTranscriptListing) -> some View {
        let language = listing.languageID.flatMap { packs.catalog.language(id: $0)?.name }
        let parts = [
            language,
            listing.duration > 0 ? TranscriptExport.durationLabel(listing.duration) : nil,
            localized("\(listing.wordCount) paraules"),
        ].compactMap { $0 }
        return Text(parts.joined(separator: "  ·  "))
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(theme.ink.opacity(0.46))
            .contentTransition(.numericText())
            .animation(.easeOut(duration: 0.2), value: listing.wordCount)
    }

    private func binding(_ path: WritableKeyPath<SavedTranscript, String>) -> Binding<String> {
        Binding(
            get: { transcript?[keyPath: path] ?? "" },
            set: { value in
                guard var changed = transcript, changed[keyPath: path] != value else { return }
                changed[keyPath: path] = value
                transcript = changed
                library.update(changed)
            }
        )
    }
}

/// A quiet glyph in the page's title strip, lifting on a well when the pointer is over it.
private struct GlyphButton: View {
    let symbol: String
    let ink: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(ink.opacity(isHovered ? 0.7 : 0.42))
                .frame(width: 30, height: 30)
                .background(Circle().fill(ink.opacity(isHovered ? 0.06 : 0)))
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { isHovered = hovering }
        }
    }
}

/// The page's bar, in the reading bar's material: the size and the typeface open inside
/// their own wells, as the reading bar's settings do, and Exporta is the ink pill.
struct MacNoteBar: View {
    @Binding var expanded: NoteBarItem?
    @Binding var fontSize: Double
    @Binding var typeface: ReadingTypeface
    let palette: SettingsBarPalette
    let onExport: () -> Void

    /// A page is read at a desk's distance: smaller than the reading pane's sizes.
    static let sizes: ClosedRange<CGFloat> = 13...29
    static let sizeStep: CGFloat = 2
    static let defaultSize: Double = 17

    private static let wellPadding: CGFloat = 3
    private static let knobSize: CGFloat = 32

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The interface language: its change re-renders the words below.
    @Environment(\.locale) private var locale
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 5) {
            toolWell(.size) { sizePanel }
            toolWell(.typeface) { typefacePanel }
            Button(action: onExport) {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 10, weight: .semibold))
                    Text(localized("Exporta"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(palette.surface)
                .fixedSize()
                .padding(.horizontal, 14)
                .frame(height: Self.knobSize)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .padding(Self.wellPadding)
            .background(Capsule(style: .continuous).fill(palette.ink))
            .accessibilityLabel(localized("Exporta el text"))
        }
        .padding(5)
        .background {
            Capsule(style: .continuous)
                .fill(palette.surface)
                .overlay(Capsule(style: .continuous).strokeBorder(palette.hairline))
                .shadow(color: palette.shadow, radius: 18, y: 8)
                .shadow(color: palette.shadow.opacity(0.5), radius: 2, y: 1)
        }
        .contentShape(Capsule(style: .continuous))
        .onTapGesture { }
        .fixedSize()
    }

    private func toolWell<Panel: View>(_ item: NoteBarItem, @ViewBuilder panel: () -> Panel) -> some View {
        let isOpen = expanded == item
        return HStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : SettingsBar.motion) {
                    expanded = isOpen ? nil : item
                }
            } label: {
                ZStack {
                    if isOpen {
                        Circle()
                            .fill(palette.knob)
                            .shadow(color: palette.shadow, radius: 4, y: 1)
                            .matchedGeometryEffect(id: "note.knob", in: namespace)
                    }
                    Group {
                        switch item {
                        case .size:
                            Image(systemName: "plus.magnifyingglass")
                        case .typeface:
                            Image(systemName: "textformat.alt")
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isOpen ? palette.ink : palette.ink.opacity(0.62))
                }
                .frame(width: Self.knobSize, height: Self.knobSize)
                .contentShape(Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .help(isOpen ? item.closeTitle : item.title)
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(isOpen ? .isSelected : [])
            if isOpen {
                panel()
                    .padding(.horizontal, 4)
                    .transition(.asymmetric(
                        insertion: .identity,
                        removal: .opacity
                            .combined(with: .scale(scale: 0.9, anchor: .leading))
                            .animation(.easeOut(duration: 0.08))
                    ))
            }
        }
        .padding(Self.wellPadding)
        .background(Capsule(style: .continuous).fill(palette.well))
    }

    private var sizePanel: some View {
        HStack(spacing: 4) {
            stepButton(glyphSize: 9, delta: -1, label: localized("Redueix la mida del text"))
                .modifier(StaggeredEntrance(index: 0))
            SizeTrack(value: $fontSize, palette: palette, range: Self.sizes, step: Self.sizeStep)
                .modifier(StaggeredEntrance(index: 1))
            stepButton(glyphSize: 13, delta: 1, label: localized("Augmenta la mida del text"))
                .modifier(StaggeredEntrance(index: 2))
            Text(verbatim: "\(Int(fontSize))")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(palette.ink.opacity(0.78))
                .contentTransition(.numericText(value: fontSize))
                .frame(width: 20, alignment: .trailing)
                .modifier(StaggeredEntrance(index: 3))
        }
    }

    private func stepButton(glyphSize: CGFloat, delta: Int, label: String) -> some View {
        Button {
            let next = min(Self.sizes.upperBound, max(Self.sizes.lowerBound, CGFloat(fontSize) + Self.sizeStep * CGFloat(delta)))
            withAnimation(SettingsBar.selection) { fontSize = Double(next) }
        } label: {
            Text(verbatim: "A")
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(palette.ink.opacity(0.7))
                .frame(width: 20, height: Self.knobSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    private var typefacePanel: some View {
        HStack(spacing: 2) {
            ForEach(Array(ReadingTypeface.allCases.enumerated()), id: \.element) { index, face in
                let isCurrent = typeface == face
                Button {
                    withAnimation(SettingsBar.selection) { typeface = face }
                } label: {
                    VStack(spacing: 0) {
                        Text(verbatim: "Ag")
                            .font(Font(face.font(ofSize: 13) as CTFont))
                        Text(face.displayName)
                            .font(.system(size: 7, weight: .semibold))
                            .opacity(0.8)
                    }
                    .foregroundStyle(isCurrent ? palette.ink : palette.mutedInk)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 52)
                    .frame(height: Self.knobSize)
                    .background {
                        if isCurrent {
                            Capsule(style: .continuous)
                                .fill(palette.knob)
                                .shadow(color: palette.shadow, radius: 3, y: 1)
                                .outlinedWithoutColour(Capsule(style: .continuous), ink: palette.ink)
                                .matchedGeometryEffect(id: "note.typeface", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .help(face.rationale)
                .accessibilityLabel(face.fullName)
                .accessibilityHint(face.rationale)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .modifier(StaggeredEntrance(index: index))
            }
        }
    }
}
