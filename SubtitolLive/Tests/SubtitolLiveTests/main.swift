import AppKit
import CoreGraphics
import CoreText
import Darwin
import SubtitolCore
import SwiftUI

private final class TestState: @unchecked Sendable {
    var failures = 0
}

private let testState = TestState()

private func check<T: Equatable>(_ actual: T, equals expected: T, _ name: String) {
    guard actual != expected else { return }
    testState.failures += 1
    print("FAIL \(name): expected \(expected), got \(actual)")
}

private func check(_ condition: Bool, _ name: String) {
    guard !condition else { return }
    testState.failures += 1
    print("FAIL \(name)")
}

private func testTranscriptLedger() {
    var ledger = TranscriptLedger()
    ledger.merge(
        words: [
            .init(text: "aquesta", startMilliseconds: 300, endMilliseconds: 650, confidence: 0.9),
            .init(text: "escrivia", startMilliseconds: 700, endMilliseconds: 1_100, confidence: 0.5),
        ],
        windowStartSequence: 0,
        windowEndSequence: 24_000,
        sampleRate: 16_000,
        isInitialWindow: true
    )
    ledger.merge(
        words: [
            .init(text: "aquesta", startMilliseconds: 300, endMilliseconds: 650, confidence: 0.95),
            .init(text: "escriu", startMilliseconds: 700, endMilliseconds: 1_050, confidence: 0.95),
            .init(text: "les", startMilliseconds: 1_080, endMilliseconds: 1_250, confidence: 0.9),
        ],
        windowStartSequence: 0,
        windowEndSequence: 24_000,
        sampleRate: 16_000,
        isInitialWindow: false
    )
    check(ledger.visibleTail(limit: 10), equals: "aquesta escriu les", "ledger replaces trusted range")

    var clippedLedger = TranscriptLedger()
    clippedLedger.merge(
        words: [.init(text: "paraules", startMilliseconds: 900, endMilliseconds: 1_300, confidence: 0.9)],
        windowStartSequence: 0,
        windowEndSequence: 24_000,
        sampleRate: 16_000,
        isInitialWindow: true
    )
    clippedLedger.merge(
        words: [
            .init(text: "taules", startMilliseconds: 80, endMilliseconds: 310, confidence: 0.4),
            .init(text: "gairebe", startMilliseconds: 350, endMilliseconds: 720, confidence: 0.9),
        ],
        windowStartSequence: 14_400,
        windowEndSequence: 38_400,
        sampleRate: 16_000,
        isInitialWindow: false
    )
    check(clippedLedger.visibleTail(limit: 10), equals: "paraules gairebe", "ledger ignores clipped boundary words")

    clippedLedger.merge(
        words: [],
        windowStartSequence: 14_400,
        windowEndSequence: 38_400,
        sampleRate: 16_000,
        isInitialWindow: false
    )
    check(clippedLedger.visibleTail(limit: 10), equals: "paraules", "empty hypothesis clears its trusted interval")

    var tailLedger = TranscriptLedger()
    tailLedger.merge(
        words: (0..<12).map {
            RecognizedWord(
                text: "w\($0)",
                startMilliseconds: Int32($0 * 100),
                endMilliseconds: Int32($0 * 100 + 80),
                confidence: 1
            )
        },
        windowStartSequence: 0,
        windowEndSequence: 24_000,
        sampleRate: 16_000,
        isInitialWindow: true
    )
    check(tailLedger.visibleTail(limit: 3), equals: "w9 w10 w11", "visible tail limit")
}

private func testLatestAudioScheduler() {
    var scheduler = LatestAudioScheduler(minimumHopSamples: 1_280)
    check(scheduler.noteAudio(sequence: 1_000) == nil, "scheduler waits for hop")
    check(scheduler.noteAudio(sequence: 1_280) == 1_280, "scheduler submits at hop")
    scheduler.alignInFlightSnapshot(sequence: 2_000)
    check(scheduler.noteAudio(sequence: 2_000) == nil, "scheduler coalesces first pending update")
    check(scheduler.noteAudio(sequence: 3_000) == nil, "scheduler coalesces second pending update")
    check(scheduler.noteAudio(sequence: 4_000) == nil, "scheduler coalesces latest pending update")
    check(scheduler.complete(latestSequence: 4_000) == 4_000, "scheduler submits newest sequence after aligned snapshot")
    check(scheduler.isInFlight, "scheduler marks resubmission in flight")

    scheduler.reset()
    check(!scheduler.isInFlight, "scheduler reset clears in-flight work")
    check(scheduler.noteAudio(sequence: 1_000) == nil, "scheduler reset clears submitted sequence")
    check(scheduler.noteAudio(sequence: 1_280) == 1_280, "scheduler restarts cleanly")

    var aligned = LatestAudioScheduler(minimumHopSamples: 1_280)
    check(aligned.noteAudio(sequence: 1_280) == 1_280, "aligned scheduler starts")
    aligned.alignInFlightSnapshot(sequence: 2_000)
    check(aligned.noteAudio(sequence: 2_500) == nil, "aligned scheduler marks dirty")
    check(aligned.complete(latestSequence: 2_500) == nil, "aligned scheduler rejects sub-hop resubmit")
    check(aligned.noteAudio(sequence: 3_279) == nil, "aligned scheduler still waits for real hop")
    check(aligned.noteAudio(sequence: 3_280) == 3_280, "aligned scheduler submits after real hop")
}

private func testWindowPolicy() {
    check(LiveWindowPolicy.minimumHopSeconds, equals: 0.18, "readable update hop")
    check(LiveWindowPolicy.targetSeconds(for: 0.35), equals: 4.0, "padded startup window")
    check(LiveWindowPolicy.targetSeconds(for: 1.5), equals: 4.0, "startup keeps one context")
    check(LiveWindowPolicy.targetSeconds(for: 2.5), equals: 4.0, "no decoder context transition")
    check(LiveWindowPolicy.targetSeconds(for: 30), equals: 4.0, "steady window")
}

private func testLatencyDistribution() {
    let distribution = LatencyDistribution(samples: [500, 100, 300, 200, 400])
    check(distribution.count, equals: 5, "latency sample count")
    check(distribution.p50, equals: 300, "latency P50")
    check(distribution.p95, equals: 500, "latency P95 nearest rank")
    check(distribution.maximum, equals: 500, "latency maximum")

    let empty = LatencyDistribution(samples: [])
    check(empty.count, equals: 0, "empty latency count")
    check(empty.p50 == nil, "empty latency P50")
}

private func testWordErrorRate() {
    check(WordErrorRate.score(reference: "hola món", hypothesis: "Hola, món!"), equals: 0, "WER normalizes case and punctuation")
    let score = WordErrorRate.score(reference: "a b c", hypothesis: "a x c d")
    check(abs(score - 2.0 / 3.0) < 0.000_001, "WER substitutions and insertions")
}

private func testStableTranscriptWords() {
    var reconciler = TranscriptWordReconciler()
    let first = reconciler.reconcile("M’agrada com queda")
    let appended = reconciler.reconcile("M’agrada com queda visual")

    check(
        Array(appended.prefix(3).map(\.id)),
        equals: Array(first.map(\.id)),
        "stable words keep identity when appending"
    )

    let inserted = reconciler.reconcile("M’agrada molt com queda visual")
    check(inserted[0].id, equals: appended[0].id, "stable words keep prefix across insertion")
    check(inserted[2].id, equals: appended[1].id, "stable words keep suffix across insertion")

    let punctuated = reconciler.reconcile("M’agrada molt com queda visual.")
    check(
        punctuated.last?.id,
        equals: inserted.last?.id,
        "punctuation does not replace a stable word"
    )

    let corrected = reconciler.reconcile("M’agrada molt com queda viva.")
    check(corrected.last?.id != punctuated.last?.id, "corrected word gets a new identity")
}

