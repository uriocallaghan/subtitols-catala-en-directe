import SubtitolCore
import SwiftUI

/// Bottom-anchored roll-up transcript.
///
/// Three animation channels, kept strictly apart, because the previous version ran all
/// three through one 0.56 s spring keyed on the word array. Updates arrive every
/// 100-300 ms, so that spring was re-targeted two to five times before it could settle —
/// which is what made the text feel broken.
///
/// | channel        | trigger                  | animation            |
/// |----------------|--------------------------|----------------------|
/// | roll-up        | the anchor line moves    | 0.24 s easeOut       |
/// | word appears   | a newly appended ID      | 0.11 s linear alpha  |
/// | word revised   | the recognizer changed it| none, instant        |
///
/// The last row matters as much as the first. A revision is not motion — it is the
/// recognizer changing its mind — so sliding a word to its new position draws the eye to
/// something that carries no meaning. Only the block translation is ever animated.
struct FixedFocusTranscriptView: View {
    let committedWords: [StableTranscriptWord]
    let provisionalWords: [StableTranscriptWord]
    let fallbackText: String
    let fontSize: CGFloat
    let theme: ReadingTheme
    let isLive: Bool
    /// Presentation mode: fade the transcript out by age. Off by default, because a
    /// reader runs one to three seconds behind the speaker and the words they still need
    /// are precisely the ones this would erase.
    let ageGradient: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var engine = RollUpTranscriptLayout()
    /// Always assigned outside `withAnimation`: a word that was re-decoded should swap
    /// in place, not travel. New IDs animate only through `appearingWordIDs`.
    @State private var placements: [RollUpTranscriptLayout.Placement] = []
    /// Absolute line number drawn on the bottom row. The only animated value here, and
    /// the reason settled text holds still: it is derived from settled lines alone, so a
    /// revision in the live tail cannot move it.
    @State private var bottomLine = 0
    /// Last line whose 240 ms transition has actually completed. Layout clipping uses
    /// this value rather than SwiftUI's already-updated animation target.
    @State private var completedBottomLine = 0
    @State private var rollTarget = 0
    @State private var rollTask: Task<Void, Never>?
    @State private var appearingWordIDs: Set<UInt64> = []

    private var words: [StableTranscriptWord] { committedWords + provisionalWords }

    private var linePitch: CGFloat { fontSize * AppVisualMetrics.lineHeightRatio }

    private var readingFont: Font {
        .custom(AppVisualMetrics.readingFontName, size: fontSize)
    }

    private var tracking: CGFloat {
        AppVisualMetrics.scaled(
            AppVisualMetrics.trackingAtReferenceFontSize,
            toFontSize: fontSize
        )
    }

