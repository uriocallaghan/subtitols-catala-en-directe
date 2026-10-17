import AppleArchive
import BackgroundAssets
import CryptoKit
import Foundation
import SubtitolCore
import System
#if os(iOS)
import UIKit
#endif

/// The languages the reader has installed, and the downloads that install them.
///
/// A language is a folder (`<id>/<speech model>.gguf`, plus the compiled punctuation
/// model where there is one). It can come from three places, asked in this order:
///
/// 1. **Inside the app** (`Languages/<id>` in the bundle, the build scripts'
///    `BUNDLED_LANGUAGES`): empty by the founder's decision of 2026-10-07, so the app
///    stays small. A language listed there would never download and could not be
///    removed.
/// 2. **Apple-hosted Background Assets** (`SpeechLanguage.assetPack`): the App Store
///    hosts and verifies them; nothing is downloaded until the reader has seen the size
///    and said yes (App Review Guideline 4.2.3).
/// 3. **Our own mirror** (`SpeechLanguage.mirror`): the same `.aar` archive uploaded to
///    App Store Connect, fetched directly and verified by SHA-256, when the App Store's
///    lookup or download fails or stalls (the App Review environment often cannot reach
///    Apple-hosted packs, Developer Forums thread 815174, which rejected build 6 on the
///    Mac). The App Store's download is cancelled first, so the two never run together.
///
/// Development builds can point `SUBTITOL_PACKS_DIR` at a folder of unpacked packs
/// (`<dir>/<language id>/…`), or carry them as `DevPacks`; the same screens then install
/// from there. `-packSource store` (Debug) ignores those and uses the App Store and the
/// mirror, as the store build does; `SUBTITOL_PACK_MIRROR=<base URL>` points the mirror
/// at another host (a local `python3 -m http.server` for a test).
@MainActor
final class LanguagePackStore: ObservableObject {
    enum PackState: Equatable {
        case notInstalled
        case downloading(fraction: Double)
        case installed
        case failed(String)
    }

    private static let selectedDefaultsKey = "language.selected"

    let catalog: LanguageCatalog
    let models: SpeechModelCatalog?
    @Published private(set) var states: [String: PackState] = [:]
    /// Exact sizes, once the store has told us.
    @Published private(set) var downloadSizes: [String: Int64] = [:]
    @Published private(set) var selectedLanguageID: String?
    /// Why the last download of each language failed, to show beside the onboarding's own words.
    private var failures: [String: PackFailure] = [:]

    private let bundled = BundledPackSource()
    /// The App Store, or a development folder.
    private let store: LanguagePackSource
    /// Our own host, tried when the store fails. Nil with a development folder.
    private let mirror: MirrorPackSource?

    init() {
        catalog = Self.loadCatalog()
        models = try? ModelIntegrityValidator.loadCatalog()
        if let directory = DevelopmentOverrides.value(for: "SUBTITOL_PACKS_DIR"), !Self.forcesStore {
            store = FolderPackSource(root: URL(fileURLWithPath: directory, isDirectory: true))
            mirror = nil
        } else if let packs = Self.developmentPacks, !Self.forcesStore {
            store = FolderPackSource(root: packs)
            mirror = nil
        } else {
            store = AppleHostedPackSource()
            mirror = MirrorPackSource()
        }
        for language in catalog.languages {
            states[language.id] = isInstalled(pack(language)) ? .installed : .notInstalled
        }
        LocalPackLibrary().removeLeftovers()
        let stored = UserDefaults.standard.string(forKey: Self.selectedDefaultsKey)
        if let stored, states[stored] == .installed {
            selectedLanguageID = stored
        } else if let suggested = suggestedLanguage, states[suggested.id] == .installed {
            // Several languages come with the app: start from the device's own.
            selectedLanguageID = suggested.id
        } else {
            selectedLanguageID = catalog.languages.first { states[$0.id] == .installed }?.id
        }
    }

    var selectedLanguage: SpeechLanguage? {
        selectedLanguageID.flatMap(catalog.language(id:))
    }

    var suggestedLanguage: SpeechLanguage? {
        catalog.suggestion(forPreferredLanguages: Locale.preferredLanguages)
    }

    /// The pack's files: they sit under a folder named after the language, and the
    /// speech model inside it tells whether the pack is on the device.
    func pack(_ language: SpeechLanguage) -> LanguagePack {
        LanguagePack(
            language: language,
            modelFile: "\(language.id)/\(models?.model(id: language.model)?.filename ?? "model.gguf")"
        )
    }