private func words(
    _ texts: [String],
    committed: Int = 0,
    firstAnchor: UInt64 = 1
) -> [StableTranscriptWord] {
    texts.enumerated().map { index, text in
        StableTranscriptWord(
            id: UInt64(index + 1),
            text: text,
            isCommitted: index < committed,
            anchor: firstAnchor + UInt64(index)
        )
    }
}

/// Row 0 is the bottom line of the pane, which is what the reader actually sees. Testing
/// absolute line numbers instead is how the previous build shipped with the pane lurching
/// a full line at a time while every assertion passed.
private func rows(
    _ placements: [RollUpTranscriptLayout.Placement],
    _ layout: RollUpTranscriptLayout
) -> [Int] {
    placements.map(layout.row(of:))
}

private func testRollUpLayoutForwardBreaking() {
    let metrics = RollUpTranscriptLayout.Metrics(
        maxWidth: 200, wordSpacing: 10, fontSize: 56
    )
    var layout = RollUpTranscriptLayout()
    let first = layout.update(
        words: words(["a", "b", "c", "d", "e"], committed: 5),
        widths: [50, 60, 40, 70, 30],
        metrics: metrics
    )
    check(first.map(\.line), equals: [0, 0, 0, 1, 1], "greedy forward line breaking")
    check(first.map(\.x), equals: [0, 60, 130, 0, 80], "left aligned offsets")

    let appended = layout.update(
        words: words(["a", "b", "c", "d", "e", "f"], committed: 6),
        widths: [50, 60, 40, 70, 30, 90],
        metrics: metrics
    )
    check(
        Array(appended.prefix(5).map(\.line)),
        equals: first.map(\.line),
        "appending keeps earlier line assignments"
    )
    check(
        Array(appended.prefix(5).map(\.x)),
        equals: first.map(\.x),
        "appending keeps earlier offsets"
    )
    check(appended[5].line, equals: 2, "overflowing word opens a new line")
}

private func testRollUpLayoutSurvivesWindowSlide() {
    let metrics = RollUpTranscriptLayout.Metrics(
        maxWidth: 200, wordSpacing: 10, fontSize: 56
    )
    var layout = RollUpTranscriptLayout()
    let settled = words(["a", "b", "c", "d", "e"], committed: 5)
    let widths: [CGFloat] = [50, 60, 40, 70, 30]
    let before = layout.update(words: settled, widths: widths, metrics: metrics)
    let beforeRows = rows(before, layout)

    // The oldest word falls out of the retained tail. Anchors are what identify settled
    // text, so the survivors have to keep the exact rows and offsets they already had.
    let after = layout.update(
        words: Array(settled.dropFirst()),
        widths: Array(widths.dropFirst()),
        metrics: metrics
    )
    check(after.map(\.x), equals: before.map(\.x), "a slide re-places nothing")
    check(rows(after, layout), equals: beforeRows, "a slide moves no row")
}

/// The defect the redesign exists to fix. A live hypothesis that grows by a line and then
/// shrinks back used to drag every settled word up and down with it, because the block
/// hung from the live edge.
private func testLiveTailLengthNeverMovesSettledRows() {
    let metrics = RollUpTranscriptLayout.Metrics(
        maxWidth: 200, wordSpacing: 10, fontSize: 56
    )
    var layout = RollUpTranscriptLayout()
    let settledTexts = ["a", "b", "c", "d"]
    let settledWidths: [CGFloat] = [50, 60, 40, 70]

    func place(live: [String], widths: [CGFloat]) -> [Int] {
        var tokens = words(settledTexts, committed: 4)
        tokens += live.enumerated().map {
            StableTranscriptWord(
                id: UInt64(100 + $0.offset),
                text: $0.element,
                isCommitted: false,
                anchor: UInt64(100 + $0.offset)
            )
        }
        let placed = layout.update(
            words: tokens,
            widths: settledWidths + widths,
            metrics: metrics
        )
        return rows(Array(placed.prefix(4)), layout)
    }

    let short = place(live: ["x"], widths: [40])
    let long = place(live: ["x", "y", "z", "w"], widths: [40, 90, 90, 90])
    let shortAgain = place(live: ["x"], widths: [40])

    check(long, equals: short, "a growing hypothesis leaves settled rows alone")
    check(shortAgain, equals: short, "a shrinking hypothesis leaves settled rows alone")
}

/// Provisional rewrites live in a fixed lane. Even an awkward three-word tail may not
/// move settled text merely because it wraps differently.
private func testProvisionalTailNeverChangesScrollAnchor() {
    let metrics = RollUpTranscriptLayout.Metrics(
        maxWidth: 200, wordSpacing: 10, fontSize: 56
    )
    var layout = RollUpTranscriptLayout()
    let settled = words(["a"], committed: 1)
    _ = layout.update(words: settled, widths: [50], metrics: metrics)
    let originalBottom = layout.anchorLine + layout.reserve
    var tokens = settled
    tokens += (0..<3).map {
        StableTranscriptWord(
            id: UInt64(100 + $0), text: "w", isCommitted: false, anchor: UInt64(100 + $0)
        )
    }
    let placed = layout.update(
        words: tokens,
        widths: [50] + Array(repeating: 190, count: 3),
        metrics: metrics
    )
    check(layout.reserve, equals: RollUpTranscriptLayout.baseReserve, "the live reserve stays fixed")
    check(layout.anchorLine + layout.reserve, equals: originalBottom, "a provisional wrap cannot scroll settled text")
    check(rows(placed, layout).allSatisfy { $0 >= 0 }, "no live word falls below the pane")
    check(placed.filter { !$0.isSettled }.count, equals: 2, "overflow waits outside the fixed live lane")
}

/// A retroactive correction to settled text must not be silently ignored. Correctness
/// beats stillness: the layout rebuilds.
private func testRetroactiveCorrectionRebuilds() {
    let metrics = RollUpTranscriptLayout.Metrics(
        maxWidth: 400, wordSpacing: 10, fontSize: 56
    )
    var layout = RollUpTranscriptLayout()
    layout.update(
        words: words(["hola", "que", "tal"], committed: 3),
        widths: [90, 80, 70],
        metrics: metrics
    )
    let corrected = layout.update(
        words: words(["hola", "com", "va"], committed: 3),
        widths: [90, 80, 70],
        metrics: metrics
    )
    check(corrected.map(\.text), equals: ["hola", "com", "va"], "a settled correction is applied")
    check(corrected.map(\.x), equals: [0, 100, 190], "the rebuild is a clean forward layout")
}

/// A new recording restarts audio positions from zero. Without a guard the layout would
/// treat every word as already placed and render nothing at all.
private func testNewSessionAnchorsRebuild() {
    let metrics = RollUpTranscriptLayout.Metrics(
        maxWidth: 400, wordSpacing: 10, fontSize: 56
    )
    var layout = RollUpTranscriptLayout()
    layout.update(
        words: words(["una", "altra"], committed: 2, firstAnchor: 90_000),
        widths: [90, 110],
        metrics: metrics
    )
    let restarted = layout.update(
        words: words(["nova", "sessio"], committed: 2, firstAnchor: 1),
        widths: [100, 120],
        metrics: metrics
    )
    check(restarted.map(\.text), equals: ["nova", "sessio"], "a restarted session still renders")
    check(restarted.map(\.x), equals: [0, 110], "and starts from the left edge")
}

private func testRollUpLayoutRelaysOutOnMetricsChange() {
    var layout = RollUpTranscriptLayout()
    let tokens = words(["a", "b", "c"], committed: 3)
    layout.update(
        words: tokens,
        widths: [50, 60, 40],
        metrics: .init(maxWidth: 200, wordSpacing: 10, fontSize: 56)
    )
    let narrow = layout.update(
        words: tokens,
        widths: [50, 60, 40],
        metrics: .init(maxWidth: 100, wordSpacing: 10, fontSize: 56)
    )
    check(narrow.map(\.line), equals: [0, 1, 2], "a resize is allowed to reflow")
}

