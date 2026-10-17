import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Colours for the transcript pane.
///
/// Ink is `#111` on a near-white ground rather than pure black on pure white: at 56pt and
/// up, maximum luminance contrast starts to halate and blur the glyph edges. `#111` on
/// `#FAFAFA` still measures about 16:1, far above the 4.5:1 floor, while reading calmer
/// over a long session.
struct ReadingTheme: Equatable {
    let ink: Color
    let paper: Color
    let canvas: Color

    static let light = ReadingTheme(
        ink: Color(red: 0.067, green: 0.067, blue: 0.067),
        paper: Color(red: 0.980, green: 0.980, blue: 0.980),
        canvas: Color(red: 0.949, green: 0.949, blue: 0.949)
    )

    /// Light-on-dark is what many people reading captions for long stretches prefer, and
    /// it is what broadcast captioning has settled on. `#F2F2F2` on `#121212` is ~15:1.
    static let dark = ReadingTheme(
        ink: Color(red: 0.949, green: 0.949, blue: 0.949),
        paper: Color(red: 0.071, green: 0.071, blue: 0.071),
        canvas: Color(red: 0.043, green: 0.043, blue: 0.043)
    )

    static func resolved(isDark: Bool) -> ReadingTheme { isDark ? .dark : .light }

    /// The theme partway between light (0) and dark (1). Switching themes animates this
    /// value, so every surface crosses over together instead of snapping.
    static func blended(darkness: Double) -> ReadingTheme {
        ReadingTheme(
            ink: .blend(light.ink, dark.ink, darkness),
            paper: .blend(light.paper, dark.paper, darkness),
            canvas: .blend(light.canvas, dark.canvas, darkness)
        )
    }
}

extension Color {
    /// Straight sRGB mix, alpha included. `Color.mix` needs macOS 15.
    static func blend(_ from: Color, _ to: Color, _ amount: Double) -> Color {
        let t = min(1, max(0, amount))
        if t == 0 { return from }
        if t == 1 { return to }
        let a = sRGBComponents(from)
        let b = sRGBComponents(to)
        func mix(_ x: CGFloat, _ y: CGFloat) -> Double { Double(x) + (Double(y) - Double(x)) * t }
        return Color(
            .sRGB,
            red: mix(a.red, b.red),
            green: mix(a.green, b.green),
            blue: mix(a.blue, b.blue),
            opacity: mix(a.alpha, b.alpha)
        )
    }

    private static func sRGBComponents(
        _ color: Color
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        #if canImport(AppKit)
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue, alpha)
        #endif
    }
}

/// Re-renders its content on every frame of a theme change with the in-between
/// darkness. Colour changes on `Text` and some AppKit-backed views do not interpolate on
/// their own, so the blend is computed here rather than left to each view.
struct ThemeBlend<Content: View>: View, Animatable {
    var darkness: Double
    @ViewBuilder let content: (Double) -> Content

    var animatableData: Double {
        get { darkness }
        set { darkness = newValue }
    }

    var body: some View { content(darkness) }
}
