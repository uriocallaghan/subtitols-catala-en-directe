import SubtitolCore
import SwiftUI

enum PhoneBarItem: Hashable {
    case profile
    case size
    case typeface
    case display

    var title: String {
        switch self {
        case .profile: localized("Fiabilitat")
        case .size: localized("Mida del text")
        case .typeface: localized("Tipografia")
        case .display: localized("Visualització")
        }
    }

    /// "Tanca …", for the close button while this setting is open.
    var closeTitle: String {
        switch self {
        case .profile: localized("Tanca la fiabilitat")
        case .size: localized("Tanca la mida del text")
        case .typeface: localized("Tanca la tipografia")
        case .display: localized("Tanca la visualització")
        }
    }

    /// What Voice Control answers to, besides the title.
    var spokenNames: [String] {
        switch self {
        case .profile: [localized("Fiabilitat"), localized("Perfil")]
        case .size: [localized("Mida"), localized("Mida del text")]
        case .typeface: [localized("Tipografia"), localized("Lletra")]
        case .display: [localized("Visualització"), localized("Configuració"), localized("Ajustos")]
        }
    }
}

/// The floating bar of the "Versió final" design.
///
/// Everything happens inside the bar, as on the Mac. The bar is one row whose wells never
/// leave the layout: tapping a setting grows its own well until it fills the bar, the
/// other wells shrink to nothing where they stand, and the record button turns into the
/// close button in place. The control is revealed by its growing well, piece by piece.
/// One spring drives all of it, and the first frame is exactly the closed bar, so
/// nothing appears or jumps. Paddings are the same in both states: 6 around the row,
/// 6 between wells, 3 inside each well around 38 pt knobs.
struct PhoneSettingsBar: View {
    @ObservedObject var controller: SubtitleController
    @Binding var expanded: PhoneBarItem?
    @Binding var fontSize: Double
    @Binding var typeface: ReadingTypeface
    @Binding var theme: PhoneTheme
    @Binding var prefersAgeGradient: Bool
    @Binding var showsOrb: Bool
    let languageName: String
    let languageIsBeta: Bool
    let themeDarkness: Double
    let maxWidth: CGFloat
    let onLanguages: () -> Void
    let onMicrophone: () -> Void
    let onVocabulary: () -> Void
    let onAbout: () -> Void
    /// After a stop, the bar's choices for the session on screen; nil the rest of the time.
    var sessionActions: SessionActions?

    static let motion = Animation.spring(response: 0.36, dampingFraction: 0.86)
    static let selection = Animation.spring(response: 0.26, dampingFraction: 0.82)
    private static let knob: CGFloat = 38
    private static let wellPadding: CGFloat = 3
    private static let barPadding: CGFloat = 6
    private static let spacing: CGFloat = 6
    /// The open bar is at least this wide, so three profiles or four typefaces fit.
    private static let openMinimumWidth: CGFloat = 340

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The interface language: its change re-renders the words below.
    @Environment(\.locale) private var locale
    @Namespace private var namespace
    /// Descarta asks first, from the button itself.
    @State private var confirmsDiscard = false
    /// The closed bar's natural width, read while it is closed.
    @State private var closedWidth: CGFloat = 0

    private var palette: SettingsBarPalette { .blended(darkness: themeDarkness) }

    private var openWidth: CGFloat {
        min(maxWidth, max(closedWidth, Self.openMinimumWidth))
    }

    /// The stopped session's choices are showing in place of the settings.
    private var showsActions: Bool { sessionActions != nil }

    /// Nothing open and no session waiting: the bar's own glyphs are showing.
    private var isIdle: Bool { expanded == nil && !showsActions }

