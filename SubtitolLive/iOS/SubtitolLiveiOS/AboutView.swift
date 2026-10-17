import SubtitolCore
import SwiftUI

/// Privacy, limits and credits. The models' licences (CC-BY-4.0, MIT) and the fonts'
/// (SIL OFL 1.1) require the attributions shown here.
struct AboutView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    /// The interface language: its change re-renders the words below.
    @Environment(\.locale) private var locale

    private var theme: ReadingTheme { scheme == .dark ? .dark : .light }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    item("lock.shield", localized("Tot passa a l'iPhone"),
                         localized("La veu es transcriu al mateix telèfon. No s'envia àudio ni text enlloc, i l'app no recull cap dada."))
                    item("wifi.slash", localized("Funciona sense connexió"),
                         localized("Només cal internet per baixar cada idioma el primer cop."))
                    item("exclamationmark.bubble", localized("Pot tenir errors"),
                         localized("És una transcripció automàtica. No substitueix un servei professional de subtitulació ni cap aparell auditiu."))
                } header: {
                    Text(localized("Privacitat"))
                }

                Section {
                    credit(localized("Model de veu en català"),
                           localized("stt_ca-es_conformer_transducer_large, de la Unitat de Tecnologies del Llenguatge del Barcelona Supercomputing Center (Projecte Aina, finançat per ILENIA). Llicència CC BY 4.0."))
                    credit(localized("Models de veu dels altres idiomes"),
                           localized("Castellà i anglès: stt_es i stt_en_fastconformer_hybrid_large_pc, de NVIDIA (CC BY 4.0). Gallec: stt_los_conformer_transducer_large_punctuated, del Barcelona Supercomputing Center (Apache 2.0). Basc: stt_eu_conformer_transducer_large_v2, d'HiTZ, UPV/EHU (Apache 2.0)."))
                    credit(localized("Models de puntuació"),
                           localized("Català: basat en distilroberta-base-ca-v2 del Projecte Aina (Apache 2.0), entrenat amb transcripcions CC0 i Common Voice. Basc: basat en BERnaT-medium d'HiTZ (Apache 2.0), entrenat amb ParlaMint (CC BY 4.0), Common Voice i subtítols d'Open Data Euskadi (CC BY 4.0)."))
                    credit(localized("Canvis de veu"),
                           localized("pyannote segmentation-3.0 (Hervé Bredin i col·laboradors). Llicència MIT."))
                    credit(localized("Motor de reconeixement"),
                           localized("NeMo-Speech.cpp de NVIDIA i ggml. Llicència Apache 2.0 i MIT."))
                    credit(localized("Tipografies"),
                           localized("Inter (Rasmus Andersson) i Atkinson Hyperlegible Next i Mono (Braille Institute of America). SIL Open Font License 1.1."))
                } header: {
                    Text(localized("Crèdits i llicències"))
                }

                Section {
                    LabeledContent(localized("Versió"), value: version)
                    Link(destination: AppLinks.privacy) {
                        Label(localized("Política de privacitat"), systemImage: "hand.raised")
                    }
                    Link(destination: AppLinks.terms) {
                        Label(localized("Condicions d'ús"), systemImage: "doc.text")
                    }
                    Link(destination: AppLinks.support) {
                        Label(localized("Suport"), systemImage: "questionmark.bubble")
                    }
                }
            }
            .navigationTitle(localized("Informació"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("Fet")) { dismiss() }
                }
            }
        }
    }

    private func item(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.39, blue: 0))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func credit(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(.subheadline, weight: .semibold))
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
