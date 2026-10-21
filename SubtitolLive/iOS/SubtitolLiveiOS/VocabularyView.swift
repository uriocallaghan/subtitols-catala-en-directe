import SubtitolCore
import SwiftUI

/// The vocabulary of the day on the iPhone: a half-height sheet with the field at the
/// top, the cloud of terms under it, and the keyboard below. The same cloud as the Mac's
/// card (`VocabularyCloud`), on the reading pane's paper.
struct VocabularyView: View {
    @ObservedObject var controller: SubtitleController
    let isDark: Bool
    @Environment(\.dismiss) private var dismiss

    private static let accent = Color(red: 1, green: 0.39, blue: 0)

    private var palette: VocabularyPalette {
        let theme = ReadingTheme.resolved(isDark: isDark)
        return VocabularyPalette(
            ink: theme.ink,
            mutedInk: theme.ink.opacity(0.5),
            pill: isDark ? Color(white: 0.24) : .white,
            well: isDark ? Color(white: 0.17) : Color(white: 0.94),
            hairline: isDark ? .white.opacity(0.08) : .black.opacity(0.06),
            shadow: isDark ? .black.opacity(0.4) : .black.opacity(0.08)
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    VocabularyCloud(
                        terms: controller.vocabulary,
                        limit: SubtitleController.vocabularyLimit,
                        palette: palette,
                        pillSize: 15,
                        fieldSize: 16,
                        onAdd: { controller.addVocabularyTerm($0) },
                        onRemove: { controller.removeVocabularyTerm($0) }
                    )
                    if !controller.vocabulary.isEmpty {
                        Button(localized("Esborra-ho tot")) {
                            withAnimation(VocabularyCloud.removal) { controller.clearVocabulary() }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.mutedInk)
                        .padding(.horizontal, 6)
                        .padding(.top, 2)
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .animation(.spring(response: 0.3, dampingFraction: 0.84), value: controller.vocabulary.isEmpty)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(localized("Vocabulari de l'acte"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("Fet")) { dismiss() }
                }
            }
        }
        .tint(Self.accent)
        .sensoryFeedback(.increase, trigger: controller.vocabulary.count)
    }
}
