import Foundation

/// duna's pages on the web (duna.uriocallaghan.com): the privacy policy, the terms of use
/// and support, in the interface language. The site is in Catalan, Spanish and English;
/// Galician and Basque readers get the Spanish pages.
public enum AppLinks {
    public static let site = "https://duna.uriocallaghan.com"

    public static var home: URL { url(ca: "/", es: "/es/", en: "/en/") }
    public static var privacy: URL { url(ca: "/privacitat", es: "/es/privacidad", en: "/en/privacy") }
    public static var terms: URL { url(ca: "/condicions", es: "/es/condiciones", en: "/en/terms") }
    public static var support: URL { url(ca: "/suport", es: "/es/soporte", en: "/en/support") }

    private static func url(ca: String, es: String, en: String) -> URL {
        let path: String
        switch InterfaceLanguage.current {
        case "ca": path = ca
        case "en": path = en
        default: path = es
        }
        return URL(string: site + path)!
    }
}