private func testRollUpLayoutOversizedWord() {
    var layout = RollUpTranscriptLayout()
    let placed = layout.update(
        words: words(["enorme", "b"], committed: 2),
        widths: [320, 40],
        metrics: .init(maxWidth: 200, wordSpacing: 10, fontSize: 56)
    )
    check(placed[0].line, equals: 0, "an oversized word keeps its own line rather than vanishing")
    check(placed[1].line, equals: 1, "the next word moves on")
}

private func testVisibleLineCount() {
    check(RollUpTranscriptLayout.visibleLineCount(height: 538, linePitch: 81), equals: 6, "line capacity")
    check(RollUpTranscriptLayout.visibleLineCount(height: 10, linePitch: 81), equals: 1, "never fewer than one line")
    check(RollUpTranscriptLayout.visibleLineCount(height: 538, linePitch: 0), equals: 1, "degenerate pitch")
}

private func testForwardRollRetainsRowsForTheAnimationStart() {
    check(
        RollUpTranscriptLayout.clippingBottomLine(
            current: 2,
            target: 5,
            animatesRoll: true,
            reduceMotion: false
        ),
        equals: 2,
        "multi-line roll clips against its starting position"
    )
    check(
        RollUpTranscriptLayout.clippingBottomLine(
            current: 2,
            target: 5,
            animatesRoll: false,
            reduceMotion: false
        ),
        equals: 5,
        "non-animated reflow clips at its final position"
    )
    check(
        RollUpTranscriptLayout.shouldSnapRoll(
            current: 3,
            target: 3,
            activeTarget: 5,
            animatesRoll: false,
            reduceMotion: false
        ),
        "a resize cancels an unfinished roll even when its target equals the model line"
    )
}

private func testAppendDetectionIgnoresPromotionState() {
    let provisional = RollUpTranscriptLayout.Placement(
        id: 1, anchor: 1, text: "hola", line: 0, x: 0, width: 80, isSettled: false
    )
    let promoted = RollUpTranscriptLayout.Placement(
        id: 1, anchor: 1, text: "hola", line: 0, x: 0, width: 80, isSettled: true
    )
    let appended = RollUpTranscriptLayout.Placement(
        id: 2, anchor: 2, text: "món", line: 0, x: 90, width: 70, isSettled: false
    )
    check(
        RollUpTranscriptLayout.appendedIDs(from: [provisional], to: [promoted, appended]),
        equals: [2],
        "promotion and append still identify the new word for fade-in"
    )
    let leaving = RollUpTranscriptLayout.Placement(
        id: 9, anchor: 0, text: "anterior", line: -1, x: 0, width: 100, isSettled: true
    )
    check(
        RollUpTranscriptLayout.appendedIDs(
            from: [leaving, provisional],
            to: [promoted, appended]
        ),
        equals: [2],
        "a word appended during roll-up still fades after the top word leaves"
    )

    let replacement = RollUpTranscriptLayout.Placement(
        id: 3, anchor: 1, text: "canvi", line: 0, x: 0, width: 85, isSettled: false
    )
    check(
        RollUpTranscriptLayout.appendedIDs(from: [provisional], to: [replacement]),
        equals: [],
        "a provisional correction is not treated as an animated append"
    )

    let evicted = RollUpTranscriptLayout.Placement(
        id: 10, anchor: 10, text: "surt", line: 0, x: 0, width: 70, isSettled: true
    )
    let entered = RollUpTranscriptLayout.Placement(
        id: 11, anchor: 11, text: "entra", line: 1, x: 0, width: 75, isSettled: true
    )
    check(
        RollUpTranscriptLayout.appendedIDs(from: [evicted], to: [entered]),
        equals: [11],
        "a new word fades even when the previous visible row is fully evicted"
    )
}

private func testCommitHorizon() {
    check(
        LiveWindowPolicy.committedThroughSequence(newestSequence: 160_000, sampleRate: 16_000),
        equals: 96_000,
        "commit horizon trails the newest sample by the widest interim window"
    )
    check(
        LiveWindowPolicy.committedThroughSequence(newestSequence: 32_000, sampleRate: 16_000),
        equals: 0,
        "nothing is settled before the horizon is reached"
    )
    check(
        LiveWindowPolicy.committedThroughSequence(newestSequence: 160_000, sampleRate: 0),
        equals: 0,
        "no sample rate, nothing settled"
    )
    check(
        LiveWindowPolicy.commitLagSeconds >= LiveWindowPolicy.targetSeconds(for: 30),
        "the commit horizon is never shorter than the widest interim window"
    )
}

private func testCommittedWordIdentity() {
    var reconciler = TranscriptWordReconciler()
    let settled = ["ara", "mateix", "les", "animacions", "estan", "molt", "trencades"]
    let first = reconciler.reconcile(settled.map { TranscriptWordInput(text: $0, isCommitted: true) })

    // The recognizer revises the live tail and appends. Nothing in the settled region
    // may be re-identified, or the view would fade and re-place text already being read.
    let revised = reconciler.reconcile(
        settled.map { TranscriptWordInput(text: $0, isCommitted: true) }
            + [TranscriptWordInput(text: "avui")]
    )
    check(
        Array(revised.prefix(settled.count).map(\.id)),
        equals: first.map(\.id),
        "settled words keep identity when the tail grows"
    )

    // The window slides: the oldest word drops off the front.
    let slid = reconciler.reconcile(
        settled.dropFirst().map { TranscriptWordInput(text: $0, isCommitted: true) }
            + [TranscriptWordInput(text: "avui")]
    )
    check(
        Array(slid.prefix(settled.count - 1).map(\.id)),
        equals: Array(first.dropFirst().map(\.id)),
        "settled words keep identity when the window slides"
    )
    check(slid.last?.id, equals: revised.last?.id, "the live word keeps identity across a slide")
    check(slid.allSatisfy { $0.isCommitted || $0.text == "avui" }, "commit flags survive reconciliation")
}

private func testLedgerTailWords() {
    var ledger = TranscriptLedger()
    ledger.merge(
        words: (0..<5).map {
            RecognizedWord(
                text: "w\($0)",
                startMilliseconds: Int32($0 * 100),
                endMilliseconds: Int32($0 * 100 + 80),
                confidence: 1
            )
        },
        windowStartSequence: 0,
        windowEndSequence: 24_000,
        sampleRate: 16_000,
        isInitialWindow: true
    )
    let tail = ledger.visibleTailWords(limit: 3)
    check(tail.map(\.text), equals: ["w2", "w3", "w4"], "word tail matches the text tail")
    check(tail.map(\.text).joined(separator: " "), equals: ledger.visibleTail(limit: 3), "both tails agree")
    check(tail.map(\.startSequence), equals: tail.map(\.startSequence).sorted(), "tail keeps reading order")
    check(ledger.visibleTailWords(limit: 0).isEmpty, "zero limit yields no words")
}


private func measuredWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
    let font = AppVisualMetrics.readingFont(ofSize: fontSize)
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(
            string: AppVisualMetrics.renderedWord(text),
            attributes: [.font: font]
        )
    )
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)).rounded(.up)
}

