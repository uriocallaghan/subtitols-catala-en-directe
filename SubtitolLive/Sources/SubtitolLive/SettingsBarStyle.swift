import SubtitolCore
import SwiftUI

// Pieces of the settings bar that the Mac bar and the iPhone bar share.

/// Soft, near-monochrome surfaces: a raised pill, recessed wells, and a lifted knob that
/// marks whichever control is open.
struct SettingsBarPalette {
    let isDark: Bool
    let surface: Color
    let well: Color
    let knob: Color
    let ink: Color
    let track: Color
    let hairline: Color
    let shadow: Color
    let recordFill: Color
    let recordStop: Color

    var mutedInk: Color { ink.opacity(0.48) }

    /// The palette partway between light (0) and dark (1); see `ReadingTheme.blended`.
    static func blended(darkness: Double) -> SettingsBarPalette {
        let l = resolved(isDark: false)
        let d = resolved(isDark: true)
        func c(_ path: KeyPath<SettingsBarPalette, Color>) -> Color {
            .blend(l[keyPath: path], d[keyPath: path], darkness)
        }
        return SettingsBarPalette(
            isDark: darkness >= 0.5,
            surface: c(\.surface),
            well: c(\.well),
            knob: c(\.knob),
            ink: c(\.ink),
            track: c(\.track),
            hairline: c(\.hairline),
            shadow: c(\.shadow),
            recordFill: c(\.recordFill),
            recordStop: c(\.recordStop)
        )
    }

    static func resolved(isDark: Bool) -> SettingsBarPalette {
        isDark
            ? SettingsBarPalette(
                isDark: true,
                surface: Color(white: 0.135),
                well: Color(white: 0.19),
                knob: Color(white: 0.31),
                ink: Color(white: 0.95),
                track: Color(white: 0.26),
                hairline: .white.opacity(0.07),
                shadow: .black.opacity(0.55),
                recordFill: Color(white: 0.95),
                recordStop: Color(white: 0.08)
            )
            : SettingsBarPalette(
                isDark: false,
                surface: .white,
                well: Color(white: 0.945),
                knob: .white,
                ink: Color(white: 0.09),
                track: Color(white: 0.86),
                hairline: .black.opacity(0.045),
                shadow: .black.opacity(0.11),
                recordFill: .white,
                recordStop: Color(white: 0.09)
            )
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Idle is a red dot; recording morphs it into a stop square and lets a ring breathe
/// out from the button.
struct RecordGlyph: View {
    let isRecording: Bool
    let isBusy: Bool
    let palette: SettingsBarPalette

    private let red = Color(red: 0.96, green: 0.23, blue: 0.21)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isRecording {
                // Under Reduce Motion the ring stays where it is and only breathes in
                // opacity; otherwise it spreads out from the button.
                Circle()
                    .stroke(red.opacity(0.6), lineWidth: 2)
                    .phaseAnimator([false, true]) { ring, expanded in
                        ring
                            .scaleEffect(reduceMotion ? 1.08 : (expanded ? 1.32 : 0.96))
                            .opacity(expanded ? (reduceMotion ? 0.25 : 0) : 0.9)
                    } animation: { expanded in
                        reduceMotion
                            ? .easeInOut(duration: 1.2)
                            : (expanded ? .easeOut(duration: 1.5) : .linear(duration: 0))
                    }
                    .transition(.opacity)
            }
            Circle()
                .fill(palette.recordFill)
                .shadow(color: palette.shadow, radius: 4, y: 2)
            if isBusy {
                ProgressView()
                    .controlSize(.mini)
                    // The record fill is light in both themes.
                    .colorScheme(.light)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            } else {
                RoundedRectangle(cornerRadius: isRecording ? 3 : 5.5, style: .continuous)
                    .fill(isRecording ? palette.recordStop : red)
                    .frame(width: isRecording ? 10 : 11, height: isRecording ? 10 : 11)
                    .rotationEffect(.degrees(isRecording ? 90 : 0))
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.68), value: isRecording)
        .animation(.easeInOut(duration: 0.2), value: isBusy)
    }
}

extension TranscriptionProfile {
    var symbolName: String {
        switch self {
        case .reliable: "tortoise.fill"
        case .balanced: "gauge.with.dots.needle.50percent"
        case .immediate: "hare.fill"
        }
    }
}

// MARK: - Accessibility

/// A system font at `size` that grows with the reader's text size (Dynamic Type), as
/// `Font.custom(_:size:relativeTo:)` does for Inter. The Mac has no system text size, so
/// there it stays at `size`.
private struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}

/// With Differentiate Without Colour on, a chosen option's raised pill also takes an ink
/// outline: a white pill on a light grey well is a difference of shade alone.
private struct OutlineWithoutColour<S: InsettableShape>: ViewModifier {
    let shape: S
    let ink: Color

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    func body(content: Content) -> some View {
        content
            .overlay {
                shape.strokeBorder(ink.opacity(differentiate ? 0.7 : 0), lineWidth: 1.5)
            }
            .animation(.easeInOut(duration: 0.25), value: differentiate)
    }
}

extension View {
    func scaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo style: Font.TextStyle = .body
    ) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, relativeTo: style))
    }

    func outlinedWithoutColour<S: InsettableShape>(_ shape: S, ink: Color) -> some View {
        modifier(OutlineWithoutColour(shape: shape, ink: ink))
    }
}