    var body: some View {
        HStack(spacing: 0) {
            slot(.profile) { profileLabel }
            slot(.size) { toolGlyph { sizeGlyph } }
            slot(.typeface) {
                toolGlyph {
                    Text(verbatim: "Aa")
                        .font(Font(typeface.font(ofSize: 17) as CTFont))
                        .contentTransition(.interpolate)
                }
            }
            slot(.display) {
                toolGlyph {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            actionWell(.discard)
            actionWell(.export)
            endWell
        }
        .padding(Self.barPadding)
        .frame(width: isIdle ? nil : openWidth, height: Self.knob + 2 * (Self.wellPadding + Self.barPadding))
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if isIdle { closedWidth = width }
        }
        .background { surface }
        // The bar has to fit across the phone at any text size.
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    private var surface: some View {
        Capsule(style: .continuous)
            .fill(palette.surface)
            .overlay(Capsule(style: .continuous).strokeBorder(palette.hairline))
            .shadow(color: palette.shadow, radius: 18, y: 8)
            .shadow(color: palette.shadow.opacity(0.5), radius: 2, y: 1)
    }

    // MARK: - Wells

    /// One setting's well. Closed it shows `glyph`; open it grows to fill the bar and
    /// shows the setting's control; while another setting is open it shrinks to nothing.
    private func slot<Glyph: View>(_ item: PhoneBarItem, @ViewBuilder glyph: () -> Glyph) -> some View {
        let isOpen = expanded == item
        let isGone = (expanded != nil && !isOpen) || showsActions
        return ZStack {
            glyph()
                .modifier(TouchDownAction(
                    label: item == .profile
                        ? localized("Fiabilitat: \(controller.transcriptionProfile.displayName)")
                        : item.title,
                    inputLabels: item == .profile
                        ? item.spokenNames + [controller.transcriptionProfile.displayName]
                        : item.spokenNames,
                    symbol: symbol(for: item)
                ) { open(item) })
                // The glyph keeps its own size whatever its well does, so no label is
                // ever squeezed or truncated on the way.
                .fixedSize()
                // It leaves at once and comes back once the control has gone.
                .animation(fadeMotion) { glyph in
                    glyph
                        .opacity(isIdle ? 1 : 0)
                        .scaleEffect(isIdle || reduceMotion ? 1 : 0.7)
                        .blur(radius: isIdle || reduceMotion ? 0 : 2)
                }
                .allowsHitTesting(isIdle)
                .accessibilityHidden(!isIdle)

            if isOpen {
                control(for: item)
                    .padding(Self.wellPadding)
                    .transition(.asymmetric(
                        insertion: .identity,
                        removal: .opacity.animation(.easeOut(duration: 0.12))
                    ))
            }
        }
        // Every well is exactly one knob plus its padding tall, open or closed, so no
        // control can make the bar taller.
        .frame(width: isGone ? 0 : nil, height: Self.knob + 2 * Self.wellPadding)
        .frame(maxWidth: isOpen ? .infinity : nil)
        .background(Capsule(style: .continuous).fill(palette.well))
        // The growing well reveals its control rather than the control spilling past it.
        .clipShape(Capsule(style: .continuous))
        // The width follows the bar's spring; the fading is quicker, so a closing well is
        // gone before it is a sliver.
        .animation(fadeMotion) { well in
            well
                .opacity(isGone ? 0 : 1)
                .scaleEffect(isGone && !reduceMotion ? 0.7 : 1)
        }
        .padding(.trailing, isGone ? 0 : Self.spacing)
        .allowsHitTesting(!isGone)
        .accessibilityHidden(isGone)
    }

    /// The glyph the large content viewer shows for a well: the bar keeps its size at the
    /// largest text sizes, so a long press shows each control large instead.
    private func symbol(for item: PhoneBarItem) -> String {
        switch item {
        case .profile: controller.transcriptionProfile.symbolName
        case .size: "textformat.size"
        case .typeface: "textformat"
        case .display: "gearshape.fill"
        }
    }

    /// Fades out fast, fades back in just after the wells have started to reopen.
    private var fadeMotion: Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        return isIdle
            ? .easeOut(duration: 0.22).delay(0.08)
            : .easeOut(duration: 0.1)
    }

    private var profileLabel: some View {
        HStack(spacing: 5) {
            Text(controller.transcriptionProfile.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.ink.opacity(0.78))
                .contentTransition(.interpolate)
                .padding(.leading, 12)
            Image(systemName: controller.transcriptionProfile.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.ink.opacity(0.62))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Self.knob, height: Self.knob)
        }
        .padding(Self.wellPadding)
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized("Fiabilitat: \(controller.transcriptionProfile.displayName)"))
    }

    private func toolGlyph<Glyph: View>(@ViewBuilder _ glyph: () -> Glyph) -> some View {
        glyph()
            .foregroundStyle(palette.ink.opacity(0.62))
            .frame(width: Self.knob, height: Self.knob)
            .padding(Self.wellPadding)
            .contentShape(Circle())
    }

    private var sizeGlyph: some View {
        HStack(alignment: .lastTextBaseline, spacing: 0.5) {
            Text(verbatim: "A").font(.system(size: 10, weight: .semibold))
            Text(verbatim: "A").font(.system(size: 15, weight: .semibold))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PhoneBarItem.size.title)
    }

    /// Record while the bar is closed, close while a setting is open, Desa after a stop:
    /// the same well, so the way out is where the thumb already is. For Desa it stretches
    /// to its share of the bar and fills with ink, the bar's one primary action.
    private var endWell: some View {
        let isOpen = expanded != nil
        let isSave = showsActions
        return Button {
            if isSave {
                sessionActions?.save()
            } else if !isOpen {
                controller.toggleRecording()
            }
        } label: {
            ZStack {
                RecordGlyph(
                    isRecording: controller.isRecording,
                    isBusy: !controller.canToggle,
                    palette: palette
                )
                .frame(width: Self.knob, height: Self.knob)
                .opacity(isOpen || isSave ? 0 : 1)
                .scaleEffect((isOpen || isSave) && !reduceMotion ? 0.6 : 1)
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
                if isSave {
                    actionLabel(.save, ink: palette.surface)
                        .modifier(BarEntrance(index: 2))
                        .transition(.asymmetric(
                            insertion: .identity,
                            removal: .opacity.animation(.easeOut(duration: 0.12))
                        ))
                }
            }
            .frame(width: isSave ? nil : Self.knob, height: Self.knob)
            .frame(maxWidth: isSave ? .infinity : nil)
            .padding(Self.wellPadding)
            .background(Capsule(style: .continuous).fill(isSave ? palette.ink : palette.well))
            .clipShape(Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        // While a setting is open the well closes it as the finger lands. The layer
        // takes the whole touch, so lifting the finger cannot also start recording.
        .overlay {
            if isOpen {
                Circle()
                    .fill(Color.clear)
                    .contentShape(Circle())
                    .modifier(TouchDownAction(label: endWellLabel, inputLabels: [localized("Tanca")], symbol: "xmark") { close() })
            }
        }
        .disabled(!isOpen && !isSave && !controller.canToggle)
        .sensoryFeedback(.impact(weight: .medium), trigger: controller.isRecording)
        .accessibilityShowsLargeContentViewer {
            Label(endWellLabel, systemImage: isSave
                ? SessionAction.save.symbol
                : (isOpen ? "xmark" : (controller.isRecording ? "stop.fill" : "record.circle")))
        }
        .accessibilityLabel(endWellLabel)
        .accessibilityInputLabels(endWellSpokenNames)
    }

    private var endWellSpokenNames: [String] {
        if showsActions { return SessionAction.save.spokenNames }
        if expanded != nil { return [localized("Tanca"), endWellLabel] }
        return controller.isRecording
            ? [localized("Atura"), localized("Para")]
            : [localized("Comença"), localized("Grava"), localized("Comença a transcriure")]
    }

    private var endWellLabel: String {
        if showsActions { return SessionAction.save.accessibilityLabel }
        if let expanded { return expanded.closeTitle }
        guard controller.canToggle else { return controller.detail }
        return controller.isRecording ? localized("Atura") : localized("Comença a transcriure")
    }

    // MARK: - After a stop

    /// Descarta and Exporta: wells that grow out of nothing where the settings were, as a
    /// setting's well grows, while the record well becomes Desa beside them.
    private func actionWell(_ action: SessionAction) -> some View {
        let isShown = showsActions
        return ZStack {
            if isShown {
                Button {
                    switch action {
                    case .discard:
                        sessionActions?.consideringDiscard(true)
                        confirmsDiscard = true
                    case .export: sessionActions?.export()
                    case .save: sessionActions?.save()
                    }
                } label: {
                    actionLabel(action, ink: palette.ink.opacity(0.82))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
                .modifier(BarEntrance(index: action == .discard ? 0 : 1))
                .transition(.asymmetric(
                    insertion: .identity,
                    removal: .opacity.animation(.easeOut(duration: 0.12))
                ))
                .accessibilityShowsLargeContentViewer {
                    Label(action.title, systemImage: action.symbol)
                }
                .accessibilityLabel(action.accessibilityLabel)
                .accessibilityInputLabels(action.spokenNames)
                .modifier(DiscardQuestion(isActive: action == .discard, isPresented: $confirmsDiscard) {
                    sessionActions?.discard()
                } dismissed: {
                    sessionActions?.consideringDiscard(false)
                })
            }
        }
        .frame(width: isShown ? nil : 0, height: Self.knob + 2 * Self.wellPadding)
        .frame(maxWidth: isShown ? .infinity : nil)
        .background(Capsule(style: .continuous).fill(palette.well))
        .clipShape(Capsule(style: .continuous))
        .animation(fadeMotion) { well in
            well
                .opacity(isShown ? 1 : 0)
                .scaleEffect(isShown || reduceMotion ? 1 : 0.7)
        }
        .padding(.trailing, isShown ? Self.spacing : 0)
        .allowsHitTesting(isShown)
        .accessibilityHidden(!isShown)
    }

    /// A glyph and a word, kept at their own size whatever the well does.
    private func actionLabel(_ action: SessionAction, ink: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: action.symbol)
                .font(.system(size: 13, weight: .semibold))
            Text(action.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(ink)
        .fixedSize()
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func control(for item: PhoneBarItem) -> some View {
        Group {
            switch item {
            case .profile: profileControl
            case .size: sizeControl
            case .typeface: typefaceControl
            case .display: scrollingDisplayControl
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.title)
    }

    private func open(_ item: PhoneBarItem) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.22) : Self.motion) { expanded = item }
    }

    private func close() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.22) : Self.motion) { expanded = nil }
    }

    private var profileControl: some View {
        let isLocked = !controller.canSelectTranscriptionProfile
        return HStack(spacing: 2) {
            ForEach(Array(TranscriptionProfile.allCases.enumerated()), id: \.element) { index, profile in
                let isCurrent = controller.transcriptionProfile == profile
                Button {
                    withAnimation(Self.selection) { controller.selectTranscriptionProfile(profile) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: profile.symbolName)
                            .font(.system(size: 11, weight: .semibold))
                        Text(profile.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(isCurrent ? palette.ink : secondaryInk)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, minHeight: Self.knob)
                    .background { selectionPill(isOn: isCurrent, id: "profile.pill") }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityShowsLargeContentViewer {
                    Label(profile.displayName, systemImage: profile.symbolName)
                }
                .accessibilityHint(profile.explanation)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .modifier(BarEntrance(index: index))
            }
        }
        .disabled(isLocked)
        .opacity(isLocked ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.25), value: isLocked)
        .sensoryFeedback(.selection, trigger: controller.transcriptionProfile)
    }

    private var sizeControl: some View {
        HStack(spacing: 2) {
            stepButton(glyphSize: 12, delta: -1, label: localized("Redueix la mida del text"))
                .modifier(BarEntrance(index: 0))
            PhoneSizeTrack(value: $fontSize, palette: palette)
                .modifier(BarEntrance(index: 1))
            stepButton(glyphSize: 19, delta: 1, label: localized("Augmenta la mida del text"))
                .modifier(BarEntrance(index: 2))
        }
    }

    private func stepButton(glyphSize: CGFloat, delta: Int, label: String) -> some View {
        Button {
            let next = PhoneMetrics.clampedFontSize(CGFloat(fontSize) + PhoneMetrics.fontSizeStep * CGFloat(delta))
            guard Double(next) != fontSize else {
                DetentHaptics.shared.boundary()
                return
            }
            withAnimation(Self.selection) { fontSize = Double(next) }
            DetentHaptics.shared.detent(fraction: PhoneSizeTrack.fraction(of: Double(next)))
        } label: {
            Text(verbatim: "A")
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(palette.ink.opacity(0.72))
                .frame(width: 40, height: Self.knob)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityShowsLargeContentViewer {
            Label(label, systemImage: delta > 0 ? "plus" : "minus")
        }
        .accessibilityLabel(label)
        .accessibilityInputLabels(delta > 0
            ? [localized("Augmenta"), localized("Més gran"), label]
            : [localized("Redueix"), localized("Més petit"), label])
    }

    private var typefaceControl: some View {
        HStack(spacing: 2) {
            ForEach(Array(ReadingTypeface.allCases.enumerated()), id: \.element) { index, face in
                let isCurrent = typeface == face
                Button {
                    withAnimation(Self.selection) { typeface = face }
                } label: {
                    VStack(spacing: 0) {
                        Text(verbatim: "Ag")
                            .font(Font(face.font(ofSize: 16) as CTFont))
                        Text(face.displayName)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(isCurrent ? palette.ink : secondaryInk)
                    .padding(.horizontal, 3)
                    .frame(maxWidth: .infinity, minHeight: Self.knob)
                    .background { selectionPill(isOn: isCurrent, id: "typeface.pill") }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityShowsLargeContentViewer {
                    Label(face.displayName, systemImage: "textformat")
                }
                .accessibilityLabel(face.fullName)
                .accessibilityInputLabels([face.displayName, face.fullName])
                .accessibilityHint(face.rationale)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .modifier(BarEntrance(index: index))
            }
        }
        .sensoryFeedback(.selection, trigger: typeface)
    }

    // MARK: - Display settings

    /// The gear's well grown into the bar: a row wider than the well, scrolled sideways.
    /// The row fades out at an edge only while there is more beyond it.
    private var scrollingDisplayControl: some View {
        ScrollView(.horizontal) {
            displayControl
                .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .onScrollGeometryChange(for: ScrollEdges.self) { geometry in
            ScrollEdges(
                leading: geometry.contentOffset.x > 1,
                trailing: geometry.contentOffset.x + geometry.containerSize.width < geometry.contentSize.width - 1
            )
        } action: { _, edges in
            withAnimation(.easeOut(duration: 0.18)) { scrollEdges = edges }
        }
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: scrollEdges.leading ? 22 : 0)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: scrollEdges.trailing ? 22 : 0)
            }
        }
    }

    /// Each display control keeps its width, so the row can outgrow the well.
    private static let displayItemWidth: CGFloat = 56

    @State private var scrollEdges = ScrollEdges(leading: false, trailing: false)

    private var displayControl: some View {
        HStack(spacing: 2) {
            Button {
                withAnimation(Self.selection) { theme = theme.next }
            } label: {
                displayLabel(symbol: theme.symbol, caption: theme.title, isOn: true)
            }
            .buttonStyle(PressableButtonStyle())
            .largeContent(theme.title, symbol: theme.symbol)
            .accessibilityLabel(localized("Tema"))
            .accessibilityInputLabels([localized("Tema"), theme.title])
            .accessibilityValue(theme.title)
            .accessibilityHint(localized("Canvia entre automàtic, clar i fosc"))
            .modifier(BarEntrance(index: 0))

            displayToggle(isOn: $prefersAgeGradient, symbol: "line.3.horizontal.decrease", caption: localized("Degradat"), index: 1)
            displayToggle(isOn: $showsOrb, symbol: "circle.fill", caption: localized("Orbe"), index: 2)

            Button(action: onMicrophone) {
                displayLabel(symbol: "mic.fill", caption: localized("Micròfon"), isOn: false)
            }
            .buttonStyle(PressableButtonStyle())
            .largeContent(localized("Micròfon"), symbol: "mic.fill")
            .accessibilityLabel(localized("Micròfon"))
            .accessibilityValue(controller.preferredInputName ?? localized("Automàtic"))
            .modifier(BarEntrance(index: 3))

            Button(action: onVocabulary) {
                displayLabel(symbol: "text.badge.star", caption: localized("Vocabulari"), isOn: false)
                    .overlay(alignment: .topTrailing) {
                        // How many terms the day has, on the corner of the glyph.
                        if !controller.vocabulary.isEmpty {
                            Text(verbatim: "\(controller.vocabulary.count)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(height: 13)
                                .background(Capsule().fill(Color(red: 1, green: 0.39, blue: 0)))
                                .padding(.top, 3)
                                .padding(.trailing, 6)
                                .contentTransition(.numericText())
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
            }
            .buttonStyle(PressableButtonStyle())
            .largeContent(localized("Vocabulari"), symbol: "text.badge.star")
            .accessibilityLabel(localized("Vocabulari de l'acte"))
            .accessibilityValue(controller.vocabulary.isEmpty ? localized("Buit") : localized("\(controller.vocabulary.count) termes"))
            .modifier(BarEntrance(index: 4))

            Button(action: onLanguages) {
                displayLabel(symbol: "globe", caption: languageName, isOn: false)
                    .overlay(alignment: .topTrailing) {
                        if languageIsBeta {
                            Circle()
                                .fill(Color(red: 1, green: 0.55, blue: 0))
                                .frame(width: 6, height: 6)
                                .padding(.top, 6)
                                .padding(.trailing, 10)
                        }
                    }
            }
            .buttonStyle(PressableButtonStyle())
            .largeContent(languageName, symbol: "globe")
            .accessibilityLabel(localized("Idioma"))
            .accessibilityInputLabels([localized("Idioma"), languageName])
            .accessibilityValue(languageIsBeta ? localized("\(languageName), nou") : languageName)
            .modifier(BarEntrance(index: 5))

            Button(action: onAbout) {
                displayLabel(symbol: "info.circle", caption: localized("Info"), isOn: false)
            }
            .buttonStyle(PressableButtonStyle())
            .largeContent(localized("Informació"), symbol: "info.circle")
            .accessibilityLabel(localized("Informació i privacitat"))
            .accessibilityInputLabels([localized("Info"), localized("Informació"), localized("Privacitat")])
            .modifier(BarEntrance(index: 6))
        }
        .sensoryFeedback(.selection, trigger: theme)
    }

    private func displayToggle(isOn: Binding<Bool>, symbol: String, caption: String, index: Int) -> some View {
        Button {
            withAnimation(Self.selection) { isOn.wrappedValue.toggle() }
        } label: {
            displayLabel(symbol: symbol, caption: caption, isOn: isOn.wrappedValue, showsPill: true)
        }
        .buttonStyle(PressableButtonStyle())
        .largeContent(caption, symbol: symbol)
        .accessibilityLabel(caption)
        .accessibilityValue(isOn.wrappedValue ? localized("Activat") : localized("Desactivat"))
        .sensoryFeedback(.selection, trigger: isOn.wrappedValue)
        .modifier(BarEntrance(index: index))
    }

    /// An icon over a small caption, the shape every display control shares. A toggle
    /// that is on sits on a raised pill; one that is off keeps its place, flat and dimmer.
    private func displayLabel(symbol: String, caption: String, isOn: Bool, showsPill: Bool = false) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 16)
            Text(caption)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.interpolate)
        }
        .foregroundStyle(isOn ? palette.ink : secondaryInk)
        .padding(.horizontal, 2)
        .frame(width: Self.displayItemWidth)
        .frame(minHeight: Self.knob)
        .background {
            if showsPill {
                Capsule(style: .continuous)
                    .fill(palette.knob)
                    .shadow(color: palette.shadow, radius: 3, y: 1)
                    .outlinedWithoutColour(Capsule(style: .continuous), ink: palette.ink)
                    .opacity(isOn ? 1 : 0)
                    .scaleEffect(isOn ? 1 : 0.82)
            }
        }
        .contentShape(Capsule())
    }

    /// Secondary text at 5:1 or more on the wells; the Mac's muted ink (48 %) reads fine
    /// at a desk but falls under 4.5:1 for small text.
    private var secondaryInk: Color { palette.ink.opacity(0.64) }

    private func selectionPill(isOn: Bool, id: String) -> some View {
        ZStack {
            if isOn {
                Capsule(style: .continuous)
                    .fill(palette.knob)
                    .shadow(color: palette.shadow, radius: 3, y: 1)
                    .outlinedWithoutColour(Capsule(style: .continuous), ink: palette.ink)
                    .matchedGeometryEffect(id: id, in: namespace)
            }
        }
    }
}

