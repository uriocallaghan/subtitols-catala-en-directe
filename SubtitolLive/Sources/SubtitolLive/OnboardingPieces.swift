import SubtitolCore
import SwiftUI

// The first run's pieces, shared by the iPhone (`OnboardingView`) and the Mac
// (`MacOnboardingView`): the level dots, the headings and buttons, the language cards,
// the download pill, the confetti and the slow entrances.

/// The first run's three levels: the app's language, the language to download, and the
/// microphone.
enum OnboardingStep: Int, CaseIterable, Comparable {
    case welcome, language, microphone

    static func < (a: OnboardingStep, b: OnboardingStep) -> Bool { a.rawValue < b.rawValue }
}

/// The language being downloaded, under the level dots: its figure, the percentage
/// filling the capsule in orange, and a check once it is ready.
struct OnboardingDownloadPill: View {
    let language: SpeechLanguage
    let state: LanguagePackStore.PackState
    let copy: OnboardingCopy
    let palette: SettingsBarPalette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 7) {
            LanguageFigure(languageID: language.id, colourful: true, ink: palette.ink)
                .frame(width: 14, height: 14)
            Group {
                switch state {
                case .downloading(let fraction):
                    Text(copy.pillDownloading(language.name, Int((fraction * 100).rounded())))
                case .installed:
                    Text(copy.pillReady(language.name))
                case .failed:
                    Text(copy.downloadFailed)
                case .notInstalled:
                    Text(language.name)
                }
            }
            .font(.inter(12, relativeTo: .caption).monospacedDigit())
            .foregroundStyle(palette.ink.opacity(0.7))
            .contentTransition(.numericText())
            if state == .installed {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(LanguageCircle.orange)
                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, typeSize.isAccessibilitySize ? 6 : 0)
        .frame(minHeight: 28)
        .background {
            ZStack(alignment: .leading) {
                Capsule().fill(palette.well)
                if case .downloading(let fraction) = state {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(LanguageCircle.orange.opacity(0.2))
                            .frame(width: max(proxy.size.height, proxy.size.width * fraction))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .animation(.easeOut(duration: 0.3), value: state)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
        .accessibilityElement(children: .combine)
    }
}

/// One dot per level, nothing between them: a dot takes the project's orange when its screen
/// is done, the current one is ink, the rest wait in grey.
struct OnboardingLevelTrack: View {
    let current: OnboardingStep
    let cleared: Set<OnboardingStep>
    let palette: SettingsBarPalette
    let label: String

    /// With Differentiate Without Colour the dots also differ in shape: the current one
    /// is a short bar, the ones still to come are rings.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    var body: some View {
        HStack(spacing: 10) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                let isCurrent = step == current && !cleared.contains(step)
                let isWaiting = !isCurrent && !cleared.contains(step)
                Capsule()
                    .fill(colour(for: step))
                    .overlay {
                        Capsule().strokeBorder(palette.ink.opacity(0.6), lineWidth: 1.5)
                            .opacity(differentiate && isWaiting ? 1 : 0)
                    }
                    .frame(width: differentiate && isCurrent ? 18 : 7, height: 7)
                    .scaleEffect(isCurrent && !differentiate ? 1.25 : 1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: differentiate)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: cleared)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: current)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private func colour(for step: OnboardingStep) -> Color {
        if cleared.contains(step) { return LanguageCircle.orange }
        if step == current { return palette.ink }
        return differentiate ? .clear : palette.ink.opacity(0.14)
    }
}

struct OnboardingHeading: View {
    let title: String
    let subtitle: String
    let theme: ReadingTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.inter(32, relativeTo: .largeTitle))
                .tracking(-0.9)
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.inter(16, relativeTo: .body))
                .foregroundStyle(theme.ink.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

struct OnboardingButton: View {
    let title: String
    let palette: SettingsBarPalette
    var isEnabled = true
    var symbol: String?
    /// While set, the capsule fills from the left as a download goes on, and cannot be pressed.
    var progress: Double?
    let action: () -> Void

    var body: some View {
        let active = isEnabled && progress == nil
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).scaledFont(size: 15, weight: .semibold, relativeTo: .headline)
                }
                Text(title)
                    .font(.inter(17, relativeTo: .headline))
                    .contentTransition(.interpolate)
            }
            .foregroundStyle(active ? palette.surface : palette.ink.opacity(progress == nil ? 0.35 : 0.8))
            .monospacedDigit()
            // Air above and below the title, so a large title never touches the capsule.
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background {
                ZStack(alignment: .leading) {
                    Capsule().fill(active ? palette.ink : palette.well)
                    if let progress {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(LanguageCircle.orange.opacity(0.28))
                                .frame(width: max(proxy.size.height, proxy.size.width * min(max(progress, 0), 1)))
                                .animation(.easeOut(duration: 0.4), value: progress)
                        }
                        .transition(.opacity)
                    }
                }
                .clipShape(Capsule())
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!active)
    }
}

struct OnboardingTextButton: View {
    let title: String
    let palette: SettingsBarPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.inter(15, relativeTo: .subheadline))
                .foregroundStyle(palette.ink.opacity(0.55))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// An app language: its figure and its name, in a card that is outlined when chosen.
