import SubtitolCore
import SwiftUI

// The vocabulary of the day, shared by the Mac card and the iPhone sheet: a field to
// type a name or a term, and the terms as a cloud of pills. A term typed arrives in the
// cloud out of the field, on a spring; one removed shrinks away and the others close
// the gap. Under Reduce Motion the same changes cross-fade.

/// Lays its children out in lines, like words in a paragraph, leading-aligned.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        return arrange(subviews, width: width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, width: bounds.width)
        for (subview, origin) in zip(subviews, arrangement.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + lineHeight), origins)
    }
}

/// The colours the cloud draws with, so the Mac card (bar material) and the iPhone
/// sheet (paper) can each pass their own.
struct VocabularyPalette {
    let ink: Color
    let mutedInk: Color
    /// The pills' fill and the field's well.
    let pill: Color
    let well: Color
    let hairline: Color
    let shadow: Color
    /// The halo a term arrives with: the app's orange.
    static let halo = Color(red: 1, green: 0.39, blue: 0)
}

/// The field and the cloud. `terms` is the controller's list; `onAdd` returns false
/// when the term was not taken (empty, repeated, or the list is full).
struct VocabularyCloud: View {
    let terms: [String]
    let limit: Int
    let palette: VocabularyPalette
    /// Type sizes of the pills and the field, for the Mac's small bar and the iPhone.
    var pillSize: CGFloat = 12
    var fieldSize: CGFloat = 12
    let onAdd: (String) -> Bool
    let onRemove: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @State private var newest: String?
    @State private var shake = 0
    @FocusState private var fieldFocused: Bool

    static let motion = Animation.spring(response: 0.36, dampingFraction: 0.74)
    static let removal = Animation.spring(response: 0.28, dampingFraction: 0.86)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            field
            if terms.isEmpty {
                Text(localized("Noms, llocs i sigles d'avui. El motor els afavoreix i surten escrits bé."))
                    .font(.system(size: pillSize - 1, weight: .medium))
                    .foregroundStyle(palette.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(terms, id: \.self) { term in
                        pill(term)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .asymmetric(
                                        insertion: .scale(scale: 0.4, anchor: .leading).combined(with: .opacity),
                                        removal: .scale(scale: 0.6).combined(with: .opacity)
                                    )
                            )
                    }
                }
                .padding(.horizontal, 2)
            }
            if terms.count >= limit {
                Text(localized("Amb \(limit) termes n'hi ha prou: més, i el motor ja no en distingeix cap."))
                    .font(.system(size: pillSize - 2, weight: .medium))
                    .foregroundStyle(palette.mutedInk)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Self.motion, value: terms)
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: fieldSize - 1, weight: .bold))
                .foregroundStyle(palette.mutedInk)
                .rotationEffect(.degrees(draft.isEmpty ? 0 : 90))
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: draft.isEmpty)
            TextField(localized("Afegeix un nom o un terme"), text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: fieldSize, weight: .semibold))
                .foregroundStyle(palette.ink)
                .focused($fieldFocused)
                .onSubmit(add)
                #if os(iOS)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                #endif
                .disabled(terms.count >= limit)
            if !draft.isEmpty {
                Button(action: add) {
                    Image(systemName: "return")
                        .font(.system(size: fieldSize - 2, weight: .bold))
                        .foregroundStyle(palette.ink)
                        .padding(5)
                        .background(Circle().fill(palette.pill))
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
                .accessibilityLabel(localized("Afegeix"))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: fieldSize * 2.6)
        .background {
            Capsule(style: .continuous)
                .fill(palette.well)
                .overlay(Capsule(style: .continuous).strokeBorder(palette.hairline))
        }
        .modifier(Shake(times: shake))
        .animation(.spring(response: 0.26, dampingFraction: 0.8), value: draft.isEmpty)
        .onAppear {
            // On the Mac the field only takes the focus once the card has settled in
            // the window; asked at once, the keystrokes went to the window instead.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                fieldFocused = true
            }
        }
    }

    private func add() {
        let term = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        if onAdd(term) {
            draft = ""
            newest = term
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                if newest == term { withAnimation(.easeOut(duration: 0.5)) { newest = nil } }
            }
        } else {
            // Already there, or no room: the field says no with a small shake.
            withAnimation(reduceMotion ? nil : .linear(duration: 0.35)) { shake += 1 }
        }
        fieldFocused = true
    }

    private func pill(_ term: String) -> some View {
        let isNew = newest == term
        return Button {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Self.removal) { onRemove(term) }
        } label: {
            HStack(spacing: 5) {
                Text(term)
                    .font(.system(size: pillSize, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: pillSize - 4, weight: .bold))
                    .opacity(0.45)
            }
            .foregroundStyle(palette.ink)
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: pillSize * 2.2)
            .background {
                Capsule(style: .continuous)
                    .fill(palette.pill)
                    .shadow(color: palette.shadow, radius: 3, y: 1)
            }
            // A term that just arrived carries the orange for a moment, then settles.
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(VocabularyPalette.halo, lineWidth: 1.5)
                    .opacity(isNew ? 1 : 0)
                    .scaleEffect(isNew ? 1 : 1.25)
            }
            .animation(.easeOut(duration: 0.5), value: isNew)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(term)
        .accessibilityHint(localized("Toca per treure'l del vocabulari"))
    }
}

/// A short horizontal shake, for a term the field did not take.
private struct Shake: ViewModifier, Animatable {
    var times: Int
    var animatableData: CGFloat {
        get { CGFloat(times) }
        set { progress = newValue }
    }
    private var progress: CGFloat = 0

    init(times: Int) {
        self.times = times
        self.progress = CGFloat(times)
    }

    func body(content: Content) -> some View {
        content.offset(x: sin(progress * .pi * 3) * 4)
    }
}
