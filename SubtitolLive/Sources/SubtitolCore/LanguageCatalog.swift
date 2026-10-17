import Foundation

/// A language the reader can install: one speech model and, when there is one, its
/// punctuation model, shipped together as one download.
public struct SpeechLanguage: Codable, Identifiable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case stable
        /// Shown with a "Beta" label and a note that the text may have more mistakes.
        case beta
    }

    public let id: String
    /// The language's own name, as its speakers write it.
    public let name: String
    public let stage: Stage
    /// Language codes (BCP 47 primary subtags) this language answers to, for the first
    /// suggestion from the phone's own languages.
    public let locales: [String]
    /// Apple-hosted Background Assets pack that carries the files.
    public let assetPack: String
    /// `models[].id` in the manifest.
    public let model: String
    /// Folder of the punctuation model inside the pack; nil when there is none yet.
    public let punctuation: String?
    /// Shown before the download starts, until the store reports the exact size.
    public let approximateDownloadBytes: Int64
    /// False while the pack's files are not in `models/` yet: the language is listed and
    /// offered like any other, but `stage-ios-resources.sh` has nothing to build for it and
    /// its model need not be in `models[]`. True when the manifest does not say.
    public let isPackStaged: Bool
    /// The same pack as a plain download from our own host, for when the App Store's
    /// cannot be reached (App Review's network, an App Store outage). Nil: no mirror.
    public let mirror: PackMirror?

    public init(
        id: String,
        name: String,
        stage: Stage,
        locales: [String],
        assetPack: String,
        model: String,
        punctuation: String?,
        approximateDownloadBytes: Int64,
        isPackStaged: Bool = true,
        mirror: PackMirror? = nil
    ) {
        self.id = id
        self.name = name
        self.stage = stage
        self.locales = locales
        self.assetPack = assetPack
        self.model = model
        self.punctuation = punctuation
        self.approximateDownloadBytes = approximateDownloadBytes
        self.isPackStaged = isPackStaged
        self.mirror = mirror
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        stage = try container.decode(Stage.self, forKey: .stage)
        locales = try container.decode([String].self, forKey: .locales)
        assetPack = try container.decode(String.self, forKey: .assetPack)
        model = try container.decode(String.self, forKey: .model)
        punctuation = try container.decodeIfPresent(String.self, forKey: .punctuation)
        approximateDownloadBytes = try container.decode(Int64.self, forKey: .approximateDownloadBytes)
        isPackStaged = try container.decodeIfPresent(Bool.self, forKey: .isPackStaged) ?? true
        mirror = try container.decodeIfPresent(PackMirror.self, forKey: .mirror)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, stage, locales, assetPack, model, punctuation, approximateDownloadBytes, mirror
        case isPackStaged = "packStaged"
    }
}

/// Where the pack's archive (the same `.aar` uploaded to App Store Connect, an Apple
/// Archive with `Contents/<language>/…`) can be fetched directly, and how to verify it.
public struct PackMirror: Codable, Equatable, Sendable {
    public let url: URL
    /// SHA-256 of the whole archive, lowercase hex.
    public let sha256: String
    public let bytes: Int64

    public init(url: URL, sha256: String, bytes: Int64) {
        self.url = url
        self.sha256 = sha256
        self.bytes = bytes
    }
}

/// The `languages` list of the model manifest.
public struct LanguageCatalog: Decodable, Sendable {
    public let languages: [SpeechLanguage]

    public init(languages: [SpeechLanguage]) {
        self.languages = languages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        languages = try container.decodeIfPresent([SpeechLanguage].self, forKey: .languages) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case languages
    }

    public func language(id: String) -> SpeechLanguage? {
        languages.first { $0.id == id }
    }

    /// The language suggested when none of the device's languages is offered, as the
    /// interface falls back to English.
    public static let fallbackLanguageID = "en"

    /// The first of the device's preferred languages that can be installed; otherwise
    /// English, else the first stable language in the catalogue.
    public func suggestion(forPreferredLanguages preferred: [String]) -> SpeechLanguage? {
        for identifier in preferred {
            let code = Self.primaryCode(identifier)
            if let match = languages.first(where: { $0.locales.contains(code) }) {
                return match
            }
        }
        return language(id: Self.fallbackLanguageID)
            ?? languages.first { $0.stage == .stable } ?? languages.first
    }

    static func primaryCode(_ identifier: String) -> String {
        let separators = CharacterSet(charactersIn: "-_")
        return identifier.components(separatedBy: separators).first?.lowercased() ?? identifier.lowercased()
    }
}
