import CryptoKit
import Foundation

/// A video's corrected subtitles, kept on the device so that corrections outlive the app:
/// the same video brought in again can go on from them instead of being heard again.
public struct SavedCorrections: Codable, Equatable, Sendable {
    /// Bumped when the file's shape changes; older files are then left unread.
    public static let formatVersion = 1

    public var version: Int
    /// The video's name when the corrections were made.
    public var title: String
    public var languageID: String?
    public var savedAt: Date
    public var document: SubtitleDocument

    public init(title: String, languageID: String?, savedAt: Date = Date(), document: SubtitleDocument) {
        version = Self.formatVersion
        self.title = title
        self.languageID = languageID
        self.savedAt = savedAt
        self.document = document
    }
}

/// Where corrections are kept: one small JSON file per video, named after the video's
/// content (`key(for:)`), so a copy of it, a file renamed or the same film taken again
/// from Photos finds them. Only the newest `keptVideos` are kept.
public struct CorrectionStore: Sendable {
    public let root: URL
    public static let keptVideos = 50
    /// How much of each end of the file names it.
    static let sampleBytes = 1 << 20

    public init(root: URL) {
        self.root = root
    }

    /// The same video whatever its name or folder: its length with its first and last
    /// megabyte, hashed. Reads at most 2 MB, so it is quick even for an hour of film.
    public static func key(for file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
        try handle.seek(toOffset: 0)
        if let head = try handle.read(upToCount: sampleBytes) { hasher.update(data: head) }
        if size > UInt64(sampleBytes) {
            try handle.seek(toOffset: size - UInt64(sampleBytes))
            if let tail = try handle.read(upToCount: sampleBytes) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func url(for key: String) -> URL {
        root.appendingPathComponent("\(key).json")
    }

    /// The corrections kept for a video, if any can be read.
    public func load(key: String) -> SavedCorrections? {
        guard let data = try? Data(contentsOf: url(for: key)),
              let saved = try? JSONDecoder().decode(SavedCorrections.self, from: data),
              saved.version == SavedCorrections.formatVersion,
              !saved.document.isEmpty else { return nil }
        return saved
    }

    /// Keeps a video's corrections, replacing the ones it had, in one atomic write.
    public func save(_ corrections: SavedCorrections, key: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(corrections)
        try data.write(to: url(for: key), options: .atomic)
        prune()
    }

    public func remove(key: String) {
        try? FileManager.default.removeItem(at: url(for: key))
    }

    /// Only the newest videos' corrections stay.
    func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }
        let saved = files.filter { $0.pathExtension == "json" }
        guard saved.count > Self.keptVideos else { return }
        let dated = saved.map { file in
            (file, (try? file.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(Self.keptVideos) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