    func state(of language: SpeechLanguage) -> PackState {
        states[language.id] ?? .notInstalled
    }

    /// The language came inside the app: nothing to download, nothing to delete.
    func isBundled(_ language: SpeechLanguage) -> Bool {
        bundled.isInstalled(pack(language))
    }

    /// Every language the app offers came with it (the Mac App Store build).
    var allBundled: Bool {
        !catalog.languages.isEmpty && catalog.languages.allSatisfy(isBundled)
    }

    /// Installed by a download, so it can be deleted to free its space.
    func isRemovable(_ language: SpeechLanguage) -> Bool {
        state(of: language) == .installed && !isBundled(language)
    }

    func downloadSize(of language: SpeechLanguage) -> Int64 {
        downloadSizes[language.id] ?? language.mirror?.bytes ?? language.approximateDownloadBytes
    }

    /// Folders the controller searches for this language's files.
    func modelDirectories(for language: SpeechLanguage) -> [URL] {
        let pack = pack(language)
        var directories = bundled.directories(for: pack)
        if store.isInstalled(pack) { directories += store.directories(for: pack) }
        if let mirror, mirror.isInstalled(pack) { directories += mirror.directories(for: pack) }
        return directories
    }

    func select(_ language: SpeechLanguage) {
        guard state(of: language) == .installed else { return }
        selectedLanguageID = language.id
        UserDefaults.standard.set(language.id, forKey: Self.selectedDefaultsKey)
    }

    func refreshSizes() async {
        for language in catalog.languages where downloadSizes[language.id] == nil && !isBundled(language) {
            if let size = await store.downloadSize(of: pack(language)) {
                downloadSizes[language.id] = size
            }
        }
    }

    /// Downloads the language, then selects it if nothing else is selected.
    func install(_ language: SpeechLanguage) async {
        guard state(of: language) != .installed else { return }
        let pack = pack(language)
        states[language.id] = .downloading(fraction: 0)
        // Each phase reports through its own gate, so a late word from the store's
        // download (its status stream can outlive our tasks) cannot move the mirror's bar.
        let phase = PackPhase()
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            let phaseID = phase.current
            Task { @MainActor in
                guard let self, phase.current == phaseID, case .downloading = self.states[language.id] else { return }
                self.states[language.id] = .downloading(fraction: fraction)
            }
        }
        packLog("\(language.id): asking the store")
        do {
            try await store.install(pack, progress: report)
        } catch {
            // The App Store could not deliver it (not found, unreachable, stalled): the
            // mirror has the same archive. The store's own download is dropped first, so
            // the two never run together.
            packLog("\(language.id): store failed (\(PackFailure(error).code)), mirror \(language.mirror?.url.absoluteString ?? "none")")
            guard let mirror, language.mirror != nil else {
                return fail(language, PackFailure(error))
            }
            phase.advance()
            await store.abandon(pack)
            report(0)
            do {
                try await mirror.install(pack, progress: report)
            } catch let mirrorError {
                return fail(language, PackFailure(error, mirror: mirrorError))
            }
        }
        packLog("\(language.id): installed")
        failures[language.id] = nil
        states[language.id] = .installed
        if selectedLanguageID == nil { select(language) }
    }

    private func fail(_ language: SpeechLanguage, _ failure: PackFailure) {
        failures[language.id] = failure
        states[language.id] = .failed(Self.describe(failure))
        // For Console and TestFlight logs: the code the reader sees, and the raw errors.
        packLog("\(language.id) failed: \(failure.code) — \(failure.details)")
    }

    /// The onboarding's words for a failed download (`general`), unless the reason is one the
    /// reader can fix (no connection, Wi-Fi needed); then that. A reason we cannot name adds
    /// its code, so a tester's screenshot says what happened.
    func failureText(of language: SpeechLanguage, general: String) -> String {
        guard let failure = failures[language.id] else { return general }
        return failure.advice ?? "\(general) (\(failure.code))"
    }

    func remove(_ language: SpeechLanguage) async {
        guard isRemovable(language) else { return }
        let pack = pack(language)
        var lastError: Error?
        if store.isInstalled(pack) {
            do { try await store.remove(pack) } catch { lastError = error }
        }
        if let mirror, mirror.isInstalled(pack) {
            do { try await mirror.remove(pack) } catch { lastError = error }
        }
        if isInstalled(pack), let lastError {
            states[language.id] = .failed(Self.describe(PackFailure(lastError)))
            return
        }
        states[language.id] = .notInstalled
        if selectedLanguageID == language.id {
            selectedLanguageID = catalog.languages.first { states[$0.id] == .installed }?.id
            UserDefaults.standard.set(selectedLanguageID, forKey: Self.selectedDefaultsKey)
        }
    }

    private func isInstalled(_ pack: LanguagePack) -> Bool {
        bundled.isInstalled(pack) || store.isInstalled(pack) || (mirror?.isInstalled(pack) ?? false)
    }

    private static func describe(_ failure: PackFailure) -> String {
        failure.advice ?? "\(localized("No s'ha pogut baixar l'idioma. Torna-ho a provar.")) (\(failure.code))"
    }

    /// Debug builds installed from Xcode carry the packs that are not inside the app as
    /// `DevPacks`, so a phone can install a language before the packs are on App Store
    /// Connect. Store builds have no `DevPacks` and use the App Store and the mirror.
    private static var developmentPacks: URL? {
        Bundle.main.url(forResource: "DevPacks", withExtension: nil)
    }

    /// Debug runs: `-packSource store` uses the App Store and the mirror even when
    /// development packs are at hand, to test what the store build does.
    private static var forcesStore: Bool {
        #if DEBUG
        UserDefaults.standard.string(forKey: "packSource") == "store"
        #else
        false
        #endif
    }

    private static func loadCatalog() -> LanguageCatalog {
        guard let url = Bundle.main.url(forResource: "ModelManifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(LanguageCatalog.self, from: data) else {
            return LanguageCatalog(languages: [])
        }
        return catalog
    }
}

