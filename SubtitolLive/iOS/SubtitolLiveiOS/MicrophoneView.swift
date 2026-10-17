import AVFoundation
import SubtitolCore
import SwiftUI

/// The microphones the iPhone can listen with right now, kept current as headphones,
/// AirPods or a USB interface come and go.
@MainActor
final class PhoneAudioInputs: ObservableObject {
    struct Input: Identifiable, Hashable {
        let id: String
        let name: String
        let caption: String
        let symbol: String
    }

    @Published private(set) var inputs: [Input] = []
    /// The one iOS is using at the moment.
    @Published private(set) var activeID: String?

    private var observer: NSObjectProtocol?

    init() {
        // Without the recording category iOS lists only the built-in microphone.
        try? AudioCapture.prepareSession()
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { self?.refresh() }
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func refresh() {
        let session = AVAudioSession.sharedInstance()
        let inputs = (session.availableInputs ?? []).map(Self.input(for:))
        let active = session.currentRoute.inputs.first?.uid
        if inputs != self.inputs { self.inputs = inputs }
        if active != activeID { activeID = active }
    }

    private static func input(for port: AVAudioSessionPortDescription) -> Input {
        switch port.portType {
        case .builtInMic:
            Input(id: port.uid, name: "iPhone", caption: localized("Micròfon del telèfon"), symbol: "iphone")
        case .headsetMic:
            Input(id: port.uid, name: localized("Auriculars"), caption: localized("Amb cable"), symbol: "headphones")
        case .bluetoothHFP:
            Input(id: port.uid, name: port.portName, caption: "Bluetooth",
                  symbol: port.portName.localizedCaseInsensitiveContains("airpods") ? "airpods" : "headphones")
        case .usbAudio:
            Input(id: port.uid, name: port.portName, caption: "USB", symbol: "cable.connector")
        case .carAudio:
            Input(id: port.uid, name: port.portName, caption: localized("Cotxe"), symbol: "car.fill")
        default:
            Input(id: port.uid, name: port.portName, caption: localized("Extern"), symbol: "mic.fill")
        }
    }
}

/// Chooses the microphone. "Automàtic" leaves it to iOS, which takes the last one
/// connected; a chosen one that is unplugged stays listed and is used again when it
/// comes back. Changing it while listening keeps the text.
struct MicrophoneView: View {
    @ObservedObject var controller: SubtitleController
    @StateObject private var inputs = PhoneAudioInputs()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The interface language: its change re-renders the words below.
    @Environment(\.locale) private var locale

    private static let accent = Color(red: 1, green: 0.39, blue: 0)
    private static let selection = Animation.spring(response: 0.26, dampingFraction: 0.82)

    private var chosenIsMissing: Bool {
        guard let chosen = controller.preferredInputUID else { return false }
        return !inputs.inputs.contains { $0.id == chosen }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(
                        symbol: "wand.and.stars",
                        name: localized("Automàtic"),
                        caption: localized("Fa servir l'últim que connectis"),
                        isChosen: controller.preferredInputUID == nil,
                        isActive: false
                    ) {
                        controller.selectInput(uid: nil, name: nil)
                    }
                    ForEach(inputs.inputs) { input in
                        row(
                            symbol: input.symbol,
                            name: input.name,
                            caption: input.caption,
                            isChosen: controller.preferredInputUID == input.id,
                            isActive: inputs.activeID == input.id && controller.isRecording
                        ) {
                            controller.selectInput(uid: input.id, name: input.name)
                        }
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                    }
                    if chosenIsMissing {
                        row(
                            symbol: "mic.slash",
                            name: controller.preferredInputName ?? localized("Micròfon"),
                            caption: localized("Desconnectat · ara s'usa l'automàtic"),
                            isChosen: true,
                            isActive: false,
                            isDimmed: true
                        ) { }
                        .transition(.opacity)
                    }
                } footer: {
                    Text(localized("Per a una sala, el micròfon de l'iPhone o un de cable acostumen a sentir-hi millor que uns auriculars Bluetooth, que graven amb menys qualitat."))
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(localized("Micròfon"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("Fet")) { dismiss() }
                }
            }
        }
        .tint(Self.accent)
        .sensoryFeedback(.selection, trigger: controller.preferredInputUID)
    }

    private func row(
        symbol: String,
        name: String,
        caption: String,
        isChosen: Bool,
        isActive: Bool,
        isDimmed: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(Self.selection) { action() }
        } label: {
            let glyph = Image(systemName: symbol)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Self.accent)
                .frame(width: 28)
            let text = VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline).foregroundStyle(.primary)
                Text(isActive ? localized("\(caption) · escoltant") : caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.interpolate)
                    .animation(.easeInOut(duration: 0.25), value: isActive)
            }
            let check = Image(systemName: "checkmark")
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(Self.accent)
                .opacity(isChosen ? 1 : 0)
                .scaleEffect(isChosen ? 1 : 0.6)
                // The list re-renders its rows without the tap's transaction, so the
                // mark carries its own animation.
                .animation(Self.selection, value: isChosen)
            Group {
                if typeSize.isAccessibilitySize {
                    // At the largest text sizes the glyph and the check sit over the name,
                    // which gets the row's whole width instead of breaking in the middle.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            glyph
                            Spacer(minLength: 8)
                            check
                        }
                        text
                    }
                } else {
                    HStack(spacing: 14) {
                        glyph
                        text
                        Spacer(minLength: 8)
                        check
                    }
                }
            }
            .opacity(isDimmed ? 0.55 : 1)
            .animation(.easeInOut(duration: 0.25), value: isDimmed)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDimmed)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}