/// End-to-end rehearsal of a live session: words arrive one at a time, the newest one is
/// a partial hypothesis that completes on the next update, the retained tail is capped,
/// and everything older than the commit horizon is settled. Real font measurements, real
/// reconciliation, real layout.
///
/// This is the test the whole redesign exists to pass. The old bottom-right layout moved
/// every word on screen on every single update; here, nothing settled may move at all.
private func testLiveStreamKeepsSettledTextStill() {
    let sentence = """
    avui hem parlat molt de com les animacions poden ajudar la lectura en directe i \
    de per que el contrast es el primer que cal resoldre quan una persona depen del \
    text per seguir una conversa sencera sense perdre cap paraula pel cami
    """.split(separator: " ").map(String.init)

    let fontSize: CGFloat = 56
    let guardWidth = measuredWidth("", fontSize: fontSize)
    let metrics = RollUpTranscriptLayout.Metrics(
        maxWidth: 730,
        wordSpacing: AppVisualMetrics.scaled(
            AppVisualMetrics.interWordGapAtReferenceFontSize,
            toFontSize: fontSize
        ) - guardWidth,
        fontSize: fontSize
    )

    var reconciler = TranscriptWordReconciler()
    var layout = RollUpTranscriptLayout()
    var placedRows: [UInt64: (row: Int, x: CGFloat)] = [:]
    var settledXMoves = 0
    var tornFrames = 0
    var shiftFrames = 0
    var overflows = 0
    var rollUps = 0
    var previousBottom = Int.min
    var bottomWentBackwards = 0

    for spoken in 1...sentence.count {
        let visible = Array(sentence.prefix(spoken).suffix(36))
        let committedCount = max(0, visible.count - 10)
        let base = UInt64(max(0, spoken - visible.count))
        var inputs = visible.enumerated().map { index, text in
            TranscriptWordInput(
                text: text,
                isCommitted: index < committedCount,
                anchor: base + UInt64(index) + 1
            )
        }
        // The newest word is still a partial hypothesis, as it is in a real stream, and
        // the one before it gets re-decoded — the case that used to scatter the pane.
        if let last = inputs.indices.last, inputs[last].text.count > 4 {
            inputs[last] = TranscriptWordInput(
                text: String(inputs[last].text.prefix(4)),
                anchor: inputs[last].anchor
            )
        }
        if spoken % 3 == 0, inputs.count > committedCount + 1 {
            let index = committedCount
            inputs[index] = TranscriptWordInput(
                text: inputs[index].text + "n",
                anchor: inputs[index].anchor
            )
        }

        let words = reconciler.reconcile(inputs)
        let widths = words.map { measuredWidth($0.text, fontSize: fontSize) }
        let placements = layout.update(words: words, widths: widths, metrics: metrics)

        let bottom = layout.anchorLine + layout.reserve
        if bottom < previousBottom { bottomWentBackwards += 1 }
        if bottom > previousBottom, previousBottom != Int.min { rollUps += 1 }
        previousBottom = bottom

        var deltas = Set<Int>()
        for placement in placements {
            if placement.x + placement.width > metrics.maxWidth + 1 { overflows += 1 }
            guard placement.isSettled, let was = placedRows[placement.anchor] else { continue }
            if was.x != placement.x { settledXMoves += 1 }
            deltas.insert(layout.row(of: placement) - was.row)
        }
        // Settled text is allowed to travel, but only as one rigid block and only when
        // the anchor itself moved. Two different deltas in the same frame means the text
        // tore apart under the reader.
        if deltas.count > 1 { tornFrames += 1 }
        if deltas.contains(where: { $0 != 0 }) { shiftFrames += 1 }

        for placement in placements where placement.isSettled {
            placedRows[placement.anchor] = (layout.row(of: placement), placement.x)
        }
    }

    // Rows, not lines. A settled word that keeps its line while the anchor moves under it
    // has still jumped in front of the reader.
    check(settledXMoves, equals: 0, "no settled word ever changes its horizontal offset")
    check(tornFrames, equals: 0, "settled text only ever moves as one rigid block")
    check(bottomWentBackwards, equals: 0, "the block never scrolls backwards")
    check(overflows, equals: 0, "no line overflows the column")
    check(rollUps >= 4, "the rehearsal produced enough roll-ups to be meaningful")
    check(
        shiftFrames <= rollUps,
        "settled text moves only on a roll-up, never on a hypothesis change"
    )
}

/// Regression: a real recognizer revises words in the MIDDLE of a hypothesis, not only at
/// the end. Reusing a stored placement for a word that sits after a revised one used to
/// leave the cursor disagreeing with the rest of the line, which drew words on top of each
/// other and started lines indented in mid-air.
private func testMidHypothesisRevisionKeepsLinesIntact() {
    let fontSize: CGFloat = 40
    let guardWidth = measuredWidth("", fontSize: fontSize)
    let metrics = RollUpTranscriptLayout.Metrics(
        maxWidth: 517,
        wordSpacing: AppVisualMetrics.scaled(
            AppVisualMetrics.interWordGapAtReferenceFontSize,
            toFontSize: fontSize
        ) - guardWidth,
        fontSize: fontSize
    )
    let hypotheses = [
        "si aixo mirant a veure que val",
        "si aixo mirant a veure que vale",
        "si aixo mirant una veure que vale",
        "si aixo mirant una veure que vale la",
        "si allo mirant una veure que vale la",
        "si allo mirant una veure que vale la pena molt mes clara",
    ]

    var reconciler = TranscriptWordReconciler()
    var layout = RollUpTranscriptLayout()
    var overlaps = 0
    var indentedLines = 0
    var backwardLines = 0

    for hypothesis in hypotheses {
        let words = reconciler.reconcile(
            hypothesis.split(separator: " ").map { TranscriptWordInput(text: String($0)) }
        )
        let placed = layout.update(
            words: words,
            widths: words.map { measuredWidth($0.text, fontSize: fontSize) },
            metrics: metrics
        )
        for index in placed.indices.dropFirst() {
            let previous = placed[index - 1]
            let current = placed[index]
            if current.line < previous.line { backwardLines += 1 }
            if current.line == previous.line, current.x < previous.x + previous.width - 1 {
                overlaps += 1
            }
            if current.line > previous.line, current.x != 0 { indentedLines += 1 }
        }
    }

    check(overlaps, equals: 0, "a mid-hypothesis revision never overlaps words")
    check(indentedLines, equals: 0, "no line ever starts indented")
    check(backwardLines, equals: 0, "words stay in reading order")
}

private func testReadingFontIsInterMedium() {
    check(
        AppVisualMetrics.readingFont(ofSize: 56).fontName,
        equals: "Inter18pt-Medium",
        "transcript uses Inter Medium"
    )
}