/// "Vols descartar…?" rising from the Descarta button.
private struct DiscardQuestion: ViewModifier {
    let isActive: Bool
    @Binding var isPresented: Bool
    let confirmed: () -> Void
    let dismissed: () -> Void

    @State private var didConfirm = false

    func body(content: Content) -> some View {
        if isActive {
            content
                .confirmationDialog(
                    localized("Vols descartar aquesta transcripció?"),
                    isPresented: $isPresented,
                    titleVisibility: .visible
                ) {
                    Button(localized("Descarta"), role: .destructive) {
                        didConfirm = true
                        confirmed()
                    }
                    Button(localized("Cancel·la"), role: .cancel) {}
                } message: {
                    Text(localized("No es desarà a Transcripcions i no es podrà recuperar."))
                }
                .onChange(of: isPresented) { _, shown in
                    if shown {
                        didConfirm = false
                    } else if !didConfirm {
                        dismissed()
                    }
                }
        } else {
            content
        }
    }
}

/// Acts the moment the finger lands instead of when it lifts, as a key does: the bar's
/// wells answer with no wait. The press dips the well a little, like `PressableButtonStyle`.
/// `GestureState` resets on its own if the touch is cancelled, so nothing stays pressed.
struct TouchDownAction: ViewModifier {
    let label: String
    var inputLabels: [String] = []
    var symbol: String?
    let action: () -> Void

