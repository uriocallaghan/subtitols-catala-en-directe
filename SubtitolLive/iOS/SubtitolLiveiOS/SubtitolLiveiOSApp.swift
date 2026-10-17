import AVFoundation
import CoreText
import SubtitolCore
import SwiftUI

@main
struct SubtitolLiveiOSApp: App {
    init() {
        Self.registerBundledFonts()
        // Copies of videos are removed with their job; one that was running when the app
        // was closed leaves its copy, which goes now.
        ImportCenter.removeLeftoverCopies()
        SharedInbox.sweep()
        PhoneServices.attachShortcuts()
    }

    var body: some Scene {
        WindowGroup {
            PhoneRootView()
                .environmentObject(PhoneServices.packs)
                .environmentObject(PhoneServices.imports)
        }
    }

    /// Inter and the two Atkinson faces ship in the bundle (SIL OFL 1.1).
    private static func registerBundledFonts() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) else { return }
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

/// The app's objects, made once at launch rather than by a view: a shortcut can run
/// before any view exists (Shortcuts launches the app in the background for the actions
/// that read the text), and it must find the same objects the screen shows.
@MainActor
enum PhoneServices {
    static let packs = LanguagePackStore()
    static let imports = ImportCenter()
    static let session = SessionHolder()

    static func attachShortcuts() {
        ShortcutHost.shared.attach(packs: packs, imports: imports, controller: { session.controller })
        ControlActions.startTranscribing = {
            try await ShortcutHost.shared.startListening(languageID: nil)
        }
    }
}

/// One recognition session per installed language. Switching language shuts the old
/// session down before the new one starts loading its model.
@MainActor
final class SessionHolder: ObservableObject {
    @Published private(set) var controller: SubtitleController?
    private(set) var languageID: String?

    func use(_ language: SpeechLanguage?, from packs: LanguagePackStore) {
        guard language?.id != languageID else { return }
        controller?.shutdown()
        controller = nil
        languageID = language?.id
        guard let language else { return }
        controller = SubtitleController(
            languageID: language.id,
            modelID: language.model,
            modelDirectories: packs.modelDirectories(for: language),
            punctuationDirectoryName: language.punctuation
        )
    }
}

struct PhoneRootView: View {
    @EnvironmentObject private var packs: LanguagePackStore
    @EnvironmentObject private var imports: ImportCenter
    /// Created on the screen (`session.use` below), never in the background: loading a
    /// model needs the graphics chip, which is the app's only while it is on screen.
    @ObservedObject private var session = PhoneServices.session
    @Environment(\.scenePhase) private var scenePhase

    /// Set once the first-run game is over (or skipped). Debug runs replay it with
    /// `-onboarding.done NO`.
    @AppStorage("onboarding.done") private var onboarded = false
    /// The interface language chosen in the onboarding (`InterfaceLanguage`).
    @AppStorage(InterfaceLanguage.defaultsKey) private var storedInterfaceLanguage = InterfaceLanguage.deviceLanguage
    /// Follows the stored choice inside an animation: a change that reaches the view
    /// through `@AppStorage` arrives outside any transaction and would snap.
    @State private var interfaceLanguage = InterfaceLanguage.current
    /// The launch splash (`LaunchSplash`), on every launch after the first run,
    /// never after the onboarding. `-splash NO` leaves it out.
    @State private var showsSplash = UserDefaults.standard.bool(forKey: "onboarding.done")
        && (UserDefaults.standard.object(forKey: "splash") == nil || UserDefaults.standard.bool(forKey: "splash"))

