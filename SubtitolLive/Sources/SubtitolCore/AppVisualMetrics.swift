import AppKit

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

    /// The AppKit counterpart of the Inter Medium font used by the SwiftUI transcript.
    /// Keeping the font choice here makes measurement and drawing use identical glyphs.
    public static func readingFont(ofSize size: CGFloat) -> NSFont {
        NSFont(name: readingFontName, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .medium)
    }

    /// SwiftUI clips glyph ink to a `Text`'s own typographic advance before an outer
    /// frame is applied. Final accents can overhang that advance, so invisible hair
    /// spaces must live inside the same text run to enlarge its internal layout bounds.
    public static let trailingGlyphGuard = "\u{200A}\u{200A}\u{200A}"

    /// Text shown for one independently laid-out transcript word.
    public static func renderedWord(_ word: String) -> String {
        word + trailingGlyphGuard
    }

    /// How far back the optional age-gradient reaches, in words. Only used by the
    /// presentation toggle; the accessible default keeps every word at full contrast.
    public static let gradientDepthInWords = 12

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
