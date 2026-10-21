import AppKit
import SubtitolCore
import SwiftUI

/// One control on the floating bar, each owning a panel that the bar grows to reveal.
enum SettingsBarItem: Hashable {
    case profile
    case size
    case typeface
    case display
    case language
    case input
    case vocabulary

    var title: String {
        switch self {
        case .profile: localized("Fiabilitat")
        case .size: localized("Mida del text")
        case .typeface: localized("Tipografia")
        case .display: localized("Visualització")
        case .language: localized("Idioma")
        case .input: localized("Micròfon")
        case .vocabulary: localized("Vocabulari")
        }
    }
}

/// The floating settings bar.
///
/// Motion has one grammar throughout: the bar's width follows a single spring, the knob
/// and every selection pill travel by `matchedGeometryEffect` rather than fading, and a
/// panel's contents arrive in a quick cascade out of the icon that opened them.
/// With Reduce Motion on, the same state changes happen as plain cross-fades.
struct SettingsBar: View {
    @ObservedObject var controller: SubtitleController
    @EnvironmentObject private var packs: LanguagePackStore
    @Binding var expanded: SettingsBarItem?
    @Binding var fontSize: Double
    @Binding var typeface: ReadingTypeface
    @Binding var isDarkTheme: Bool
    @Binding var prefersAgeGradient: Bool
    @Binding var showsDecoration: Bool
    /// The theme's animated position, 0 light to 1 dark, so the bar crosses over in
    /// step with the reading pane.
    var themeDarkness: Double
    /// After a stop, the bar's choices for the session on screen; nil the rest of the time.
    var sessionActions: SessionActions?

    static let motion = Animation.spring(response: 0.3, dampingFraction: 0.84)
    static let selection = Animation.spring(response: 0.24, dampingFraction: 0.82)
    private static let wellPadding: CGFloat = 3
    private static let knobSize: CGFloat = 32

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace
    @State private var hoveredTypeface: ReadingTypeface?
    /// The family the card describes; it outlives the hover while the card fades out.
    @State private var infoFace: ReadingTypeface?
    @State private var infoIsShown = false
    @State private var infoReveal: Task<Void, Never>?
    @StateObject private var inputs = AudioInputDeviceList()
    /// Descarta asks first, from the button itself.
    @State private var confirmsDiscard = false

    /// The stopped session's choices are showing in place of the settings.
    private var showsActions: Bool { sessionActions != nil }
    /// The settings panel is open, alone or with its language or microphone card above
    /// the bar (`.language` and `.input` open inside the settings).
    private func isOpen(_ item: SettingsBarItem) -> Bool {
        item == .display ? [.display, .language, .input, .vocabulary].contains(expanded) : expanded == item
    }

    /// Opens or closes one of the settings' cards, leaving the settings open.
    private func card(_ item: SettingsBarItem) -> Binding<Bool> {
        Binding(
            get: { expanded == item },
            set: { expanded = $0 ? item : .display }
        )
    }

    private var palette: SettingsBarPalette { .blended(darkness: themeDarkness) }