    var body: some View {
        ZStack {
            if !onboarded {
                OnboardingView(controller: session.controller) {
                    withAnimation(.easeInOut(duration: 0.8)) { onboarded = true }
                }
                // Only a cross-fade: the onboarding orb has already moved onto the reader's.
                .transition(.opacity)
            } else if let controller = session.controller {
                PhoneReaderView(controller: controller)
                    .transition(.opacity)
            } else {
                LanguageSetupView(mode: .firstRun)
                    .transition(.opacity)
            }
            if showsSplash {
                // The language screen always shows the orb, in the reader's place; the
                // reader only while the orb is on (`phone.showsOrb`).
                LaunchSplash(
                    landsOnOrb: packs.selectedLanguage == nil
                        || UserDefaults.standard.object(forKey: "phone.showsOrb") == nil
                        || UserDefaults.standard.bool(forKey: "phone.showsOrb"),
                    isReady: { session.controller?.canToggle ?? true },
                    onFinished: { showsSplash = false }
                )
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: session.controller == nil)
        // Every view that shows the app's own words depends on the locale, so a new
        // interface language re-renders them, cross-fading, without a relaunch.
        .environment(\.locale, Locale(identifier: interfaceLanguage))
        .onChange(of: storedInterfaceLanguage) { _, language in
            guard language != interfaceLanguage else { return }
            withAnimation(.easeInOut(duration: 0.35)) { interfaceLanguage = language }
        }
        // "Canvia l'idioma" in Shortcuts can change the language while the app is in the
        // background, where the graphics chip is not the app's: the new session waits
        // for the screen.
        .onChange(of: packs.selectedLanguageID, initial: true) { _, _ in
            guard scenePhase != .background else { return }
            session.use(packs.selectedLanguage, from: packs)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .background else { return }
            session.use(packs.selectedLanguage, from: packs)
        }
        #if DEBUG
        .task {
            // Screenshot runs: `-autoInstall ca` downloads a language without a tap and
            // makes it the one in use.
            if let id = UserDefaults.standard.string(forKey: "autoInstall"),
               let language = packs.catalog.language(id: id) {
                await packs.install(language)
                packs.select(language)
            }
        }
        #endif
        // Videos handed to the app: "Open in" from Files, or the share menu's extension,
        // which leaves its copy in the app group and opens `subtitollive://import`.
        .onOpenURL { url in
            if url.isFileURL {
                imports.open(url, languageID: packs.selectedLanguageID)
            } else if let file = SharedInbox.file(for: url) {
                imports.open(file, ownsSource: true, languageID: packs.selectedLanguageID)
            }
        }
        #if DEBUG
        .task {
            // `-importFile PATH` opens a video as if it had been shared to the app; a
            // relative path is taken from the app's Documents. With `-importLanguage xx`
            // the transcription starts at once.
            if let path = UserDefaults.standard.string(forKey: "importFile") {
                try? await Task.sleep(for: .seconds(1.5))
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : documents.appendingPathComponent(path)
                imports.open(url, languageID: packs.selectedLanguageID)
                // `-importResume YES` goes on from the corrections kept for the video.
                if UserDefaults.standard.bool(forKey: "importResume"), let job = imports.current {
                    for _ in 0..<50 where job.savedCorrections == nil { try? await Task.sleep(for: .milliseconds(100)) }
                    job.resume()
                } else if let id = UserDefaults.standard.string(forKey: "importLanguage"),
                   let language = packs.catalog.language(id: id), let job = imports.current {
                    try? await Task.sleep(for: .seconds(1))
                    job.start(language: language, packs: packs)
                }
            }
        }
        .task {
            // `-debugSnapshots "20,26"`: at those seconds the app draws its own screen,
            // sheets and covers included, into Documents/snapshot-<s>.png, with the
            // window's safe area in snapshot-<s>.txt: a phone has no screenshot tool.
            guard let times = UserDefaults.standard.string(forKey: "debugSnapshots") else { return }
            let started = Date()
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            for old in (try? FileManager.default.contentsOfDirectory(atPath: documents.path)) ?? [] where old.hasPrefix("snapshot-") {
                try? FileManager.default.removeItem(at: documents.appendingPathComponent(old))
            }
            for time in times.split(separator: ",").compactMap({ Double($0) }) {
                let wait = time - Date().timeIntervalSince(started)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                DebugSnapshot.write(named: "snapshot-\(Int(time))")
            }
        }
        #endif
        // A video left by the share menu: taken when the app comes to the screen.
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active, imports.current == nil,
                  let file = SharedInbox.claimPending() else { return }
            imports.open(file, ownsSource: true, languageID: packs.selectedLanguageID)
        }
        .onChange(of: scenePhase) { _, phase in
            // In the background the GPU is not the app's: a video waits for the reader.
            imports.current?.setPaused(phase == .background)
            // The app records only while it is open: leaving it closes the sentence.
            if phase == .background, let controller = session.controller, controller.isRecording {
                controller.toggleRecording()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began,
                  let controller = session.controller,
                  controller.isRecording else { return }
            controller.toggleRecording()
        }
    }
}

#if DEBUG
@MainActor
enum DebugSnapshot {
    static func write(named name: String) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        try? image.pngData()?.write(to: documents.appendingPathComponent("\(name).png"))
        var lines = ["window \(window.bounds) safe \(window.safeAreaInsets)"]
        var controller = window.rootViewController
        while let current = controller {
            lines.append("\(type(of: current)) view \(current.view.frame) safe \(current.view.safeAreaInsets)")
            controller = current.presentedViewController
        }
        try? lines.joined(separator: "\n").write(to: documents.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    }
}
#endif
