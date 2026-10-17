import CoreGraphics

public enum AppVisualMetrics {
    public static let minimumPanelInset: CGFloat = 0
    public static let referencePanelInset: CGFloat = 0
    /// A little rounder than the native Mac titlebar window, without the Figma 40pt bite.
    public static let panelCornerRadius: CGFloat = 22
    public static let trafficLightOffset = CGSize(width: 8, height: 8)

    // MARK: - Reading

    /// About -0.031em: a compact Inter setting that keeps word shapes readable.
    public static let trackingAtReferenceFontSize: CGFloat = -2.2
    /// Roughly 0.27em at the 70pt reference — about a typed space. The gap has to read
    /// as wider than the letter gap for word shapes to separate at a glance.
    public static let interWordGapAtReferenceFontSize: CGFloat = 19
    public static let referenceFontSize: CGFloat = 70

    /// Line pitch as a multiple of font size. Tightened by request from 1.45. Below about
    /// 1.2 the descenders of one line start colliding with the ascenders of the next.
    public static let lineHeightRatio: CGFloat = 1.25

    /// Height of the top fade band, in line pitches. Text dissolves as the roll-up pushes
    /// it out of the pane, so nothing fades while it is still inside the reading block.
    public static let exitBandLineFraction: CGFloat = 0.75

    public static let caretWidthRatio: CGFloat = 0.05
    public static let caretHeightRatio: CGFloat = 0.78

    public static let defaultFontSize: CGFloat = 56
    public static let minimumFontSize: CGFloat = 32
    public static let maximumFontSize: CGFloat = 96
    public static let fontSizeStep: CGFloat = 4

    public static let readingFontName = "Inter18pt-Medium"

    /// The platform counterpart of the Inter Medium font used by the SwiftUI transcript.
    /// Keeping the font choice here makes measurement and drawing use identical glyphs.
    public static func readingFont(ofSize size: CGFloat) -> PlatformFont {
        PlatformFont(name: readingFontName, size: size)
            ?? PlatformFont.systemFont(ofSize: size, weight: .medium)
    }

    /// SwiftUI clips glyph ink to a `Text`'s own typographic advance before an outer
    /// frame is applied. Final accents can overhang that advance, so invisible hair
    /// spaces must live inside the same text run to enlarge its internal layout bounds.
    public static let trailingGlyphGuard = "\u{200A}\u{200A}\u{200A}"

    /// Text shown for one independently laid-out transcript word.
    public static func renderedWord(
        _ word: String,
        typeface: ReadingTypeface = .default
    ) -> String {
        word + typeface.trailingGlyphGuard
    }

    /// Opacity of a whole line under the age gradient, from the row it sits on.
    ///
    /// Whole lines fade together: fading word by word left the start of a sentence
    /// dimmer than its end, so the reader met faint words exactly where they start
    /// reading. The live lane (`reserve` rows) plus the two rows above it keep full
    /// contrast; from there opacity falls in equal steps and reaches zero on the first
    /// row above the pane, so the top row is still faintly readable and a line is
    /// already invisible by the time it is dropped. Anything that reached the edge with
    /// ink left would vanish at once — the pop this curve exists to avoid.
    ///
    /// `curve` shapes the steps. The Mac pane is tall, so equal steps read evenly. A
    /// phone shows few rows under the voice orb: `.eased` keeps the rows just above the
    /// live lane nearly at full contrast, where the reader still is, and spends the fall
    /// on the rows next to the orb, so the text melts into it rather than dimming as a
    /// staircase.
    public static func ageGradientOpacity(
        rowFromBottom: Int,
        visibleRows: Int,
        reserve: Int,
        curve: AgeGradientCurve = .linear
    ) -> Double {
        let lastFullRow = reserve + 1
        let depth = rowFromBottom - lastFullRow
        let stepsToZero = visibleRows - lastFullRow
        guard depth > 0 else { return 1 }
        guard stepsToZero > 0 else { return 0 }
        let fraction = min(1, Double(depth) / Double(stepsToZero))
        switch curve {
        case .linear:
            return max(0, 1 - fraction)
        case .eased:
            return max(0, 1 - fraction * fraction * (3 - 2 * fraction))
        }
    }

    public enum AgeGradientCurve: Sendable, Equatable {
        case linear
        case eased
    }

    /// Rows kept mounted above the pane while the age gradient is on, so a line that
    /// has rolled out finishes easing to zero instead of being removed mid-fade.
    public static let ageGradientTrailingRows = 2

    /// How long a line takes to ease into its new opacity. Much longer than the 0.24 s
    /// roll on purpose: the line moves briskly but dims slowly, so the change is felt
    /// rather than seen.
    public static let ageGradientTransitionSeconds: Double = 0.9

    /// Cross-fade between the old and new wrapping when the text size or typeface changes.
    public static let rewrapCrossFadeSeconds: Double = 0.3

    /// Top inset of the transcript pane. It reaches up into the margin to keep more past
    /// lines on screen, and it is the same with the age gradient on or off: tying it to
    /// the gradient made the top lines vanish whenever the gradient was switched off.
    public static let transcriptTopInset: CGFloat = 36

    public static func clampedFontSize(_ size: CGFloat) -> CGFloat {
        min(maximumFontSize, max(minimumFontSize, size))
    }

    public static func scaled(_ value: CGFloat, toFontSize fontSize: CGFloat) -> CGFloat {
        value * fontSize / referenceFontSize
    }

    public static func transcriptBottomInset(
        baseInset: CGFloat,
        fontSize: CGFloat
    ) -> CGFloat {
        let reservedLines = CGFloat(RollUpTranscriptLayout.baseReserve)
        let referenceReserveHeight = reservedLines
            * defaultFontSize
            * lineHeightRatio
        let currentReserveHeight = reservedLines
            * fontSize
            * lineHeightRatio

        // The roll-up layout keeps two logical lines free for live words. If the outer
        // inset stayed fixed, those lines would push the settled reading anchor upward
        // whenever the reader enlarged the type. Let the reserved lane consume the
        // bottom inset instead, so changing type size does not move the visual anchor.
        return max(0, baseInset + referenceReserveHeight - currentReserveHeight)
    }
}