    var body: some View {
        // The settings and the stopped session's choices share one row: each set grows
        // out of nothing where the other shrinks away, while the record well becomes Desa.
        HStack(spacing: 0) {
            profileWell
                .modifier(BarCollapse(isGone: showsActions))
            toolWell(.size) { sizePanel }
                .modifier(BarCollapse(isGone: showsActions))
            toolWell(.typeface) { typefacePanel }
                .modifier(BarCollapse(isGone: showsActions))
            toolWell(.display) { displayPanel }
                .modifier(BarCollapse(isGone: showsActions))
            actionWell(.discard)
                .modifier(BarCollapse(isGone: !showsActions))
            actionWell(.export)
                .modifier(BarCollapse(isGone: !showsActions))
            recordWell
        }
        .padding(5)
        .background {
            Capsule(style: .continuous)
                .fill(palette.surface)
                .overlay(Capsule(style: .continuous).strokeBorder(palette.hairline))
                .shadow(color: palette.shadow, radius: 18, y: 8)
                .shadow(color: palette.shadow.opacity(0.5), radius: 2, y: 1)
        }
        // The system tooltips are stripped app-wide, so hovering a family raises a card
        // of the bar's own material just above it, saying why the family is offered.
        .overlay {
            // A second bar, the same shape and size as this one, just above it.
            GeometryReader { proxy in
                if infoIsShown, let face = infoFace {
                    TypefaceInfoBar(face: face, palette: palette)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .modifier(active: InfoBarRise(amount: 1), identity: InfoBarRise(amount: 0))
                        )
                        .offset(y: -proxy.size.height - Self.infoGap)
                }
            }
            .allowsHitTesting(false)
        }
        // Gaps between wells belong to the bar, not to the recording surface beneath.
        .contentShape(Capsule(style: .continuous))
        .onTapGesture { }
        // The microphones need a list, not a row: they open in a card of the bar's own
        // material that rises just above it, flush with its right end. It is attached
        // after the bar's hit shape: under it, the capsule would swallow every click on
        // the card.
        .overlay(alignment: .bottomTrailing) {
            GeometryReader { proxy in
                if expanded == .input {
                    InputPanel(controller: controller, inputs: inputs, palette: palette)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .modifier(active: InfoBarRise(amount: 1), identity: InfoBarRise(amount: 0))
                        )
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomTrailing)
                        .offset(y: -proxy.size.height - Self.infoGap)
                }
                if expanded == .vocabulary {
                    VocabularyPanel(controller: controller, palette: palette) {
                        withAnimation(Self.motion) { expanded = nil }
                    }
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .modifier(active: InfoBarRise(amount: 1), identity: InfoBarRise(amount: 0))
                        )
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomTrailing)
                        .offset(y: -proxy.size.height - Self.infoGap)
                }
                if expanded == .language {
                    LanguagePanel(packs: packs, isBusy: controller.isRecording || controller.state == .transcribing, palette: palette)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .modifier(active: InfoBarRise(amount: 1), identity: InfoBarRise(amount: 0))
                        )
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomTrailing)
                        .offset(y: -proxy.size.height - Self.infoGap)
                }
            }
        }
        .fixedSize()
        .onChange(of: hoveredTypeface) { _, face in presentInfoCard(for: face) }
        #if DEBUG
        .task {
            // Screenshot runs: `-openPanel input` opens that panel after launch.
            guard let raw = UserDefaults.standard.string(forKey: "openPanel") else { return }
            try? await Task.sleep(for: .milliseconds(800))
            let item: SettingsBarItem? = switch raw {
            case "profile": .profile
            case "size": .size
            case "typeface": .typeface
            case "display": .display
            case "language": .language
            case "input": .input
            case "vocabulary": .vocabulary
            default: nil
            }
            withAnimation(Self.motion) { expanded = item }
            // `-clickAt x,y` (window points from the top left) clicks there once the
            // panel is open, without the window needing focus.
            guard let spot = UserDefaults.standard.string(forKey: "clickAt")?
                .split(separator: ",").compactMap({ Double($0) }), spot.count == 2,
                  let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
            try? await Task.sleep(for: .milliseconds(800))
            let point = NSPoint(x: spot[0], y: window.contentLayoutRect.height - spot[1])
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                ) {
                    window.sendEvent(event)
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
        #endif
    }

    // MARK: - Typeface card

    private static let infoAppear = Animation.spring(response: 0.34, dampingFraction: 0.86)
    private static let infoDisappear = Animation.easeOut(duration: 0.16)
    private static let infoSwap = Animation.spring(response: 0.32, dampingFraction: 0.88)
    /// Clear air between the two bars.
    private static let infoGap: CGFloat = 8
    /// A pointer that only crosses the panel on its way elsewhere raises nothing.
    private static let infoHoverIntent: Duration = .milliseconds(140)

    private func presentInfoCard(for face: ReadingTypeface?) {
        infoReveal?.cancel()
        guard let face else {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.16) : Self.infoDisappear) {
                infoIsShown = false
            } completion: {
                if !infoIsShown { infoFace = nil }
            }
            return
        }
        if infoIsShown {
            withAnimation(Self.infoSwap) { infoFace = face }
            return
        }
        infoFace = face
        infoReveal = Task { @MainActor in
            try? await Task.sleep(for: Self.infoHoverIntent)
            guard !Task.isCancelled, hoveredTypeface == face else { return }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Self.infoAppear) {
                infoIsShown = true
            }
        }
    }

    // MARK: - Wells

    private var profileWell: some View {
        HStack(spacing: 0) {
            if expanded == .profile {
                profilePanel
                    .transition(panelTransition)
                itemButton(.profile) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
            } else {
                Button {
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Self.motion) {
                        expanded = .profile
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(controller.transcriptionProfile.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .contentTransition(.interpolate)
                            .padding(.leading, 10)
                        Image(systemName: controller.transcriptionProfile.symbolName)
                            .font(.system(size: 11, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: Self.knobSize, height: Self.knobSize)
                    }
                    .foregroundStyle(palette.ink.opacity(0.78))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(SettingsBarItem.profile.title)
                .transition(.opacity.combined(with: .offset(x: -5)))
            }
        }
        .padding(Self.wellPadding)
        .background(Capsule(style: .continuous).fill(palette.well))
    }

    private func toolWell<Panel: View>(
        _ item: SettingsBarItem,
        @ViewBuilder panel: () -> Panel
    ) -> some View {
        HStack(spacing: 0) {
            itemButton(item) { icon(for: item) }
            if isOpen(item) {
                panel()
                    .padding(.leading, 4)
                    .padding(.trailing, 4)
                    .transition(panelTransition)
            }
        }
        .padding(Self.wellPadding)
        .background(Capsule(style: .continuous).fill(palette.well))
    }

    /// Record, or, after a stop, Desa: the well stretches to its word and fills with ink,
    /// the bar's one primary action, where the pointer already is.
    private var recordWell: some View {
        let isSave = showsActions
        return Button {
            if let sessionActions {
                sessionActions.save()
                return
            }
            withAnimation(Self.motion) { expanded = nil }
            controller.toggleRecording()
        } label: {
            ZStack {
                RecordGlyph(
                    isRecording: controller.isRecording,
                    isBusy: !controller.canToggle && controller.state != .needsLanguage,
                    palette: palette
                )
                .frame(width: Self.knobSize, height: Self.knobSize)
                .opacity(isSave ? 0 : 1)
                .scaleEffect(isSave && !reduceMotion ? 0.6 : 1)
                if isSave {
                    actionLabel(.save, ink: palette.surface)
                        .modifier(StaggeredEntrance(index: 2))
                        .transition(.asymmetric(
                            insertion: .identity,
                            removal: .opacity.animation(.easeOut(duration: 0.1))
                        ))
                }
            }
            .frame(width: isSave ? nil : Self.knobSize, height: Self.knobSize)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!isSave && !controller.canToggle)
        .padding(Self.wellPadding)
        .background(Capsule(style: .continuous).fill(isSave ? palette.ink : palette.well))
        .accessibilityLabel(isSave
            ? SessionAction.save.accessibilityLabel
            : (controller.canToggle ? controller.buttonTitle : controller.detail))
    }

    // MARK: - After a stop

    /// Descarta (which asks first, from a card under the pointer) or Exporta.
    private func actionWell(_ action: SessionAction) -> some View {
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
                .frame(height: Self.knobSize)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .padding(Self.wellPadding)
        .background(Capsule(style: .continuous).fill(palette.well))
        .accessibilityLabel(action.accessibilityLabel)
        .popover(isPresented: action == .discard ? $confirmsDiscard : .constant(false), arrowEdge: .top) {
            DiscardCard {
                confirmsDiscard = false
                sessionActions?.discard()
            } onCancel: {
                confirmsDiscard = false
            }
        }
        .onChange(of: confirmsDiscard) { _, shown in
            if action == .discard, !shown { sessionActions?.consideringDiscard(false) }
            #if DEBUG
            // Test runs: `-autoDiscard YES` answers the question after a moment.
            if action == .discard, shown, UserDefaults.standard.bool(forKey: "autoDiscard") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    confirmsDiscard = false
                    sessionActions?.discard()
                }
            }
            #endif
        }
    }

    /// A glyph and a word, kept at their own size whatever the well does.
    private func actionLabel(_ action: SessionAction, ink: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: action.symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(action.title)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(ink)
        .fixedSize()
        .padding(.horizontal, 12)
    }

    // MARK: - Item button

    private func itemButton<Label: View>(
        _ item: SettingsBarItem,
        @ViewBuilder label: () -> Label
    ) -> some View {
        let isOpen = isOpen(item)
        return Button {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Self.motion) {
                expanded = isOpen ? nil : item
            }
        } label: {
            ZStack {
                if isOpen {
                    Circle()
                        .fill(palette.knob)
                        .shadow(color: palette.shadow, radius: 4, y: 1)
                        .matchedGeometryEffect(id: "knob", in: namespace)
                }
                label()
                    .foregroundStyle(isOpen ? palette.ink : palette.ink.opacity(0.62))
            }
            .frame(width: Self.knobSize, height: Self.knobSize)
            .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }

    @ViewBuilder
    private func icon(for item: SettingsBarItem) -> some View {
        switch item {
        case .size:
            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
        case .typeface:
            Image(systemName: "textformat.alt")
                .font(.system(size: 12, weight: .semibold))
        case .display:
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12, weight: .semibold))
        case .input:
            Image(systemName: "mic.fill")
                .font(.system(size: 12, weight: .semibold))
        case .vocabulary:
            Image(systemName: "text.badge.star")
                .font(.system(size: 12, weight: .semibold))
        case .profile, .language:
            EmptyView()
        }
    }

    // MARK: - Panels

    private var profilePanel: some View {
        let isLocked = !controller.canSelectTranscriptionProfile
        return HStack(spacing: 2) {
            ForEach(Array(TranscriptionProfile.allCases.enumerated()), id: \.element) { index, profile in
                let isCurrent = controller.transcriptionProfile == profile
                Button {
                    withAnimation(Self.selection) {
                        controller.selectTranscriptionProfile(profile)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: profile.symbolName)
                            .font(.system(size: 9, weight: .semibold))
                        Text(profile.displayName)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(isCurrent ? palette.ink : palette.mutedInk)
                    .padding(.horizontal, 9)
                    .frame(height: Self.knobSize)
                    .background {
                        if isCurrent {
                            Capsule(style: .continuous)
                                .fill(palette.knob)
                                .shadow(color: palette.shadow, radius: 3, y: 1)
                                .outlinedWithoutColour(Capsule(style: .continuous), ink: palette.ink)
                                .matchedGeometryEffect(id: "profile.pill", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .modifier(StaggeredEntrance(index: index))
            }
        }
        .disabled(isLocked)
        .opacity(isLocked ? 0.75 : 1)
        .animation(.easeInOut(duration: 0.25), value: isLocked)
        .padding(.trailing, 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Perfil de transcripció"))
        .accessibilityHint(localized("Es pot canviar també mentre grava, sense perdre el text"))
    }

    private var sizePanel: some View {
        HStack(spacing: 4) {
            stepButton(glyphSize: 9, delta: -1, label: localized("Redueix la mida del text"))
                .modifier(StaggeredEntrance(index: 0))
            SizeTrack(value: $fontSize, palette: palette)
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
            let next = CGFloat(fontSize) + AppVisualMetrics.fontSizeStep * CGFloat(delta)
            withAnimation(Self.selection) {
                fontSize = Double(AppVisualMetrics.clampedFontSize(next))
            }
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
                let isHovered = hoveredTypeface == face
                Button {
                    withAnimation(Self.selection) { typeface = face }
                } label: {
                    VStack(spacing: 0) {
                        Text(verbatim: "Ag")
                            .font(Font(face.font(ofSize: 13) as CTFont))
                        Text(face.displayName)
                            .font(.system(size: 7, weight: .semibold))
                            .opacity(0.8)
                    }
                    .foregroundStyle(
                        isCurrent ? palette.ink : isHovered ? palette.ink.opacity(0.72) : palette.mutedInk
                    )
                    .padding(.horizontal, 8)
                    .frame(minWidth: 52)
                    .frame(height: Self.knobSize)
                    .background {
                        if isCurrent {
                            Capsule(style: .continuous)
                                .fill(palette.knob)
                                .shadow(color: palette.shadow, radius: 3, y: 1)
                                .outlinedWithoutColour(Capsule(style: .continuous), ink: palette.ink)
                                .matchedGeometryEffect(id: "typeface.pill", in: namespace)
                        } else if isHovered {
                            // The selection pill at half strength, gliding from button
                            // to button as the pointer moves.
                            Capsule(style: .continuous)
                                .fill(palette.knob.opacity(0.5))
                                .matchedGeometryEffect(id: "typeface.hover", in: namespace)
                                .transition(.opacity)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .onHover { isInside in
                    // Only entering changes the target; the panel's own hover clears
                    // it, so crossing the gap between two buttons never drops the card.
                    guard isInside, hoveredTypeface != face else { return }
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                        hoveredTypeface = face
                    }
                }
                .accessibilityLabel(face.fullName)
                .accessibilityHint(face.rationale)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .modifier(StaggeredEntrance(index: index))
            }
        }
        .onHover { isInside in
            guard !isInside else { return }
            withAnimation(.easeOut(duration: 0.16)) { hoveredTypeface = nil }
        }
        .onDisappear { hoveredTypeface = nil }
    }

    private var displayPanel: some View {
        HStack(spacing: 2) {
            displayToggle(
                isOn: $isDarkTheme,
                symbol: isDarkTheme ? "moon.fill" : "sun.max.fill",
                title: isDarkTheme ? localized("Fosc") : localized("Clar"),
                index: 0
            )
            displayToggle(
                isOn: $prefersAgeGradient,
                symbol: "line.3.horizontal.decrease",
                title: localized("Degradat"),
                index: 1
            )
            displayToggle(
                isOn: $showsDecoration,
                symbol: "rectangle.righthalf.inset.filled",
                title: localized("Panell"),
                index: 2
            )
            // The language and microphone lists open in a card above the bar.
            displayToggle(
                isOn: card(.language),
                symbol: "globe",
                title: localized("Idioma"),
                index: 3
            )
            displayToggle(
                isOn: card(.input),
                symbol: "mic.fill",
                title: localized("Micròfon"),
                index: 4
            )
            // The vocabulary of the day: its pill counts the terms.
            displayToggle(
                isOn: card(.vocabulary),
                symbol: "text.badge.star",
                title: controller.vocabulary.isEmpty
                    ? localized("Vocabulari")
                    : localized("Vocabulari") + " \(controller.vocabulary.count)",
                index: 5
            )
        }
    }

    private func displayToggle(
        isOn: Binding<Bool>,
        symbol: String,
        title: String,
        index: Int
    ) -> some View {
        Button {
            withAnimation(Self.selection) { isOn.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .contentTransition(.interpolate)
            }
            .foregroundStyle(isOn.wrappedValue ? palette.ink : palette.mutedInk)
            .padding(.horizontal, 9)
            .frame(height: Self.knobSize - 6)
            .background {
                Capsule(style: .continuous)
                    .fill(palette.knob)
                    .shadow(color: palette.shadow, radius: 3, y: 1)
                    .outlinedWithoutColour(Capsule(style: .continuous), ink: palette.ink)
                    .opacity(isOn.wrappedValue ? 1 : 0)
                    .scaleEffect(isOn.wrappedValue ? 1 : 0.82)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
        .modifier(StaggeredEntrance(index: index))
    }

    private var panelTransition: AnyTransition {
        // Entrance is choreographed per child by `StaggeredEntrance`; the container
        // only has to leave quickly enough that the shrinking well never outruns it.
        .asymmetric(
            insertion: .identity,
            removal: .opacity
                .combined(with: .scale(scale: 0.9, anchor: .leading))
                .animation(.easeOut(duration: 0.08))
        )
    }
}

// MARK: - Pieces

/// A panel's children arrive one after another, drifting out of the icon that opened
/// them and sharpening as they land.
// MARK: - Typeface card

/// The bar's twin: same height, surface, outline and shadow. The family's name sits in
/// a well like the bar's own, and why it is offered follows on the white; both are set
/// in the family itself so "I l 1" shows what the line claims. Its width follows the
/// line, so moving between families resizes the capsule while the words cross-fade.
private struct TypefaceInfoBar: View {
    let face: ReadingTypeface
    let palette: SettingsBarPalette

    private static let fontSize: CGFloat = 12
    /// The bar's own inset (5) plus its wells' padding (3), so the name's well lines up
    /// with the wells below.
    private static let wellInset: CGFloat = 8
    private static let namePadding: CGFloat = 14
    private static let spacing: CGFloat = 10
    private static let trailingPadding: CGFloat = 22

    /// Measured, not laid out: during a cross-fade both lines are present, and the
    /// capsule must size to the arriving one alone.
    static func width(for face: ReadingTypeface) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: face.font(ofSize: fontSize)]
        let name = (face.displayName as NSString).size(withAttributes: attributes).width
        let reason = (face.rationale as NSString).size(withAttributes: attributes).width
        return ceil(wellInset + namePadding * 2 + name + spacing + reason + trailingPadding)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            line(for: face)
                .id(face)
                .transition(.opacity)
        }
        .frame(width: Self.width(for: face), alignment: .leading)
        .frame(maxHeight: .infinity)
        // A longer line fading in stays inside the capsule while it widens.
        .clipShape(Capsule(style: .continuous))
        .background {
            Capsule(style: .continuous)
                .fill(palette.surface)
                .overlay(Capsule(style: .continuous).strokeBorder(palette.hairline))
                .shadow(color: palette.shadow, radius: 18, y: 8)
                .shadow(color: palette.shadow.opacity(0.5), radius: 2, y: 1)
        }
        .accessibilityHidden(true)
    }

    private func line(for face: ReadingTypeface) -> some View {
        HStack(spacing: Self.spacing) {
            Text(face.displayName)
                .foregroundStyle(palette.ink)
                .padding(.horizontal, Self.namePadding)
                .frame(maxHeight: .infinity)
                .background(Capsule(style: .continuous).fill(palette.well))
            Text(face.rationale)
                .foregroundStyle(palette.ink.opacity(0.6))
        }
        .font(Font(face.font(ofSize: Self.fontSize) as CTFont))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(Self.wellInset)
    }
}

/// The microphones, one per line. "Automàtic" follows the system input; a chosen
/// microphone that is unplugged stays listed, so it is clear the choice is kept and will
/// be used again when it comes back. The selection pill glides between rows.
private struct InputPanel: View {
    @ObservedObject var controller: SubtitleController
    @ObservedObject var inputs: AudioInputDeviceList
    let palette: SettingsBarPalette

    @Namespace private var namespace
    @StateObject private var monitor = InputLevelMonitor()
    private static let width: CGFloat = 300
    private static let rowHeight: CGFloat = 40

    var body: some View {
        let chosen = controller.preferredInputUID
        let chosenIsMissing = chosen.map { uid in !inputs.devices.contains { $0.uid == uid } } ?? false
        VStack(alignment: .leading, spacing: 2) {
            InputLevelBar(monitor: monitor, palette: palette)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 4)
            if let problem = meterProblem {
                Text(problem)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.ink.opacity(0.7))
                    .padding(.horizontal, 12)
                    .transition(.opacity)
            }
            Text(localized("Micròfon"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.mutedInk)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 2)
            row(
                id: "automatic",
                symbol: "wand.and.stars",
                name: localized("Automàtic"),
                caption: inputs.systemDefault.map { localized("Ara: \($0.name)") } ?? localized("El del sistema"),
                isCurrent: chosen == nil
            ) {
                controller.selectInput(uid: nil, name: nil)
            }
            ForEach(inputs.devices) { device in
                row(
                    id: device.uid,
                    symbol: device.symbol,
                    name: device.name,
                    caption: device.transportLabel,
                    isCurrent: chosen == device.uid
                ) {
                    controller.selectInput(uid: device.uid, name: device.name)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
            if chosenIsMissing, let chosen {
                row(
                    id: chosen,
                    symbol: "mic.slash",
                    name: controller.preferredInputName ?? localized("Micròfon"),
                    caption: localized("Desconnectat · ara s'usa l'automàtic"),
                    isCurrent: true,
                    isDimmed: true
                ) { }
                .transition(.opacity)
            }
        }
        .padding(6)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .animation(SettingsBar.motion, value: inputs.devices)
        .animation(SettingsBar.motion, value: inputs.systemDefaultUID)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(palette.surface)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(palette.hairline))
                .shadow(color: palette.shadow, radius: 18, y: 8)
                .shadow(color: palette.shadow.opacity(0.5), radius: 2, y: 1)
        }
        .onTapGesture { }
        // The meter follows whichever microphone would be used now: the chosen one, or
        // the system's while it is unplugged or "Automàtic" is chosen.
        .animation(.easeInOut(duration: 0.25), value: monitor.status)
        .onAppear { listenToCurrentInput() }
        .onDisappear { monitor.stop() }
        .onChange(of: controller.preferredInputUID) { _, _ in listenToCurrentInput() }
        .onChange(of: inputs.devices) { _, _ in listenToCurrentInput() }
        .onChange(of: inputs.systemDefaultUID) { _, _ in listenToCurrentInput() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Micròfon"))
        .accessibilityHint(localized("Es pot canviar també mentre grava, sense perdre el text"))
    }

    private var meterProblem: String? {
        switch monitor.status {
        case .listening: nil
        case .asking: localized("Esperant el permís del micròfon…")
        case .denied: localized("Sense permís: Configuració del Sistema › Privacitat i seguretat › Micròfon")
        case .unavailable: localized("Aquest micròfon no s'ha pogut obrir")
        }
    }

    private func listenToCurrentInput() {
        monitor.listen(to: AudioInputs.resolve(preferredUID: controller.preferredInputUID))
    }

    private func row(
        id: String,
        symbol: String,
        name: String,
        caption: String,
        isCurrent: Bool,
        isDimmed: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(SettingsBar.selection) { action() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(caption)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .opacity(0.75)
                        .contentTransition(.interpolate)
                }
                Spacer(minLength: 6)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(isCurrent ? 1 : 0)
                    .scaleEffect(isCurrent ? 1 : 0.6)
            }
            .foregroundStyle(isCurrent && !isDimmed ? palette.ink : palette.mutedInk)
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .background {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(palette.knob.opacity(isDimmed ? 0.55 : 1))
                        .shadow(color: palette.shadow, radius: 3, y: 1)
                        .matchedGeometryEffect(id: "input.pill", in: namespace)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isDimmed)
        .accessibilityLabel(name)
        .accessibilityValue(caption)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// The vocabulary of the day in a card of the bar's material above it: the field, the
/// cloud of terms, and "Esborra-ho tot" once there are any.
private struct VocabularyPanel: View {
    @ObservedObject var controller: SubtitleController
    let palette: SettingsBarPalette
    let close: () -> Void
    private static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(localized("Vocabulari de l'acte"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.mutedInk)
                Spacer()
                if !controller.vocabulary.isEmpty {
                    Button(localized("Esborra-ho tot")) {
                        withAnimation(VocabularyCloud.removal) { controller.clearVocabulary() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.mutedInk)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            VocabularyCloud(
                terms: controller.vocabulary,
                limit: SubtitleController.vocabularyLimit,
                palette: VocabularyPalette(
                    ink: palette.ink, mutedInk: palette.mutedInk, pill: palette.knob,
                    well: palette.well, hairline: palette.hairline, shadow: palette.shadow
                ),
                pillSize: 12,
                fieldSize: 12,
                onAdd: { controller.addVocabularyTerm($0) },
                onRemove: { controller.removeVocabularyTerm($0) },
                onCancel: close
            )
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .padding(6)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .animation(SettingsBar.motion, value: controller.vocabulary.isEmpty)
        .background {
            // The empty tap on the material, not on the card, keeps a click on the
            // card from reaching the recording surface beneath while leaving the
            // field free to take the focus (a tap gesture over it kept it from doing so).
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(palette.surface)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(palette.hairline))
                .shadow(color: palette.shadow, radius: 18, y: 8)
                .shadow(color: palette.shadow.opacity(0.5), radius: 2, y: 1)
                .onTapGesture { }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Vocabulari de l'acte"))
    }
}

/// The languages, one per line: the one in use carries the pill, an installed one is
/// chosen with a click, and one not yet on the Mac shows its size and downloads only
/// when "Baixa" is clicked (App Review Guideline 4.2.3). The download fills its row's
/// button from the left. Right-click an installed language to delete it.
private struct LanguagePanel: View {
    @ObservedObject var packs: LanguagePackStore
    /// While listening or closing a sentence the language cannot change.
    let isBusy: Bool
    let palette: SettingsBarPalette

    @Namespace private var namespace
    @State private var pendingRemoval: SpeechLanguage?
    private static let width: CGFloat = 320
    private static let rowHeight: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(localized("Idioma de la veu"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.mutedInk)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 2)
            ForEach(packs.catalog.languages) { language in
                row(language)
            }
            if isBusy {
                Text(localized("Atura la transcripció per canviar d'idioma"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.ink.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .transition(.opacity)
            }
        }
        .padding(6)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .animation(SettingsBar.motion, value: packs.states)
        .animation(SettingsBar.selection, value: packs.selectedLanguageID)
        .animation(.easeInOut(duration: 0.25), value: isBusy)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(palette.surface)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(palette.hairline))
                .shadow(color: palette.shadow, radius: 18, y: 8)
                .shadow(color: palette.shadow.opacity(0.5), radius: 2, y: 1)
        }
        .onTapGesture { }
        .task { await packs.refreshSizes() }
        .confirmationDialog(
            pendingRemoval.map { localized("Vols esborrar \($0.name)?") } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { language in
            Button(localized("Esborra"), role: .destructive) {
                Task { await packs.remove(language) }
            }
        } message: { language in
            Text(localized("S'alliberaran \(Self.size(packs.downloadSize(of: language))). Es pot tornar a baixar quan vulguis."))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Idioma de la veu"))
    }

    private func row(_ language: SpeechLanguage) -> some View {
        let state = packs.state(of: language)
        let isCurrent = packs.selectedLanguageID == language.id
        return HStack(spacing: 10) {
            LanguageCircle(languageID: language.id, look: figureLook(state: state, isCurrent: isCurrent), palette: palette)
                .frame(width: 16, height: 16)
                .frame(width: 30, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isCurrent ? LanguageCircle.orange.opacity(0.09) : palette.well)
                }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(language.name)
                        .font(.system(size: 12, weight: .semibold))
                    if language.stage == .beta {
                        BetaBadge(text: localized("Nou"), palette: palette, size: 9)
                    }
                }
                Text(caption(language, state: state, isCurrent: isCurrent))
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .opacity(0.75)
                    .contentTransition(.interpolate)
            }
            Spacer(minLength: 6)
            action(language, state: state, isCurrent: isCurrent)
        }
        .foregroundStyle(isCurrent ? palette.ink : palette.mutedInk)
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background {
            if isCurrent {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(palette.knob)
                    .shadow(color: palette.shadow, radius: 3, y: 1)
                    .outlinedWithoutColour(RoundedRectangle(cornerRadius: 16, style: .continuous), ink: palette.ink)
                    .matchedGeometryEffect(id: "language.pill", in: namespace)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            guard state == .installed, !isCurrent, !isBusy else { return }
            withAnimation(SettingsBar.selection) { packs.select(language) }
        }
        .contextMenu {
            if packs.isRemovable(language) {
                Button(localized("Esborra \(language.name)…"), role: .destructive) { pendingRemoval = language }
                    .disabled(isCurrent && isBusy)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(language.stage == .beta ? localized("\(language.name), nou") : language.name)
        .accessibilityValue(caption(language, state: state, isCurrent: isCurrent))
        .accessibilityAddTraits(isCurrent ? [.isSelected, .isButton] : .isButton)
    }

    /// The figure in colour on the Mac, faint to download, filling while it downloads.
    private func figureLook(state: LanguagePackStore.PackState, isCurrent: Bool) -> LanguageCircle.Look {
        switch state {
        case .installed: isCurrent ? .active : .installed
        case .downloading(let fraction): .downloading(fraction)
        case .notInstalled, .failed: .available
        }
    }

    private func caption(_ language: SpeechLanguage, state: LanguagePackStore.PackState, isCurrent: Bool) -> String {
        switch state {
        case .installed:
            if isCurrent { return localized("En ús") }
            return packs.isBundled(language)
                ? localized("Inclòs amb l'app · clica per fer-lo servir")
                : localized("Instal·lat · clica per fer-lo servir")
        case .notInstalled:
            return language.isPackStaged ? Self.size(packs.downloadSize(of: language)) : localized("Aviat")
        case .downloading(let fraction): return localized("Baixant… \(Int((fraction * 100).rounded())) %")
        case .failed(let message): return message
        }
    }

    @ViewBuilder
    private func action(_ language: SpeechLanguage, state: LanguagePackStore.PackState, isCurrent: Bool) -> some View {
        switch state {
        case .installed:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .opacity(isCurrent ? 1 : 0)
                .scaleEffect(isCurrent ? 1 : 0.6)
                .frame(width: 64, alignment: .trailing)
        case .notInstalled where !language.isPackStaged:
            // Listed so the reader knows it is coming; there is nothing to download yet.
            Color.clear.frame(width: 64, height: 24)
        case .notInstalled, .failed:
            Button {
                Task { await packs.install(language) }
            } label: {
                Text(state == .notInstalled ? localized("Baixa") : localized("Torna-hi"))
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 64, height: 24)
                    .background(Capsule(style: .continuous).fill(palette.well))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(localized("Baixa \(language.name), \(Self.size(packs.downloadSize(of: language)))"))
        case .downloading(let fraction):
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(palette.well)
                Capsule(style: .continuous)
                    .fill(palette.isDark ? palette.knob : palette.track)
                    .frame(width: max(8, 64 * CGFloat(fraction)))
                    .animation(.linear(duration: 0.2), value: fraction)
            }
            .frame(width: 64, height: 24)
            .accessibilityHidden(true)
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A thin bar across the top of the microphone card: how loud the microphone in use is
/// right now, so a quiet or wrong channel shows before anyone speaks. It rises with the
/// voice at once and falls back gently, in light grey on the card's well.
private struct InputLevelBar: View {
    let monitor: InputLevelMonitor
    let palette: SettingsBarPalette

    @State private var envelope = LevelEnvelope()

    var body: some View {
        TimelineView(.animation) { context in
            let level = envelope.advance(to: monitor.level(), at: context.date)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.well)
                    Capsule()
                        .fill(palette.isDark ? palette.knob : palette.track)
                        .frame(width: max(0, proxy.size.width * CGFloat(level)))
                }
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel(localized("Nivell del micròfon"))
    }
}

/// Fast attack, slower release, per frame: a meter that jumps up with a syllable and
/// sinks between words instead of flickering.
private final class LevelEnvelope {
    private var value: Float = 0
    private var last: Date?

    func advance(to target: Float, at date: Date) -> Float {
        let elapsed = Float(min(0.1, max(0, date.timeIntervalSince(last ?? date))))
        last = date
        let time: Float = target > value ? 0.03 : 0.25
        value += (target - value) * (1 - exp(-elapsed / time))
        return value
    }
}

/// The twin bar rises out from behind the bar: a short lift and a fade, with a slight
/// scale about its lower edge.
private struct InfoBarRise: ViewModifier {
    let amount: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - 0.03 * amount, anchor: .bottom)
            .offset(y: 10 * amount)
            .opacity(1 - amount)
    }
}

/// "Vols descartar…?", in a card that rises from the Descarta well.
private struct DiscardCard: View {
    let onDiscard: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized("Vols descartar aquesta transcripció?"))
                .font(.system(size: 13, weight: .semibold))
            Text(localized("No es desarà a Transcripcions i no es podrà recuperar."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(localized("Cancel·la"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(localized("Descarta"), role: .destructive, action: onDiscard)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
            .padding(.top, 8)
        }
        .padding(16)
        .frame(width: 290)
    }
}

/// A well of the bar that shrinks to nothing where it stands (or grows back): its width
/// follows the bar's spring, its fade is quicker, so a closing well has gone before it
/// is a sliver and an opening one shows once it has room.
private struct BarCollapse: ViewModifier {
    let isGone: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .fixedSize()
            .frame(width: isGone ? 0 : nil, alignment: .leading)
            .clipShape(Rectangle().inset(by: isGone ? 0 : -16))
            .animation(fade) { well in
                well
                    .opacity(isGone ? 0 : 1)
                    .scaleEffect(isGone && !reduceMotion ? 0.7 : 1)
                    .blur(radius: isGone && !reduceMotion ? 2 : 0)
            }
            .padding(.trailing, isGone ? 0 : 5)
            .allowsHitTesting(!isGone)
            .accessibilityHidden(isGone)
    }

    private var fade: Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        return isGone ? .easeOut(duration: 0.1) : .easeOut(duration: 0.22).delay(0.08)
    }
}

struct StaggeredEntrance: ViewModifier {
    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(x: isShown || reduceMotion ? 0 : -8)
            .scaleEffect(isShown || reduceMotion ? 1 : 0.92, anchor: .leading)
            .blur(radius: isShown || reduceMotion ? 0 : 3)
            .onAppear {
                let animation = reduceMotion
                    ? Animation.easeOut(duration: 0.18)
                    : .spring(response: 0.26, dampingFraction: 0.82)
                        .delay(0.02 + Double(index) * 0.022)
                withAnimation(animation) { isShown = true }
            }
    }
}

/// A notched track with one stop per size step. Dragging snaps stop to stop with a
/// haptic tick, so the size is chosen by feel as much as by eye.
struct SizeTrack: View {
    @Binding var value: Double
    let palette: SettingsBarPalette
    /// The reading pane's sizes unless told otherwise (a kept transcription's are smaller).
    var range: ClosedRange<CGFloat> = AppVisualMetrics.minimumFontSize...AppVisualMetrics.maximumFontSize
    var step: CGFloat = AppVisualMetrics.fontSizeStep

    @GestureState private var isDragging = false

    private let width: CGFloat = 124
    private let knob: CGFloat = 14
    private var lower: CGFloat { range.lowerBound }
    private var upper: CGFloat { range.upperBound }
    private var stops: Int { Int(((upper - lower) / step).rounded()) + 1 }
    private var usable: CGFloat { width - knob }

    private func clamped(_ size: CGFloat) -> CGFloat { min(upper, max(lower, size)) }

    private var fraction: CGFloat {
        (clamped(CGFloat(value)) - lower) / (upper - lower)
    }

    var body: some View {
        let knobCenter = knob / 2 + usable * fraction
        ZStack(alignment: .leading) {
            Capsule()
                .fill(palette.track)
                .frame(height: 3)
                .padding(.horizontal, knob / 2 - 1.5)
            HStack(spacing: 0) {
                ForEach(0..<stops, id: \.self) { index in
                    Circle()
                        .fill(palette.ink.opacity(0.22))
                        .frame(width: 2, height: 2)
                    if index < stops - 1 { Spacer(minLength: 0) }
                }
            }
            .padding(.horizontal, knob / 2 - 1)
            .offset(y: 6)
            Capsule()
                .fill(palette.ink.opacity(0.85))
                .frame(width: max(3, knobCenter - knob / 2 + 3), height: 3)
                .padding(.leading, knob / 2 - 1.5)
            Circle()
                .fill(palette.knob)
                .overlay(Circle().strokeBorder(palette.hairline))
                .shadow(color: palette.shadow.opacity(1.4), radius: isDragging ? 5 : 3, y: 1)
                .frame(width: knob, height: knob)
                .scaleEffect(isDragging ? 1.18 : 1)
                .offset(x: knobCenter - knob / 2)
        }
        .frame(width: width, height: 32)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isDragging) { _, state, _ in state = true }
                .onChanged { drag in
                    let position = min(1, max(0, (drag.location.x - knob / 2) / usable))
                    let snapped = lower + (position * (upper - lower) / step).rounded() * step
                    guard Double(snapped) != value else { return }
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
                        value = Double(snapped)
                    }
                    NSHapticFeedbackManager.defaultPerformer.perform(
                        .alignment,
                        performanceTime: .now
                    )
                }
        )
        .animation(.spring(response: 0.26, dampingFraction: 0.7), value: isDragging)
        .accessibilityElement()
        .accessibilityLabel(localized("Mida del text"))
        .accessibilityValue(localized("\(Int(value)) punts"))
        .accessibilityAdjustableAction { direction in
            let delta: CGFloat = direction == .increment ? step : -step
            value = Double(clamped(CGFloat(value) + delta))
        }
    }
}
