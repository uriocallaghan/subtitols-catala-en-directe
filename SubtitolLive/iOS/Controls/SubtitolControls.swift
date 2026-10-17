import AppIntents
import SwiftUI
import WidgetKit

/// The controls the reader can put in Control Center, on the Lock Screen or on the
/// Action button.
@main
struct SubtitolControls: WidgetBundle {
    var body: some Widget {
        StartTranscribingControl()
    }
}

/// One press opens Subtítol Live listening, in the language in use.
struct StartTranscribingControl: ControlWidget {
    static let kind = "cat.subtitollive.start-transcribing"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartTranscribingControlIntent()) {
                Label("Subtitula", systemImage: "captions.bubble")
            }
        }
        .displayName("Comença a subtitular")
        .description("Obre duna i comença a posar per escrit el que se sent.")
    }
}
