import AppIntents

// Compiled into the app and into the Controls extension: a control's action must exist
// in both, but it runs in the app, which the system opens first (`.foreground`). The
// extension never runs it, so it does not need the app's code: the app hands its own
// start over through `ControlActions` at launch.

/// The button's action: open the app and start listening in the language in use.
/// Not listed in Shortcuts, which has "Comença a subtitular" with a choice of language.
struct StartTranscribingControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Comença a subtitular"
    static let description = IntentDescription("Obre duna i comença a posar per escrit el que se sent.")
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ControlActions.startTranscribing?()
        return .result()
    }
}

/// Set by the app at launch.
@MainActor
enum ControlActions {
    static var startTranscribing: (() async throws -> Void)?
}
