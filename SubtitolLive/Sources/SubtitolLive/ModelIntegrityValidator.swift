import CryptoKit
import Foundation
import SubtitolCore

enum ModelIntegrityValidator {
    enum IntegrityError: LocalizedError {
        case missingManifest
        case invalidManifest
        case unexpectedFilename
        case hashMismatch

        var errorDescription: String? {
            switch self {
            case .missingManifest:
                localized("No s'ha trobat el manifest d'integritat del model.")
            case .invalidManifest:
                localized("El manifest d'integritat del model no és vàlid.")
            case .unexpectedFilename:
                localized("El model seleccionat no correspon al manifest instal·lat.")
            case .hashMismatch:
                localized("El model de veu no supera la verificació SHA-256.")
            }
        }
    }

    /// The models the installed manifest vouches for.
    static func loadCatalog() throws -> SpeechModelCatalog {
        var url = Bundle.main.url(forResource: "ModelManifest", withExtension: "json")
        #if SWIFT_PACKAGE
        // Only for `swift run`: SwiftPM's accessor looks for its bundle beside the app and
        // then in the build folder under ~/Documents, which makes an installed app ask for
        // Documents access and blocks its launch until someone answers.
        if url == nil {
            url = Bundle.module.url(forResource: "ModelManifest", withExtension: "json")
        }
        #endif
        guard let url else { throw IntegrityError.missingManifest }
        do {
            return try JSONDecoder().decode(SpeechModelCatalog.self, from: Data(contentsOf: url))
        } catch {
            throw IntegrityError.invalidManifest
        }
    }

    static func validate(modelURL: URL, against model: SpeechModelDescriptor) throws {
        guard modelURL.lastPathComponent == model.filename else {
            throw IntegrityError.unexpectedFilename
        }
        let actualHash = try sha256(of: modelURL)
        guard actualHash.caseInsensitiveCompare(model.sha256) == .orderedSame else {
            throw IntegrityError.hashMismatch
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
