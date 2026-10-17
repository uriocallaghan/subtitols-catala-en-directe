import SubtitolCore
import SwiftUI

/// Choosing, downloading and removing languages.
///
/// First run: the app has no language yet, so this is the whole screen. It proposes the
/// phone's own language, shows the exact size before anything is downloaded, and waits
/// for a tap (App Review Guideline 4.2.3). From the settings it opens as a sheet where
/// languages can be added, chosen and removed.
///
/// Every language is its own card, flat colours only: its geometric mark in a rounded
/// frame, its name, the space it takes, and one capsule that says and does what comes
/// next ("En ús", "Tria", "Baixa" filling with the download, "Esborra" while editing).
/// Above it all, `GreetingLettering` writes each language's greeting, and four promises
/// sit under the title.
struct LanguageSetupView: View {
    enum Mode {
        case firstRun
        case manage
    }

    let mode: Mode
    @EnvironmentObject private var packs: LanguagePackStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The interface language: its change re-renders the words below.
    @Environment(\.locale) private var locale
    @State private var pendingRemoval: SpeechLanguage?
    @State private var isEditing = false
    /// The order the list opened with. Rows keep their places while the sheet is open:
    /// a row jumping past another as its download finished crossed their text.
    @State private var openingOrder: [String]?

    private var theme: ReadingTheme { scheme == .dark ? .dark : .light }
    private var palette: SettingsBarPalette { .resolved(isDark: scheme == .dark) }
    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.42, dampingFraction: 0.86)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                (mode == .firstRun ? theme.paper : Color.clear).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if mode == .firstRun {
                            // The same orb, in the same place, as on the reading screen, so
                            // finishing the download only changes what is below it.
                            SedaOrbView(voiceLevel: { 0 }, isListening: false, background: theme.paper)
                                .frame(height: PhoneMetrics.orbHeight(in: proxy))
                                .padding(.horizontal, -20)
                                .accessibilityHidden(true)
                        }
                        if mode == .manage {
                            GreetingLettering(languageIDs: greetingOrder)
                                .frame(height: 80)
                                .frame(maxWidth: .infinity)
                                // Air all round, so the lettering reads as the page's picture.
                                .padding(.top, 44)
                                .padding(.bottom, 56)
                                .modifier(StaggeredEntrance(index: 0))
                        }
                        header
                            .modifier(StaggeredEntrance(index: 0))
                            .padding(.bottom, 28)
                        listTitle
                            .modifier(StaggeredEntrance(index: 1))
                            .padding(.bottom, 10)
                        list
                            .padding(.bottom, 18)
                        footnote
                            .modifier(StaggeredEntrance(index: 2 + stableOrder.count))
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, mode == .firstRun ? 0 : 30)
                    .padding(.bottom, 36)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            }
            .overlay(alignment: .topTrailing) {
                if mode == .manage {
                    closeButton
                        .padding(.top, 14)
                        .padding(.trailing, 14)
                }
            }
        }
        .task { await packs.refreshSizes() }
        .onAppear { if openingOrder == nil { openingOrder = ordered.map(\.id) } }
        .onChange(of: removableCount) { _, count in
            // Nothing left to delete: leave editing on its own.
            if count == 0 { withAnimation(motion) { isEditing = false } }
        }
        .confirmationDialog(
            pendingRemoval.map { localized("Vols esborrar l'idioma \(LanguageLabels.localName(of: $0)) d'aquest iPhone?") } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            if let language = pendingRemoval {
                Button(localized("Esborra"), role: .destructive) {
                    Task { await packs.remove(language) }
                }
            }
        } message: {
            if let language = pendingRemoval {
                Text(removalMessage(for: language))
            }
        }
        .sensoryFeedback(.success, trigger: installedCount) { old, new in new > old }
        .sensoryFeedback(.selection, trigger: packs.selectedLanguageID)
        .sensoryFeedback(.selection, trigger: isEditing)
    }

    private func removalMessage(for language: SpeechLanguage) -> String {
        let size = LanguageRow.formattedSize(packs.downloadSize(of: language))
        if packs.selectedLanguageID == language.id {
            return localized("Allibera \(size). És l'idioma que fas servir ara. Es pot tornar a baixar quan vulguis.")
        }
        return localized("Allibera \(size). Es pot tornar a baixar quan vulguis.")
    }

    /// Choosing a language, or touching the one in use, closes the sheet once the card
    /// has shown it: the reader asked for this language, so the next thing is reading.
    private func choose(_ language: SpeechLanguage) {
        let wasSelected = packs.selectedLanguageID == language.id
        withAnimation(motion) { packs.select(language) }
        guard mode == .manage else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(wasSelected ? 120 : 420))
            dismiss()
        }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.ink.opacity(0.7))
                .frame(width: 32, height: 32)
                .background(Circle().fill(palette.well))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(localized("Tanca"))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mode == .firstRun ? localized("Tria l'idioma\nque vols llegir") : localized("Idiomes"))
                .font(.custom(AppVisualMetrics.readingFontName, size: mode == .firstRun ? 34 : 30, relativeTo: .largeTitle))
                .tracking(-0.9)
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            // Four cards across; at the largest text sizes, one promise per line.
            featureLayout {
                feature("lock", localized("Privat\nper disseny"))
                feature("airplane", localized("Sense\nconnexió"))
                feature("waveform", localized("En\ndirecte"))
                feature("accessibility", localized("Adaptat per\naccessibilitat"))
            }
            // The cards share the tallest one's height.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 18)
        }
        .accessibilityElement(children: .combine)
    }

    /// One of the four promises under the title (private, offline, live, accessible):
    /// a plain glyph in ink over two short lines, on its own light grey card.
    /// Four cards across hold "accessibilitat" up to Extra Large; from the next size up
    /// the word would break in the middle, so the promises go one per line.
    private var listsFeatures: Bool { typeSize >= .xxLarge }

    private var featureLayout: AnyLayout {
        listsFeatures
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 6))
    }

    @ViewBuilder
    private func feature(_ symbol: String, _ text: String) -> some View {
        if listsFeatures {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(.title3))
                    .foregroundStyle(theme.ink)
                Text(text.replacingOccurrences(of: "\n", with: " "))
                    .font(.inter(13, relativeTo: .caption))
                    .foregroundStyle(theme.ink.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.well))
        } else {
            compactFeature(symbol, text)
        }
    }

    private func compactFeature(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(theme.ink)
                .frame(height: 24)
            Text(text)
                .font(.inter(13, relativeTo: .caption))
                .tracking(-0.1)
                .foregroundStyle(theme.ink.opacity(0.72))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.85)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.vertical, 14)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.well))
    }

    private var listTitle: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(localized("IDIOMES"))
                .font(.inter(11, relativeTo: .caption2))
                .tracking(1.2)
                .foregroundStyle(theme.ink.opacity(0.5))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if removableCount > 0 {
                Button {
                    withAnimation(motion) { isEditing.toggle() }
                } label: {
                    Text(isEditing ? localized("Fet") : localized("Edita"))
                        .font(.inter(15, relativeTo: .subheadline))
                        .foregroundStyle(palette.ink)
                        .contentTransition(.interpolate)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 32)
                        .background(Capsule().fill(isEditing ? palette.well : Color.clear))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityHint(isEditing ? localized("Acaba d'esborrar") : localized("Per esborrar idiomes d'aquest iPhone"))
                .transition(.opacity)
            }
        }
        .padding(.leading, 6)
        .frame(minHeight: 44)
    }

    /// The catalogue's own order, which leads with the minority languages the app is
    /// for (Catalan, Galician, Basque) and ends with Spanish and English. It does not
    /// follow the choice or the downloads, so every language keeps its place.
    private var ordered: [SpeechLanguage] {
        packs.catalog.languages
    }

    private var stableOrder: [SpeechLanguage] {
        guard let openingOrder else { return ordered }
        let rank = Dictionary(uniqueKeysWithValues: openingOrder.enumerated().map { ($1, $0) })
        return packs.catalog.languages.sorted {
            rank[$0.id, default: Int.max] < rank[$1.id, default: Int.max]
        }
    }

    /// The greetings start with the language in use, then follow the catalogue.
    private var greetingOrder: [String] {
        let ids = packs.catalog.languages.map(\.id)
        guard let selected = packs.selectedLanguageID, let start = ids.firstIndex(of: selected) else { return ids }
        return Array(ids[start...] + ids[..<start])
    }

    private var installedCount: Int {
        packs.catalog.languages.filter { packs.state(of: $0) == .installed }.count
    }

    /// Downloaded languages, which can be deleted; the one inside the app cannot.
    private var removableCount: Int {
        packs.catalog.languages.filter(packs.isRemovable).count
    }

    private var list: some View {
        let languages = stableOrder
        return VStack(spacing: 6) {
            ForEach(Array(languages.enumerated()), id: \.element.id) { index, language in
                LanguageRow(
                    language: language,
                    state: packs.state(of: language),
                    isSelected: packs.selectedLanguageID == language.id,
                    isSuggested: packs.suggestedLanguage?.id == language.id,
                    isEditing: isEditing,
                    isBundled: packs.isBundled(language),
                    size: packs.downloadSize(of: language),
                    theme: theme,
                    palette: palette,
                    onInstall: { Task { await packs.install(language) } },
                    onSelect: { choose(language) },
                    onRemove: { pendingRemoval = language }
                )
                .modifier(StaggeredEntrance(index: 2 + index))
            }
        }
    }

    private var footnote: some View {
        Text(localized("La transcripció automàtica pot tenir errors. No substitueix un servei professional de subtitulació ni cap aparell auditiu."))
            .font(.inter(12, relativeTo: .caption))
            .foregroundStyle(theme.ink.opacity(0.62))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
    }
}