/// One line in the system log (Console, TestFlight crash/log bundles) about a pack.
func packLog(_ message: String) {
    NSLog("[packs] %@", message)
}

/// Paths a development run may point at through the environment (`SUBTITOL_MODEL`,
/// `SUBTITOL_PACKS_DIR`…). A Mac App Store build ignores them outside Debug: its sandbox
/// could not read those folders anyway, and it takes its languages from the store.
enum DevelopmentOverrides {
    static func value(for key: String) -> String? {
        #if SUBTITOL_STORE && !DEBUG
        return nil
        #else
        return ProcessInfo.processInfo.environment[key]
        #endif
    }
}

struct LanguagePack: Sendable {
    let language: SpeechLanguage
    /// Path of the speech model inside the pack, e.g. `ca/catalan-conformer-q8.gguf`.
    let modelFile: String

    var id: String { language.id }
    var assetPack: String { language.assetPack }
}

protocol LanguagePackSource: Sendable {
    func isInstalled(_ pack: LanguagePack) -> Bool
    func directories(for pack: LanguagePack) -> [URL]
    func downloadSize(of pack: LanguagePack) async -> Int64?
    func install(_ pack: LanguagePack, progress: @escaping @Sendable (Double) -> Void) async throws
    func remove(_ pack: LanguagePack) async throws
    /// Drops a download this source gave up on, so another source can take over alone.
    func abandon(_ pack: LanguagePack) async
}

extension LanguagePackSource {
    func abandon(_ pack: LanguagePack) async {}
}

/// Which phase of an install (the store's, then the mirror's) may report progress.
final class PackPhase: @unchecked Sendable {
    private let lock = NSLock()
    private var number = 0

    var current: Int {
        lock.lock(); defer { lock.unlock() }
        return number
    }

    func advance() {
        lock.lock(); number += 1; lock.unlock()
    }
}

/// The languages inside the app itself: `Languages/<id>/…` in the bundle, put there by
/// the build (`project.yml`'s "Bundle languages" phase, `build-app.sh`). Always
/// installed, never downloaded, never removed.
struct BundledPackSource: LanguagePackSource {
    static let folderName = "Languages"

    private var root: URL? {
        Bundle.main.resourceURL?.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    func isInstalled(_ pack: LanguagePack) -> Bool {
        guard let root else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(pack.modelFile).path)
    }

    func directories(for pack: LanguagePack) -> [URL] {
        guard isInstalled(pack), let root else { return [] }
        return [root.appendingPathComponent(pack.id, isDirectory: true)]
    }

    func downloadSize(of pack: LanguagePack) async -> Int64? { 0 }

