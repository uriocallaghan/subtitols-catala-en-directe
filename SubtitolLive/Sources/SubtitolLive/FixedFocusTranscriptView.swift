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
    let typeface: ReadingTypeface
    let theme: ReadingTheme
    let isLive: Bool
    /// Presentation mode: fade the transcript out by age. Off by default, because a
    /// reader runs one to three seconds behind the speaker and the words they still need
    /// are precisely the ones this would erase.
    let ageGradient: Bool
    /// How text leaves the pane. The Mac default; the phone passes `.phone`.
    var fade: TranscriptFade = .desktop
    /// A drag scrolls back through what was said (the phone). Without a scroll bar: the
    /// pane only shows a way back to the live text once it has left it.
    var scrollsBack = false
    /// The transcript's language (a BCP 47 code, "es"), so VoiceOver reads it with that
    /// language's voice rather than the interface's.
    var speechLanguage: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

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
    @State private var visibleRows = 1
    /// Bumped when the size or typeface re-wraps every line. The live block is keyed on
    /// it, so its words mount fresh at their new rows' opacity instead of each easing
    /// from wherever it used to sit.
    @State private var wrapGeneration = 0
    /// The previous wrapping, frozen, fading out over the new one.
    @State private var outgoingWrap: WrapSnapshot?
    /// 0 → 1 during a re-wrap cross-fade; the outgoing copy is drawn at its complement.
    @State private var rewrapProgress: Double = 1
    /// How far the reader has scrolled back, in points. Zero follows the live text.
    @State private var scrollBack: CGFloat = 0
    /// `scrollBack` when the current drag began.
    @State private var dragOrigin: CGFloat?
    /// While the reader is back in the history, the line the text is drawn from, held
    /// still as new rows roll in below. Compensating each roll with an equal animated
    /// scroll instead left rows mounted mid-roll a whole line out of place, on top of
    /// their neighbours, until both animations had settled.
    @State private var heldLine: Int?
    /// History rows kept mounted while a scroll animates back towards the live text, so
    /// the rows it carries out of the top leave through the fade instead of vanishing.
    @State private var departingRows = 0
    @State private var scrollGeneration = 0
    @State private var paneSize: CGSize = .zero
    /// The pane's width. A word wider than it (a long word at a very large size) is
    /// narrowed to fit instead of being cut at the edge.
    @State private var columnWidth: CGFloat = .infinity
    /// Reads new settled text aloud to VoiceOver while listening.
    @State private var announcer = TranscriptAnnouncer()
    @State private var announcementFlush: Task<Void, Never>?

    /// Everything needed to draw a wrapping without reading live state. The outgoing
    /// copy must not follow the new size: SwiftUI re-renders a view on its way out, which
    /// drew the old line breaks in the new size.
    private struct WrapSnapshot {
        let generation: Int
        let placements: [RollUpTranscriptLayout.Placement]
        let fontSize: CGFloat
        let typeface: ReadingTypeface
        let bottomLine: Int
        let visibleRows: Int
        let reserve: Int
    }

    private var words: [StableTranscriptWord] { committedWords + provisionalWords }

    private var linePitch: CGFloat { fontSize * AppVisualMetrics.lineHeightRatio }

    /// Built from the same `NSFont` that `WordMetrics` measures, so a typeface change
    /// can never leave layout and drawing disagreeing about a word's width.
    private var readingFont: Font { Self.readingFont(fontSize: fontSize, typeface: typeface) }

    private var tracking: CGFloat { Self.tracking(fontSize: fontSize, typeface: typeface) }

    private static func readingFont(fontSize: CGFloat, typeface: ReadingTypeface) -> Font {
        Font(typeface.font(ofSize: fontSize) as CTFont)
    }

    private static func tracking(fontSize: CGFloat, typeface: ReadingTypeface) -> CGFloat {
        AppVisualMetrics.scaled(
            AppVisualMetrics.trackingAtReferenceFontSize,
            toFontSize: fontSize
        ) * typeface.trackingScale
    }

    private var wordSpacing: CGFloat {
        let gap = typeface.wordGapIsOwnSpace
            ? WordMetrics.spaceWidth(typeface: typeface, fontSize: fontSize, tracking: tracking)
            : AppVisualMetrics.scaled(
                AppVisualMetrics.interWordGapAtReferenceFontSize,
                toFontSize: fontSize
            )
        return max(
            0,
            gap - WordMetrics.trailingGuardWidth(
                typeface: typeface,
                fontSize: fontSize,
                tracking: tracking
            )
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
            .mask(scrolledMask(height: proxy.size.height))
            .contentShape(Rectangle())
            .gesture(scrollsBack && !words.isEmpty ? scrollGesture(in: proxy.size) : nil)
            .overlay(alignment: .bottom) { backToLive }
            .onChange(of: scrolledRows) { _, _ in retrim(in: proxy.size) }
            .onChange(of: heldLine) { _, _ in retrim(in: proxy.size) }
            .onChange(of: words.isEmpty) { _, isEmpty in
                if isEmpty { returnToLiveAtOnce() }
            }
            .onChange(of: words) { _, updated in
                // Stopping may replace the trusted final window atomically. Snapping
                // avoids presenting that one correction as a burst of animated edits.
                relayout(updated, in: proxy.size, animatesRoll: isLive)
            }
            .onChange(of: fontSize) { previous, _ in
                rewrap(from: previous, typeface, in: proxy.size)
            }
            .onChange(of: typeface) { previous, _ in
                rewrap(from: fontSize, previous, in: proxy.size)
            }
            .onChange(of: proxy.size) { previous, size in
                // New line breaks renumber the history, so the place held in it is gone.
                if previous.width != size.width { returnToLiveAtOnce() }
                // A new width re-wraps every line. Moving the old lines to their new
                // places would slide fragments across each other (the panel toggle
                // animates the width), so the text is re-placed in one step.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    relayout(words, in: size, animatesRoll: false)
                }
            }
            .onAppear { relayout(words, in: proxy.size, animatesRoll: false) }
            .onDisappear {
                rollTask?.cancel()
                rollTask = nil
                announcementFlush?.cancel()
            }
        }
        .onChange(of: committedWords, initial: true) { _, committed in announce(committed) }
        .onChange(of: voiceOverEnabled) { _, _ in announcer.reset(markingSpoken: committedWords) }
        .textSelection(.disabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            words.isEmpty ? Text(fallbackText) : Text(spoken(words.map(\.text).joined(separator: " ")))
        )
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

            if let outgoingWrap {
                frozenWords(outgoingWrap)
                    .opacity(1 - rewrapProgress)
                    .id(outgoingWrap.generation)
            }

            ZStack(alignment: .bottomLeading) {
                // IDs are minted by the stabilizer and survive timestamp drift. Raw ASR
                // positions are deliberately never used as SwiftUI identity.
                ForEach(placements) { placement in
                    Text(verbatim: AppVisualMetrics.renderedWord(placement.text, typeface: typeface))
                        .font(readingFont)
                        .tracking(tracking)
                        .lineLimit(1)
                        .foregroundStyle(theme.ink)
                        // Scoped so only the line fade eases; the text itself and its
                        // position still change instantly.
                        .animation(.easeInOut(duration: AppVisualMetrics.ageGradientTransitionSeconds)) {
                            $0.opacity(opacity(of: placement))
                        }
                        .minimumScaleFactor(0.2)
                        .frame(width: min(placement.width, columnWidth), alignment: .leading)
                        .offset(x: placement.x, y: verticalOffset(of: placement))
                        .opacity(appearingWordIDs.contains(placement.id) ? 0 : 1)
                }

                caret
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .id(wrapGeneration)
            .opacity(rewrapProgress)
            // Not `.offset`: SwiftUI hands an animated offset down to each word, and a
            // row mounted while a scroll springs (a row the scroll brings in, a new
            // word) started at the scroll's end, over its neighbours.
            .modifier(ScrollShift(offset: scrollBack))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    /// The previous wrapping exactly as it was last drawn, with no caret and no motion.
    private func frozenWords(_ wrap: WrapSnapshot) -> some View {
        let font = Self.readingFont(fontSize: wrap.fontSize, typeface: wrap.typeface)
        let tracking = Self.tracking(fontSize: wrap.fontSize, typeface: wrap.typeface)
        let pitch = wrap.fontSize * AppVisualMetrics.lineHeightRatio
        return ZStack(alignment: .bottomLeading) {
            ForEach(wrap.placements) { placement in
                Text(verbatim: AppVisualMetrics.renderedWord(placement.text, typeface: wrap.typeface))
                    .font(font)
                    .tracking(tracking)
                    .lineLimit(1)
                    .foregroundStyle(theme.ink)
                    .opacity(ageGradient
                        ? AppVisualMetrics.ageGradientOpacity(
                            rowFromBottom: wrap.bottomLine - placement.line,
                            visibleRows: wrap.visibleRows,
                            reserve: wrap.reserve,
                            curve: fade.ageCurve
                        )
                        : 1)
                    .minimumScaleFactor(0.2)
                    .frame(width: min(placement.width, columnWidth), alignment: .leading)
                    .offset(
                        x: placement.x,
                        y: -CGFloat(wrap.bottomLine - placement.line) * pitch
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
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
        -CGFloat(drawnLine - placement.line) * linePitch
    }

    /// The line on the bottom row before scrolling: the live one, or the one held.
    private var drawnLine: Int { heldLine ?? bottomLine }

    /// Whole lines fade by the row they sit on; see `AppVisualMetrics.ageGradientOpacity`.
    private func opacity(of placement: RollUpTranscriptLayout.Placement) -> Double {
        guard ageGradient else { return 1 }
        return AppVisualMetrics.ageGradientOpacity(
            rowFromBottom: drawnLine - placement.line - scrolledRows,
            visibleRows: visibleRows,
            reserve: engine.reserve,
            curve: fade.ageCurve
        )
    }

    /// Text dissolves as the roll-up pushes it out of the top of the pane. Binding the
    /// fade to leaving rather than to age gives the same look at no cost to reading:
    /// every word inside the block stays at full contrast for as long as it is there.
    private func exitMask(height: CGFloat) -> some View {
        let band = min(0.9, linePitch * fade.exitBandLines / max(height, 1))
        return LinearGradient(
            stops: fade.exitStops(band: band),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - VoiceOver

    /// New settled text, read aloud as phrases while listening. The announcements queue
    /// behind whatever VoiceOver is saying, so the reader hears every phrase in order.
    private func announce(_ committed: [StableTranscriptWord]) {
        guard voiceOverEnabled, isLive else {
            announcer.reset(markingSpoken: committed)
            return
        }
        for phrase in announcer.observe(committed: committed) { post(phrase) }
        // What is left of a phrase is read once the speaker has paused.
        announcementFlush?.cancel()
        announcementFlush = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let phrase = announcer.flush() else { return }
            post(phrase)
        }
    }

    private func spoken(_ phrase: String) -> AttributedString {
        var text = AttributedString(phrase)
        if let speechLanguage, !speechLanguage.isEmpty { text.languageIdentifier = speechLanguage }
        return text
    }

    private func post(_ phrase: String) {
        var text = spoken(phrase)
        text.accessibilitySpeechAnnouncementPriority = .low
        AccessibilityNotification.Announcement(text).post()
    }

    // MARK: - Layout

    private func relayout(
        _ tokens: [StableTranscriptWord],
        in size: CGSize,
        animatesRoll: Bool
    ) {
        guard size.width > 0, size.height > 0 else { return }
        if columnWidth != size.width { columnWidth = size.width }
        if paneSize != size { paneSize = size }
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
            WordMetrics.width(
                of: $0.text,
                typeface: typeface,
                fontSize: fontSize,
                tracking: tracking
            )
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
        // The layout rebuilt from scratch (a retroactive correction): the line held no
        // longer means the same text.
        if let heldLine, nextBottomLine < heldLine { returnToLiveAtOnce() }
        let next = visible(engine.placements, bottomLine: heldLine ?? clippingBottomLine, in: size)

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

    /// A new size or typeface sends almost every word to another row. Easing each word
    /// from its old row's age-gradient opacity to its new one made words on the same line
    /// brighten or dim at different moments, and words that had been hidden popped in.
    /// Instead the whole block cross-fades: nothing inside it animates on its own.
    private func rewrap(
        from previousFontSize: CGFloat,
        _ previousTypeface: ReadingTypeface,
        in size: CGSize
    ) {
        outgoingWrap = placements.isEmpty ? nil : WrapSnapshot(
            generation: wrapGeneration,
            placements: placements,
            fontSize: previousFontSize,
            typeface: previousTypeface,
            bottomLine: drawnLine,
            visibleRows: visibleRows,
            reserve: engine.reserve
        )
        wrapGeneration &+= 1
        rewrapProgress = 0
        returnToLiveAtOnce()
        relayout(words, in: size, animatesRoll: false)
        appearingWordIDs.removeAll(keepingCapacity: true)

        let generation = wrapGeneration
        withAnimation(.easeInOut(duration: AppVisualMetrics.rewrapCrossFadeSeconds)) {
            rewrapProgress = 1
        } completion: {
            guard generation == wrapGeneration else { return }
            outgoingWrap = nil
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
        if visibleRows != rows { visibleRows = rows }
        // With the age gradient, rows that have left the pane stay mounted at zero
        // opacity until their fade has finished; see `ageGradientTrailingRows`.
        let trailing = ageGradient ? AppVisualMetrics.ageGradientTrailingRows : 0
        // One spare row above while scrolled, so the next row up is in place before the
        // drag brings it in.
        let history = max(scrollBack > 0 ? scrolledRows + 1 : 0, departingRows)
        let topLine = bottomLine - rows + 1 - trailing - history
        let onScreen = all.drop { $0.line < topLine }
        let start = onScreen.firstIndex { $0.x == 0 } ?? onScreen.startIndex
        return Array(onScreen[start...])
    }
}

extension FixedFocusTranscriptView {
    // MARK: - Scrolling back

    /// Whole rows the reader has scrolled back, rounded up: a row partly in view counts.
    fileprivate var scrolledRows: Int {
        guard scrollBack > 0, linePitch > 0 else { return 0 }
        return Int((scrollBack / linePitch).rounded(.up))
    }

    /// The farthest back the kept history reaches: its first line resting on the
    /// pane's top row.
    fileprivate func maximumScroll(in size: CGSize) -> CGFloat {
        guard let first = engine.placements.first?.line else { return 0 }
        let rows = RollUpTranscriptLayout.visibleLineCount(height: size.height, linePitch: linePitch)
        return CGFloat(max(0, drawnLine - first + 1 - rows)) * linePitch
    }

    /// How far the text on screen is from the live text, rows rolled in below included.
    fileprivate var awayDistance: CGFloat {
        scrollBack + CGFloat(bottomLine - drawnLine) * linePitch
    }

    fileprivate func scrollGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { drag in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if dragOrigin == nil {
                        dragOrigin = scrollBack
                        if heldLine == nil { heldLine = bottomLine }
                    }
                    let origin = dragOrigin ?? scrollBack
                    let limit = maximumScroll(in: size)
                    let raw = origin + drag.translation.height
                    // Past either end the text follows the finger at a third of the pace,
                    // and springs back on release.
                    scrollBack = raw > limit ? limit + (raw - limit) / 3 : raw < 0 ? raw / 3 : raw
                }
            }
            .onEnded { drag in
                let origin = dragOrigin ?? scrollBack
                let caughtUp = catchUpHeldLine()
                dragOrigin = nil
                let limit = maximumScroll(in: size)
                let flung = origin + caughtUp + drag.predictedEndTranslation.height
                // Rest on whole rows, so a line is never left cut in half; half a row or
                // less from the live text is the live text.
                var target = (min(limit, max(0, flung)) / linePitch).rounded() * linePitch
                if target < linePitch * 0.5 { target = 0 }
                scroll(to: target, animation: reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.55, dampingFraction: 0.92))
            }
    }

    /// Moves the held line down to the live one and scrolls back by the same rows, in
    /// one still step, so a scroll can be measured from the live text again. Returns the
    /// points added to `scrollBack`.
    @discardableResult
    fileprivate func catchUpHeldLine() -> CGFloat {
        guard let held = heldLine else { return 0 }
        let shift = CGFloat(bottomLine - held) * linePitch
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            heldLine = bottomLine
            scrollBack += shift
        }
        return shift
    }

    /// Animates the scroll to `target`; at zero the text follows the live edge again.
    fileprivate func scroll(to target: CGFloat, animation: Animation) {
        if target < scrollBack {
            departingRows = max(departingRows, scrollBack > 0 ? scrolledRows + 1 : 0)
        }
        if target == 0 { heldLine = nil }
        scrollGeneration &+= 1
        let generation = scrollGeneration
        withAnimation(animation) {
            scrollBack = target
        } completion: {
            guard generation == scrollGeneration else { return }
            departingRows = 0
            retrim(in: paneSize)
        }
    }

    /// Straight back to the live text, for changes that re-place every line anyway.
    fileprivate func returnToLiveAtOnce() {
        scrollGeneration &+= 1
        heldLine = nil
        departingRows = 0
        scrollBack = 0
    }

    /// Re-trims the placed words to the rows now in view, without treating the rows a
    /// scroll brings back as new words.
    fileprivate func retrim(in size: CGSize) {
        guard !engine.placements.isEmpty, size.width > 0, size.height > 0 else { return }
        let next = visible(engine.placements, bottomLine: heldLine ?? min(bottomLine, completedBottomLine), in: size)
        guard next != placements else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { placements = next }
        appearingWordIDs.formIntersection(next.map(\.id))
    }

    /// Scrolled back, the bottom edge fades too, as the top one always does: lines slide
    /// under it instead of being cut.
    fileprivate func scrolledMask(height: CGFloat) -> some View {
        let reach = min(1, max(0, awayDistance / max(linePitch, 1)))
        let band = min(0.4, linePitch * 0.8 / max(height, 1))
        return LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 1 - band),
                .init(color: .black.opacity(1 - reach), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    @ViewBuilder
    fileprivate var backToLive: some View {
        if scrollsBack {
            let isAway = awayDistance > linePitch * 0.5
            Button {
                catchUpHeldLine()
                scroll(to: 0, animation: reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.6, dampingFraction: 0.9))
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down")
                        .scaledFont(size: 13, weight: .bold)
                    Text(isLive ? localized("Al directe") : localized("Al final"))
                        .scaledFont(size: 15, weight: .semibold)
                }
                .foregroundStyle(theme.paper)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(Capsule(style: .continuous).fill(theme.ink.opacity(0.88)))
                .contentShape(Capsule())
            }
            .buttonStyle(PressableButtonStyle())
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityShowsLargeContentViewer {
                Label(isLive ? localized("Al directe") : localized("Al final"), systemImage: "arrow.down")
            }
            .opacity(isAway ? 1 : 0)
            .scaleEffect(isAway || reduceMotion ? 1 : 0.85)
            .offset(y: isAway || reduceMotion ? 0 : 12)
            .allowsHitTesting(isAway)
            .accessibilityHidden(!isAway)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.34, dampingFraction: 0.82), value: isAway)
            // Half in the clear air above the bar, so it covers as little text as it can.
            .alignmentGuide(.bottom) { $0[.bottom] - 14 }
        }
    }
}

