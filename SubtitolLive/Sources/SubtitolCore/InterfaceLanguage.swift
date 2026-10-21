import Foundation

/// The language the app's own words are in: Catalan (the source), Galician, Basque,
/// Spanish or English. The transcript is never translated; this is only the interface.
///
/// The strings live in `Resources/Localizable.xcstrings`, compiled into one `<code>.lproj`
/// per language. The Mac follows the system (and its per-app language), reading
/// `Bundle.main`, until its onboarding stores a choice. The iPhone follows the choice made on the first screen of the
/// onboarding (`app.interfaceLanguage`), so it reads that language's `.lproj` directly
/// and switches without a relaunch. Views that show these strings depend on
/// `\.locale`, which the iPhone's root view sets from the same choice, so a change
/// re-renders them inside its animation.
public enum InterfaceLanguage {
    /// Where the iPhone keeps the choice.
    public static let defaultsKey = "app.interfaceLanguage"

    /// The interface languages, in the order the onboarding offers them, each in its own name.
    public static let all: [(id: String, name: String)] = [
        ("ca", "Català"), ("gl", "Galego"), ("eu", "Euskara"), ("es", "Español"), ("en", "English"),
    ]

    public static let codes: [String] = all.map(\.id)

    /// The first of the device's preferred languages that the interface speaks, else English.
    public static var deviceLanguage: String {
        for identifier in Locale.preferredLanguages {
            let code = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased() ?? ""
            if codes.contains(code) { return code }
        }
        return "en"
    }

    /// The language the interface is in now.
    public static var current: String {
        if let stored = UserDefaults.standard.string(forKey: defaultsKey), codes.contains(stored) {
            return stored
        }
        #if os(iOS)
        return deviceLanguage
        #else
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        return codes.contains(preferred) ? preferred : "en"
        #endif
    }

    /// For dates and numbers in the interface language, so a date inside a sentence is
    /// in the sentence's language.
    public static var locale: Locale {
        Locale(identifier: current)
    }

    /// The bundle the strings are read from.
    public static var bundle: Bundle {
        #if os(iOS)
        bundle(for: current)
        #else
        // The Mac follows the system until the onboarding's first screen stores a choice.
        UserDefaults.standard.string(forKey: defaultsKey) == nil ? .main : bundle(for: current)
        #endif
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var bundles: [String: Bundle] = [:]

    /// `<code>.lproj` inside the app, or the main bundle when it is missing (tests,
    /// command-line tools), which then answers with the Catalan source.
    public static func bundle(for code: String) -> Bundle {
        lock.lock()
        defer { lock.unlock() }
        if let cached = bundles[code] { return cached }
        let found = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        bundles[code] = found
        return found
    }
}

/// One of the app's own strings, in the interface language. The key is the Catalan text;
/// interpolations become format arguments, and plurals are variations in the catalogue.
public func localized(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: InterfaceLanguage.bundle, locale: InterfaceLanguage.locale)
}