    func install(_ pack: LanguagePack, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard isInstalled(pack) else { throw PackNotBundled() }
        progress(1)
    }

    func remove(_ pack: LanguagePack) async throws {
        throw PackNotRemovable()
    }
}

struct PackNotBundled: Error {}
struct PackNotRemovable: Error {}

/// Packs hosted by the App Store. A pack's files sit under a folder named after the
/// language (`ca/catalan-conformer-q8.gguf`, `ca/catala-puntuacio/…`).
struct AppleHostedPackSource: LanguagePackSource {
    /// `url(for:)` alone is not proof: without the pack on the device it can still return a
    /// URL (seen on iOS 26.5 in the Simulator), and the app then called a language that was
    /// never downloaded "ready". The system's own answer comes first, then the model file.
    func isInstalled(_ pack: LanguagePack) -> Bool {
        if #available(iOS 26.4, macOS 26.4, *),
           !AssetPackManager.shared.assetPackIsAvailableLocally(withID: pack.assetPack) {
            return false
        }
        return modelURL(pack) != nil
    }

    /// The language's folder, asked for as a folder. A file's URL is only that file's:
    /// the packs share one merged namespace, and the folder around a file's URL need not
    /// hold its neighbours. Taking the model's folder that way found no punctuation
    /// model in the first TestFlight build, and then no word settled while listening.
    func directories(for pack: LanguagePack) -> [URL] {
        var isDirectory: ObjCBool = false
        guard let folder = try? AssetPackManager.shared.url(for: FilePath(pack.id)),
              FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return modelURL(pack).map { [$0.deletingLastPathComponent()] } ?? []
        }
        return [folder] + (modelURL(pack).map { [$0.deletingLastPathComponent()] } ?? [])
    }

    private func modelURL(_ pack: LanguagePack) -> URL? {
        guard let url = try? AssetPackManager.shared.url(for: FilePath(pack.modelFile)),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func downloadSize(of pack: LanguagePack) async -> Int64? {
        guard let assetPack = try? await AssetPackManager.shared.assetPack(withID: pack.assetPack) else {
            return nil
        }
        return Int64(assetPack.downloadSize)
    }

    /// Done as soon as the pack is on the device, whoever says so first: the system's
    /// `ensureLocalAvailability`, its `.finished` update, or the pack found in place. In a
    /// TestFlight build (iOS 26, 2026-10-01) the download reached 100 % and
    /// `ensureLocalAvailability` never returned, leaving the onboarding stuck. A download
    /// that shows no progress for `stallLimit` fails instead, and the store then tries
    /// the mirror.
    func install(_ pack: LanguagePack, progress: @escaping @Sendable (Double) -> Void) async throws {
        // The lookup itself can hang where the App Store is unreachable; a bounded wait
        // turns that into a failure the store can answer with the mirror.
        let assetPack = try await withDeadline(seconds: Self.lookupLimit) {
            try await AssetPackManager.shared.assetPack(withID: pack.assetPack)
        }
        let outcome = PackInstallOutcome()
        let lastProgress = PackInstallClock()
        let report: @Sendable (Double) -> Void = { fraction in
            lastProgress.touch()
            progress(fraction)
        }
        let tasks = [
            Task {
                do {
                    try await AssetPackManager.shared.ensureLocalAvailability(of: assetPack)
                    outcome.finish(.success(()))
                } catch {
                    outcome.finish(.failure(error))
                }
            },
            Task {
                for await update in AssetPackManager.shared.statusUpdates(forAssetPackWithID: pack.assetPack) {
                    switch update {
                    case .downloading(_, let fraction): report(fraction.fractionCompleted)
                    case .finished: report(1)
                    case .failed(_, let error): outcome.finish(.failure(error))
                    case .began, .paused: lastProgress.touch()
                    @unknown default: break
                    }
                }
            },
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    if isInstalled(pack) {
                        outcome.finish(.success(()))
                    } else if await !Self.appIsActive() {
                        // In the background the system may pause the download, and that
                        // is not a stall: the clock starts again on return.
                        lastProgress.touch()
                    } else if lastProgress.secondsSinceTouch > Self.stallLimit {
                        outcome.finish(.failure(PackInstallStalled()))
                    }
                }
            },
        ]
        defer { tasks.forEach { $0.cancel() } }
        try await outcome.value
        progress(1)
    }

    @MainActor
    private static func appIsActive() -> Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .active
        #else
        true
        #endif
    }

    /// Cancels the system's download (removing the pack does that) when the mirror takes
    /// over, bounded like the lookup: nothing here may hold the mirror back.
    func abandon(_ pack: LanguagePack) async {
        _ = try? await withDeadline(seconds: 5) {
            try await AssetPackManager.shared.remove(assetPackWithID: pack.assetPack)
        }
    }

    /// Seconds without any word from the download before it counts as stuck, and seconds
    /// the pack lookup may take. Short on purpose: the mirror is waiting behind them, and
    /// a reader (or a reviewer) should not stare at 0 % for a minute.
    static let stallLimit: Double = 20
    static let lookupLimit: Double = 15

    func remove(_ pack: LanguagePack) async throws {
        try await withDeadline(seconds: Self.lookupLimit) {
            try await AssetPackManager.shared.remove(assetPackWithID: pack.assetPack)
        }
    }
}