private func testFinalAccentFitsInsideSwiftUITextLayout() {
    let samples = ["així", "aixi\u{301}", "sí", "si\u{301}"]
    let fontSizes: [CGFloat] = [32, 56, 70, 96]

    for fontSize in fontSizes {
        let tracking = AppVisualMetrics.scaled(
            AppVisualMetrics.trackingAtReferenceFontSize,
            toFontSize: fontSize
        )
        for sample in samples {
            let attributed = NSAttributedString(
                string: sample,
                attributes: [
                    .font: AppVisualMetrics.readingFont(ofSize: fontSize),
                    .kern: tracking,
                ]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            let inkBounds = CTLineGetBoundsWithOptions(
                line,
                [.useGlyphPathBounds, .excludeTypographicLeading]
            )
            let host = NSHostingView(
                rootView: Text(verbatim: AppVisualMetrics.renderedWord(sample))
                    .font(.custom(AppVisualMetrics.readingFontName, size: fontSize))
                    .tracking(tracking)
                    .lineLimit(1)
            )

            check(
                host.fittingSize.width >= inkBounds.maxX + 1,
                "SwiftUI layout contains final accent ink for \(sample) at \(fontSize) pt"
            )
        }
    }
}

private func testAppVisualMetrics() {
    check(AppVisualMetrics.minimumPanelInset, equals: 0, "window has no residual outer gutter")
    check(AppVisualMetrics.referencePanelInset, equals: 0, "panel reaches the window edge")
    check(AppVisualMetrics.panelCornerRadius, equals: 22, "window is a little rounder than stock Mac chrome")
    check(AppVisualMetrics.trafficLightOffset.width, equals: 8, "traffic lights move away from left edge")
    check(AppVisualMetrics.trafficLightOffset.height, equals: 8, "traffic lights move away from top edge")
    check(
        AppVisualMetrics.trackingAtReferenceFontSize,
        equals: -2.2,
        "Inter Medium uses the requested compact character spacing"
    )
    check(!AppVisualMetrics.trailingGlyphGuard.isEmpty, "every word includes an internal glyph guard")
    check(
        AppVisualMetrics.interWordGapAtReferenceFontSize >= 17,
        "the word gap reads as wider than the letter gap"
    )
    check(
        AppVisualMetrics.lineHeightRatio >= 1.2,
        "line pitch stays clear of ascender and descender collisions"
    )
    check(AppVisualMetrics.clampedFontSize(8), equals: AppVisualMetrics.minimumFontSize, "font size floor")
    check(AppVisualMetrics.clampedFontSize(400), equals: AppVisualMetrics.maximumFontSize, "font size ceiling")
    check(
        AppVisualMetrics.scaled(AppVisualMetrics.interWordGapAtReferenceFontSize, toFontSize: 35),
        equals: AppVisualMetrics.interWordGapAtReferenceFontSize / 2,
        "metrics scale linearly with font size"
    )

    let baseInset: CGFloat = 147
    func readingAnchorDistance(fontSize: CGFloat) -> CGFloat {
        AppVisualMetrics.transcriptBottomInset(
            baseInset: baseInset,
            fontSize: fontSize
        ) + CGFloat(RollUpTranscriptLayout.baseReserve)
            * fontSize
            * AppVisualMetrics.lineHeightRatio
    }
    check(
        abs(
            readingAnchorDistance(fontSize: AppVisualMetrics.maximumFontSize)
                - readingAnchorDistance(fontSize: AppVisualMetrics.defaultFontSize)
        ) < 0.001,
        "font size changes keep the reading anchor at a stable visual height"
    )
}

private func observed(
    _ text: String,
    start: UInt64,
    end: UInt64
) -> TranscriptObservationWord {
    TranscriptObservationWord(
        text: text,
        startSequence: start,
        endSequence: end,
        confidence: 1
    )
}

private func testTranscriptionProfilesExposeFrozenPolicies() {
    check(TranscriptionProfile.default, equals: .reliable, "reliable is the default profile")
    check(TranscriptionProfile.reliable.policy.minimumHopSeconds, equals: 0.300, "reliable hop")
    check(TranscriptionProfile.reliable.policy.initialEvidenceRequired, equals: 3, "reliable show evidence")
    check(TranscriptionProfile.reliable.policy.replacementEvidenceRequired, equals: 3, "reliable replacement evidence")
    check(TranscriptionProfile.reliable.policy.minimumWordAgeSeconds, equals: 0.650, "reliable word age")
    check(TranscriptionProfile.balanced.policy.minimumHopSeconds, equals: 0.240, "balanced hop")
    check(TranscriptionProfile.balanced.policy.initialEvidenceRequired, equals: 2, "balanced show evidence")
    check(TranscriptionProfile.immediate.policy.minimumHopSeconds, equals: 0.180, "immediate hop")
    check(TranscriptionProfile.immediate.policy.initialEvidenceRequired, equals: 1, "immediate show evidence")
}

private func testReliableProfileSuppressesABAChurn() {
    var stabilizer = ReadableTranscriptStabilizer(policy: .reliable)
    let a = [observed("món", start: 580, end: 700)]
    let b = [observed("mont", start: 580, end: 700)]

    check(
        stabilizer.observe(a, audioEndSequence: 800, sampleRate: 1_000).words.isEmpty,
        "reliable does not publish a one-pass hypothesis"
    )
    check(
        stabilizer.observe(b, audioEndSequence: 850, sampleRate: 1_000).words.isEmpty,
        "a contradictory second pass remains internal"
    )
    check(
        stabilizer.observe(a, audioEndSequence: 900, sampleRate: 1_000).words.isEmpty,
        "A/B/A does not count as three confirmations"
    )
    _ = stabilizer.observe(a, audioEndSequence: 950, sampleRate: 1_000)
    let visible = stabilizer.observe(a, audioEndSequence: 1_000, sampleRate: 1_000)
    check(visible.words.map(\.text), equals: ["món"], "three consecutive exact observations publish once")

    _ = stabilizer.observe(b, audioEndSequence: 1_050, sampleRate: 1_000)
    _ = stabilizer.observe(a, audioEndSequence: 1_100, sampleRate: 1_000)
    let stillA = stabilizer.observe(b, audioEndSequence: 1_150, sampleRate: 1_000)
    check(stillA.words.map(\.text), equals: ["món"], "a visible word survives alternating replacements")
}

private func testReplacementKeepsItsVisualIdentityWhenCommitted() {
    var stabilizer = ReadableTranscriptStabilizer(
        stabilityLagSeconds: 0.35,
        confirmationsRequired: 2
    )
    let first = stabilizer.observe(
        [observed("casa", start: 100, end: 220)],
        audioEndSequence: 400,
        sampleRate: 1_000
    )
    let visibleID = first.provisionalWords.first?.id
    _ = stabilizer.observe(
        [observed("caça", start: 100, end: 220)],
        audioEndSequence: 500,
        sampleRate: 1_000
    )
    let committed = stabilizer.observe(
        [observed("caça", start: 105, end: 225)],
        audioEndSequence: 700,
        sampleRate: 1_000
    )
    check(committed.committedWords.first?.text, equals: "caça", "the replacement commits")
    check(
        committed.committedWords.first?.id,
        equals: visibleID,
        "promotion from revised provisional to committed preserves visual identity"
    )
}

private func testDiacriticsRequireExactConfirmation() {
    var stabilizer = ReadableTranscriptStabilizer(policy: .balanced)
    _ = stabilizer.observe(
        [observed("mon", start: 100, end: 220)],
        audioEndSequence: 600,
        sampleRate: 1_000
    )
    let accentChanged = stabilizer.observe(
        [observed("món", start: 105, end: 225)],
        audioEndSequence: 650,
        sampleRate: 1_000
    )
    check(accentChanged.words.isEmpty, "mon/món do not count as the same confirmation")
    let confirmed = stabilizer.observe(
        [observed("món", start: 110, end: 230)],
        audioEndSequence: 700,
        sampleRate: 1_000
    )
    check(confirmed.words.map(\.text), equals: ["món"], "the exact accented form confirms independently")
}

private func testBalancedRequiresTwoConsecutiveReplacementObservations() {
    var stabilizer = ReadableTranscriptStabilizer(policy: .balanced)
    let a = [observed("casa", start: 430, end: 550)]
    let b = [observed("caça", start: 430, end: 550)]
    _ = stabilizer.observe(a, audioEndSequence: 600, sampleRate: 1_000)
    let visibleA = stabilizer.observe(a, audioEndSequence: 650, sampleRate: 1_000)
    let id = visibleA.words.first?.id
    let oneB = stabilizer.observe(b, audioEndSequence: 700, sampleRate: 1_000)
    check(oneB.words.map(\.text), equals: ["casa"], "balanced ignores the first alternative")
    let twoB = stabilizer.observe(b, audioEndSequence: 750, sampleRate: 1_000)
    check(twoB.words.map(\.text), equals: ["caça"], "balanced accepts two consecutive alternatives")
    check(twoB.words.first?.id, equals: id, "balanced replacement preserves visual identity")
}

private func testFinalCorrectionAtomicallyReplacesCoveredCommittedText() {
    var stabilizer = ReadableTranscriptStabilizer(policy: .reliable)
    let live = [
        observed("abans", start: 100, end: 250),
        observed("equivocat", start: 900, end: 1_100),
    ]
    _ = stabilizer.observe(live, audioEndSequence: 5_200, sampleRate: 1_000)
    _ = stabilizer.observe(live, audioEndSequence: 5_300, sampleRate: 1_000)
    _ = stabilizer.observe(live, audioEndSequence: 5_400, sampleRate: 1_000)

    let corrected = stabilizer.finalize(
        [observed("correcte", start: 850, end: 1_080)],
        windowStartSequence: 500,
        windowIncludesSessionStart: false,
        timingQuality: .wordOffsets,
        audioEndSequence: 5_400,
        sampleRate: 1_000
    )
    check(
        corrected.committedWords.map(\.text),
        equals: ["abans", "correcte"],
        "the final decode replaces committed text inside its trusted window"
    )
    check(corrected.provisionalWords.isEmpty, "an atomic final correction has no live tail")
    check(
        stabilizer.finalCorrectionDisposition,
        equals: .corrected,
        "the successful correction is observable for diagnostics"
    )
}

private func testFinalCorrectionPreservesStableTextWithoutRealTiming() {
    var stabilizer = ReadableTranscriptStabilizer(policy: .reliable)
    let live = [observed("estable", start: 100, end: 250)]
    _ = stabilizer.observe(live, audioEndSequence: 5_000, sampleRate: 1_000)
    _ = stabilizer.observe(live, audioEndSequence: 5_100, sampleRate: 1_000)
    _ = stabilizer.observe(live, audioEndSequence: 5_200, sampleRate: 1_000)

    let preserved = stabilizer.finalize(
        [observed("inventat", start: 100, end: 250)],
        windowStartSequence: 0,
        windowIncludesSessionStart: true,
        timingQuality: .estimated,
        audioEndSequence: 5_200,
        sampleRate: 1_000
    )
    check(preserved.words.map(\.text), equals: ["estable"], "estimated timing cannot destructively rewrite stable text")
    check(
        stabilizer.finalCorrectionDisposition,
        equals: .preservedBecauseTimingUnavailable,
        "timing degradation is recorded"
    )
}

private func testPartialWordOffsetsAreTimingDegradation() {
    check(
        TranscriptTimingQuality.classify(
            transcriptText: "hola món",
            timedWordTexts: ["hola"]
        ),
        equals: .estimated,
        "partial offsets cannot authorize a destructive final replacement"
    )
    check(
        TranscriptTimingQuality.classify(
            transcriptText: "Hola, món!",
            timedWordTexts: ["hola", "món"]
        ),
        equals: .wordOffsets,
        "complete offsets tolerate case and punctuation differences"
    )
    check(
        TranscriptTimingQuality.classify(transcriptText: "", timedWordTexts: []),
        equals: .wordOffsets,
        "a genuinely empty decode has complete timing coverage"
    )
    check(
        !TranscriptTimingQuality.spansAreTrustworthy([(start: 100, end: 100)]),
        "a zero-duration offset cannot authorize replacement"
    )
    check(
        !TranscriptTimingQuality.spansAreTrustworthy([
            (start: 200, end: 300),
            (start: 100, end: 180),
        ]),
        "out-of-order offsets cannot authorize replacement"
    )
    check(
        TranscriptTimingQuality.spansAreTrustworthy([
            (start: 100, end: 180),
            (start: 200, end: 300),
        ]),
        "positive ordered offsets are trustworthy"
    )
}

private func testLegacyReconcilerDoesNotReuseCommittedIdentityAcrossAccentChange() {
    var reconciler = TranscriptWordReconciler()
    let first = reconciler.reconcile([
        TranscriptWordInput(text: "mon", isCommitted: true, anchor: 1)
    ])
    let second = reconciler.reconcile([
        TranscriptWordInput(text: "món", isCommitted: true, anchor: 1)
    ])
    check(first.first?.id != second.first?.id, "a committed accent change cannot reuse identity")
}

private func testFinalCorrectionGuardPreservesAWordCrossingTheLeftBoundary() {
    var stabilizer = ReadableTranscriptStabilizer(policy: .reliable)
    let live = [
        observed("abans", start: 100, end: 250),
        observed("tallada", start: 700, end: 900),
    ]
    _ = stabilizer.observe(live, audioEndSequence: 5_100, sampleRate: 1_000)
    _ = stabilizer.observe(live, audioEndSequence: 5_200, sampleRate: 1_000)
    _ = stabilizer.observe(live, audioEndSequence: 5_300, sampleRate: 1_000)
    let final = stabilizer.finalize(
        [observed("nova", start: 1_000, end: 1_150)],
        windowStartSequence: 500,
        windowIncludesSessionStart: false,
        timingQuality: .wordOffsets,
        audioEndSequence: 5_300,
        sampleRate: 1_000
    )
    check(
        final.words.map(\.text),
        equals: ["abans", "tallada", "nova"],
        "the 250 ms guard preserves a word that began before the trusted boundary"
    )
}

private func testReadableTranscriptNeverRewritesCommittedPrefix() {
    var stabilizer = ReadableTranscriptStabilizer()
    _ = stabilizer.observe(
        [
            observed("hola", start: 100, end: 220),
            observed("món", start: 240, end: 360),
        ],
        audioEndSequence: 700,
        sampleRate: 1_000
    )
    let confirmed = stabilizer.observe(
        [
            observed("hola", start: 112, end: 232),
            observed("món", start: 252, end: 372),
        ],
        audioEndSequence: 760,
        sampleRate: 1_000
    )
    check(
        confirmed.committedWords.map(\.text),
        equals: ["hola", "món"],
        "two old matching observations commit an immutable prefix"
    )

    let contradicted = stabilizer.observe(
        [
            observed("hola", start: 80, end: 210),
            observed("mon", start: 220, end: 350),
            observed("canviat", start: 390, end: 510),
        ],
        audioEndSequence: 900,
        sampleRate: 1_000
    )
    check(
        contradicted.committedWords.map(\.text),
        equals: ["hola", "món"],
        "a later hypothesis cannot rewrite committed words"
    )
    check(
        contradicted.provisionalWords.count <= 3,
        "the visible provisional tail is capped at three words"
    )
}

private func testReadableTranscriptReplayHandlesChurnAndEmptyFrames() {
    var stabilizer = ReadableTranscriptStabilizer()
    let first = stabilizer.observe(
        [
            observed("una", start: 100, end: 200),
            observed("frase", start: 220, end: 340),
            observed("que", start: 360, end: 440),
            observed("encara", start: 460, end: 580),
        ],
        audioEndSequence: 700,
        sampleRate: 1_000
    )
    let originalIDs = first.provisionalWords.map(\.id)
    check(first.provisionalWords.count, equals: 3, "only three provisional words are visible")

    let inserted = stabilizer.observe(
        [
            observed("una", start: 110, end: 210),
            observed("petita", start: 215, end: 300),
            observed("frase", start: 305, end: 350),
            observed("que", start: 365, end: 450),
            observed("encara", start: 470, end: 590),
        ],
        audioEndSequence: 760,
        sampleRate: 1_000
    )
    check(inserted.committedWords.map(\.text), equals: ["una"], "an insertion blocks later commits until confirmed")
    check(inserted.committedWords.first?.id, equals: originalIDs.first, "timestamp drift keeps app identity")

    let confirmedInsertion = stabilizer.observe(
        [
            observed("una", start: 115, end: 215),
            observed("petita", start: 220, end: 305),
            observed("frase", start: 310, end: 355),
            observed("que", start: 370, end: 455),
            observed("encara", start: 475, end: 595),
        ],
        audioEndSequence: 820,
        sampleRate: 1_000
    )
    check(
        confirmedInsertion.committedWords.map(\.text),
        equals: ["una", "petita", "frase", "que"],
        "a confirmed insertion preserves every later word"
    )
    check(
        confirmedInsertion.committedWords.map(\.anchor),
        equals: [1, 2, 3, 4],
        "layout order is monotonic even when stable IDs were created earlier"
    )
    var layout = RollUpTranscriptLayout()
    let laidOut = layout.update(
        words: confirmedInsertion.words,
        widths: Array(repeating: 40, count: confirmedInsertion.words.count),
        metrics: .init(maxWidth: 400, wordSpacing: 10, fontSize: 56)
    )
    check(
        laidOut.filter(\.isSettled).map(\.text),
        equals: ["una", "petita", "frase", "que"],
        "layout never skips surviving words after a provisional insertion"
    )

    let afterOneEmpty = stabilizer.observe([], audioEndSequence: 860, sampleRate: 1_000)
    check(
        afterOneEmpty.provisionalWords.map(\.text),
        equals: confirmedInsertion.provisionalWords.map(\.text),
        "one empty observation cannot erase the visible tail"
    )
    let afterTwoEmpty = stabilizer.observe([], audioEndSequence: 900, sampleRate: 1_000)
    check(afterTwoEmpty.provisionalWords.isEmpty, "two empty observations clear only the provisional tail")
    check(
        afterTwoEmpty.committedWords.map(\.text),
        equals: ["una", "petita", "frase", "que"],
        "empty observations preserve committed history"
    )
}

private func testReadableTranscriptFinalOnlyResolvesSuffix() {
    var stabilizer = ReadableTranscriptStabilizer()
    _ = stabilizer.observe(
        [
            observed("text", start: 100, end: 200),
            observed("visible", start: 220, end: 320),
            observed("avui", start: 340, end: 520),
        ],
        audioEndSequence: 650,
        sampleRate: 1_000
    )
    let live = stabilizer.observe(
        [
            observed("text", start: 105, end: 205),
            observed("visible", start: 225, end: 325),
            observed("avui", start: 345, end: 525),
        ],
        audioEndSequence: 710,
        sampleRate: 1_000
    )
    check(live.committedWords.map(\.text), equals: ["text", "visible"], "live prefix is committed")

    let final = stabilizer.finalize(
        [
            observed("text", start: 90, end: 190),
            observed("visibles", start: 210, end: 330),
            observed("demà", start: 350, end: 530),
        ],
        audioEndSequence: 710,
        sampleRate: 1_000
    )
    check(
        final.committedWords.map(\.text),
        equals: ["text", "visible", "demà"],
        "final correction preserves the committed prefix and resolves only its suffix"
    )
    check(final.provisionalWords.isEmpty, "final correction leaves no provisional tail")
}

private func testCommittedBoundarySurvivesForwardTimestampDrift() {
    var stabilizer = ReadableTranscriptStabilizer()
    let first = [
        observed("hola", start: 100, end: 200),
        observed("món", start: 240, end: 420),
    ]
    _ = stabilizer.observe(first, audioEndSequence: 520, sampleRate: 1_000)
    let committed = stabilizer.observe(first, audioEndSequence: 600, sampleRate: 1_000)
    check(committed.committedWords.map(\.text), equals: ["hola"], "drift fixture commits its prefix")

    let drifted = stabilizer.observe(
        [
            observed("hola", start: 160, end: 260),
            observed("món", start: 300, end: 480),
        ],
        audioEndSequence: 700,
        sampleRate: 1_000
    )
    check(
        drifted.provisionalWords.map(\.text),
        equals: ["món"],
        "forward timestamp drift cannot duplicate the committed boundary"
    )
}

private func testReadableTranscriptPreservesRepeatedBoundaryWords() {
    var live = ReadableTranscriptStabilizer()
    let repeated = [
        observed("no", start: 100, end: 200),
        observed("no", start: 230, end: 320),
    ]
    _ = live.observe(repeated, audioEndSequence: 500, sampleRate: 1_000)
    let boundary = live.observe(repeated, audioEndSequence: 600, sampleRate: 1_000)
    check(boundary.committedWords.map(\.text), equals: ["no"], "first repeated word commits")
    check(boundary.provisionalWords.map(\.text), equals: ["no"], "second repeated word remains visible")
    let both = live.observe(repeated, audioEndSequence: 680, sampleRate: 1_000)
    check(both.committedWords.map(\.text), equals: ["no", "no"], "adjacent repeated words both commit")

    var final = ReadableTranscriptStabilizer()
    _ = final.observe(repeated, audioEndSequence: 500, sampleRate: 1_000)
    _ = final.observe(repeated, audioEndSequence: 600, sampleRate: 1_000)
    let resolved = final.finalize(repeated, audioEndSequence: 600, sampleRate: 1_000)
    check(resolved.committedWords.map(\.text), equals: ["no", "no"], "final decode keeps a repeated suffix word")

    var newlyRepeated = ReadableTranscriptStabilizer()
    let firstNo = [observed("no", start: 100, end: 200)]
    _ = newlyRepeated.observe(firstNo, audioEndSequence: 500, sampleRate: 1_000)
    _ = newlyRepeated.observe(firstNo, audioEndSequence: 600, sampleRate: 1_000)
    let newNo = newlyRepeated.observe(
        [observed("no", start: 230, end: 320)],
        audioEndSequence: 600,
        sampleRate: 1_000
    )
    check(
        newNo.words.map(\.text),
        equals: ["no", "no"],
        "a new adjacent repetition appears without needing an earlier provisional copy"
    )

    var overlappingNewRepeat = ReadableTranscriptStabilizer()
    _ = overlappingNewRepeat.observe(firstNo, audioEndSequence: 500, sampleRate: 1_000)
    _ = overlappingNewRepeat.observe(firstNo, audioEndSequence: 600, sampleRate: 1_000)
    let overlappingNo = overlappingNewRepeat.observe(
        [observed("no", start: 180, end: 260)],
        audioEndSequence: 600,
        sampleRate: 1_000
    )
    check(
        overlappingNo.words.map(\.text),
        equals: ["no", "no"],
        "a slightly overlapping new repetition is not consumed as boundary context"
    )

    var missingBoundary = ReadableTranscriptStabilizer()
    _ = missingBoundary.observe(repeated, audioEndSequence: 500, sampleRate: 1_000)
    _ = missingBoundary.observe(repeated, audioEndSequence: 600, sampleRate: 1_000)
    let suffixOnly = missingBoundary.observe(
        [observed("no", start: 180, end: 260)],
        audioEndSequence: 650,
        sampleRate: 1_000
    )
    check(
        suffixOnly.words.map(\.text),
        equals: ["no", "no"],
        "an overlapping repeated suffix survives when the committed copy is absent"
    )


    var disappearingSuffix = ReadableTranscriptStabilizer()
    _ = disappearingSuffix.observe(repeated, audioEndSequence: 500, sampleRate: 1_000)
    _ = disappearingSuffix.observe(repeated, audioEndSequence: 600, sampleRate: 1_000)
    let committedCopyOnly = disappearingSuffix.observe(
        [observed("no", start: 130, end: 210)],
        audioEndSequence: 650,
        sampleRate: 1_000
    )
    check(
        committedCopyOnly.words.map(\.text),
        equals: ["no"],
        "a disappearing repeated suffix cannot turn a drifted committed copy into a duplicate"
    )
}

private func testEmptyFinalDropsOnlyStaleProvisionalText() {
    var stabilizer = ReadableTranscriptStabilizer()
    let observation = [
        observed("segur", start: 100, end: 200),
        observed("dubtós", start: 300, end: 520),
    ]
    _ = stabilizer.observe(observation, audioEndSequence: 500, sampleRate: 1_000)
    let live = stabilizer.observe(observation, audioEndSequence: 600, sampleRate: 1_000)
    check(live.committedWords.map(\.text), equals: ["segur"], "confirmed prefix exists before an empty final")
    check(live.provisionalWords.map(\.text), equals: ["dubtós"], "unresolved suffix exists before an empty final")

    let final = stabilizer.finalize([], audioEndSequence: 600, sampleRate: 1_000)
    check(final.committedWords.map(\.text), equals: ["segur"], "empty final preserves only committed history")
    check(final.provisionalWords.isEmpty, "empty final does not fossilize stale provisional text")
}

private func testReadableTranscriptBoundsLongSessionSnapshots() {
    var stabilizer = ReadableTranscriptStabilizer(retainedCommittedLimit: 160)
    var longObservation: [TranscriptObservationWord] = []
    for index in 0..<240 {
        let start = UInt64(index) * 100
        longObservation.append(
            observed("w\(index)", start: start, end: start + 80)
        )
    }
    _ = stabilizer.observe(
        longObservation,
        audioEndSequence: 100_000,
        sampleRate: 1_000
    )
    let snapshot = stabilizer.observe(
        longObservation,
        audioEndSequence: 100_100,
        sampleRate: 1_000
    )
    check(snapshot.committedWords.count, equals: 160, "long sessions keep bounded presentation work")
    check(snapshot.committedWords.first?.text, equals: "w80", "bounded snapshot drops only the oldest words")
    check(snapshot.committedWords.last?.text, equals: "w239", "bounded snapshot retains the live edge")
    let expectedAnchors: [UInt64] = (81...240).map { UInt64($0) }
    check(
        snapshot.committedWords.map { $0.anchor },
        equals: expectedAnchors,
        "bounded snapshots preserve global monotonic layout positions"
    )
}

private func testShaderMotionDynamics() {
    var idle = ShaderMotionDynamics()
    let idleStart = idle.phase
    for _ in 0..<24 {
        idle.advance(deltaTime: 1.0 / 24.0, voiceLevel: 0)
    }
    check(idle.phase > idleStart, "shader phase always advances in silence")

    var speaking = ShaderMotionDynamics()
    for _ in 0..<24 {
        speaking.advance(deltaTime: 1.0 / 24.0, voiceLevel: 1)
    }
    check(
        speaking.phase > idle.phase * 4,
        "normalised voice accelerates the same shader phase"
    )
    check(
        speaking.speedMultiplier <= ShaderMotionDynamics.maximumSpeedMultiplier,
        "voice acceleration is bounded"
    )

    var conversationalIdle = ShaderMotionDynamics()
    var conversationalVoice = ShaderMotionDynamics()
    conversationalIdle.advance(deltaTime: 1.0 / 30.0, voiceLevel: 0)
    conversationalVoice.advance(deltaTime: 1.0 / 30.0, voiceLevel: 0.12)
    check(
        conversationalVoice.speedMultiplier >= 8,
        "a quiet conversational microphone level strongly affects the very first frame"
    )
    for _ in 1..<12 {
        conversationalIdle.advance(deltaTime: 1.0 / 30.0, voiceLevel: 0)
        conversationalVoice.advance(deltaTime: 1.0 / 30.0, voiceLevel: 0.12)
    }
    check(
        conversationalVoice.speedMultiplier >= 9.5,
        "a quiet conversational microphone level produces emphatic sustained acceleration"
    )
    check(
        conversationalVoice.phase >= conversationalIdle.phase * 9,
        "a quiet conversational microphone level dominates accumulated shader evolution"
    )
    check(
        ShaderMotionDynamics.idleSpeed >= 0.16,
        "the decorative field has a slightly quicker baseline motion"
    )
    check(
        ShaderMotionDynamics.attackSeconds <= 0.020,
        "the visible microphone response begins within about one rendered frame"
    )

    var envelope = ShaderMotionDynamics()
    envelope.advance(deltaTime: ShaderMotionDynamics.attackSeconds, voiceLevel: 1)
    let attacked = envelope.voiceResponse
    check(attacked > 0.6 && attacked < 0.7, "voice envelope reaches one time constant after its 20 ms attack")
    for _ in 0..<6 {
        envelope.advance(deltaTime: 0.040, voiceLevel: 0)
    }
    let expectedAfterRelease = attacked * exp(-1)
    check(
        abs(envelope.voiceResponse - expectedAfterRelease) < 0.001,
        "voice envelope releases by one time constant over 240 ms"
    )

    var gated = ShaderMotionDynamics()
    for _ in 0..<24 {
        gated.advance(
            deltaTime: 1.0 / 24.0,
            voiceLevel: Float(ShaderMotionDynamics.noiseGate * 0.5)
        )
    }
    check(gated.speedMultiplier == 1, "microphone noise below the gate does not accelerate motion")

    var protected = ShaderMotionDynamics()
    let beforeGap = protected.phase
    protected.advance(deltaTime: 10, voiceLevel: 1)
    let maximumAllowedAdvance = ShaderMotionDynamics.idleSpeed
        * ShaderMotionDynamics.maximumSpeedMultiplier
        * ShaderMotionDynamics.maximumDeltaTime
    check(
        protected.phase - beforeGap <= maximumAllowedAdvance + 0.000_001,
        "a long scheduling gap cannot jump the pattern"
    )
    let beforeInvalid = protected.phase
    protected.advance(deltaTime: .nan, voiceLevel: .nan)
    check(protected.phase == beforeInvalid, "invalid timing cannot corrupt shader phase")
}

private func testAudioLevelPeakAccumulator() {
    var levels = AudioLevelPeakAccumulator()
    levels.observe(0.08)
    levels.observe(0.82)
    levels.observe(0.02)

    check(
        abs(levels.consume() - 0.82) < 0.000_001,
        "a short microphone peak survives until the next rendered frame"
    )
    check(
        abs(levels.consume() - 0.02) < 0.000_001,
        "a consumed peak falls back to the latest microphone level"
    )

    levels.observe(0.91)
    levels.observe(0.01)
    levels.discardPendingPeak()
    check(
        abs(levels.consume() - 0.01) < 0.000_001,
        "resuming a paused renderer discards stale peaks but retains the current level"
    )

    levels.observe(.nan)
    levels.observe(-1)
    check(levels.consume() == 0, "invalid microphone levels cannot escape the accumulator")
}

testTranscriptLedger()
testLatestAudioScheduler()
testWindowPolicy()
testLatencyDistribution()
testWordErrorRate()
testStableTranscriptWords()
testRollUpLayoutForwardBreaking()
testRollUpLayoutSurvivesWindowSlide()
testLiveTailLengthNeverMovesSettledRows()
testProvisionalTailNeverChangesScrollAnchor()
testRetroactiveCorrectionRebuilds()
testNewSessionAnchorsRebuild()
testRollUpLayoutRelaysOutOnMetricsChange()
testRollUpLayoutOversizedWord()
testVisibleLineCount()
testForwardRollRetainsRowsForTheAnimationStart()
testAppendDetectionIgnoresPromotionState()
testCommitHorizon()
testCommittedWordIdentity()
testLedgerTailWords()
testLiveStreamKeepsSettledTextStill()
testMidHypothesisRevisionKeepsLinesIntact()
testReadingFontIsInterMedium()
testFinalAccentFitsInsideSwiftUITextLayout()
testAppVisualMetrics()
testTranscriptionProfilesExposeFrozenPolicies()
testReliableProfileSuppressesABAChurn()
testReplacementKeepsItsVisualIdentityWhenCommitted()
testDiacriticsRequireExactConfirmation()
testBalancedRequiresTwoConsecutiveReplacementObservations()
testFinalCorrectionAtomicallyReplacesCoveredCommittedText()
testFinalCorrectionPreservesStableTextWithoutRealTiming()
testPartialWordOffsetsAreTimingDegradation()
testLegacyReconcilerDoesNotReuseCommittedIdentityAcrossAccentChange()
testFinalCorrectionGuardPreservesAWordCrossingTheLeftBoundary()
testReadableTranscriptNeverRewritesCommittedPrefix()
testReadableTranscriptReplayHandlesChurnAndEmptyFrames()
testReadableTranscriptFinalOnlyResolvesSuffix()
testCommittedBoundarySurvivesForwardTimestampDrift()
testReadableTranscriptPreservesRepeatedBoundaryWords()
testEmptyFinalDropsOnlyStaleProvisionalText()
testReadableTranscriptBoundsLongSessionSnapshots()
testShaderMotionDynamics()
testAudioLevelPeakAccumulator()

if testState.failures == 0 {
    print("PASS SubtitolLiveTests")
} else {
    print("FAILED SubtitolLiveTests: \(testState.failures) failure(s)")
    exit(1)
}
