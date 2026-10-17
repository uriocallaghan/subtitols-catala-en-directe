import CoreGraphics

/// The families the reader can set the transcript in.
///
/// Inter and the two Atkinson Hyperlegible faces (Braille Institute) ship in the bundle,
/// all SIL OFL 1.1; SF Pro is the system font, reached through `PlatformFont.systemFont` and
/// never bundled, as Apple's licence requires. Atkinson Next is drawn for low vision:
/// letters that are easily confused get distinct shapes. Atkinson Mono adds fixed
/// width, which gave the best reading acuity for macular degeneration (Courier in
/// Mansfield 1996, Tarita-Nistor 2013, Xiong 2018). Measurement and drawing both go
/// through `font(ofSize:)`, which keeps the roll-up layout and the rendered glyphs in
/// exact agreement.
public enum ReadingTypeface: String, CaseIterable, Codable, Sendable {
    case inter
    case system
    case hyperlegible
    case hyperlegibleMono

    public static let `default`: Self = .inter

    public var displayName: String {
        switch self {
        case .inter: "Inter"
        case .system: "SF Pro"
        case .hyperlegible: "Atkinson"
        case .hyperlegibleMono: "Atkinson Mono"
        }
    }

    /// The family's full name, for the hover card.
    public var fullName: String {
        switch self {
        case .inter: "Inter"
        case .system: "SF Pro"
        case .hyperlegible: "Atkinson Hyperlegible Next"
        case .hyperlegibleMono: "Atkinson Hyperlegible Mono"
        }
    }

    /// Why the family is offered, short enough to share one line with its name.
    public var rationale: String {
        switch self {
        case .inter: localized("Feta per a pantalla: clara i compacta.")
        case .system: Self.systemRationale
        case .hyperlegible: localized("Creada pel Braille Institute™ per llegir amb baixa visió.")
        case .hyperlegibleMono: localized("Braille Institute™: lletres igual d'amples.")
        }
    }

    /// The PostScript name of the bundled face; nil for the system font.
    public var bundledFontName: String? {
        switch self {
        case .inter: AppVisualMetrics.readingFontName
        case .system: nil
        case .hyperlegible: "AtkinsonHyperlegibleNext-Medium"
        case .hyperlegibleMono: "AtkinsonHyperlegibleMono-Medium"
        }
    }

    /// The compact -2.2 pt at 70 pt was tuned for Inter Medium. The other faces take
    /// only a fraction of it: SF Pro carries its own optical tracking, Atkinson's
    /// legibility depends on letters that stay apart, and a fixed-width face would lose
    /// the even spacing that makes it legible.
    public var trackingScale: CGFloat {
        switch self {
        case .inter: 1
        case .system: 0.35
        case .hyperlegible: 0.2
        case .hyperlegibleMono: 0.02
        }
    }

    /// Hair spaces that keep a final accent's overhang inside the word's own text run
    /// (see `AppVisualMetrics.trailingGlyphGuard`). Atkinson Mono has no hair space, so
    /// the system drew a fallback a whole cell wide: three of them opened a gap of nearly
    /// two letters after every word. None of its glyphs reaches past its cell, so it
    /// needs no guard.
    public var trailingGlyphGuard: String {
        switch self {
        case .hyperlegibleMono: ""
        case .inter, .system, .hyperlegible: AppVisualMetrics.trailingGlyphGuard
        }
    }

    /// A fixed-width face separates words by one of its own spaces, a full cell: its
    /// letters already stand a cell apart, so the compact proportional gap would not
    /// read as a word break.
    public var wordGapIsOwnSpace: Bool {
        self == .hyperlegibleMono
    }

    #if os(iOS)
    private static var systemRationale: String { localized("La lletra del sistema de l'iPhone.") }
    #else
    private static var systemRationale: String { localized("La lletra del sistema del Mac.") }
    #endif

    public func font(ofSize size: CGFloat) -> PlatformFont {
        if let name = bundledFontName, let font = PlatformFont(name: name, size: size) {
            return font
        }
        return PlatformFont.systemFont(ofSize: size, weight: .medium)
    }
}