    @GestureState private var isPressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: isPressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, pressed, _ in
                        guard !pressed else { return }
                        pressed = true
                        action()
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityShowsLargeContentViewer {
                Label(label, systemImage: symbol ?? "circle")
            }
            .accessibilityLabel(label)
            .accessibilityInputLabels(inputLabels.isEmpty ? [label] : inputLabels + [label])
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

extension View {
    /// The bar keeps its size at the largest text sizes; a long press on a control shows
    /// it large, as the system's own tab bars do.
    func largeContent(_ title: String, symbol: String) -> some View {
        accessibilityShowsLargeContentViewer {
            Label(title, systemImage: symbol)
        }
    }
}

extension PhoneTheme {
    /// The display control cycles through the three in this order.
    var next: PhoneTheme {
        switch self {
        case .automatic: .light
        case .light: .dark
        case .dark: .automatic
        }
    }
}


private struct ScrollEdges: Equatable {
    var leading: Bool
    var trailing: Bool
}

/// A control's pieces arrive one after another, drifting in from the close button's side
/// and sharpening as they land.
struct BarEntrance: ViewModifier {
    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(x: isShown || reduceMotion ? 0 : 10)
            .scaleEffect(isShown || reduceMotion ? 1 : 0.9)
            .blur(radius: isShown || reduceMotion ? 0 : 3)
            .onAppear {
                let animation = reduceMotion
                    ? Animation.easeOut(duration: 0.2)
                    : .spring(response: 0.32, dampingFraction: 0.84).delay(Double(index) * 0.03)
                withAnimation(animation) { isShown = true }
            }
    }
}