struct ChoiceChip: View {
    let languageID: String
    let title: String
    let isSelected: Bool
    let palette: SettingsBarPalette
    let theme: ReadingTheme
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Button(action: action) {
            HStack(spacing: 10) {
                // The figure fills with colour from the bottom when chosen.
                LanguageCircle(languageID: languageID, look: isSelected ? .active : .available, palette: palette)
                    .frame(width: 20, height: 20)
                    .frame(width: 36, height: 36)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? LanguageCircle.orange.opacity(0.09) : palette.well)
                    }
                Text(title)
                    .font(.inter(16, relativeTo: .body))
                    .foregroundStyle(theme.ink)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(shape.fill(palette.surface))
            .overlay(shape.strokeBorder(isSelected ? palette.ink : palette.hairline, lineWidth: isSelected ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A language to read, as on the languages screen: figure, name, size, and a check.
struct SpeechLanguageCard: View {
    let language: SpeechLanguage
    let size: String
    /// The language's name in the interface language, when it differs from its own.
    let localName: String?
    let isInstalled: Bool
    let isSelected: Bool
    let palette: SettingsBarPalette
    let theme: ReadingTheme
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    /// The name and its tags sit side by side, or one under the other at the largest sizes.
    private var tagLayout: AnyLayout {
        typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 7))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        Button(action: action) {
            HStack(spacing: 14) {
                LanguageCircle(languageID: language.id, look: isSelected ? .active : .available, palette: palette)
                    .frame(width: 24, height: 24)
                    .frame(width: 46, height: 46)
                    .background {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(isSelected ? LanguageCircle.orange.opacity(0.09) : palette.well)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    tagLayout {
                        Text(language.name)
                            .font(.inter(18, relativeTo: .headline))
                            .foregroundStyle(theme.ink)
                        if language.stage == .beta {
                            BetaBadge(text: localized("Nou"), palette: palette)
                        }
                    }
                    tagLayout {
                        // What it costs to download, as a tag: this screen is about the download.
                        HStack(spacing: 3) {
                            Image(systemName: isInstalled ? "checkmark" : "arrow.down")
                                .scaledFont(size: 9, weight: .bold, relativeTo: .caption)
                            Text(size)
                                .font(.inter(12, relativeTo: .caption).monospacedDigit())
                        }
                        .foregroundStyle(palette.ink.opacity(0.7))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(palette.well))
                        if let localName, localName.compare(language.name, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame {
                            Text(localName.prefix(1).uppercased() + localName.dropFirst())
                                .font(.inter(13, relativeTo: .footnote))
                                .foregroundStyle(theme.ink.opacity(0.56))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    Circle().strokeBorder(palette.ink.opacity(0.2), lineWidth: 1.5)
                        .opacity(isSelected ? 0 : 1)
                    Circle().fill(palette.ink)
                        .scaleEffect(isSelected ? 1 : 0.3)
                        .opacity(isSelected ? 1 : 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(palette.surface)
                        .scaleEffect(isSelected ? 1 : 0.3)
                        .opacity(isSelected ? 1 : 0)
                }
                .frame(width: 26, height: 26)
                .padding(.trailing, 6)
            }
            .padding(12)
            .background(shape.fill(palette.surface))
            .overlay(shape.strokeBorder(isSelected ? palette.ink : palette.hairline, lineWidth: isSelected ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Orange pieces thrown up from the middle, falling and turning as they fade.
struct Confetti: View {
    let trigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?

    struct Bit {
        let angle: Double
        let speed: Double
        let spin: Double
        let size: CGFloat
        let tone: Int
        let round: Bool
    }

    private static let bits: [Bit] = (0..<46).map { i in
        var g = SystemRandomNumberGenerator()
        return Bit(
            angle: -.pi / 2 + Double.random(in: -1.25...1.25, using: &g),
            speed: Double.random(in: 260...520, using: &g),
            spin: Double.random(in: -8...8, using: &g),
            size: CGFloat.random(in: 6...11, using: &g),
            tone: i % 4,
            round: i % 3 == 0
        )
    }

    private static let tones: [Color] = [
        Color(red: 1, green: 0.392, blue: 0), Color(red: 1, green: 0.549, blue: 0),
        Color(red: 1, green: 0.651, blue: 0), Color(red: 1, green: 0.761, blue: 0),
    ]

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { context in
            Canvas { g, size in
                guard let start else { return }
                let t = context.date.timeIntervalSince(start)
                guard t < 2.2 else { return }
                let origin = CGPoint(x: size.width / 2, y: size.height / 2)
                for bit in Self.bits {
                    let x = origin.x + cos(bit.angle) * bit.speed * t
                    let y = origin.y + sin(bit.angle) * bit.speed * t + 420 * t * t
                    var piece = g
                    piece.opacity = max(0, 1 - t / 2.2)
                    piece.translateBy(x: x, y: y)
                    piece.rotate(by: .radians(bit.spin * t))
                    let rect = CGRect(x: -bit.size / 2, y: -bit.size / 2, width: bit.size, height: bit.round ? bit.size : bit.size * 0.45)
                    let shape = bit.round ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 1.5)
                    piece.fill(shape, with: .color(Self.tones[bit.tone]))
                }
            }
        }
        .onChange(of: trigger) { _, _ in
            guard !reduceMotion else { return }
            start = Date()
            Task {
                try? await Task.sleep(for: .seconds(2.3))
                start = nil
            }
        }
    }
}

/// A screen's pieces arrive slowly, one after another, rising out of a blur. Under
/// Reduce Motion they only fade in.
struct SlowEntrance: ViewModifier {
    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown || reduceMotion ? 0 : 22)
            .blur(radius: isShown || reduceMotion ? 0 : 6)
            .onAppear {
                guard !isShown else { return }
                let animation = reduceMotion
                    ? Animation.easeOut(duration: 0.35)
                    : .spring(response: 0.8, dampingFraction: 0.9).delay(0.18 + Double(min(index, 8)) * 0.11)
                withAnimation(animation) { isShown = true }
            }
    }
}

struct StepFade: ViewModifier {
    let offset: CGFloat
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .blur(radius: blur)
            .opacity(opacity)
    }
}
