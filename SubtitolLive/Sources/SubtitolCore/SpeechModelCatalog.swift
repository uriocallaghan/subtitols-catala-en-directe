import Foundation

/// One speech model the installed manifest vouches for.
///
/// Only the fields the app acts on are decoded; provenance and evaluation notes in the
/// manifest stay documentation.
public struct SpeechModelDescriptor: Decodable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let filename: String
    public let sha256: String
    public let sizeBytes: Int64
    /// Audio each live hypothesis sees. Models trained on longer clips need more
    /// context: the Conformer halves its errors going from 4 s to 6 s.
    public let liveWindowSeconds: TimeInterval
    /// The model writes its own marks and capitals ("clima.", "¿cierto?"), so no
    /// punctuation model runs after it: `RecognizerPunctuation` reads them instead.
    public let writesPunctuation: Bool

    private enum CodingKeys: String, CodingKey {
        case id, displayName, filename, sha256, sizeBytes, liveWindowSeconds, writesPunctuation
    }

    public init(
        id: String,
        displayName: String,
        filename: String,
        sha256: String,
        sizeBytes: Int64,
        liveWindowSeconds: TimeInterval = LiveWindowPolicy.liveWindowSeconds,
        writesPunctuation: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.filename = filename
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.liveWindowSeconds = liveWindowSeconds
        self.writesPunctuation = writesPunctuation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        filename = try container.decode(String.self, forKey: .filename)
        sha256 = try container.decode(String.self, forKey: .sha256)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        liveWindowSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .liveWindowSeconds)
            ?? LiveWindowPolicy.liveWindowSeconds
        writesPunctuation = try container.decodeIfPresent(Bool.self, forKey: .writesPunctuation) ?? false
    }
}

/// The speech models the manifest lists, and the one the app runs.
///
/// The app ships a single model (the Aina Conformer); the list form lets the build and
/// download scripts pin every file the same way.
public struct SpeechModelCatalog: Decodable, Sendable {
    public enum CatalogError: Error, Equatable {
        case empty
        case duplicateIdentifier(String)
        case unknownDefault(String)
    }

    public let defaultModel: String
    public let models: [SpeechModelDescriptor]

    private enum CodingKeys: String, CodingKey {
        case defaultModel
        case models
    }

    public init(defaultModel: String, models: [SpeechModelDescriptor]) throws {
        self.defaultModel = defaultModel
        self.models = models
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultModel = try container.decode(String.self, forKey: .defaultModel)
        models = try container.decode([SpeechModelDescriptor].self, forKey: .models)
        try validate()
    }

    public func model(id: String) -> SpeechModelDescriptor? {
        models.first { $0.id == id }
    }

    /// The model the app loads.
    public var defaultDescriptor: SpeechModelDescriptor {
        // `validate()` guarantees the default exists.
        model(id: defaultModel)!
    }

    private func validate() throws {
        guard !models.isEmpty else { throw CatalogError.empty }
        var seen = Set<String>()
        for model in models where !seen.insert(model.id).inserted {
            throw CatalogError.duplicateIdentifier(model.id)
        }
        guard seen.contains(defaultModel) else {
            throw CatalogError.unknownDefault(defaultModel)
        }
    }
}