// MARK: - Row

/// One language as its own card: its mark in a rounded frame, its name with the space it
/// takes, and one capsule on the right that says and does what comes next (in use,
/// choose, download with its progress, or delete while editing). The language in use
/// is outlined in ink.
private struct LanguageRow: View {
    let language: SpeechLanguage
    let state: LanguagePackStore.PackState
    let isSelected: Bool
    let isSuggested: Bool
    let isEditing: Bool
    /// Came with the app: no size to show, nothing to delete.
    let isBundled: Bool
    let size: Int64
    let theme: ReadingTheme
    let palette: SettingsBarPalette
    let onInstall: () -> Void
    let onSelect: () -> Void
    let onRemove: () -> Void

    private static let deleteRed = Color(red: 0.86, green: 0.22, blue: 0.14)
    private static let orange = LanguageCircle.orange

    private var isInstalled: Bool { state == .installed }
    private var isRemovable: Bool { isInstalled && !isBundled }
    /// While editing, only what can be deleted stays at full strength.
    private var isDimmed: Bool { isEditing && !isRemovable }

    @Environment(\.dynamicTypeSize) private var typeSize
    /// The interface language: its change re-renders the words below.
    @Environment(\.locale) private var locale

    /// Mark, name and capsule in one row; at the largest text sizes, one under the other,
    /// so the name is never cut.
    private var rowLayout: AnyLayout {
        typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 14))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        rowLayout {
            LanguageCircle(languageID: language.id, look: circleLook, palette: palette)
                .frame(width: 24, height: 24)
                .frame(width: 46, height: 46)
                .background {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(isSelected ? Self.orange.opacity(palette.isDark ? 0.16 : 0.09) : palette.well)
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(language.name)
                        .font(.inter(18, relativeTo: .headline))
                        .tracking(-0.3)
                        .foregroundStyle(theme.ink)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    if language.stage == .beta {
                        BetaBadge(text: localized("Nou"), palette: palette)
                    }
                }
                Text(detail)
                    .font(.inter(13, relativeTo: .footnote).monospacedDigit())
                    .foregroundStyle(isFailure ? Color(red: 0.78, green: 0.2, blue: 0.1) : theme.ink.opacity(0.56))
                    .contentTransition(.numericText())
                    .lineLimit(typeSize.isAccessibilitySize || isFailure ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            capsule
        }
        .padding(12)
        .padding(.trailing, 2)
        .background {
            shape.fill(palette.surface)
        }
        .overlay {
            shape.strokeBorder(isSelected ? palette.ink : palette.hairline, lineWidth: isSelected ? 1.5 : 1)
        }
        .opacity(isDimmed ? 0.4 : 1)
        .contentShape(shape)
        .onTapGesture { rowTapped() }
        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: state)
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: isSelected)
        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: isEditing)
        .contextMenu {
            if isRemovable {
                Button(localized("Esborra de l'iPhone"), systemImage: "trash", role: .destructive, action: onRemove)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityName)
        .accessibilityInputLabels(spokenNames)
        .accessibilityValue(detail)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(accessibilityHint)
        .accessibilityAction(named: localized("Esborra")) { if isRemovable { onRemove() } }
    }

    private var circleLook: LanguageCircle.Look {
        switch state {
        case .installed: return isSelected ? .active : .installed
        case .downloading(let fraction): return .downloading(fraction)
        case .notInstalled, .failed: return .available
        }
    }

    private enum CapsuleKind: Equatable {
        case inUse, choose, download, retry, progress(Double), delete
    }

    private var kind: CapsuleKind {
        if isEditing && isRemovable { return .delete }
        switch state {
        case .installed: return isSelected ? .inUse : .choose
        case .downloading(let fraction): return .progress(fraction)
        case .notInstalled: return .download
        case .failed: return .retry
        }
    }

    /// The one control on the right. Every state is the same capsule, so changing state
    /// morphs it in place instead of swapping a radio for a ring for a button.
    private var capsule: some View {
        let kind = kind
        let label: String
        var symbol: String?
        var fill: Color = palette.well
        var ink: Color = palette.ink
        var stroke: Color = .clear
        switch kind {
        case .inUse:
            label = localized("En ús"); symbol = "checkmark"; fill = palette.ink; ink = palette.surface
        case .choose:
            label = localized("Tria"); fill = .clear; stroke = palette.ink.opacity(0.22)
        case .download:
            label = localized("Baixa"); symbol = "arrow.down"
        case .retry:
            label = localized("Reprova"); symbol = "arrow.clockwise"
        case .progress(let fraction):
            label = localized("\(Int((fraction * 100).rounded())) %")
        case .delete:
            label = localized("Esborra"); fill = Self.deleteRed.opacity(palette.isDark ? 0.2 : 0.1); ink = Self.deleteRed
        }
        return Button {
            switch kind {
            case .choose: onSelect()
            case .download, .retry: onInstall()
            case .delete: onRemove()
            case .inUse: onSelect()
            case .progress: break
            }
        } label: {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .scaledFont(size: 11, weight: .bold, relativeTo: .subheadline)
                        .transition(.opacity)
                }
                Text(label)
                    .font(.inter(15, relativeTo: .subheadline).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 14)
            .frame(minWidth: 76, minHeight: 36)
            .background {
                ZStack(alignment: .leading) {
                    Capsule().fill(fill)
                    if case .progress(let fraction) = kind {
                        // The download fills the capsule from the left.
                        GeometryReader { proxy in
                            Capsule()
                                .fill(Self.orange.opacity(0.28))
                                .frame(width: max(proxy.size.height, proxy.size.width * fraction))
                                .animation(.easeOut(duration: 0.25), value: fraction)
                        }
                        .clipShape(Capsule())
                    }
                    Capsule().strokeBorder(stroke, lineWidth: 1)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isDimmed)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: kind)
        .accessibilityLabel(label)
    }

    private func rowTapped() {
        if isEditing {
            if isRemovable { onRemove() }
            return
        }
        switch state {
        case .installed: onSelect()
        case .notInstalled, .failed: onInstall()
        default: break
        }
    }

    private var isFailure: Bool {
        if case .failed = state { return true }
        return false
    }

    private var accessibilityName: String {
        var parts = [language.name]
        if let local = LanguageLabels.localNameIfDifferent(of: language) { parts.append(local) }
        if language.stage == .beta { parts.append(localized("nou")) }
        return parts.joined(separator: ", ")
    }

    /// What Voice Control answers to: the name as shown, and in the interface language.
    private var spokenNames: [String] {
        var names = [language.name]
        if let local = LanguageLabels.localNameIfDifferent(of: language) { names.append(local) }
        names.append(accessibilityName)
        return names
    }

    private var accessibilityHint: String {
        if isEditing { return isRemovable ? localized("Esborra'l d'aquest iPhone") : "" }
        switch state {
        case .installed: return isSelected ? localized("Torna a la lectura") : localized("Fes-lo servir i torna a la lectura")
        case .downloading: return ""
        case .notInstalled, .failed: return localized("Baixa \(Self.formattedSize(size))")
        }
    }

    /// Under the name: the language in the interface language and the space it takes,
    /// or what is wrong.
    private var detail: String {
        if case .failed(let message) = state { return message }
        var parts: [String] = []
        if let local = LanguageLabels.localNameIfDifferent(of: language) {
            parts.append(local.prefix(1).uppercased() + local.dropFirst())
        }
        parts.append(isBundled ? localized("Inclòs amb l'app") : Self.formattedSize(size))
        return parts.joined(separator: " · ")
    }

    static func formattedSize(_ bytes: Int64) -> String {
        // In the interface language ("193,7 MB", "193.7 MB"), not the phone's region.
        bytes.formatted(.byteCount(style: .file, allowedUnits: [.mb, .gb]).locale(InterfaceLanguage.locale))
    }
}