/// A notched track with one stop per size step.
///
/// The knob follows the finger continuously, leaning slightly towards the nearest size,
/// and the text changes as each size is crossed; on release it settles onto the chosen
/// stop. `DetentHaptics` gives the travel its feel: fine grain between sizes, a soft
/// tok on each, a muffled bump at either end.
struct PhoneSizeTrack: View {
    @Binding var value: Double
    let palette: SettingsBarPalette
    /// The reading screen's sizes unless told otherwise (a kept transcription's are smaller).
    var range: ClosedRange<Double> = Double(PhoneMetrics.minimumFontSize)...Double(PhoneMetrics.maximumFontSize)
    var step = Double(PhoneMetrics.fontSizeStep)

    @State private var dragFraction: Double?
    /// The last quarter-step the finger crossed, for the fine ticks.
    @State private var lastGrain: Int?
    @State private var pressedEnd = false
    private let knob: CGFloat = 22

    private var lower: Double { range.lowerBound }
    private var upper: Double { range.upperBound }
    private var stops: Int { Int(((upper - lower) / step).rounded()) + 1 }

    static func fraction(of size: Double) -> Double {
        fraction(of: size, in: Double(PhoneMetrics.minimumFontSize)...Double(PhoneMetrics.maximumFontSize))
    }

