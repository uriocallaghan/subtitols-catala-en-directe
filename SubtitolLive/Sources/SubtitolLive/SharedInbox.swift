import Foundation

/// Where the share menu's extension leaves a video for the app: a folder of its own in
/// the app group's `Inbox`. The extension cannot open the app (only widgets may), so it
/// says so, and the app claims the newest deposit when it next comes to the screen
/// (`claimPending`). `subtitollive://import?file=<folder>/<name>` still opens one
/// directly. The app takes the file over and removes it when the job is gone.
enum SharedInbox {
    static let appGroup = "group.com.uriocallaghan.duna"
    static let scheme = "subtitollive"

    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Copies `file` into the inbox and returns the address that opens the app on it.
    static func deposit(copyOf file: URL) throws -> URL {
        guard let inbox = folder else { throw CocoaError(.fileNoSuchFile) }
        let id = UUID().uuidString
        let destination = inbox.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let copy = destination.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: copy)
        var components = URLComponents()
        components.scheme = scheme
        components.host = "import"
        components.queryItems = [URLQueryItem(name: "file", value: "\(id)/\(file.lastPathComponent)")]
        guard let url = components.url else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// The deposited file an address names, if it is inside the inbox and there.
    static func file(for url: URL) -> URL? {
        guard url.scheme == scheme, url.host == "import", let inbox = folder,
              let relative = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "file" })?.value,
              !relative.contains("..") else { return nil }
        let file = inbox.appendingPathComponent(relative)
        guard file.standardizedFileURL.path.hasPrefix(inbox.standardizedFileURL.path),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }

    /// The newest deposit no one has taken yet, marked as taken (its folder gains the
    /// `.taken` suffix, so it is handed over once).
    static func claimPending() -> URL? {
        guard let inbox = folder,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
              ) else { return nil }
        let waiting = entries
            .filter { $0.pathExtension != "taken" }
            .sorted {
                let first = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let second = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return first > second
            }
        for entry in waiting {
            guard let name = try? FileManager.default.contentsOfDirectory(atPath: entry.path).first(where: { !$0.hasPrefix(".") }) else { continue }
            let taken = entry.appendingPathExtension("taken")
            guard (try? FileManager.default.moveItem(at: entry, to: taken)) != nil else { continue }
            return taken.appendingPathComponent(name)
        }
        return nil
    }

    /// Removes deposits older than a day that were never opened.
    static func sweep() {
        guard let inbox = folder,
              let entries = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let limit = Date().addingTimeInterval(-86_400)
        for entry in entries {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < limit { try? FileManager.default.removeItem(at: entry) }
        }
    }
}
