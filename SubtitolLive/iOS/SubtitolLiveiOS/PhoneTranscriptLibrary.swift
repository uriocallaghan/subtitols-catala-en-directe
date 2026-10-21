import SubtitolCore
import SwiftUI

// The iPhone's screens for the kept transcriptions: the list, one transcription as a
// note, and the note's bar. The library itself is shared (`TranscriptLibrary`).

// MARK: - The list

/// Notes for what was heard: the kept transcriptions by day, newest first, with a search
/// across their titles, descriptions and text.
struct TranscriptLibraryView: View {
    @ObservedObject var library: TranscriptLibrary
    let isDark: Bool
    /// A transcription to open straight away (the one just kept, from the reading screen).
    var opening: UUID?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The interface language: its change re-renders the words below.
    @Environment(\.locale) private var locale
    @State private var query = ""
    @State private var path: [UUID] = []
    @State private var pendingDeletion: SavedTranscriptListing?

    static let listMotion = Animation.spring(response: 0.4, dampingFraction: 0.86)

    private var filtered: [SavedTranscriptListing] {
        library.listings.filter { $0.matches(query) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(localized("Transcripcions"))
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(localized("Fet")) { dismiss() }
                    }
                }
                .navigationDestination(for: UUID.self) { id in
                    TranscriptNoteView(library: library, id: id, isDark: isDark)
                }
        }
        .tint(TranscriptLibrary.accent)
        .onAppear {
            if let opening, library.contains(opening) { path = [opening] }
        }
        .confirmationDialog(
            localized("Vols eliminar aquesta transcripció?"),
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { listing in
            Button(localized("Elimina"), role: .destructive) {
                withAnimation(Self.listMotion) { library.remove(listing.id) }
            }
            Button(localized("Cancel·la"), role: .cancel) {}
        } message: { listing in
            Text(localized("«\(listing.displayTitle)» s'esborrarà d'aquest iPhone."))
        }
        #if DEBUG
        .task {
            // Screenshot runs: `-openNote YES` opens the newest transcription.
            guard UserDefaults.standard.bool(forKey: "openNote") else { return }
            while library.listings.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(500))
            path = [library.listings[0].id]
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if !library.isLoaded {
            Color.clear
        } else if library.listings.isEmpty {
            emptyState
                .transition(.opacity)
        } else {
            list
                .searchable(text: $query, prompt: Text(localized("Cerca")))
        }
    }

    private var list: some View {
        List {
            let groups = TranscriptDates.groups(filtered)
            ForEach(groups, id: \.title) { group in
                Section {
                    ForEach(group.items) { listing in
                        NavigationLink(value: listing.id) {
                            TranscriptRow(listing: listing, date: TranscriptDates.rowDate(listing.createdAt))
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeletion = listing
                            } label: {
                                Label(localized("Elimina"), systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = listing.text
                            } label: {
                                Label(localized("Copia el text"), systemImage: "doc.on.doc")
                            }
                            Button(role: .destructive) {
                                pendingDeletion = listing
                            } label: {
                                Label(localized("Elimina"), systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(group.title)
                }
            }
            if filtered.isEmpty {
                noResults
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .scrollContentBackground(.hidden)
        .animation(Self.listMotion, value: filtered.map(\.id))
    }

    private var noResults: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(localized("Cap transcripció no diu «\(query)»."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    /// No list yet: a folder waiting, and one sentence on how it fills.
    private var emptyState: some View {
        let palette = SettingsBarPalette.resolved(isDark: isDark)
        return VStack(spacing: 16) {
            Image(systemName: "folder")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(palette.ink.opacity(0.42))
                .frame(width: 84, height: 84)
                .background(Circle().fill(palette.well))
            VStack(spacing: 6) {
                Text(localized("Encara no hi ha cap transcripció"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(palette.ink)
                Text(localized("Quan aturis una transcripció, la trobaràs aquí."))
                    .font(.subheadline)
                    .foregroundStyle(palette.ink.opacity(0.56))
            }
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }
}

/// The title on its line, and under it the date with the description or what was said.
private struct TranscriptRow: View {
    let listing: SavedTranscriptListing
    let date: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(listing.displayTitle.isEmpty ? localized("Sense text") : listing.displayTitle)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .contentTransition(.interpolate)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(date)
                    .foregroundStyle(.primary.opacity(0.72))
                    .monospacedDigit()
                Text(listing.detailLine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One transcription

/// One kept transcription, as a note: the date, its title and description to write, how
/// long it lasted, then the text itself, which can be corrected in place. The bar at the
/// foot sets the text's size and typeface, and exports it.
struct TranscriptNoteView: View {
    @ObservedObject var library: TranscriptLibrary
    let id: UUID
    let isDark: Bool

    @AppStorage("library.fontSize") private var fontSize = NoteBar.defaultSize
    @AppStorage("library.typeface") private var typeface: ReadingTypeface = .default
    @AppStorage("export.format") private var exportFormat: TranscriptExportFormat = .text
    @EnvironmentObject private var packs: LanguagePackStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The interface language: its change re-renders the words below.
    @Environment(\.locale) private var locale

    @State private var transcript: SavedTranscript?
    @State private var expanded: NoteBarItem?
    @State private var exporting: NoteExport?
    @State private var exportHeight: CGFloat = 560
    @State private var confirmsDeletion = false
    @State private var copied = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case title
        case summary
        case text
    }

    private var theme: ReadingTheme { .resolved(isDark: isDark) }
    private var palette: SettingsBarPalette { .resolved(isDark: isDark) }
    private var isEditing: Bool { focus != nil }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    if let transcript {
                        page(transcript)
                            .transition(.opacity)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                // The text runs on under the bar, and is never left behind it.
                .contentMargins(.bottom, 110, for: .scrollContent)
                // A tap on the page outside the fields closes the setting that is open.
                .simultaneousGesture(TapGesture().onEnded { closeBar() })

                NoteBar(
                    expanded: $expanded,
                    fontSize: $fontSize,
                    typeface: $typeface,
                    palette: palette,
                    maxWidth: proxy.size.width - 32,
                    onExport: openExport
                )
                .padding(.bottom, 12)
                // While typing, the keyboard has the foot of the screen: the bar steps down
                // behind it rather than riding up on it.
                .opacity(isEditing ? 0 : 1)
                .offset(y: isEditing && !reduceMotion ? 24 : 0)
                .allowsHitTesting(!isEditing)
                .animation(.spring(response: 0.36, dampingFraction: 0.9), value: isEditing)
                .ignoresSafeArea(.keyboard, edges: .bottom)
            }
        }
        .background(theme.paper.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isEditing {
                    Button(localized("Fet")) { focus = nil }
                        .fontWeight(.semibold)
                } else {
                    Menu {
                        Button {
                            copyText()
                        } label: {
                            Label(localized("Copia el text"), systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            confirmsDeletion = true
                        } label: {
                            Label(localized("Elimina"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "ellipsis")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel(localized("Més opcions"))
                }
            }
        }
        .onAppear {
            if transcript == nil { transcript = library.transcript(id) }
        }
        .onDisappear { library.flush() }
        .onChange(of: focus) { _, field in
            if field != nil { closeBar() }
        }
        .sensoryFeedback(.success, trigger: copied) { _, now in now }
        .confirmationDialog(
            localized("Vols eliminar aquesta transcripció?"),
            isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button(localized("Elimina"), role: .destructive) { delete() }
            Button(localized("Cancel·la"), role: .cancel) {}
        } message: {
            Text(localized("S'esborrarà d'aquest iPhone i no es podrà recuperar."))
        }
        .sheet(item: $exporting) { export in
            exportSheet(export)
        }
    }

    // MARK: The page

    private func page(_ transcript: SavedTranscript) -> some View {
        let listing = transcript.listing
        let size = PhoneMetrics.readingSize(CGFloat(fontSize), typeSize: typeSize)
        return VStack(alignment: .leading, spacing: 0) {
            Text(TranscriptDates.dateLine(transcript.createdAt))
                .font(.footnote.weight(.medium))
                .foregroundStyle(theme.ink.opacity(0.48))
                .padding(.bottom, 8)

            TextField(
                "",
                text: lineBinding(\.title, next: .summary),
                prompt: Text(listing.automaticTitle.isEmpty ? localized("Títol") : listing.automaticTitle)
                    .foregroundStyle(theme.ink.opacity(0.26)),
                axis: .vertical
            )
            .font(.system(.title, weight: .bold))
            .foregroundStyle(theme.ink)
            .lineLimit(1...4)
            .submitLabel(.next)
            .focused($focus, equals: .title)
            .accessibilityLabel(localized("Títol"))

            TextField(
                "",
                text: lineBinding(\.summary, next: .text),
                prompt: Text(localized("Afegeix una descripció")).foregroundStyle(theme.ink.opacity(0.3)),
                axis: .vertical
            )
            .font(.title3)
            .foregroundStyle(theme.ink.opacity(0.66))
            .lineLimit(1...3)
            .submitLabel(.next)
            .focused($focus, equals: .summary)
            .padding(.top, 6)
            .accessibilityLabel(localized("Descripció"))

            meta(listing)
                .padding(.top, 16)

            Rectangle()
                .fill(theme.ink.opacity(0.08))
                .frame(height: 1)
                .padding(.vertical, 22)

            TextField(
                "",
                text: Binding(
                    get: { self.transcript?.text ?? "" },
                    set: { text in edit { $0.text = text } }
                ),
                prompt: Text(localized("Sense text")).foregroundStyle(theme.ink.opacity(0.3)),
                axis: .vertical
            )
            .font(Font(typeface.font(ofSize: size) as CTFont))
            .tracking(-0.012 * size * typeface.trackingScale)
            .lineSpacing(size * 0.34)
            .foregroundStyle(theme.ink.opacity(0.9))
            .focused($focus, equals: .text)
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: fontSize)
            .accessibilityLabel(localized("Text de la transcripció"))
        }
        .tint(TranscriptLibrary.accent)
        .padding(.horizontal, 22)
        .padding(.top, 4)
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
            .font(.footnote.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(theme.ink.opacity(0.48))
            .contentTransition(.numericText())
            .animation(.easeOut(duration: 0.2), value: listing.wordCount)
    }

    /// A one-line field: Return goes on to the next field instead of breaking the line.
    private func lineBinding(_ path: WritableKeyPath<SavedTranscript, String>, next: Field) -> Binding<String> {
        Binding(
            get: { transcript?[keyPath: path] ?? "" },
            set: { value in
                guard value.contains(where: \.isNewline) else {
                    edit { $0[keyPath: path] = value }
                    return
                }
                let joined = value.split(whereSeparator: \.isNewline).joined(separator: " ")
                edit { $0[keyPath: path] = joined }
                // After the field has taken its text: moving the focus inside its update
                // left the next field with the caret while the view thought none had it.
                Task { @MainActor in focus = next }
            }
        )
    }

    private func edit(_ change: (inout SavedTranscript) -> Void) {
        guard var changed = transcript else { return }
        change(&changed)
        guard changed != transcript else { return }
        transcript = changed
        library.update(changed)
    }

    private func closeBar() {
        guard expanded != nil else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.22) : PhoneSettingsBar.motion) { expanded = nil }
    }

    private func copyText() {
        guard let transcript else { return }
        UIPasteboard.general.string = transcript.render(.text).trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeInOut(duration: 0.25)) { copied = false }
        }
    }

    /// Back to the list first, so the row is seen leaving.
    private func delete() {
        let id = self.id
        let library = self.library
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(TranscriptLibraryView.listMotion) { library.remove(id) }
        }
    }

    // MARK: Export

    private func openExport() {
        guard let transcript else { return }
        focus = nil
        exporting = NoteExport(transcript: transcript)
    }

    /// Fits its panel, like the reading screen's export sheet.
    @ViewBuilder
    private func exportSheet(_ export: NoteExport) -> some View {
        let panel = ExportPanel(
            session: export.session,
            palette: palette,
            typeface: typeface,
            storedFormat: $exportFormat,
            actions: [
                ExportAction(title: localized("Notes"), symbol: "note.text") { _ in
                    ShareSheet.present(items: [export.transcript.note])
                },
                ExportAction(title: localized("Envia"), symbol: "square.and.arrow.up", isPrimary: true) { format in
                    ShareSheet.presentFile(
                        named: export.transcript.filename(for: format),
                        contents: export.rendered(format)
                    )
                },
            ],
            footnote: localized("Amb AirDrop, el fitxer arriba a la carpeta Baixades del Mac."),
            render: export.rendered,
            drawsCard: false,
            onClose: { exporting = nil }
        )
        .preferredColorScheme(isDark ? .dark : .light)
        if typeSize.isAccessibilitySize {
            ScrollView { panel }
                .scrollBounceBehavior(.basedOnSize)
                .presentationDetents([.large])
                .presentationCornerRadius(28)
                .presentationBackground(palette.surface)
        } else {
            panel
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { exportHeight = $0 }
                .frame(maxHeight: .infinity, alignment: .top)
                .presentationDetents([.height(exportHeight)])
                .presentationCornerRadius(28)
                .presentationBackground(palette.surface)
        }
    }
}

// MARK: - The note's bar


/// The reading screen's bar, for one transcription: size and typeface open inside it the
/// same way, and Exporta, the bar's primary action, turns into the close button while
/// one of them is open.
struct NoteBar: View {
    @Binding var expanded: NoteBarItem?
    @Binding var fontSize: Double
    @Binding var typeface: ReadingTypeface
    let palette: SettingsBarPalette
    let maxWidth: CGFloat
    let onExport: () -> Void

    /// Smaller than the reading screen's: this text is read at arm's length, not across a room.
    static let sizes: ClosedRange<Double> = 14...34
    static let sizeStep: Double = 2
    static let defaultSize: Double = 20

    private static let knob: CGFloat = 38
    private static let wellPadding: CGFloat = 3
    private static let barPadding: CGFloat = 6
    private static let spacing: CGFloat = 6
    private static let openMinimumWidth: CGFloat = 340

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The interface language: its change re-renders the words below.
    @Environment(\.locale) private var locale
    @Namespace private var namespace
    @State private var closedWidth: CGFloat = 0

    private var openWidth: CGFloat {
        min(maxWidth, max(closedWidth, Self.openMinimumWidth))
    }

    var body: some View {
        HStack(spacing: 0) {
            slot(.size) {
                HStack(alignment: .lastTextBaseline, spacing: 0.5) {
                    Text(verbatim: "A").font(.system(size: 10, weight: .semibold))
                    Text(verbatim: "A").font(.system(size: 15, weight: .semibold))
                }
            }
            slot(.typeface) {
                Text(verbatim: "Aa")
                    .font(Font(typeface.font(ofSize: 17) as CTFont))
                    .contentTransition(.interpolate)
            }
            endWell
        }
        .padding(Self.barPadding)
        .frame(width: expanded == nil ? nil : openWidth, height: Self.knob + 2 * (Self.wellPadding + Self.barPadding))
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if expanded == nil { closedWidth = width }
        }
        .background {
            Capsule(style: .continuous)
                .fill(palette.surface)
                .overlay(Capsule(style: .continuous).strokeBorder(palette.hairline))
                .shadow(color: palette.shadow, radius: 18, y: 8)
                .shadow(color: palette.shadow.opacity(0.5), radius: 2, y: 1)
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    private var fadeMotion: Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        return expanded == nil ? .easeOut(duration: 0.22).delay(0.08) : .easeOut(duration: 0.1)
    }

    private func slot<Glyph: View>(_ item: NoteBarItem, @ViewBuilder glyph: () -> Glyph) -> some View {
        let isOpen = expanded == item
        let isGone = expanded != nil && !isOpen
        return ZStack {
            glyph()
                .foregroundStyle(palette.ink.opacity(0.62))
                .frame(width: Self.knob, height: Self.knob)
                .padding(Self.wellPadding)
                .contentShape(Circle())
                .modifier(TouchDownAction(label: item.title, symbol: item == .size ? "textformat.size" : "textformat") {
                    open(item)
                })
                .fixedSize()
                .animation(fadeMotion) { glyph in
                    glyph
                        .opacity(expanded == nil ? 1 : 0)
                        .scaleEffect(expanded == nil || reduceMotion ? 1 : 0.7)
                        .blur(radius: expanded == nil || reduceMotion ? 0 : 2)
                }
                .allowsHitTesting(expanded == nil)
                .accessibilityHidden(expanded != nil)

            if isOpen {
                Group {
                    switch item {
                    case .size: sizeControl
                    case .typeface: typefaceControl
                    }
                }
                .padding(Self.wellPadding)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(item.title)
                .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: 0.12))))
            }
        }
        .frame(width: isGone ? 0 : nil, height: Self.knob + 2 * Self.wellPadding)
        .frame(maxWidth: isOpen ? .infinity : nil)
        .background(Capsule(style: .continuous).fill(palette.well))
        .clipShape(Capsule(style: .continuous))
        .animation(fadeMotion) { well in
            well
                .opacity(isGone ? 0 : 1)
                .scaleEffect(isGone && !reduceMotion ? 0.7 : 1)
        }
        .padding(.trailing, isGone ? 0 : Self.spacing)
        .allowsHitTesting(!isGone)
        .accessibilityHidden(isGone)
    }

    /// Exporta while the bar is closed; the close button while a setting is open.
    private var endWell: some View {
        let isOpen = expanded != nil
        return Button {
            if !isOpen { onExport() }
        } label: {
            ZStack {
                if !isOpen {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                        Text(localized("Exporta"))
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(palette.surface)
                    .fixedSize()
                    .padding(.horizontal, 14)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(fadeMotion),
                        removal: .opacity.animation(.easeOut(duration: 0.1))
                    ))
                }
                ZStack {
                    Circle()
                        .fill(palette.knob)
                        .shadow(color: palette.shadow, radius: 4, y: 1)
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(palette.ink)
                        .rotationEffect(.degrees(isOpen || reduceMotion ? 0 : -90))
                }
                .frame(width: Self.knob, height: Self.knob)
                .opacity(isOpen ? 1 : 0)
                .scaleEffect(isOpen || reduceMotion ? 1 : 0.6)
            }
            .frame(width: isOpen ? Self.knob : nil, height: Self.knob)
            .padding(Self.wellPadding)
            .background(Capsule(style: .continuous).fill(isOpen ? palette.well : palette.ink))
            .clipShape(Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .overlay {
            if isOpen {
                Capsule()
                    .fill(Color.clear)
                    .contentShape(Capsule())
                    .modifier(TouchDownAction(label: expanded?.closeTitle ?? localized("Tanca"), inputLabels: [localized("Tanca")], symbol: "xmark") {
                        close()
                    })
            }
        }
        .accessibilityShowsLargeContentViewer {
            Label(isOpen ? localized("Tanca") : localized("Exporta"), systemImage: isOpen ? "xmark" : "square.and.arrow.up")
        }
        .accessibilityLabel(isOpen ? (expanded?.closeTitle ?? localized("Tanca")) : localized("Exporta el text"))
        .accessibilityInputLabels(isOpen ? [localized("Tanca")] : [localized("Exporta"), localized("Comparteix")])
    }

    private func open(_ item: NoteBarItem) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.22) : PhoneSettingsBar.motion) { expanded = item }
    }

    private func close() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.22) : PhoneSettingsBar.motion) { expanded = nil }
    }

    private var sizeControl: some View {
        HStack(spacing: 2) {
            stepButton(glyphSize: 12, delta: -1, label: localized("Redueix la mida del text"))
                .modifier(BarEntrance(index: 0))
            PhoneSizeTrack(value: $fontSize, palette: palette, range: Self.sizes, step: Self.sizeStep)
                .modifier(BarEntrance(index: 1))
            stepButton(glyphSize: 19, delta: 1, label: localized("Augmenta la mida del text"))
                .modifier(BarEntrance(index: 2))
        }
    }

    private func stepButton(glyphSize: CGFloat, delta: Int, label: String) -> some View {
        Button {
            let next = min(Self.sizes.upperBound, max(Self.sizes.lowerBound, fontSize + Self.sizeStep * Double(delta)))
            guard next != fontSize else {
                DetentHaptics.shared.boundary()
                return
            }
            withAnimation(PhoneSettingsBar.selection) { fontSize = next }
            DetentHaptics.shared.detent(fraction: PhoneSizeTrack.fraction(of: next, in: Self.sizes))
        } label: {
            Text(verbatim: "A")
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(palette.ink.opacity(0.72))
                .frame(width: 40, height: Self.knob)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .largeContent(label, symbol: delta > 0 ? "plus" : "minus")
        .accessibilityLabel(label)
    }

    private var typefaceControl: some View {
        HStack(spacing: 2) {
            ForEach(Array(ReadingTypeface.allCases.enumerated()), id: \.element) { index, face in
                let isCurrent = typeface == face
                Button {
                    withAnimation(PhoneSettingsBar.selection) { typeface = face }
                } label: {
                    VStack(spacing: 0) {
                        Text(verbatim: "Ag")
                            .font(Font(face.font(ofSize: 16) as CTFont))
                        Text(face.displayName)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(isCurrent ? palette.ink : palette.ink.opacity(0.64))
                    .padding(.horizontal, 3)
                    .frame(maxWidth: .infinity, minHeight: Self.knob)
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
                .largeContent(face.displayName, symbol: "textformat")
                .accessibilityLabel(face.fullName)
                .accessibilityHint(face.rationale)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .modifier(BarEntrance(index: index))
            }
        }
        .sensoryFeedback(.selection, trigger: typeface)
    }
}
