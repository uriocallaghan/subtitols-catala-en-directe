import SwiftUI

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
}
