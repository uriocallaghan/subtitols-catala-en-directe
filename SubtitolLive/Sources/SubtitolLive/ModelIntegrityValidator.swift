import CryptoKit
import Foundation

enum ModelIntegrityValidator {
    struct Manifest: Decodable {
        struct Artifact: Decodable {
            let filename: String
            let sha256: String
        }

        let artifact: Artifact
    }

    enum IntegrityError: LocalizedError {
        case missingManifest
        case invalidManifest
        case unexpectedFilename
        case hashMismatch

        var errorDescription: String? {
            switch self {
            case .missingManifest:
                "No s'ha trobat el manifest d'integritat del model."
            case .invalidManifest:
                "El manifest d'integritat del model no és vàlid."
            case .unexpectedFilename:
                "El model seleccionat no correspon al manifest instal·lat."
            case .hashMismatch:
                "El model català no supera la verificació SHA-256."
            }
        }
    }

    static func validate(modelURL: URL) throws {
        let manifest = try loadManifest()
        guard modelURL.lastPathComponent == manifest.artifact.filename else {
            throw IntegrityError.unexpectedFilename
        }
        let actualHash = try sha256(of: modelURL)
        guard actualHash.caseInsensitiveCompare(manifest.artifact.sha256) == .orderedSame else {
            throw IntegrityError.hashMismatch
        }
    }

    private static func loadManifest() throws -> Manifest {
        let urls = [
            Bundle.main.url(forResource: "ModelManifest", withExtension: "json"),
            Bundle.module.url(forResource: "ModelManifest", withExtension: "json"),
        ].compactMap { $0 }
        guard let url = urls.first else { throw IntegrityError.missingManifest }
        do {
            return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        } catch {
            throw IntegrityError.invalidManifest
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