/// Why a download failed: words the reader can act on when there are some, and a short code.
struct PackFailure {
    let advice: String?
    let code: String
    /// The errors as the system describes them, for the log.
    let details: String

    init(_ error: Error) {
        advice = Self.advice(for: error)
        code = Self.code(for: error)
        details = String(describing: error)
    }

    /// The store failed, then the mirror. The mirror's reason is the one the reader can
    /// act on (it is the plainer download); both codes are kept.
    init(_ storeError: Error, mirror mirrorError: Error) {
        advice = Self.advice(for: mirrorError) ?? Self.advice(for: storeError)
        code = "\(Self.code(for: storeError)) · mirror \(Self.code(for: mirrorError))"
        details = "store: \(String(describing: storeError)); mirror: \(String(describing: mirrorError))"
    }

    private static func advice(for error: Error) -> String? {
        let error = error as NSError
        if error.domain == NSURLErrorDomain,
           [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed, NSURLErrorTimedOut].contains(error.code) {
            return localized("Cal connexió a internet per baixar l'idioma. Després funciona sense.")
        }
        if error.domain == BAErrorDomain, [112, 203, 204].contains(error.code) {
            // Over the allowance for downloads on mobile data.
            return localized("Connecta't a una xarxa Wi-Fi per baixar l'idioma. Després funciona sense connexió.")
        }
        return nil
    }

    /// Short: the reader may have to read it out to us. Not found is what a tester
    /// outside the packs' TestFlight group gets.
    private static func code(for error: Error) -> String {
        switch error as? ManagedBackgroundAssetsError {
        case .assetPackNotFound: return "not found"
        case .fileNotFound: return "file not found"
        default: break
        }
        switch error {
        case is PackInstallStalled: return "stalled"
        case is PackMirrorMissing: return "no mirror"
        case is PackArchiveCorrupt: return "checksum"
        case is PackArchiveUnreadable: return "archive"
        case let status as PackMirrorStatus: return "http \(status.code)"
        default: break
        }
        let error = error as NSError
        return "\(error.domain.split(separator: ".").last.map(String.init) ?? error.domain) \(error.code)"
            .replacingOccurrences(of: "ErrorDomain", with: "")
    }
}

/// The first result of a pack install, from whichever of its watchers has it first.
/// Later results are dropped, and a watcher that never answers is simply cancelled.
final class PackInstallOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?

    func finish(_ value: Result<Void, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(with: value)
    }

    var value: Void {
        get async throws {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }
    }
}

/// When a pack install last showed any progress.
final class PackInstallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()

    func touch() {
        lock.lock(); last = Date(); lock.unlock()
    }

    var secondsSinceTouch: Double {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(last)
    }
}

/// A download that stopped moving without finishing or failing.
struct PackInstallStalled: Error {}

/// Runs `work`, or throws `PackInstallStalled` once `seconds` have passed without it
/// finishing. The work is not awaited after that: a system call that ignores
/// cancellation (the pack lookup, where the App Store is unreachable) would otherwise
/// hold the caller as long as it hangs.
func withDeadline<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    let first = FirstResult<T>()
    let worker = Task {
        do { first.finish(.success(try await work())) } catch { first.finish(.failure(error)) }
    }
    let timer = Task {
        try? await Task.sleep(for: .seconds(seconds))
        if !Task.isCancelled { first.finish(.failure(PackInstallStalled())) }
    }
    defer { worker.cancel(); timer.cancel() }
    return try await first.value
}