    private var wordSpacing: CGFloat {
        max(
            0,
            AppVisualMetrics.scaled(
                AppVisualMetrics.interWordGapAtReferenceFontSize,
                toFontSize: fontSize
            ) - WordMetrics.trailingGuardWidth(fontSize: fontSize, tracking: tracking)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if words.isEmpty {
                    status
                } else {
                    transcript
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .clipped()
            .mask(exitMask(height: proxy.size.height))
            .onChange(of: words) { _, updated in
                // Stopping may replace the trusted final window atomically. Snapping
                // avoids presenting that one correction as a burst of animated edits.
                relayout(updated, in: proxy.size, animatesRoll: isLive)
            }
            .onChange(of: fontSize) { _, _ in
                relayout(words, in: proxy.size, animatesRoll: false)
            }
            .onChange(of: proxy.size) { _, size in
                relayout(words, in: size, animatesRoll: false)
            }
            .onAppear { relayout(words, in: proxy.size, animatesRoll: false) }
            .onDisappear {
                rollTask?.cancel()
                rollTask = nil
            }
        }
        .textSelection(.disabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(words.isEmpty ? fallbackText : words.map(\.text).joined(separator: " "))
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Content

    /// Status messages are not transcript, so they do not roll up or fade in word by word.
    private var status: some View {
        Text(fallbackText)
            .font(readingFont)
            .tracking(tracking)
            .lineSpacing(linePitch - fontSize * 1.2)
            .foregroundStyle(theme.ink.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transcript: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear

            // IDs are minted by the stabilizer and survive timestamp drift. Raw ASR
            // positions are deliberately never used as SwiftUI identity.
            ForEach(Array(placements.enumerated()), id: \.element.id) { index, placement in
                Text(verbatim: AppVisualMetrics.renderedWord(placement.text))
                    .font(readingFont)
                    .tracking(tracking)
                    .lineLimit(1)
                    .foregroundStyle(
                        theme.ink.opacity(
                            opacity(
                                of: placement,
                                wordsBehind: placements.count - 1 - index
                            )
                        )
                    )
                    .frame(width: placement.width, alignment: .leading)
                    .offset(x: placement.x, y: verticalOffset(of: placement))
                    .opacity(appearingWordIDs.contains(placement.id) ? 0 : 1)
            }

            caret
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    /// A still bar at the live edge. It marks where new text lands without dimming
    /// anything, and it does not blink: a blinking element beside running text is a
    /// distractor the reader cannot switch off.
    @ViewBuilder
    private var caret: some View {
        if isLive, let last = placements.last {
            let width = fontSize * AppVisualMetrics.caretWidthRatio
            RoundedRectangle(cornerRadius: width / 2, style: .continuous)
                .fill(theme.ink.opacity(0.45))
                .frame(width: width, height: fontSize * AppVisualMetrics.caretHeightRatio)
                .offset(
                    x: last.x + last.width,
                    y: verticalOffset(of: last) - fontSize * 0.17
                )
        }
    }

    private func verticalOffset(of placement: RollUpTranscriptLayout.Placement) -> CGFloat {
        -CGFloat(bottomLine - placement.line) * linePitch
    }

    private func opacity(
        of placement: RollUpTranscriptLayout.Placement,
        wordsBehind: Int
    ) -> Double {
        // The active suffix has exactly the same contrast as committed text. Its cursor,
        // not reduced opacity, is the only indication that recognition is still live.
        guard placement.isSettled else { return 1 }
        guard ageGradient else { return 1 }
        let depth = Double(AppVisualMetrics.gradientDepthInWords)
        return max(0, 1 - Double(wordsBehind) / depth)
    }

    /// Text dissolves as the roll-up pushes it out of the top of the pane. Binding the
    /// fade to leaving rather than to age gives the same look at no cost to reading:
    /// every word inside the block stays at full contrast for as long as it is there.
    private func exitMask(height: CGFloat) -> some View {
        let band = min(0.9, linePitch * AppVisualMetrics.exitBandLineFraction / max(height, 1))
        return LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black, location: band),
                .init(color: .black, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Layout

    private func relayout(
        _ tokens: [StableTranscriptWord],
        in size: CGSize,
        animatesRoll: Bool
    ) {
        guard size.width > 0, size.height > 0 else { return }
        guard !tokens.isEmpty else {
            engine.reset()
            placements = []
            appearingWordIDs.removeAll(keepingCapacity: true)
            rollTask?.cancel()
            rollTask = nil
            bottomLine = 0
            completedBottomLine = 0
            rollTarget = 0
            return
        }

        let widths = tokens.map {
            WordMetrics.width(of: $0.text, fontSize: fontSize, tracking: tracking)
        }
        engine.update(
            words: tokens,
            widths: widths,
            metrics: .init(
                maxWidth: size.width,
                wordSpacing: wordSpacing,
                fontSize: fontSize
            )
        )

        let nextBottomLine = engine.anchorLine + engine.reserve
        let clippingBottomLine = RollUpTranscriptLayout.clippingBottomLine(
            current: completedBottomLine,
            target: nextBottomLine,
            animatesRoll: animatesRoll,
            reduceMotion: reduceMotion
        )
        let next = visible(engine.placements, bottomLine: clippingBottomLine, in: size)

        if next != placements {
            let appendedIDs = RollUpTranscriptLayout.appendedIDs(
                from: placements,
                to: next
            )
            if !reduceMotion, !appendedIDs.isEmpty {
                appearingWordIDs.formUnion(appendedIDs)
            }
            placements = next
            appearingWordIDs.formIntersection(next.map(\.id))
            reveal(appendedIDs)
        }

        if RollUpTranscriptLayout.shouldSnapRoll(
            current: bottomLine,
            target: nextBottomLine,
            activeTarget: rollTarget,
            animatesRoll: animatesRoll,
            reduceMotion: reduceMotion
        ) {
            rollTask?.cancel()
            rollTask = nil
            rollTarget = nextBottomLine
            bottomLine = nextBottomLine
            completedBottomLine = nextBottomLine
        } else if nextBottomLine > bottomLine {
            animateRoll(to: nextBottomLine)
        }
    }

    /// A batch may stabilize enough text to open several lines. Advancing one absolute
    /// line per animation keeps the lyric motion legible instead of jumping several line
    /// pitches in a single retargeted transaction.
    private func animateRoll(to target: Int) {
        rollTarget = target
        guard rollTask == nil else { return }
        rollTask = Task { @MainActor in
            defer { rollTask = nil }
            while bottomLine < rollTarget, !Task.isCancelled {
                let nextLine = bottomLine + 1
                withAnimation(.easeOut(duration: 0.24)) {
                    bottomLine = nextLine
                }
                do {
                    try await Task.sleep(for: .milliseconds(240))
                } catch {
                    return
                }
                completedBottomLine = nextLine
            }
        }
    }

    private func reveal(_ ids: [UInt64]) {
        guard !reduceMotion, !ids.isEmpty else { return }
        Task { @MainActor in
            // Let SwiftUI mount the new IDs at alpha zero before starting their one
            // appearance animation. Existing offsets remain outside this transaction.
            await Task.yield()
            withAnimation(.linear(duration: 0.11)) {
                appearingWordIDs.subtract(ids)
            }
        }
    }

    /// Trims to the rows the pane can show, then drops any leading fragment so no visible
    /// line ever starts indented in mid-air.
    private func visible(
        _ all: [RollUpTranscriptLayout.Placement],
        bottomLine: Int,
        in size: CGSize
    ) -> [RollUpTranscriptLayout.Placement] {
        let rows = RollUpTranscriptLayout.visibleLineCount(
            height: size.height,
            linePitch: linePitch
        )
        let topLine = bottomLine - rows + 1
        let onScreen = all.drop { $0.line < topLine }
        let start = onScreen.firstIndex { $0.x == 0 } ?? onScreen.startIndex
        return Array(onScreen[start...])
    }
}