/// The scroll offset, interpolated here rather than on each word, so every word, one
/// mounted halfway through a scroll included, sits where the scroll is on that frame.
private struct ScrollShift: ViewModifier, Animatable {
    var offset: CGFloat

    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    func body(content: Content) -> some View {
        content.offset(y: offset)
    }
}

/// How the rising text leaves the top of the pane.
struct TranscriptFade: Equatable {
    /// Height of the exit band, in line pitches.
    var exitBandLines: CGFloat
    /// An eased band has no visible edge where the fade starts; a linear one is the Mac's.
    var easedExit: Bool
    var ageCurve: AppVisualMetrics.AgeGradientCurve

    static let desktop = TranscriptFade(
        exitBandLines: AppVisualMetrics.exitBandLineFraction,
        easedExit: false,
        ageCurve: .linear
    )

    /// A phone pane holds few rows directly under the orb. A band of one and a half
    /// lines shaped like smoothstep lets a line thin out over its last step instead of
    /// being cut at the orb's edge, and the eased age curve keeps the rows being read at
    /// full contrast.
    static let phone = TranscriptFade(
        exitBandLines: 1.5,
        easedExit: true,
        ageCurve: .eased
    )

    func exitStops(band: CGFloat) -> [Gradient.Stop] {
        guard easedExit else {
            return [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black, location: band),
                .init(color: .black, location: 1),
            ]
        }
        var stops = (0...6).map { step -> Gradient.Stop in
            let t = CGFloat(step) / 6
            let alpha = t * t * (3 - 2 * t)
            return .init(color: .black.opacity(alpha), location: band * t)
        }
        stops.append(.init(color: .black, location: 1))
        return stops
    }
}
