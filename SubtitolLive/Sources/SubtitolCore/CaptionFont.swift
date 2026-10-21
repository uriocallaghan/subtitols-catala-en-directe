import CoreText
import Foundation
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#else
import UIKit
#endif

/// The faces a video's captions can be set in. Besides the three the app bundles, all
/// of them ship with every iPhone and Mac, so offering them adds nothing to the app.
/// Captions read best heavier than body text, so each face is taken at a bold weight
/// where it has one. Raw values of the first four match `ReadingTypeface`, which the
/// first version stored.
public enum CaptionFont: String, CaseIterable, Sendable {
    case inter
    case system
    case rounded
    case serif
    case avenir
    case futura
    case helvetica
    case gillSans
    case optima
    case georgia
    case didot
    case baskerville
    case typewriter
    case marker
    case hyperlegible
    case hyperlegibleMono
    case mono

    public static let `default`: Self = .system

    /// The face's own name, shown in that face.
    public var displayName: String {
        switch self {
        case .inter: "Inter"
        case .system: "SF Pro"
        case .rounded: "SF Rounded"
        case .serif: "New York"
        case .avenir: "Avenir Next"
        case .futura: "Futura"
        case .helvetica: "Helvetica"
        case .gillSans: "Gill Sans"
        case .optima: "Optima"
        case .georgia: "Georgia"
        case .didot: "Didot"
        case .baskerville: "Baskerville"
        case .typewriter: "Typewriter"
        case .marker: "Marker"
        case .hyperlegible: "Atkinson"
        case .hyperlegibleMono: "Atkinson Mono"
        case .mono: "SF Mono"
        }
    }

    /// PostScript names of the named faces; the system's own designs have none.
    var postScriptName: String? {
        switch self {
        case .inter: AppVisualMetrics.readingFontName
        case .avenir: "AvenirNext-Bold"
        case .futura: "Futura-Bold"
        case .helvetica: "HelveticaNeue-Bold"
        case .gillSans: "GillSans-SemiBold"
        case .optima: "Optima-Bold"
        case .georgia: "Georgia-Bold"
        case .didot: "Didot-Bold"
        case .baskerville: "Baskerville-SemiBold"
        case .typewriter: "AmericanTypewriter-Semibold"
        case .marker: "MarkerFelt-Wide"
        case .hyperlegible: "AtkinsonHyperlegibleNext-Medium"
        case .hyperlegibleMono: "AtkinsonHyperlegibleMono-Medium"
        case .system, .rounded, .serif, .mono: nil
        }
    }

    /// The faces this device has (a named face missing would silently become Helvetica).
    /// Looked up once, the first time the editor asks (after the app's own faces are
    /// registered at launch).
    public static let available: [CaptionFont] = {
        allCases.filter { font in
            guard let name = font.postScriptName else { return true }
            let made = CTFontCreateWithName(name as CFString, 12, nil)
            return CTFontCopyPostScriptName(made) as String == name
        }
    }()

    public func font(ofSize size: CGFloat) -> CTFont {
        if let name = postScriptName {
            let made = CTFontCreateWithName(name as CFString, size, nil)
            if CTFontCopyPostScriptName(made) as String == name { return made }
        }
        let weight: PlatformFont.Weight = switch self {
        case .serif, .mono: .semibold
        default: .bold
        }
        let base = PlatformFont.systemFont(ofSize: size, weight: weight)
        let design: PlatformFontDesign? = switch self {
        case .rounded: .rounded
        case .serif: .serif
        case .mono: .monospaced
        default: nil
        }
        guard let design, let descriptor = base.fontDescriptor.withDesign(design) else { return base as CTFont }
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return (NSFont(descriptor: descriptor, size: size) ?? base) as CTFont
        #else
        return UIFont(descriptor: descriptor, size: size) as CTFont
        #endif
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
typealias PlatformFontDesign = NSFontDescriptor.SystemDesign
#else
typealias PlatformFontDesign = UIFontDescriptor.SystemDesign
#endif