/// The first result handed in, by whichever task has it; later ones are dropped.
final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var waiter: CheckedContinuation<T, Error>?

    func finish(_ value: Result<T, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(with: value)
    }

    var value: T {
        get async throws {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }
    }
}

// MARK: - Packs kept in Application Support

/// Where the packs that the app downloads itself (the mirror) or copies (a development
/// folder) live: `Application Support/LanguagePacks/<id>/…`, inside the sandbox on the
/// stores' builds. Removal deletes the language's folder.
struct LocalPackLibrary: Sendable {
    var root: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        // Outside a sandbox, Application Support is shared by every app.
        return support.appendingPathComponent("Subtítol Live/LanguagePacks", isDirectory: true)
        #else
        return support.appendingPathComponent("LanguagePacks", isDirectory: true)
        #endif
    }

    func folder(for pack: LanguagePack) -> URL {
        root.appendingPathComponent(pack.id, isDirectory: true)
    }

    func isInstalled(_ pack: LanguagePack) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(pack.modelFile).path)
    }

    /// Puts a finished language folder in place, replacing what was there, by one rename.
    func install(from staged: URL, as pack: LanguagePack) throws {
        try prepareRoot()
        let destination = folder(for: pack)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staged, to: destination)
    }

    func remove(_ pack: LanguagePack) throws {
        try FileManager.default.removeItem(at: folder(for: pack))
    }

    /// A fresh folder for work in progress, beside the packs so the final move is a rename.
    func makeStagingFolder(for pack: LanguagePack) throws -> URL {
        try prepareRoot()
        let staging = root.appendingPathComponent(".\(pack.id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    /// Work left by an install the app was killed during (`.<id>-<UUID>` folders).
    func removeLeftovers() {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for entry in entries where entry.hasPrefix(".") {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(entry))
        }
    }

    /// The packs are re-downloadable, so they stay out of iCloud and computer backups
    /// (iOS Data Storage Guidelines, App Review Guideline 2.23).
    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var folder = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }
}

/// Development only: installs from unpacked packs in a local folder, copying them into
/// Application Support so removal and re-installation behave as they will in the store.
struct FolderPackSource: LanguagePackSource {
    let root: URL
    private let library = LocalPackLibrary()

    func isInstalled(_ pack: LanguagePack) -> Bool {
        library.isInstalled(pack) || FileManager.default.fileExists(atPath: previewMarker(pack).path)
    }

    /// Left by a language whose pack is not built yet: it "installs" so the screens can
    /// be seen with it, and the reading screen then says its model is missing.
    private func previewMarker(_ pack: LanguagePack) -> URL {
        library.folder(for: pack).appendingPathComponent(".preview")
    }

    func directories(for pack: LanguagePack) -> [URL] {
        [library.folder(for: pack)]
    }

    func downloadSize(of pack: LanguagePack) async -> Int64? {
        let folder = root.appendingPathComponent(pack.id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        return Self.folderSize(folder)
    }

    private static func folderSize(_ folder: URL) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return nil }
        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    func install(_ pack: LanguagePack, progress: @escaping @Sendable (Double) -> Void) async throws {
        let source = root.appendingPathComponent(pack.id)
        // A visible, paced progress so the screens can be checked as they will look. A
        // language whose pack is not built yet plays the same download and installs as a
        // preview (no model).
        let hasPack = FileManager.default.fileExists(atPath: source.path)
        for step in 1...(hasPack ? 20 : 40) {
            try await Task.sleep(for: .milliseconds(60))
            progress(Double(step) / (hasPack ? 21 : 42))
        }
        guard hasPack else {
            try FileManager.default.createDirectory(at: library.folder(for: pack), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: previewMarker(pack).path, contents: nil)
            progress(1)
            return
        }
        let staging = try library.makeStagingFolder(for: pack)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: source, to: staging)
        try library.install(from: staging, as: pack)
        progress(1)
    }

    func remove(_ pack: LanguagePack) async throws {
        try library.remove(pack)
    }
}

// MARK: - The mirror

/// The pack's archive from our own host (`SpeechLanguage.mirror`): the very `.aar` that
/// goes to App Store Connect, an Apple Archive holding `Contents/<id>/…` and the pack's
/// `Manifest.json`. The archive is verified against its SHA-256 before anything is
/// unpacked, unpacked beside the packs, and put in place by one rename.
struct MirrorPackSource: LanguagePackSource {
    private let library = LocalPackLibrary()