    static func fraction(of size: Double, in range: ClosedRange<Double>) -> Double {
        (min(range.upperBound, max(range.lowerBound, size)) - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func fraction(of size: Double) -> Double {
        Self.fraction(of: size, in: range)
    }

    var body: some View {
        GeometryReader { proxy in
            let usable = max(1, proxy.size.width - knob)
            let settled = fraction(of: value)
            // While dragging, the knob sits between the finger and its size.
            let shown = dragFraction.map { $0 * 0.75 + settled * 0.25 } ?? settled
            let center = knob / 2 + usable * shown
            ZStack(alignment: .leading) {
                Capsule().fill(palette.track).frame(height: 4)
                    .padding(.horizontal, knob / 2 - 2)
                HStack(spacing: 0) {
                    ForEach(0..<stops, id: \.self) { index in
                        Circle().fill(palette.ink.opacity(0.22)).frame(width: 3, height: 3)
                        if index < stops - 1 { Spacer(minLength: 0) }
                    }
                }
                .padding(.horizontal, knob / 2 - 1.5)
                .offset(y: 9)
                Capsule().fill(palette.ink.opacity(0.85))
                    .frame(width: max(4, center - knob / 2 + 4), height: 4)
                    .padding(.leading, knob / 2 - 2)
                Circle()
                    .fill(palette.knob)
                    .overlay(Circle().strokeBorder(palette.hairline))
                    .shadow(color: palette.shadow.opacity(1.4), radius: dragFraction != nil ? 6 : 3, y: 1)
                    .frame(width: knob, height: knob)
                    .scaleEffect(dragFraction != nil ? 1.18 : 1)
                    .offset(x: center - knob / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let raw = Double((drag.location.x - knob / 2) / usable)
                        track(to: raw)
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { dragFraction = nil }
                        lastGrain = nil
                        pressedEnd = false
                        DetentHaptics.shared.settle()
                    }
            )
        }
        .frame(height: 38)
        .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.86), value: dragFraction)
        .accessibilityElement()
        .accessibilityLabel(localized("Mida del text"))
        .accessibilityValue(localized("\(Int(value)) punts"))
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? step : -step
            value = min(upper, max(lower, value + delta))
        }
    }

    private func track(to raw: Double) {
        let haptics = DetentHaptics.shared
        if dragFraction == nil { haptics.grab() }
        let position = min(1, max(0, raw))
        dragFraction = position

        let span = upper - lower
        // Four fine ticks per size.
        let grain = Int((position * span / step * 4).rounded(.down))
        let snapped = lower + (position * span / step).rounded() * step

        if snapped != value {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) { value = snapped }
            haptics.detent(fraction: fraction(of: snapped))
        } else if let lastGrain, grain != lastGrain {
            haptics.grain()
        }
        lastGrain = grain

        let beyond = raw < -0.02 || raw > 1.02
        if beyond, !pressedEnd { haptics.boundary() }
        pressedEnd = beyond
    }
}

extension TranscriptionProfile {
    /// One line on what the profile trades, read by VoiceOver on the profile control.
    var explanation: String {
        switch self {
        case .reliable: localized("Espera una mica més abans de fixar cada paraula: el text es corregeix menys.")
        case .balanced: localized("El punt mitjà entre rapidesa i estabilitat.")
        case .immediate: localized("Mostra les paraules tan bon punt les sent, a canvi de corregir-ne més.")
        }
    }
}
