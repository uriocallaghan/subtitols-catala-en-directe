import CoreText
import SubtitolCore
import SwiftUI

/// Measures rendered word widths so the layout engine and the drawn text agree exactly.
///
/// Widths are cached because the same words recur constantly in a transcript and the
/// measurement sits on the main actor, in the path that also has to stay clear for the
/// recognizer's updates.
@MainActor
enum WordMetrics {
    private static var cache: [String: CGFloat] = [:]
    private static var cachedFontSize: CGFloat = 0
    private static var cachedTracking: CGFloat = 0
    private static var cachedTypeface: ReadingTypeface = .default

    private static let cacheLimit = 1_024

    static func width(
        of text: String,
        typeface: ReadingTypeface,
        fontSize: CGFloat,
        tracking: CGFloat
    ) -> CGFloat {
        measuredWidth(
            of: AppVisualMetrics.renderedWord(text, typeface: typeface),
            typeface: typeface,
            fontSize: fontSize,
            tracking: tracking
        )
    }

    static func trailingGuardWidth(
        typeface: ReadingTypeface,
        fontSize: CGFloat,
        tracking: CGFloat
    ) -> CGFloat {
        measuredWidth(
            of: typeface.trailingGlyphGuard,
            typeface: typeface,
            fontSize: fontSize,
            tracking: tracking
        )
    }

    static func spaceWidth(
        typeface: ReadingTypeface,
        fontSize: CGFloat,
        tracking: CGFloat
    ) -> CGFloat {
        measuredWidth(of: " ", typeface: typeface, fontSize: fontSize, tracking: tracking)
    }

    private static func measuredWidth(
        of renderedText: String,
        typeface: ReadingTypeface,
        fontSize: CGFloat,
        tracking: CGFloat
    ) -> CGFloat {
        if cachedFontSize != fontSize || cachedTracking != tracking || cachedTypeface != typeface {
            cache.removeAll(keepingCapacity: true)
            cachedFontSize = fontSize
            cachedTracking = tracking
            cachedTypeface = typeface
        }
        if let cached = cache[renderedText] { return cached }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: typeface.font(ofSize: fontSize)
        ]
        if tracking != 0 { attributes[.kern] = tracking }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: renderedText, attributes: attributes)
        )
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)).rounded(.up)

        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[renderedText] = width
        return width
    }
}