/// Each language's name in the interface language, for the line under its own name.
enum LanguageLabels {
    private static func name(for id: String) -> String? {
        switch id {
        case "ca": localized("català")
        case "es": localized("castellà")
        case "en": localized("anglès")
        case "gl": localized("gallec")
        case "eu": localized("basc")
        case "fr": localized("francès")
        case "pt": localized("portuguès")
        case "it": localized("italià")
        case "de": localized("alemany")
        case "oc": localized("occità")
        default: nil
        }
    }

    static func localName(of language: SpeechLanguage) -> String {
        name(for: language.id) ?? language.name
    }

    /// Nil when the interface's name for it is its own (Catalan in Catalan).
    static func localNameIfDifferent(of language: SpeechLanguage) -> String? {
        guard let name = name(for: language.id),
              name.compare(language.name, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame else {
            return nil
        }
        return name
    }
}

// MARK: - Pieces

/// Download progress as a thin orange ring.
private struct ProgressRing: View {
    let fraction: Double
    let track: Color

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(LanguageCircle.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: fraction)
        }
        .accessibilityLabel(localized("Baixant"))
        .accessibilityValue(localized("\(Int(fraction * 100)) per cent"))
    }
}

/// The sheet's pieces arrive one after another, rising and sharpening as they land.
/// Under Reduce Motion they only fade in.
struct StaggeredEntrance: ViewModifier {
    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown || reduceMotion ? 0 : 16)
            .blur(radius: isShown || reduceMotion ? 0 : 5)
            .onAppear {
                guard !isShown else { return }
                let animation = reduceMotion
                    ? Animation.easeOut(duration: 0.25)
                    : .spring(response: 0.55, dampingFraction: 0.86).delay(0.05 + Double(min(index, 10)) * 0.05)
                withAnimation(animation) { isShown = true }
            }
    }
}