    func isInstalled(_ pack: LanguagePack) -> Bool {
        library.isInstalled(pack)
    }

    func directories(for pack: LanguagePack) -> [URL] {
        [library.folder(for: pack)]
    }

    func downloadSize(of pack: LanguagePack) async -> Int64? {
        pack.language.mirror?.bytes
    }

    func install(_ pack: LanguagePack, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let mirror = pack.language.mirror else { throw PackMirrorMissing() }
        let staging = try library.makeStagingFolder(for: pack)
        defer { try? FileManager.default.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("pack.aar")
        // The download is the long part; checking and unpacking take a few seconds.
        packLog("\(pack.id): mirror download starts")
        try await PackDownload.fetch(Self.url(for: mirror), to: archive, expectedBytes: mirror.bytes) { fraction in
            progress(fraction * 0.94)
        }
        try Task.checkCancellation()
        packLog("\(pack.id): mirror download done, checking")
        guard try Self.sha256(of: archive) == mirror.sha256.lowercased() else { throw PackArchiveCorrupt() }
        progress(0.97)
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try Self.extract(archive, to: unpacked)
        let contents = unpacked.appendingPathComponent("Contents").appendingPathComponent(pack.id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: contents.appendingPathComponent(pack.modelFile.split(separator: "/").dropFirst().joined(separator: "/")).path) else {
            throw PackArchiveUnreadable()
        }
        try library.install(from: contents, as: pack)
        progress(1)
    }

    func remove(_ pack: LanguagePack) async throws {
        try library.remove(pack)
    }

    /// `SUBTITOL_PACK_MIRROR=<base URL>` (development) serves the same file names from
    /// another host, e.g. `python3 -m http.server` in `.work/ios-asset-packs`.
    private static func url(for mirror: PackMirror) -> URL {
        if let base = DevelopmentOverrides.value(for: "SUBTITOL_PACK_MIRROR"), let baseURL = URL(string: base) {
            return baseURL.appendingPathComponent(mirror.url.lastPathComponent)
        }
        return mirror.url
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

    /// Unpacks an Apple Archive (`ba-package` writes them compressed) into `folder`.
    static func extract(_ archive: URL, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let file = ArchiveByteStream.fileStream(
            path: FilePath(archive.path), mode: .readOnly, options: [], permissions: FilePermissions(rawValue: 0o644)
        ) else { throw PackArchiveUnreadable() }
        defer { try? file.close() }
        let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file)
        defer { try? decompressed?.close() }
        guard let decode = ArchiveStream.decodeStream(readingFrom: decompressed ?? file) else { throw PackArchiveUnreadable() }
        defer { try? decode.close() }
        guard let extract = ArchiveStream.extractStream(extractingTo: FilePath(folder.path), flags: [.ignoreOperationNotPermitted]) else {
            throw PackArchiveUnreadable()
        }
        defer { try? extract.close() }
        _ = try ArchiveStream.process(readingFrom: decode, writingTo: extract)
    }
}

struct PackMirrorMissing: Error {}
struct PackArchiveCorrupt: Error {}
struct PackArchiveUnreadable: Error {}
struct PackMirrorStatus: Error { let code: Int }

/// One file fetched with its progress, to a place of ours. The system's download task
/// writes it; the file is moved into place the moment the task hands it over, before
/// the system can delete it.
enum PackDownload {
    static func fetch(_ url: URL, to destination: URL, expectedBytes: Int64, progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = Delegate(destination: destination, expectedBytes: expectedBytes, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.downloadTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let destination: URL
        private let expectedBytes: Int64
        private let progress: @Sendable (Double) -> Void
        private let lock = NSLock()
        private var moved: Result<Void, Error>?
        private var finished = false
        var continuation: CheckedContinuation<Void, Error>?

        init(destination: URL, expectedBytes: Int64, progress: @escaping @Sendable (Double) -> Void) {
            self.destination = destination
            self.expectedBytes = expectedBytes
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
            guard total > 0 else { return }
            progress(min(1, Double(totalBytesWritten) / Double(total)))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            lock.lock(); defer { lock.unlock() }
            if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                moved = .failure(PackMirrorStatus(code: response.statusCode))
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                moved = .success(())
            } catch {
                moved = .failure(error)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { packLog("download ended with error: \(error)") }
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let result: Result<Void, Error> = if let error { .failure(error) } else { moved ?? .failure(PackArchiveUnreadable()) }
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }
}
