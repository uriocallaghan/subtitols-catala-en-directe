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

func check<T: Equatable>(_ actual: T, equals expected: T, _ name: String) {
    guard actual != expected else { return }
    testState.failures += 1
    print("FAIL \(name): expected \(expected), got \(actual)")
}

func check(_ condition: Bool, _ name: String) {
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
    check(LiveWindowPolicy.liveWindowSeconds, equals: 7.0, "the Conformer hears 7 s per hypothesis")
    check(
        LiveWindowPolicy.finalWindowSeconds >= LiveWindowPolicy.liveWindowSeconds,
        "the final correction never hears less than the live hypotheses it replaces"
    )
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

private func testAgeGradientFadesWholeLines() {
    func opacity(_ row: Int) -> Double {
        AppVisualMetrics.ageGradientOpacity(rowFromBottom: row, visibleRows: 8, reserve: 2)
    }
    check(opacity(0), equals: 1, "live lane at full contrast")
    check(opacity(2), equals: 1, "anchor line at full contrast")
    check(opacity(3), equals: 1, "line above the anchor at full contrast")
    check(opacity(4) < 1, "older lines fade")
    check(opacity(5) < opacity(4), "fade grows with height")
    check(opacity(4) - opacity(5) < 0.3, "each roll dims a line only a little")
    check(opacity(7) >= 0.15, "the top line stays readable")
    check(opacity(8), equals: 0, "a line is invisible once it leaves the pane")
    check(opacity(9), equals: 0, "and stays invisible until it is dropped")
    check(
        AppVisualMetrics.ageGradientOpacity(rowFromBottom: 3, visibleRows: 4, reserve: 2),
        equals: 1,
        "a pane with no room to fade keeps full contrast"
    )
    check(
        AppVisualMetrics.ageGradientOpacity(rowFromBottom: 4, visibleRows: 4, reserve: 2),
        equals: 0,
        "even a short pane never drops a line with ink left"
    )
}

private func testPhoneAgeGradientEasesTowardTheOrb() {
    func opacity(_ row: Int) -> Double {
        AppVisualMetrics.ageGradientOpacity(
            rowFromBottom: row, visibleRows: 10, reserve: 2, curve: .eased
        )
    }
    func linear(_ row: Int) -> Double {
        AppVisualMetrics.ageGradientOpacity(rowFromBottom: row, visibleRows: 10, reserve: 2)
    }
    check(opacity(3), equals: 1, "the rows being read keep full contrast on the phone too")
    check(opacity(4) > linear(4), "the first faded row stays brighter than the Mac's equal steps")
    check(opacity(9) < linear(9), "the rows next to the orb fall further than equal steps")
    for row in 3..<11 {
        check(opacity(row + 1) <= opacity(row), "the phone fade never brightens with height")
    }
    check(opacity(10), equals: 0, "a line is invisible once it leaves the phone pane")
}

private func testOrbAnswersTheVoice() {
    var orb = OrbMotionDynamics(theta: 0.2)
    var rest = orb.advance(deltaTime: 1.0 / 60, voiceLevel: 0, listening: true)
    for _ in 0..<120 { rest = orb.advance(deltaTime: 1.0 / 60, voiceLevel: 0, listening: true) }
    let restTheta = rest.theta
    // The liquid never stops, even in silence.
    var still = orb
    check(still.advance(deltaTime: 0.5, voiceLevel: 0, listening: true).flow != rest.flow, "the inside keeps moving at rest")
    var speaking = rest
    for _ in 0..<60 { speaking = orb.advance(deltaTime: 1.0 / 60, voiceLevel: 0.2, listening: true) }
    check(speaking.size == rest.size && speaking.deform == 0 && rest.deform == 0, "the outline stays a still circle")
    check(speaking.churn > rest.churn + 0.4, "the liquid inside churns deeper with the voice")
    check(speaking.turbulence > rest.turbulence, "the silk churns with the voice")
    check(speaking.theta - restTheta > 0.01, "the silk turns much faster while speaking")
    var settled = speaking
    for _ in 0..<(60 * 6) { settled = orb.advance(deltaTime: 1.0 / 60, voiceLevel: 0, listening: true) }
    check(settled.churn < rest.churn + 0.1, "a few seconds of silence settle the orb again")
    check(settled.level < 0.01, "the pulse falls quickly in silence")

    var idle = OrbMotionDynamics()
    var ignored = idle.advance(deltaTime: 1.0 / 60, voiceLevel: 0, listening: false)
    for _ in 0..<60 { ignored = idle.advance(deltaTime: 1.0 / 60, voiceLevel: 0.5, listening: false) }
    check(ignored.level, equals: 0, "the orb ignores the microphone when nothing is being recorded")

    var gap = OrbMotionDynamics(theta: 0.99)
    let wrapped = gap.advance(deltaTime: 10, voiceLevel: 1, listening: true)
    check(wrapped.theta >= 0 && wrapped.theta < 1, "the cycle angle wraps into one turn")
}

private func testLanguageCatalogReadsTheManifest() {
    let manifest = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/SubtitolLive/Resources/ModelManifest.json")
    guard let data = try? Data(contentsOf: manifest),
          let catalog = try? JSONDecoder().decode(LanguageCatalog.self, from: data),
          let models = try? JSONDecoder().decode(SpeechModelCatalog.self, from: data) else {
        check(false, "the manifest decodes as a language catalogue")
        return
    }
    check(!catalog.languages.isEmpty, "the manifest lists at least one language")
    for language in catalog.languages where language.isPackStaged {
        check(models.model(id: language.model) != nil, "\(language.id) names a model the manifest carries")
        check(!language.assetPack.isEmpty, "\(language.id) names its download")
    }
    check(catalog.language(id: "ca")?.stage, equals: .stable, "Catalan is stable")
}

private func testLanguageSuggestionFollowsThePhone() {
    let catalog = LanguageCatalog(languages: [
        SpeechLanguage(id: "ca", name: "Català", stage: .stable, locales: ["ca"], assetPack: "lang-ca",
                       model: "conformer", punctuation: "catala-puntuacio", approximateDownloadBytes: 1),
        SpeechLanguage(id: "gl", name: "Galego", stage: .beta, locales: ["gl"], assetPack: "lang-gl",
                       model: "los", punctuation: nil, approximateDownloadBytes: 1),
    ])
    check(catalog.suggestion(forPreferredLanguages: ["gl-ES", "ca-ES"])?.id, equals: "gl", "the phone's first language wins")
    check(catalog.suggestion(forPreferredLanguages: ["ca_ES"])?.id, equals: "ca", "underscored identifiers match too")
    check(catalog.suggestion(forPreferredLanguages: ["ja-JP"])?.id, equals: "ca", "without English, the first stable language")
    let withEnglish = LanguageCatalog(languages: catalog.languages + [
        SpeechLanguage(id: "en", name: "English", stage: .stable, locales: ["en"], assetPack: "lang-en",
                       model: "fastconformer-en", punctuation: nil, approximateDownloadBytes: 1),
    ])
    check(withEnglish.suggestion(forPreferredLanguages: ["fr-FR", "de-DE"])?.id, equals: "en", "a device language the app lacks falls back to English")
    check(withEnglish.suggestion(forPreferredLanguages: ["fr-FR", "ca-ES"])?.id, equals: "ca", "a later device language the app has still wins")
    check(LanguageCatalog(languages: []).suggestion(forPreferredLanguages: ["ca"]) == nil, "an empty catalogue suggests nothing")
    let decoded = try? JSONDecoder().decode(SpeechLanguage.self, from: Data(#"{"id":"ca","name":"Català","stage":"stable","locales":["ca"],"assetPack":"lang-ca","model":"conformer","approximateDownloadBytes":1}"#.utf8))
    check(decoded?.isPackStaged, equals: true, "a language whose manifest entry says nothing is staged")
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

private func testSilenceTracker() {
    // 1 s of voice, 0.6 s of silence, 1 s of voice, 0.1 s of silence, 0.5 s of voice, then silence.
    let rate: Int32 = 16_000
    func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { Float(sin(Double($0) * 0.2)) * 0.2 }
    }
    func quiet(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { Float(($0 * 7919) % 13) * 0.00001 }
    }
    let audio = quiet(1) + tone(1) + quiet(0.6) + tone(1) + quiet(0.1) + tone(0.5) + quiet(0.9)
    var tracker = SilenceTracker()
    // Overlapping windows, as the app feeds them: already analysed audio is skipped.
    var end = 0
    while end < audio.count {
        end = min(audio.count, end + 4_800)
        let start = max(0, end - 64_000)
        tracker.append(audio[start..<end], endSequence: UInt64(end), sampleRate: rate)
    }
    let map = tracker.map
    func seconds(_ value: Double) -> UInt64 { UInt64(value * Double(rate)) }
    let first = (start: seconds(1.2), end: seconds(1.9))
    let second = (start: seconds(2.7), end: seconds(3.5))
    let third = (start: seconds(3.8), end: seconds(4.1))
    check(abs(map.pause(between: first, and: second) - 0.6) < 0.03, "a 0.6 s pause is measured between two words")
    check(abs(map.pause(between: second, and: third) - 0.1) < 0.03, "a short pause is measured too")
    check(abs(map.trailingSilence(after: third) - 0.9) < 0.03, "the silence at the end is still running")
    check(map.trailingSilence(after: (start: seconds(4.3), end: seconds(4.5))) == 0, "a word heard inside the silence ends it")

    // Audio lost in between: no pause is measured across the hole.
    var gapped = SilenceTracker()
    gapped.append(quiet(1)[...] , endSequence: seconds(1), sampleRate: rate)
    gapped.append(tone(1)[...], endSequence: seconds(3), sampleRate: rate)
    check(gapped.map.pauses.allSatisfy { $0.upperBound <= seconds(1) || $0.lowerBound >= seconds(2) }, "a gap in the audio is not a pause")
}

private func testFormatterParagraphsAndPauses() {
    // "…vam anar a la rambla | hi havia molta gent" with 48 kHz timings and a silence map.
    let rate: Int32 = 48_000
    let spoken = "vam anar a la rambla hi havia molta gent i vam riure".split(separator: " ").map(String.init)
    func at(_ index: Int) -> (UInt64, UInt64) {
        // 0.3 s per word; a 0.7 s pause after "rambla" (index 4).
        let start = Double(index) * 0.3 + (index > 4 ? 0.7 : 0)
        return (UInt64(start * Double(rate)), UInt64((start + 0.25) * Double(rate)))
    }
    let pauseStart = UInt64(1.45 * Double(rate))
    let pauseEnd = UInt64(2.2 * Double(rate))
    func words(_ heard: Int, committed: Int) -> [StableTranscriptWord] {
        spoken.prefix(heard).enumerated().map { index, text in
            StableTranscriptWord(id: UInt64(index + 1), text: text, isCommitted: index < committed,
                                 anchor: UInt64(index + 1), startSequence: at(index).0, endSequence: at(index).1)
        }
    }
    func snapshot(_ heard: Int, committed: Int) -> ReadableTranscriptSnapshot {
        let all = words(heard, committed: committed)
        return ReadableTranscriptSnapshot(committedWords: Array(all.prefix(committed)), provisionalWords: Array(all.dropFirst(committed)),
                                          audioEndSequence: at(heard - 1).1, sampleRate: rate, lastHeardEndSequence: at(heard - 1).1)
    }
    // The model is unsure about "rambla" (40 % sentence end); the pause decides.
    final class Unsure: PunctuationPredicting {
        func predictions(for words: [String]) -> [PunctuationPrediction]? {
            words.map { word in
                word == "rambla"
                    ? PunctuationPrediction(best: PunctuationLabel(mark: .none, casing: .capitalized),
                                            markProbabilities: [.none: 0.6, .period: 0.4])
                    : PunctuationPrediction(certain: word == "riure" ? PunctuationLabel(mark: .period, casing: .lower) : .plain)
            }
        }
    }
    let predictor = Unsure()
    let silences = SilenceMap(sampleRate: rate, pauses: [pauseStart..<pauseEnd], analysedThrough: at(10).1)
    var formatter = TranscriptFormatter()
    let live = formatter.format(snapshot(10, committed: 9), silences: silences, predictor: predictor)
    check(live.text.hasPrefix("Vam anar a la Rambla. Hi havia"), "a pause turns an unsure boundary into a full stop")
    check(live.words.first { $0.text == "Hi" }?.startsParagraph == true, "the sentence after a pause opens a paragraph")
    check(live.words.filter(\.startsParagraph).count, equals: 1, "only that word opens a paragraph")

    var noVoice = TranscriptFormatter()
    let textOnly = noVoice.format(snapshot(10, committed: 9), predictor: predictor)
    check(textOnly.text.hasPrefix("Vam anar a la Rambla hi havia"), "without the audio the model alone decides")
    check(!textOnly.words.contains { $0.startsParagraph }, "without the audio there are no paragraphs")

    // Only formatted words are committed: the reading pane places each word once.
    for word in live.committedWords { check(formatter.format(snapshot(10, committed: 9), silences: silences, predictor: predictor).committedWords.contains(word), "settled words stay identical") }
    let tail = live.provisionalWords.map(\.text)
    check(tail, equals: ["molta", "gent", "i"], "words still waiting for context stay in the live lane")

    // Before "rambla" is even committed, the words after the pause already sit on the new
    // line, capitalised, so they do not jump there a second later.
    var early = TranscriptFormatter()
    let waiting = early.format(snapshot(7, committed: 4), silences: silences, predictor: predictor)
    check(waiting.words.first { $0.text == "Hi" }?.startsParagraph == true, "words after a long pause are placed on their new line early")
    check(waiting.words.first { $0.text.lowercased() == "rambla" }?.isCommitted == false, "while the sentence end itself is still undecided")

    // The speaker stops: after half a second of silence the edge settles without more words.
    var edge = TranscriptFormatter()
    let quietEdge = SilenceMap(sampleRate: rate, pauses: [at(11).1..<(at(11).1 + UInt64(rate))], analysedThrough: at(11).1 + UInt64(rate))
    let stopped = ReadableTranscriptSnapshot(committedWords: words(12, committed: 12), audioEndSequence: at(11).1 + UInt64(rate),
                                             sampleRate: rate, lastHeardEndSequence: at(11).1)
    let settled = edge.format(stopped, silences: quietEdge, predictor: predictor)
    check(settled.text.hasSuffix("i vam riure."), "a pause at the edge settles the last words with their mark: \(settled.text)")
    check(settled.provisionalWords.isEmpty, "nothing is left waiting once the speaker has paused")
}

private func testSpeakerTurns() {
    // The tracker: one voice for 5 s, then another. Classes come from the model; here
    // they are written by hand, 589 frames per 10 s window.
    let rate: Int32 = 48_000
    func frames(changeAt seconds: Double, windowEnd: Double, second: Int = 2, reply: ClosedRange<Double>? = nil) -> [Int] {
        (0..<589).map { frame in
            let time = windowEnd - 10 + (Double(frame) * 270 + 495) / 16_000
            if let reply, reply.contains(time) { return 2 }
            return time < seconds ? 1 : second
        }
    }
    var tracker = SpeakerTurnTracker()
    tracker.append([Float](repeating: 0.01, count: Int(rate) * 10), endSequence: UInt64(rate) * 10, sampleRate: rate)
    guard let first = tracker.nextWindow() else { return check(false, "a window is ready after 10 s of audio") }
    check(first.samples.count, equals: SpeakerTurnTracker.windowSamples, "windows are 10 s at 16 kHz")
    tracker.ingest(frameClasses: frames(changeAt: 8, windowEnd: 10), of: first)
    check(tracker.map.changes.isEmpty, "one window alone does not confirm a change")
    check(tracker.nextWindow() == nil, "the next window waits for half a second of new audio")
    tracker.append([Float](repeating: 0.01, count: Int(rate) / 2), endSequence: UInt64(rate) * 21 / 2, sampleRate: rate)
    guard let second = tracker.nextWindow() else { return check(false, "a window follows half a second later") }
    tracker.ingest(frameClasses: frames(changeAt: 8, windowEnd: 10.5), of: second)
    check(tracker.map.changes.count, equals: 1, "a second window confirms the change")
    if let change = tracker.map.changes.first {
        check(abs(Double(change) / Double(rate) - 8) < 0.05, "the change sits where the new voice starts: \(Double(change) / Double(rate))")
    }

    // A short reply inside one voice's turn is not a turn.
    var replies = SpeakerTurnTracker()
    replies.append([Float](repeating: 0.01, count: Int(rate) * 10), endSequence: UInt64(rate) * 10, sampleRate: rate)
    for end in [10.0, 10.5, 11.0] {
        if end > 10 {
            replies.append([Float](repeating: 0.01, count: Int(rate) / 2), endSequence: UInt64(end * Double(rate)), sampleRate: rate)
        }
        guard let window = replies.nextWindow() else { continue }
        replies.ingest(frameClasses: frames(changeAt: 99, windowEnd: end, reply: 5.0...5.3), of: window)
    }
    check(replies.map.changes.isEmpty, "a 0.3 s reply does not open a paragraph")

    // Placing a change: the word it falls in, or the next one.
    let map = SpeakerChangeMap(sampleRate: rate, changes: [UInt64(2.05 * Double(rate))], decidedThrough: UInt64(rate) * 5)
    let spans: [(start: UInt64, end: UInt64)?] = [0.0, 0.5, 1.0, 1.5, 2.1, 2.6].map { start in
        (UInt64(start * Double(rate)), UInt64((start + 0.4) * Double(rate)))
    }
    check(map.turnStarts(in: spans), equals: [4], "a change just before a word opens that word")
    let inside = SpeakerChangeMap(sampleRate: rate, changes: [UInt64(2.2 * Double(rate))], decidedThrough: UInt64(rate) * 5)
    check(inside.turnStarts(in: spans), equals: [4], "a change inside a word's first sound opens that word")
    let short: [(start: UInt64, end: UInt64)?] = [(0, UInt64(0.5 * Double(rate))), (UInt64(1.0 * Double(rate)), UInt64(1.04 * Double(rate))),
                                                  (UInt64(1.1 * Double(rate)), UInt64(1.4 * Double(rate)))]
    let onShortWord = SpeakerChangeMap(sampleRate: rate, changes: [UInt64(1.02 * Double(rate))], decidedThrough: UInt64(rate) * 5)
    check(onShortWord.turnStarts(in: short), equals: [1], "a change on a 40 ms word like \"i\" opens that word")
    // Replayed podcast, 177.94 s: "no" is stamped 177.89-177.93 and the change lands
    // just after it; the paragraph must open at "No", not at "sempre".
    let justAfter = SpeakerChangeMap(sampleRate: rate, changes: [UInt64(1.05 * Double(rate))], decidedThrough: UInt64(rate) * 5)
    check(justAfter.turnStarts(in: short), equals: [1], "a change just past a 40 ms word's end opens that word")
    let lateInWord = SpeakerChangeMap(sampleRate: rate, changes: [UInt64(0.87 * Double(rate))], decidedThrough: UInt64(rate) * 5)
    check(lateInWord.turnStarts(in: spans), equals: [2], "a change in a long word's last 50 ms opens the next word")
    let far = SpeakerChangeMap(sampleRate: rate, changes: [UInt64(9 * Double(rate))], decidedThrough: UInt64(rate) * 10)
    check(far.turnStarts(in: spans).isEmpty, "a change far from every word is not placed")

    // The formatter: a new voice without any pause still starts a paragraph, and the
    // last word of the turn waits until the detector has settled the audio after it.
    let spoken = "ja hi som tots aquí doncs comencem el programa d'avui".split(separator: " ").map(String.init)
    func at(_ index: Int) -> (UInt64, UInt64) {
        let start = Double(index) * 0.3
        return (UInt64(start * Double(rate)), UInt64((start + 0.25) * Double(rate)))
    }
    func snapshot(_ heard: Int) -> ReadableTranscriptSnapshot {
        let all = spoken.prefix(heard).enumerated().map { index, text in
            StableTranscriptWord(id: UInt64(index + 1), text: text, isCommitted: true,
                                 anchor: UInt64(index + 1), startSequence: at(index).0, endSequence: at(index).1)
        }
        return ReadableTranscriptSnapshot(committedWords: all, audioEndSequence: at(heard - 1).1,
                                          sampleRate: rate, lastHeardEndSequence: at(heard - 1).1)
    }
    let predictor = TablePunctuationPredictor([:])
    let turn = UInt64(1.475 * Double(rate)) // between "aquí" (index 4) and "doncs"
    let pending = SpeakerChangeMap(sampleRate: rate, changes: [], decidedThrough: at(3).1)
    var waiting = TranscriptFormatter()
    let early = waiting.format(snapshot(10), speakers: pending, predictor: predictor)
    check(early.words.first { $0.text.lowercased() == "aquí" }?.isCommitted == false, "the end of a turn waits for the detector")
    let known = SpeakerChangeMap(sampleRate: rate, changes: [turn], decidedThrough: at(9).1)
    let later = waiting.format(snapshot(10), speakers: known, predictor: predictor)
    check(later.words.first { $0.text.lowercased() == "doncs" }?.startsParagraph == true, "a new voice opens a paragraph")
    check(later.words.contains { $0.text == "Doncs" }, "a paragraph starts with a capital even without a full stop: \(later.text)")
    check(early.words.contains { $0.text == "aquí" }, "the word before the turn keeps its case")
    check(later.words.filter(\.startsParagraph).count, equals: 1, "only the new voice opens one")
    var plain = TranscriptFormatter()
    check(!plain.format(snapshot(10), predictor: predictor).words.contains { $0.startsParagraph },
          "without the detector the text runs on as before")
    var stalled = TranscriptFormatter()
    let behind = SpeakerChangeMap(sampleRate: rate, changes: [], decidedThrough: 0)
    let slow = ReadableTranscriptSnapshot(committedWords: snapshot(10).committedWords, audioEndSequence: UInt64(rate) * 10,
                                          sampleRate: rate, lastHeardEndSequence: at(9).1)
    check(stalled.format(slow, speakers: behind, predictor: predictor).committedWords.count > 0,
          "a detector far behind the audio holds nothing back")
}

private func testNumbersSettleOnlyWhenComplete() {
    // Word by word, as the stabiliser commits them: a settled word never changes text,
    // and a word a number absorbed never appears later.
    func stream(_ sentence: String, labels: [String: String]) -> (text: String, stable: Bool) {
        let spoken = sentence.split(separator: " ").map(String.init)
        let predictor = TablePunctuationPredictor(labels)
        var formatter = TranscriptFormatter()
        var settled: [UInt64: String] = [:]
        var stable = true
        var last = ""
        for heard in 1...spoken.count {
            let words = spoken.prefix(heard).enumerated().map { index, text in
                StableTranscriptWord(id: UInt64(index + 1), text: text, isCommitted: index < heard - 1, anchor: UInt64(index + 1))
            }
            let snapshot = ReadableTranscriptSnapshot(committedWords: words.filter(\.isCommitted),
                                                      provisionalWords: words.filter { !$0.isCommitted })
            let formatted = formatter.format(snapshot, isFinal: heard == spoken.count, predictor: predictor)
            for word in formatted.committedWords {
                if let previous = settled[word.id], previous != word.text { stable = false }
                settled[word.id] = word.text
            }
            let shown = Set(formatted.words.map(\.id))
            if settled.keys.contains(where: { !shown.contains($0) && $0 > (formatted.words.first?.id ?? 0) }) { stable = false }
            last = formatted.text
        }
        return (last, stable)
    }
    let percent = stream("només un quinze per cent dels alumnes hi van participar el mes de maig",
                         labels: ["maig": ".l"])
    check(percent.text, equals: "Només un 15 % dels alumnes hi van participar el mes de maig.", "a percentage settles as digits")
    check(percent.stable, "a percentage never rewrites text already settled")
    let year = stream("uns cent més o menys l'any dinou noranta dos barcelona va organitzar els jocs olímpics",
                      labels: ["barcelona": "u", "olímpics": ".l"])
    check(year.text, equals: "Uns 100 més o menys l'any 1992 Barcelona va organitzar els jocs olímpics.", "a year read in halves settles as digits")
    check(year.stable, "a year never rewrites text already settled")
}

private func testFormatterBreaksLinesAtLongPauses() {
    // "vam anar a la | rambla i vam riure": the speaker stops for 1.2 s inside the sentence.
    let rate: Int32 = 16_000
    let spoken = "vam anar a la rambla i vam riure molt".split(separator: " ").map(String.init)
    func at(_ index: Int, pause: Double) -> (UInt64, UInt64) {
        let start = Double(index) * 0.3 + (index > 3 ? pause : 0)
        return (UInt64(start * Double(rate)), UInt64((start + 0.25) * Double(rate)))
    }
    func formatted(pause: Double) -> ReadableTranscriptSnapshot {
        let words = spoken.enumerated().map { index, text in
            StableTranscriptWord(id: UInt64(index + 1), text: text, isCommitted: true, anchor: UInt64(index + 1),
                                 startSequence: at(index, pause: pause).0, endSequence: at(index, pause: pause).1)
        }
        let silence = at(3, pause: pause).1..<at(4, pause: pause).0
        let silences = SilenceMap(sampleRate: rate, pauses: [silence], analysedThrough: at(8, pause: pause).1)
        var formatter = TranscriptFormatter()
        return formatter.format(ReadableTranscriptSnapshot(committedWords: words, audioEndSequence: at(8, pause: pause).1,
                                                           sampleRate: rate, lastHeardEndSequence: at(8, pause: pause).1),
                                silences: silences, predictor: TablePunctuationPredictor([:]))
    }
    let long = formatted(pause: 1.2)
    check(long.words.first { $0.text == "rambla" }?.startsLine == true, "a long pause starts a new line inside a sentence")
    check(!long.words.contains { $0.startsParagraph }, "a pause inside a sentence is not a paragraph")
    check(long.words.filter(\.startsLine).count, equals: 1, "only the word after the pause moves")
    check(long.text.hasPrefix("Vam anar a la rambla"), "a pause alone does not end the sentence or capitalise: \(long.text)")
    let hesitation = formatted(pause: 0.6)
    check(!hesitation.words.contains { $0.startsParagraph || $0.startsLine }, "a short hesitation inside a sentence keeps the line")
}

private func testFilePauseRuleWeighsThePauseMore() {
    func prediction(none: Float, comma: Float, period: Float) -> PunctuationPrediction {
        let best: PunctuationLabel.Mark = none >= max(comma, period) ? .none : (comma >= period ? .comma : .period)
        return PunctuationPrediction(best: PunctuationLabel(mark: best, casing: .lower),
                                     markProbabilities: [.none: none, .comma: comma, .period: period])
    }
    // The model gives a sentence end 20 %; after 0.7 s of silence live listening keeps
    // the sentence going, a whole file ends it.
    let unsure = prediction(none: 0.7, comma: 0.1, period: 0.2)
    check(PauseEvidence.decide(unsure, pauseAfter: 0.7).mark, equals: .none, "live, a 0.7 s pause does not outweigh an 80 % no-end")
    check(PauseEvidence.decide(unsure, pauseAfter: 0.7, rule: .file).mark, equals: .period, "in a file, the same pause ends the sentence")
    check(PauseEvidence.decide(unsure, pauseAfter: 0.0, rule: .file).mark, equals: .none, "without a pause the model's no-end stands")
    // A comma the model half-believes: a pause tips it in a file, never live.
    let halfComma = prediction(none: 0.55, comma: 0.44, period: 0.01)
    check(PauseEvidence.decide(halfComma, pauseAfter: 0.3).mark, equals: .none, "live keeps the model's own choice between comma and none")
    check(PauseEvidence.decide(halfComma, pauseAfter: 0.3, rule: .file).mark, equals: .comma, "in a file a short pause tips a likely comma")
    check(PauseEvidence.decide(prediction(none: 0.9, comma: 0.09, period: 0.01), pauseAfter: 0.3, rule: .file).mark, equals: .none,
          "an unlikely comma stays out")
    // Certain marks (a recogniser that writes its own) are never overturned.
    let certain = PunctuationPrediction(certain: PunctuationLabel(mark: .none, casing: .lower))
    check(PauseEvidence.decide(certain, pauseAfter: 3, rule: .file).mark, equals: .none, "a certain no-mark survives a long pause")
    check(FileTranscriber.Configuration().pauseRule, equals: PauseEvidence.Rule.file, "the file transcriber uses the file rule")
}

private func testSilentWordFilter() {
    // 7 s of room noise at -50 dBFS, with a soft vowel (15 dB above the room) at 2.0-2.3 s.
    let rate: Int32 = 16_000
    var state: UInt64 = 0x5EED
    func noise() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return (Float((state >> 40) & 0xFFFFFF) / Float(0xFFFFFF) * 2 - 1) * 0.0055
    }
    var samples = (0..<(7 * Int(rate))).map { _ in noise() }
    for index in (2 * Int(rate))..<(Int(2.3 * Double(rate))) {
        samples[index] += 0.025 * Float(sin(2 * Double.pi * 220 * Double(index) / Double(rate)))
    }
    func word(_ text: String, _ start: Int32, _ end: Int32) -> RecognizedWord {
        RecognizedWord(text: text, startMilliseconds: start, endMilliseconds: end, confidence: nil)
    }
    let heard = SilentWordFilter.voicedWords(
        [word("la", 1_860, 1_900), word("hola", 2_000, 2_300), word("més", 5_000, 5_250), word("i", 2_320, 2_380)],
        samples: samples, sampleRate: rate
    )
    check(heard.map(\.text), equals: ["la", "hola", "i"], "a soft voice keeps its words; words in the room noise are dropped")

    let zeros = [Float](repeating: 0, count: 7 * Int(rate))
    check(SilentWordFilter.voicedWords([word("muy", 3_000, 3_200)], samples: zeros, sampleRate: rate).isEmpty,
          "digital silence has no words")

    // Leading padding is not audio: it must not set the floor.
    var padded = [Float](repeating: 0, count: 5 * Int(rate))
    padded += (0..<(2 * Int(rate))).map { _ in noise() }
    check(SilentWordFilter.voicedWords([word("más", 6_000, 6_200)], samples: padded, sampleRate: rate,
                                       leadingPaddingSamples: 5 * Int(rate)).isEmpty,
          "padding zeros do not make room noise look like speech")
}

private func testSilentWordFilterInSteadyNoise() {
    // A steady hum with most of its power low (white noise through a leaky integrator):
    // its 10 ms frames swing 8 dB over their own floor. A vowel as loud as the hum (0 dB
    // SNR, harmonics of 180 Hz up to 2.7 kHz) rises under 9 dB over it at 2.0-2.25 s.
    let rate: Int32 = 16_000
    var state: UInt64 = 0x5EED
    var integrated: Float = 0
    var hum = (0..<(7 * Int(rate))).map { _ -> Float in
        state = state &* 6_364_136_223_846_793_005 &+ 1
        integrated = 0.95 * integrated + (Float((state >> 40) & 0xFFFFFF) / Float(0xFFFFFF) * 2 - 1)
        return integrated
    }
    let humRMS = sqrtf(hum.reduce(0) { $0 + $1 * $1 } / Float(hum.count))
    hum = hum.map { $0 / humRMS * 0.03 }
    let vowel = (0..<Int(0.25 * Double(rate))).map { index in
        (1...15).reduce(Float(0)) { $0 + Float(sin(2 * Double.pi * 180 * Double($1 * index) / Double(rate))) }
    }
    let vowelRMS = sqrtf(vowel.reduce(0) { $0 + $1 * $1 } / Float(vowel.count))
    var samples = hum
    for (offset, value) in vowel.enumerated() {
        samples[2 * Int(rate) + offset] += value / vowelRMS * 0.03
    }
    func word(_ text: String, _ start: Int32, _ end: Int32) -> RecognizedWord {
        RecognizedWord(text: text, startMilliseconds: start, endMilliseconds: end, confidence: nil)
    }
    let heard = SilentWordFilter.voicedWords(
        [word("hola", 2_000, 2_250), word("muy", 3_500, 3_700), word("més", 5_000, 5_250)],
        samples: samples, sampleRate: rate
    )
    check(heard.map(\.text), equals: ["hola"], "a voice in steady noise keeps its word; words in the noise are dropped")
    check(SilentWordFilter.voicedWords([word("más", 1_000, 1_200), word("más", 4_000, 4_200), word("muy", 6_000, 6_300)],
                                       samples: hum, sampleRate: rate).isEmpty,
          "steady noise alone has no words")
}

private func testRollUpLayoutParagraphs() {
    var layout = RollUpTranscriptLayout()
    let texts = ["Bon", "dia.", "Com", "estàs?"]
    let words = texts.enumerated().map { index, text in
        StableTranscriptWord(id: UInt64(index + 1), text: text, isCommitted: true, anchor: UInt64(index + 1), startsParagraph: index == 2)
    }
    let placements = layout.update(words: words, widths: texts.map { CGFloat($0.count) },
                                   metrics: .init(maxWidth: 40, wordSpacing: 1, fontSize: 1))
    check(placements[1].line, equals: placements[0].line, "words of one paragraph share a line")
    check(placements[2].line, equals: placements[1].line + 2, "a new paragraph starts after a blank line")
    check(placements[2].x, equals: 0, "a new paragraph starts at the left edge")

    // A word that only wraps keeps the next line: the blank line is for paragraphs.
    var wrapping = RollUpTranscriptLayout()
    let long = ["una", "frase", "prou", "llarga"].enumerated().map { index, text in
        StableTranscriptWord(id: UInt64(index + 1), text: text, isCommitted: true, anchor: UInt64(index + 1))
    }
    let wrapped = wrapping.update(words: long, widths: [5, 5, 5, 5], metrics: .init(maxWidth: 12, wordSpacing: 1, fontSize: 1))
    check(wrapped[2].line, equals: wrapped[1].line + 1, "a wrapped line follows directly")

    // A pause inside a sentence starts a new line without a blank one.
    var paused = RollUpTranscriptLayout()
    let midSentence = texts.enumerated().map { index, text in
        StableTranscriptWord(id: UInt64(index + 1), text: text, isCommitted: true, anchor: UInt64(index + 1), startsLine: index == 2)
    }
    let lines = paused.update(words: midSentence, widths: texts.map { CGFloat($0.count) }, metrics: .init(maxWidth: 40, wordSpacing: 1, fontSize: 1))
    check(lines[2].line, equals: lines[1].line + 1, "a pause mid-sentence starts the next line, with no blank line")
    check(lines[2].x, equals: 0, "at the left edge")

    // Before it settles, a new paragraph already sits after its blank line in the live
    // lane, so settling does not move it.
    var live = RollUpTranscriptLayout()
    let pending = texts.enumerated().map { index, text in
        StableTranscriptWord(id: UInt64(index + 1), text: text, isCommitted: index < 2, anchor: UInt64(index + 1), startsParagraph: index == 2)
    }
    let before = live.update(words: pending, widths: texts.map { CGFloat($0.count) }, metrics: .init(maxWidth: 40, wordSpacing: 1, fontSize: 1))
    let after = live.update(words: words, widths: texts.map { CGFloat($0.count) }, metrics: .init(maxWidth: 40, wordSpacing: 1, fontSize: 1))
    check(before[2].line, equals: after[2].line, "settling a paragraph does not move it")
    check(before[2].line - before[1].line, equals: 2, "the live lane has room for the blank line")
}

private func testCatalanNumberNormalizer() {
    let cases: [(String, String)] = [
        ("el vint-i-tres d'abril", "el 23 d'abril"),
        ("l'any mil nou-cents noranta-dos", "l'any 1992"),
        ("només un quinze per cent", "només un 15 %"),
        ("fa uns deu mil anys", "fa uns 10.000 anys"),
        ("el cinc de maig de dos mil vint-i-sis", "el 5 de maig de 2026"),
        ("mil gràcies", "mil gràcies"),
        ("un home i una dona", "un home i una dona"),
        // Spellings some recognisers produce.
        ("tinc trenta dos anys", "tinc 32 anys"),
        ("l'any dinou noranta dos barcelona", "l'any 1992 barcelona"),
        ("l'any dinou noranta-dos", "l'any 1992"),
        ("l'any dinou", "l'any dinou"),
        ("el dinou de març", "el 19 de març"),
    ]
    for (spoken, written) in cases {
        check(CatalanNumberNormalizer.normalize(spoken), equals: written, "numbers: \(spoken)")
    }
    // A mark between two number words keeps them apart.
    let replacements = CatalanNumberNormalizer.replacements(in: ["trenta", "dos", "anys"], boundaries: [0])
    check(replacements.map(\.text), equals: ["30"], "a comma after the tens stops the number")
    let year = CatalanNumberNormalizer.replacements(in: ["l'any", "dinou", "noranta", "dos", "barcelona"], boundaries: [1, 2, 3])
    check(year.map(\.text), equals: ["1992"], "commas inside a year read in halves do not split it")
    check(year.first?.range, equals: 1..<4, "the whole year is replaced")
}

private func testReadingFontIsInterMedium() {
    check(
        AppVisualMetrics.readingFont(ofSize: 56).fontName,
        equals: "Inter18pt-Medium",
        "transcript uses Inter Medium"
    )
}

/// Registers the fonts `build-app.sh` bundles, as the app does at launch, so these
/// checks never depend on what happens to be installed on the test machine.
private func registerBundledReadingFonts() {
    let fontsURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../Resources/Fonts")
        .standardizedFileURL
    let urls = (try? FileManager.default.contentsOfDirectory(at: fontsURL, includingPropertiesForKeys: nil)) ?? []
    for url in urls where url.pathExtension == "ttf" {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

private func testReadingTypefacesResolveDistinctFonts() {
    registerBundledReadingFonts()
    check(ReadingTypeface.default, equals: .inter, "Inter stays the default reading face")
    for face in ReadingTypeface.allCases {
        guard let name = face.bundledFontName else { continue }
        check(face.font(ofSize: 56).fontName, equals: name, "\(face) draws with its bundled font, not a fallback")
    }
    // The retired system designs fall back to the default instead of failing to load.
    check(ReadingTypeface(rawValue: "serif"), equals: nil, "New York is no longer offered")
    check(ReadingTypeface(rawValue: "rounded"), equals: nil, "the rounded design is no longer offered")
    check(ReadingTypeface(rawValue: "hyperlegible"), equals: .hyperlegible, "Atkinson keeps its stored value")
    check(ReadingTypeface(rawValue: "lexend"), equals: nil, "Lexend is no longer offered")
    check(ReadingTypeface(rawValue: "courier"), equals: nil, "Courier Prime is no longer offered")

    // What the recogniser and formatter actually write: accents, the l·l middle dot,
    // the typographic apostrophe, digits and punctuation. (Ŀŀ are never produced.)
    let catalan = "àèéíïòóúüçÀÈÉÍÏÒÓÚÜÇ·’'0123456789.,;:?!«»-"
    let units = Array(catalan.utf16)
    for face in ReadingTypeface.allCases {
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        let covered = CTFontGetGlyphsForCharacters(face.font(ofSize: 56) as CTFont, units, &glyphs, units.count)
        check(covered, "\(face) has its own glyph for every Catalan character")
    }
    check(ReadingTypeface.inter.trackingScale, equals: 1, "Inter keeps the tuned tracking")

    // The glyph guard rides at the end of every word, so a face that lacks the hair
    // space would draw a fallback and push each word far from the next. Atkinson Mono
    // did: the guard was 1.8 em, seven times the intended word gap.
    let referenceSize = AppVisualMetrics.referenceFontSize
    let wordGap = AppVisualMetrics.interWordGapAtReferenceFontSize
    for face in ReadingTypeface.allCases {
        let font = face.font(ofSize: referenceSize)
        func width(_ text: String) -> CGFloat {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.font: font])
            )
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        let guardWidth = width(face.trailingGlyphGuard)
        check(guardWidth < wordGap, "\(face) glyph guard (\(guardWidth) pt) stays inside the word gap")
        if face.trailingGlyphGuard.isEmpty {
            // No guard is safe only if no glyph reaches past its own advance.
            var overhang: CGFloat = 0
            for unit in units {
                var glyph: CGGlyph = 0
                var character = unit
                guard CTFontGetGlyphsForCharacters(font as CTFont, &character, &glyph, 1) else { continue }
                var bounds = CGRect.zero
                CTFontGetBoundingRectsForGlyphs(font as CTFont, .horizontal, &glyph, &bounds, 1)
                var advance = CGSize.zero
                CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, &glyph, &advance, 1)
                overhang = max(overhang, bounds.maxX - advance.width)
            }
            check(overhang <= 0.5, "\(face) needs no glyph guard: nothing overhangs its cell")
        }
        if face.wordGapIsOwnSpace {
            check(width(" ") > wordGap, "\(face) separates words by more than the proportional gap")
        }
    }

    let names = ReadingTypeface.allCases.map { $0.font(ofSize: 56).fontName }
    check(Set(names).count, equals: ReadingTypeface.allCases.count, "every typeface draws with its own font")
    for face in ReadingTypeface.allCases {
        check(face.font(ofSize: 56).pointSize, equals: 56, "\(face) honours the requested size")
        check(ReadingTypeface(rawValue: face.rawValue), equals: face, "\(face) survives storage")
        check(face.trackingScale > 0 && face.trackingScale <= 1, "\(face) tracking stays compact")
        check(!face.fullName.isEmpty && !face.rationale.isEmpty, "\(face) explains itself on hover")
        check(face.displayName.split(separator: " ").allSatisfy { face.fullName.contains($0) }, "\(face) is labelled by its own name")
        let line = NSAttributedString(
            string: face.displayName + "  " + face.rationale,
            attributes: [.font: face.font(ofSize: 12)]
        )
        // The bar is about 525 pt wide with the typeface panel open; its well and margins
        // leave about 480 for the line.
        check(line.size().width < 460, "\(face) explains itself in one line of the info bar")
    }
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


private func testUndecidedWordWithoutAgreementIsDropped() {
    // In a crowd the recogniser writes a different word at the same place every window.
    // No form is ever heard twice, so the word is dropped once overdue; the stable
    // words around it still settle.
    var stabilizer = ReadableTranscriptStabilizer(policy: .reliable)
    let inventions = ["més", "mas", "muy", "mes", "mis", "mos", "mus", "mès", "mís", "mós", "mus", "mas"]
    var snapshot = ReadableTranscriptSnapshot()
    var end: UInt64 = 1_600
    var step = 0
    while end <= 5_500 {
        let heard = [
            observed("una", start: 1_000, end: 1_150),
            observed("\(inventions[step % inventions.count])\(step)", start: 1_200, end: 1_500),
            observed("que", start: 1_550, end: 1_600),
        ] + (end >= 2_000 ? [observed("amenaça", start: 1_650, end: 1_950)] : [])
        snapshot = stabilizer.observe(heard, audioEndSequence: end, sampleRate: 1_000, windowStartSequence: 0)
        end += 300
        step += 1
    }
    let committed = snapshot.committedWords.map(\.text)
    check(committed, equals: ["una", "que", "amenaça"], "a word no two windows agreed on is dropped, not settled as last heard: \(committed)")
    check(stabilizer.overdueDrops, equals: 1, "the drop is counted")
    check(snapshot.provisionalWords.isEmpty, "nothing of it stays on screen")

    // The form heard most often wins, not the last one heard (a policy that settles
    // undecided words, like Immediat).
    var majority = ReadableTranscriptStabilizer(policy: TranscriptStabilityPolicy(
        minimumHopSeconds: 0.3, initialEvidenceRequired: 3, replacementEvidenceRequired: 3,
        minimumWordAgeSeconds: 0.65, commitEvidenceRequired: 3, commitLagSeconds: 0.65, overdueEvidenceRequired: 2
    ))
    let forms = ["reaccionària", "redsonària", "reaccionària", "reaccionaria", "reaccionària", "redsonària", "reacionària", "redsonaria", "reaccionaria"]
    end = 1_600
    step = 0
    while end <= 5_200 {
        let heard = [
            observed("una", start: 1_000, end: 1_150),
            observed(forms[step % forms.count], start: 1_200, end: 1_500),
            observed("que", start: 1_550, end: 1_600),
            observed("amenaça", start: 1_650, end: 1_950),
        ]
        snapshot = majority.observe(heard, audioEndSequence: end, sampleRate: 1_000, windowStartSequence: 0)
        end += 300
        step += 1
    }
    check(snapshot.committedWords.map(\.text), equals: ["una", "reaccionària", "que", "amenaça"], "the form heard most often is the one settled: \(snapshot.committedWords.map(\.text))")

    // Immediate settles an undecided word once two windows heard the same form.
    var immediate = ReadableTranscriptStabilizer(policy: .immediate)
    end = 1_600
    step = 0
    while end <= 5_200 {
        let heard = [
            observed("una", start: 1_000, end: 1_150),
            observed(step % 2 == 0 ? "reaccionària" : "reaccionaria\(step)", start: 1_200, end: 1_500),
            observed("que", start: 1_550, end: 1_600),
        ]
        snapshot = immediate.observe(heard, audioEndSequence: end, sampleRate: 1_000, windowStartSequence: 0)
        end += 300
        step += 1
    }
    check(snapshot.committedWords.map(\.text), equals: ["una", "reaccionària", "que"], "the immediate profile settles an undecided word heard twice the same way")
    // Fiable never settles an undecided word, however often one form was heard.
    var fiable = ReadableTranscriptStabilizer(policy: .reliable)
    end = 1_600
    step = 0
    while end <= 5_200 {
        let heard = [
            observed("una", start: 1_000, end: 1_150),
            observed(step % 2 == 0 ? "reaccionària" : "reaccionaria\(step)", start: 1_200, end: 1_500),
            observed("que", start: 1_550, end: 1_600),
        ]
        snapshot = fiable.observe(heard, audioEndSequence: end, sampleRate: 1_000, windowStartSequence: 0)
        end += 300
        step += 1
    }
    check(snapshot.committedWords.map(\.text), equals: ["una", "que"], "Fiable drops a word no three windows in a row agreed on")
}

private func testCommittedWordsCarryTheRecognisersConfidence() {
    // Each hearing brings the engine's confidence; the settled word carries the mean
    // of the hearings of its form, and a form heard without one carries none.
    var stabilizer = ReadableTranscriptStabilizer(policy: .reliable)
    var snapshot = ReadableTranscriptSnapshot()
    for (step, confidence) in [Float(0.9), 0.6, 0.3].enumerated() {
        let heard = [
            TranscriptObservationWord(text: "casa", startSequence: 1_000, endSequence: 1_300, confidence: confidence),
            TranscriptObservationWord(text: "gran", startSequence: 1_400, endSequence: 1_700, confidence: nil),
        ]
        snapshot = stabilizer.observe(heard, audioEndSequence: 2_600 + UInt64(step) * 300, sampleRate: 1_000, windowStartSequence: 0)
    }
    let casa = snapshot.words.first { $0.text == "casa" }
    check(casa != nil, "the word is on screen")
    if let confidence = casa?.confidence {
        check(abs(confidence - 0.6) < 0.001, "the word carries the mean confidence of its hearings: \(confidence)")
    } else {
        check(false, "the word carries a confidence")
    }
    check(snapshot.words.first { $0.text == "gran" }?.confidence == nil, "a word heard without confidence carries none")
}

private func testDoubtfulWordsStayUnseenAndGo() {
    // "gardinet" is heard the same way every window but the recogniser is never sure
    // of it: Fiable neither shows it nor settles it, and the words after it go on.
    var stabilizer = ReadableTranscriptStabilizer(policy: .reliable)
    var snapshot = ReadableTranscriptSnapshot()
    var end: UInt64 = 1_600
    while end <= 5_500 {
        let heard = [
            TranscriptObservationWord(text: "una", startSequence: 1_000, endSequence: 1_150, confidence: 0.9),
            TranscriptObservationWord(text: "gardinet", startSequence: 1_200, endSequence: 1_500, confidence: 0.3),
            TranscriptObservationWord(text: "que", startSequence: 1_550, endSequence: 1_600, confidence: 0.8),
        ]
        snapshot = stabilizer.observe(heard, audioEndSequence: end, sampleRate: 1_000, windowStartSequence: 0)
        check(!snapshot.words.map(\.text).contains("gardinet"), "a doubtful word is never on screen")
        end += 300
    }
    check(snapshot.committedWords.map(\.text), equals: ["una", "que"], "the doubtful word goes and the rest settle: \(snapshot.committedWords.map(\.text))")
}

private func testVocabularyCasingWritesTermsAsGiven() {
    let casing = VocabularyCasing(["Korotkoff", "Artur Mas", "renfe"])
    let snapshot = ReadableTranscriptSnapshot(
        committedWords: [
            StableTranscriptWord(id: 1, text: "Sorolls", isCommitted: true, anchor: 1),
            StableTranscriptWord(id: 2, text: "de", isCommitted: true, anchor: 2),
            StableTranscriptWord(id: 3, text: "korotkoff,", isCommitted: true, anchor: 3),
            StableTranscriptWord(id: 4, text: "artur", isCommitted: true, anchor: 4),
            StableTranscriptWord(id: 5, text: "mas.", isCommitted: true, anchor: 5),
            StableTranscriptWord(id: 6, text: "Una", isCommitted: true, anchor: 6),
            StableTranscriptWord(id: 7, text: "mas", isCommitted: true, anchor: 7),
        ],
        provisionalWords: [StableTranscriptWord(id: 8, text: "renfe", anchor: 8)]
    )
    let written = casing.apply(to: snapshot)
    check(written.committedWords.map(\.text), equals: ["Sorolls", "de", "Korotkoff,", "Artur", "Mas.", "Una", "mas"],
          "terms are written as given, marks kept, 'mas' alone untouched: \(written.committedWords.map(\.text))")
    check(written.provisionalWords.map(\.text), equals: ["renfe"], "a lowercase term changes nothing")
    check(written.committedWords.map(\.id), equals: snapshot.committedWords.map(\.id), "identities survive")
    check(VocabularyCasing([]).apply(to: snapshot) == snapshot, "no terms, no change")
}

private func testSpeechPresenceMapDropsWordsWhereNobodySpoke() {
    let rate: Int32 = 16_000
    // One 10 s window: a voice from 2 s to 6 s, nobody before or after.
    func frames(voiceFrom: Double, to: Double) -> [Int] {
        (0..<Int((10.0 * 16_000 - 990) / 270) + 1).map { frame in
            let time = (Double(frame) * 270 + 495) / 16_000
            return time >= voiceFrom && time < to ? 1 : 0
        }
    }
    var tracker = SpeakerTurnTracker()
    check(tracker.speech.verdict(start: 0, end: 100), equals: .undecided, "before any analysis nothing is decided")
    tracker.append([Float](repeating: 0.01, count: Int(rate) * 10), endSequence: UInt64(rate) * 10, sampleRate: rate)
    guard let window = tracker.nextWindow() else { return check(false, "a window is ready after 10 s") }
    tracker.ingest(frameClasses: frames(voiceFrom: 2, to: 6), of: window)
    let map = tracker.speech
    func seconds(_ s: Double) -> UInt64 { UInt64(s * Double(rate)) }
    check(map.verdict(start: seconds(3), end: seconds(3.4)), equals: .voice, "a word inside the voice")
    check(map.verdict(start: seconds(0.5), end: seconds(0.9)), equals: .nobody, "a word where nobody spoke")
    check(map.verdict(start: seconds(7.5), end: seconds(8.0)), equals: .nobody, "a word after the voice")
    check(map.verdict(start: seconds(5.95), end: seconds(6.3)), equals: .voice, "a word that starts in the voice's last sound")
    check(map.verdict(start: seconds(1.85), end: seconds(1.95)), equals: .voice, "a word stamped up to 100 ms before its sound is kept")
    check(map.verdict(start: seconds(9.8), end: seconds(10.2)), equals: .undecided, "a word the detector has not listened to in full is left")
    let words = [observed("hola", start: seconds(2.5), end: seconds(2.9)), observed("muy", start: seconds(8), end: seconds(8.3)),
                 observed("més", start: seconds(9.9), end: seconds(10.1))]
    check(map.voicedWords(words).map(\.text), equals: ["hola", "més"], "only the word where nobody spoke is dropped")
    check(SpeechPresenceMap.empty.voicedWords(words).count, equals: 3, "without the detector every word stays")

    // A later window hears the same time again: its verdict replaces the older one.
    tracker.append([Float](repeating: 0.01, count: Int(rate) / 2), endSequence: UInt64(rate) * 21 / 2, sampleRate: rate)
    guard let next = tracker.nextWindow() else { return check(false, "a window follows half a second later") }
    tracker.ingest(frameClasses: frames(voiceFrom: 7, to: 10), of: next)
    check(tracker.speech.verdict(start: seconds(8), end: seconds(8.3)), equals: .voice, "the newest analysis of a moment wins")
    check(tracker.speech.verdict(start: seconds(3), end: seconds(3.4)), equals: .nobody, "even when it takes a voice away")
}

private func testTranscriptionProfilesExposeFrozenPolicies() {
    check(TranscriptionProfile.default, equals: .reliable, "reliable is the default profile")
    check(TranscriptionProfile.reliable.policy.minimumHopSeconds, equals: 0.300, "reliable hop")
    check(TranscriptionProfile.reliable.policy.initialEvidenceRequired, equals: 3, "reliable show evidence")
    check(TranscriptionProfile.reliable.policy.replacementEvidenceRequired, equals: 3, "reliable replacement evidence")
    check(TranscriptionProfile.reliable.policy.minimumWordAgeSeconds, equals: 0.650, "reliable word age")
    check(TranscriptionProfile.reliable.policy.overdueEvidenceRequired, equals: TranscriptStabilityPolicy.never, "reliable never settles an undecided word")
    check(TranscriptionProfile.reliable.policy.minimumConfidence, equals: 0.5, "reliable asks half a confidence")
    check(TranscriptionProfile.immediate.policy.minimumConfidence, equals: 0.4, "immediate asks a little less")
    check(TranscriptionProfile.balanced.policy.minimumHopSeconds, equals: 0.300, "balanced hop")
    check(TranscriptionProfile.balanced.policy.initialEvidenceRequired, equals: 2, "balanced show evidence")
    check(TranscriptionProfile.balanced.policy.commitEvidenceRequired, equals: 3, "balanced commit evidence")
    check(TranscriptionProfile.balanced.policy.overdueEvidenceRequired, equals: TranscriptStabilityPolicy.never, "balanced never settles an undecided word")
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

private func testProfileSwitchMidSessionKeepsText() {
    var stabilizer = ReadableTranscriptStabilizer(policy: .immediate)
    let heard = [observed("bon", start: 100, end: 250), observed("dia", start: 300, end: 450)]
    _ = stabilizer.observe(heard, audioEndSequence: 900, sampleRate: 1_000)
    let before = stabilizer.observe(heard, audioEndSequence: 1_000, sampleRate: 1_000)
    check(before.words.map(\.text), equals: ["bon", "dia"], "immediate shows both words")

    stabilizer.adopt(.reliable)
    check(stabilizer.policy, equals: TranscriptionProfile.reliable.policy, "the new profile's thresholds apply")
    let after = stabilizer.observe(heard, audioEndSequence: 1_100, sampleRate: 1_000)
    check(after.words.map(\.text), equals: ["bon", "dia"], "switching profile keeps the text on screen")
    check(after.words.map(\.id), equals: before.words.map(\.id), "switching profile keeps word identities")

    let next = stabilizer.observe(
        heard + [observed("a", start: 500, end: 560)],
        audioEndSequence: 1_200,
        sampleRate: 1_000
    )
    check(next.words.map(\.text), equals: ["bon", "dia"], "a new word now waits for reliable's evidence")

    var scheduler = LatestAudioScheduler(minimumHopSamples: 180)
    scheduler.setMinimumHopSamples(300)
    check(scheduler.minimumHopSamples, equals: 300, "the scheduler takes the new hop")
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

private func testShortSettledWordsDriftingAFrameAreNotRepeated() {
    // FastConformer: one 80 ms frame per short word, placed a frame later next window.
    var stabilizer = ReadableTranscriptStabilizer()
    let first = [
        observed("cualquier", start: 5_730, end: 5_810),
        observed("riesgo", start: 6_170, end: 6_490),
        observed("del", start: 6_490, end: 6_570),
        observed("clima", start: 6_650, end: 6_970),
    ]
    _ = stabilizer.observe(first, audioEndSequence: 7_250, sampleRate: 1_000)
    let settled = stabilizer.observe(first, audioEndSequence: 7_250, sampleRate: 1_000)
    check(settled.committedWords.map(\.text), equals: ["cualquier", "riesgo", "del"], "short-word fixture settles through del")

    let shifted = stabilizer.observe(
        [
            observed("cualquier", start: 5_770, end: 5_850),
            observed("riesgo", start: 6_170, end: 6_570),
            observed("del", start: 6_570, end: 6_650),
            observed("clima", start: 6_730, end: 7_050),
            observed("extremo", start: 7_210, end: 7_690),
        ],
        audioEndSequence: 8_450,
        sampleRate: 1_000
    )
    check(
        shifted.words.map(\.text),
        equals: ["cualquier", "riesgo", "del", "clima", "extremo"],
        "a settled short word heard a frame later is the same word, not a repetition"
    )
}

private func testLastWordBeforeSilenceIsNotRepeated() {
    // Once the speaker stops, FastConformer stretches the last word over the silence
    // that follows: same start, end at the window's end. It is the settled word, not a
    // new one ("…bring our children along? Along?").
    var stretched = ReadableTranscriptStabilizer()
    let spoken = [
        observed("children", start: 3_400, end: 3_480),
        observed("along", start: 3_600, end: 4_300),
    ]
    _ = stretched.observe(spoken, audioEndSequence: 5_000, sampleRate: 1_000, windowStartSequence: 0)
    _ = stretched.observe(spoken, audioEndSequence: 5_300, sampleRate: 1_000, windowStartSequence: 0)
    let settled = stretched.observe(spoken, audioEndSequence: 6_200, sampleRate: 1_000, windowStartSequence: 0)
    check(settled.committedWords.map(\.text), equals: ["children", "along"], "stretched fixture settles its last word")
    var silence = settled
    for end in stride(from: 7_000, through: 10_000, by: 500) {
        silence = stretched.observe(
            [
                observed("children", start: 3_400, end: 3_480),
                observed("along", start: 3_600, end: UInt64(end)),
            ],
            audioEndSequence: UInt64(end),
            sampleRate: 1_000,
            windowStartSequence: UInt64(end - 7_000)
        )
    }
    check(silence.words.map(\.text), equals: ["children", "along"], "a last word stretched over the silence is the same word")

    // As the window slides on over the silence, the words it heard earliest sit at its
    // left edge, where the decoder places them less surely: a settled short word came
    // back a frame after itself, behind words it misheard ("para para todos").
    var edge = ReadableTranscriptStabilizer()
    let heard = [
        observed("bizcocho", start: 3_300, end: 3_600),
        observed("para", start: 3_700, end: 3_780),
    ]
    _ = edge.observe(heard, audioEndSequence: 5_000, sampleRate: 1_000, windowStartSequence: 0)
    _ = edge.observe(heard, audioEndSequence: 5_300, sampleRate: 1_000, windowStartSequence: 0)
    let committed = edge.observe(heard, audioEndSequence: 6_500, sampleRate: 1_000, windowStartSequence: 0)
    check(committed.committedWords.map(\.text), equals: ["bizcocho", "para"], "edge fixture settles para")
    let atEdge = edge.observe(
        [
            observed("coxo", start: 3_330, end: 3_560),
            observed("para", start: 3_820, end: 3_900),
            observed("todos", start: 3_980, end: 7_300),
        ],
        audioEndSequence: 7_300,
        sampleRate: 1_000,
        windowStartSequence: 2_700
    )
    check(
        atEdge.words.map(\.text).filter { $0 == "para" }.count,
        equals: 1,
        "a settled word heard again at the window's left edge is not repeated"
    )
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

private func testPartialObservationDoesNotSkipHeardWords() {
    // Reliable profile, 1 kHz clock. "quan vam arribar" is heard twice, then the recogniser
    // returns only the words after it: those must not commit over the phrase.
    var stabilizer = ReadableTranscriptStabilizer(policy: .reliable)
    let full = [
        observed("quan", start: 1_000, end: 1_200), observed("vam", start: 1_250, end: 1_400),
        observed("arribar", start: 1_450, end: 1_700), observed("plovia", start: 2_000, end: 2_400),
        observed("feia", start: 2_500, end: 2_700),
    ]
    let partial = Array(full.suffix(2))
    _ = stabilizer.observe(full, audioEndSequence: 2_800, sampleRate: 1_000, windowStartSequence: 0)
    _ = stabilizer.observe(full, audioEndSequence: 3_100, sampleRate: 1_000, windowStartSequence: 0)
    for end in [3_400, 3_700] as [UInt64] {
        let skipped = stabilizer.observe(partial, audioEndSequence: end, sampleRate: 1_000, windowStartSequence: 0)
        check(!skipped.committedWords.map(\.text).contains("plovia"), "a window that drops heard words commits nothing after them")
    }
    var text: [String] = []
    for end in [4_000, 4_300, 4_600, 4_900] as [UInt64] {
        text = stabilizer.observe(full, audioEndSequence: end, sampleRate: 1_000, windowStartSequence: 0).words.map(\.text)
    }
    check(text, equals: ["quan", "vam", "arribar", "plovia", "feia"], "the dropped phrase survives and is committed in order")

    // A hole that persists is real: the words go.
    var persistent = ReadableTranscriptStabilizer(policy: .reliable)
    _ = persistent.observe(full, audioEndSequence: 2_800, sampleRate: 1_000, windowStartSequence: 0)
    _ = persistent.observe(full, audioEndSequence: 3_100, sampleRate: 1_000, windowStartSequence: 0)
    var last = ReadableTranscriptSnapshot()
    for end in [3_400, 3_700, 4_000, 4_300, 4_600, 4_900] as [UInt64] {
        last = persistent.observe(partial, audioEndSequence: end, sampleRate: 1_000, windowStartSequence: 0)
    }
    check(!last.words.map(\.text).contains("quan"), "a hole that persists is accepted")

    // Words the window has moved past are not a hole: the window now starts after them.
    var slid = ReadableTranscriptStabilizer(policy: .reliable)
    _ = slid.observe(full, audioEndSequence: 2_800, sampleRate: 1_000, windowStartSequence: 0)
    _ = slid.observe(full, audioEndSequence: 3_100, sampleRate: 1_000, windowStartSequence: 0)
    let moved = slid.observe(partial, audioEndSequence: 3_400, sampleRate: 1_000, windowStartSequence: 1_800)
    check(moved.words.map(\.text).contains("plovia"), "an observation from a window that starts after the words is used")
}

private func testOverdueUndecidedWordIsCommittedNotLost() {
    // The recogniser rewords one word every window; the words after it are stable. A
    // policy that settles undecided words (two hearings of a form, like Immediat).
    var stabilizer = ReadableTranscriptStabilizer(policy: TranscriptStabilityPolicy(
        minimumHopSeconds: 0.3, initialEvidenceRequired: 3, replacementEvidenceRequired: 3,
        minimumWordAgeSeconds: 0.65, commitEvidenceRequired: 3, commitLagSeconds: 0.65, overdueEvidenceRequired: 2
    ))
    let spellings = ["reaccionària", "redsonària", "reaccionaria", "mera"]
    var snapshot = ReadableTranscriptSnapshot()
    var end: UInt64 = 1_600
    var step = 0
    while end <= 5_200 {
        let heard = [
            observed("una", start: 1_000, end: 1_150),
            observed(spellings[step % spellings.count], start: 1_200, end: 1_500),
            observed("que", start: 1_550, end: 1_600),
        ] + (end >= 2_000 ? [observed("amenaça", start: 1_650, end: 1_950)] : [])
        snapshot = stabilizer.observe(heard, audioEndSequence: end, sampleRate: 1_000, windowStartSequence: 0)
        let ids = snapshot.words.map(\.id)
        check(Set(ids).count, equals: ids.count, "no identity is both settled and on screen")
        end += 300
        step += 1
    }
    let committed = snapshot.committedWords.map(\.text)
    check(committed.first, equals: "una", "the stable word before commits normally")
    check(committed.count >= 3 && committed[1] == "reaccionària", "an undecided word is committed as its most frequent form once it is overdue: \(committed)")
    check(committed.contains("que"), "and the words after it are not held back for ever")

    // A shown word whose later spelling the recogniser keeps changing settles once, as
    // itself: its identity never appears twice.
    var shown = ReadableTranscriptStabilizer(policy: .immediate)
    end = 1_300
    step = 0
    while end <= 5_200 {
        let heard = [observed(spellings[min(step, spellings.count - 1) == 0 ? 0 : step % spellings.count], start: 1_000, end: 1_250),
                     observed("fi", start: 1_300, end: 1_400)]
        let snap = shown.observe(heard, audioEndSequence: end, sampleRate: 1_000, windowStartSequence: 0)
        let ids = snap.words.map(\.id)
        check(Set(ids).count, equals: ids.count, "identities stay unique while a shown word goes overdue")
        end += 300
        step += 1
    }
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

    // Conversational speech: syllables at a quiet microphone level separated by short
    // gaps, and longer pauses between words, rendered at 60 fps.
    let frame = 1.0 / 60.0
    var conversationalIdle = ShaderMotionDynamics()
    var conversation = ShaderMotionDynamics()
    var speakingMultipliers: [Double] = []
    var largestFrameStep = 0.0
    for _ in 0..<8 {
        for _ in 0..<3 {
            for level: Float in Array(repeating: 0.15, count: 9) + Array(repeating: 0, count: 5) {
                let before = conversation.speedMultiplier
                conversation.advance(deltaTime: frame, voiceLevel: level)
                conversationalIdle.advance(deltaTime: frame, voiceLevel: 0)
                largestFrameStep = max(largestFrameStep, abs(conversation.speedMultiplier - before))
                speakingMultipliers.append(conversation.speedMultiplier)
            }
        }
        for _ in 0..<15 {
            let before = conversation.speedMultiplier
            conversation.advance(deltaTime: frame, voiceLevel: 0)
            conversationalIdle.advance(deltaTime: frame, voiceLevel: 0)
            largestFrameStep = max(largestFrameStep, abs(conversation.speedMultiplier - before))
            speakingMultipliers.append(conversation.speedMultiplier)
        }
    }
    let settled = speakingMultipliers.dropFirst(30)
    check(
        settled.reduce(0, +) / Double(settled.count) >= 18,
        "conversational speech drives the field far faster than silence"
    )
    check(
        settled.min() ?? 0 >= 14,
        "gaps between syllables and words do not drop the field back towards idle"
    )
    check(
        conversation.phase >= conversationalIdle.phase * 15,
        "conversational speech dominates accumulated shader evolution"
    )
    check(
        largestFrameStep <= ShaderMotionDynamics.maximumSpeedMultiplier * 0.08,
        "speed changes glide between frames instead of jumping"
    )

    var onset = ShaderMotionDynamics()
    for _ in 0..<9 {
        onset.advance(deltaTime: frame, voiceLevel: 0.15)
    }
    check(onset.speedMultiplier >= 8, "speech accelerates the field visibly within 150 ms")

    for _ in 0..<60 {
        conversation.advance(deltaTime: frame, voiceLevel: 0)
    }
    check(conversation.speedMultiplier < 6, "a second of silence clearly slows the field")
    for _ in 0..<120 {
        conversation.advance(deltaTime: frame, voiceLevel: 0)
    }
    check(conversation.speedMultiplier < 1.5, "sustained silence returns to the idle speed")
    check(
        ShaderMotionDynamics.idleSpeed >= 0.16,
        "the decorative field has a slightly quicker baseline motion"
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

private func testSubtitleDocument() {
    func session(_ words: [(String, Double, Double, Bool)]) -> SessionTranscript {
        SessionTranscript(
            words: words.map { SessionTranscript.Word(text: $0.0, start: $0.1, end: $0.2, startsParagraph: $0.3) },
            duration: 20,
            startedAt: nil
        )
    }
    let opening: [(String, Double, Double, Bool)] = [
        ("Bon", 0.0, 0.3, false), ("dia.", 0.35, 0.7, false),
        ("Avui", 1.0, 1.3, false), ("parlarem", 1.35, 1.8, false), ("de", 1.85, 1.95, false),
        ("la", 2.0, 2.1, false), ("plaça", 2.15, 2.6, false),
        ("després", 3.6, 4.0, false), ("de", 4.05, 4.1, false), ("dinar", 4.15, 4.5, false),
        ("Nova", 6.0, 6.3, true),
    ]
    let rest: [(String, Double, Double, Bool)] = "veu que arriba tard, molt llarga i que no cap mai."
        .split(separator: " ").enumerated().map { item -> (String, Double, Double, Bool) in
            let start = 6.4 + Double(item.offset) * 0.4
            return (String(item.element), start, start + 0.3, false)
        }
    let source = session(opening + rest)
    var document = SubtitleDocument(session: source)
    check(document.lines.map { $0.text }, equals: [
        "Bon dia.",
        "Avui parlarem de la plaça",
        "després de dinar",
        "Nova veu que arriba tard,",
        "molt llarga i que no cap mai.",
    ], "subtitle lines break at sentences, pauses, paragraphs and after a comma when too long")
    check(document.lines.allSatisfy { $0.text.count <= SubtitleDocument.maximumCharacters }, "subtitle lines stay short")
    check(document.session.words.map { $0.text }, equals: source.words.map { $0.text }, "subtitle document round-trips its words")
    check(TranscriptExport.paragraphs(document.session), equals: TranscriptExport.paragraphs(source), "subtitle document keeps paragraphs")
    check(document.lineIndex(at: 0.5), equals: 0, "line at a time")
    check(document.lineIndex(at: 3.0), equals: 1, "the last line heard stays current in a pause")
    check(document.lineIndex(at: -1) == nil, "no line before the first")

    // A corrected accent keeps every time; a replaced word takes the old one's time.
    let id = document.lines[1].id
    check(document.setText("Avui parlarem de la Plaça", ofLine: id), "a correction changes the line")
    check(document.lines[1].words.map { $0.start }, equals: [1.0, 1.35, 1.85, 2.0, 2.15] as [TimeInterval], "case changes keep times")
    document.setText("Avui xerrarem de la Plaça", ofLine: id)
    check(document.lines[1].words[1].start, equals: 1.35, "a replaced word takes the old start")
    check(document.lines[1].words[1].end, equals: 1.8, "a replaced word takes the old end")
    // One word heard as two: they share its time by length.
    document.setText("Avui xerrarem de la Plaça Major", ofLine: id)
    let split = document.lines[1].words
    check(split.count, equals: 6, "a word added at the end")
    check(split[5].end, equals: 2.6, "the line keeps its end")
    check(split[4].start, equals: 2.15, "the kept word before the new one keeps its start")
    check(split[4].end <= split[5].start + 0.0001 && split[5].start > 2.15, "the new word follows in the shared time")
    check(zip(split, split.dropFirst()).allSatisfy { $0.end <= $1.start + 0.0001 }, "words stay in order")
    // Two words heard as one.
    document.setText("Avui xerrarem de laplaça Major", ofLine: id)
    check(document.lines[1].words[3].start, equals: 2.0, "merged words start with the first")
    check(document.lines[1].words[3].end, equals: document.lines[1].words[4].start, "merged words take both times")
    check(document.lines[1].words.count, equals: 5, "merged words count")
    check(!document.setText("Avui xerrarem de laplaça Major", ofLine: id), "the same text changes nothing")

    // Removing the line that opens a paragraph moves the paragraph to the next line.
    let paragraphLine = document.lines[3].id
    document.setText("   ", ofLine: paragraphLine)
    check(document.lines.count, equals: 4, "an empty line is removed")
    check(document.lines[3].startsParagraph, "the next line opens the paragraph")

    let cues = document.cues
    check(cues.count, equals: document.lines.count, "one cue per line")
    check(cues[0].end, equals: cues[1].start, "a short gap is bridged")
    check(cues[2].end, equals: cues[2].words.last!.end + 0.6, "a long gap leaves the screen empty after a hold")
    check(zip(cues, cues.dropFirst()).allSatisfy { $0.end <= $1.start }, "cues never overlap")
    check(TranscriptExport.subRip(document.session).contains("\nxerrarem\n"), "the .srt carries corrections")

    testSubtitleDocumentEditing(SubtitleDocument(session: source))
}

private func testSubtitleDocumentEditing(_ original: SubtitleDocument) {
    func ordered(_ document: SubtitleDocument) -> Bool {
        let words = document.lines.flatMap(\.words)
        return zip(words, words.dropFirst()).allSatisfy { $0.end <= $1.start + 0.0001 }
            && words.allSatisfy { $0.start <= $0.end }
    }
    var document = original
    let total = document.wordCount

    // Splitting keeps every word and time; the halves get distinct ids.
    let longID = document.lines[1].id
    check(document.naturalSplit(ofLine: longID), equals: 2, "a line splits near its middle")
    let tailID = document.split(lineID: longID, beforeWord: 2)
    check(tailID != nil && tailID != longID, "a split makes a new line")
    check(document.lines[1].text, equals: "Avui parlarem", "the first half stays")
    check(document.lines[2].text, equals: "de la plaça", "the second half follows")
    check(document.lines[2].start, equals: 1.85, "the second half keeps its words' times")
    check(document.wordCount, equals: total, "a split keeps every word")
    check(Set(document.lines.map(\.id)).count, equals: document.lines.count, "line ids stay unique")
    check(document.split(lineID: longID, beforeWord: 0) == nil, "nothing to split before the first word")
    check(document.split(lineID: longID, beforeWord: 2) == nil, "nothing to split after the last word")
    let comma = SubtitleDocument(session: SessionTranscript(words: "Ara sí, que comencem la sessió de bon matí".split(separator: " ").enumerated().map {
        SessionTranscript.Word(text: String($0.element), start: Double($0.offset), end: Double($0.offset) + 0.5)
    }, duration: 12, startedAt: nil))
    check(comma.naturalSplit(ofLine: comma.lines[0].id), equals: 2, "a comma near the middle is preferred")

    // Merging joins it back.
    check(document.mergeWithNext(lineID: longID), "the next line joins")
    check(document.lines[1].text, equals: "Avui parlarem de la plaça", "merged text")
    check(document.lines[1].words.map(\.start), equals: original.lines[1].words.map(\.start), "merged words keep their times")
    check(!document.mergeWithNext(lineID: document.lines.last!.id), "the last line has nothing to join")

    // A missing line goes into the silence after a line, inside it.
    let after = document.lines[2].id
    let gap = document.gap(after: after)
    check(gap, equals: 4.5...6.0, "the silence after a line")
    let added = document.insertLine("Bona tarda a tots", after: after, span: 4.2...7.0)
    check(added != nil, "a line is added")
    check(document.lines[3].text, equals: "Bona tarda a tots", "the added line sits after")
    check(document.lines[3].start >= 4.5 && document.lines[3].end <= 6.0, "the added line stays inside the silence")
    check(ordered(document), "words stay in order after adding a line")
    check(document.insertLine("   ", after: after, span: 4.5...6.0) == nil, "an empty line is not added")
    let first = document.insertLine("Hola", after: nil, span: 0...0)
    check(first != nil && document.lines[0].text == "Hola", "a line before the first")
    check(ordered(document), "a line before the first stays in order")
    check(document.removeLine(id: first!), "a line is removed")
    check(document.lines[0].text, equals: "Bon dia.", "removed")

    // Finding and replacing: whole words, case and accents aside, marks and elisions kept.
    var names = SubtitleDocument(session: SessionTranscript(words: [
        ("En", 0.0), ("Joan", 0.3), ("diu", 0.6), ("que", 0.9), ("joan,", 1.2), ("vine.", 1.5),
        ("Joanet", 3.0), ("i", 3.3), ("l'escola", 3.6), ("de", 3.9), ("l’Escola", 4.2), ("Nova.", 4.5),
    ].map { SessionTranscript.Word(text: $0.0, start: $0.1, end: $0.1 + 0.25) }, duration: 6, startedAt: nil))
    check(names.matches(of: "joan").count, equals: 2, "whole words only, any case")
    check(names.matches(of: "  ").isEmpty, "an empty search finds nothing")
    check(names.matches(of: "escola").count, equals: 2, "a word after an elision is found")
    check(names.matches(of: "escola nova").count, equals: 1, "a phrase is found")
    check(names.replaceAll("joan", with: "jaume"), equals: 2, "every place is replaced")
    check(names.lines.map(\.text).joined(separator: " "), equals: "En Jaume diu que jaume, vine. Joanet i l'escola de l’Escola Nova.", "replacing keeps marks and a leading capital")
    check(names.replaceAll("escola nova", with: "Universitat"), equals: 1, "a phrase is replaced")
    check(names.lines.map(\.text).joined(separator: " ").hasSuffix("de l’Universitat."), "the elision and the full stop stay")
    check(ordered(names), "words stay in order after replacing")
    check(names.replaceAll("vine", with: "vine"), equals: 0, "replacing with the same changes nothing")
    check(names.replaceAll("diu que", with: ""), equals: 1, "a phrase can be removed")
    check(names.lines.first?.text, equals: "En Jaume jaume, vine.", "the phrase is gone")
    var place = SubtitleDocument(session: SessionTranscript(words: [
        ("Visc", 0.0), ("a", 0.3), ("l'Hospitalet.", 0.6),
    ].map { SessionTranscript.Word(text: $0.0, start: $0.1, end: $0.1 + 0.25) }, duration: 2, startedAt: nil))
    check(place.replaceAll("l'Hospitalet", with: "l'Hospitalet de Llobregat"), equals: 1, "a search with its elision is found")
    check(place.lines[0].text, equals: "Visc a l'Hospitalet de Llobregat.", "a search with its elision keeps one elision")

    // Words added to a line never run into the next line, and captions never overlap.
    var tight = SubtitleDocument(session: SessionTranscript(words: [
        SessionTranscript.Word(text: "Hola.", start: 0.9, end: 1.0),
        SessionTranscript.Word(text: "Adéu", start: 1.1, end: 1.4),
        SessionTranscript.Word(text: "amics.", start: 1.45, end: 1.8),
    ], duration: 3, startedAt: nil))
    check(tight.lines.count, equals: 2, "two tight lines")
    tight.setText("Hola a tots els meus amics i amigues.", ofLine: tight.lines[0].id)
    check(tight.lines[0].end <= 1.1 + 0.0001, "added words stay before the next line")
    check(ordered(tight), "added words stay in order")
    tight.setText("Doncs, ara sí, molt bon dia Adéu amics.", ofLine: tight.lines[1].id)
    check(tight.lines[1].start >= tight.lines[0].end - 0.0001, "words added in front stay after the line before")
    check(ordered(tight), "words added in front stay in order")
    for words in [0, 1, 2, 3] {
        let cues = tight.cues(wordsPerCue: words)
        check(zip(cues, cues.dropFirst()).allSatisfy { $0.start <= $1.start && $0.end <= $1.start + 0.0001 }, "cues of \(words) stay ordered")
        check(cues.allSatisfy { $0.end >= $0.start }, "cues of \(words) end after they start")
    }
    check(tight.cues(wordsPerCue: 0).count, equals: tight.lines.count, "0 words per cue is a line per cue")
    check(tight.subRip(wordsPerCue: 0).contains("Hola a tots els meus amics i amigues."), "whole-line .srt")
    check(CaptionStyle(wordsPerCue: 0).wordsPerCue, equals: 0, "whole lines can be chosen")

    testSavedCorrections(tight)
}

private func testSavedCorrections(_ document: SubtitleDocument) {
    // A corrected document survives the trip to disk whole, ids and times included.
    var edited = document
    let tailID = edited.split(lineID: edited.lines[0].id, beforeWord: 2)
    let encoded = try? JSONEncoder().encode(SavedCorrections(title: "Prova", languageID: "ca", document: edited))
    let decoded = encoded.flatMap { try? JSONDecoder().decode(SavedCorrections.self, from: $0) }
    check(decoded?.document == edited, "corrections round-trip through JSON")
    if var restored = decoded?.document {
        let next = restored.split(lineID: restored.lines[0].id, beforeWord: 1)
        check(next != nil && next != tailID && !restored.lines.dropFirst().contains { $0.id == restored.lines[0].id },
              "a restored document keeps making new ids")
    }

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("corrections-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // The key follows the video's content, not its name.
    let video = folder.appendingPathComponent("a.mov")
    let copy = folder.appendingPathComponent("b còpia.mov")
    let other = folder.appendingPathComponent("c.mov")
    let bytes = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    try? bytes.write(to: video)
    try? bytes.write(to: copy)
    var changed = bytes
    changed[changed.count - 10] ^= 0xFF
    try? changed.write(to: other)
    let key = try? CorrectionStore.key(for: video)
    check(key != nil && key == (try? CorrectionStore.key(for: copy)), "a copy of a video has the same key")
    check(key != (try? CorrectionStore.key(for: other)), "another video has another key")

    let store = CorrectionStore(root: folder.appendingPathComponent("Corrections"))
    check(store.load(key: "res") == nil, "nothing kept for an unknown video")
    if let key {
        try? store.save(SavedCorrections(title: "Prova", languageID: "es", document: edited), key: key)
        check(store.load(key: key)?.document == edited, "kept corrections come back")
        check(store.load(key: key)?.languageID, equals: "es", "kept corrections remember the language")
        store.remove(key: key)
        check(store.load(key: key) == nil, "forgotten corrections are gone")
    }
    for index in 0..<(CorrectionStore.keptVideos + 3) {
        try? store.save(SavedCorrections(title: "\(index)", languageID: nil, document: edited), key: "k\(index)")
    }
    let kept = (try? FileManager.default.contentsOfDirectory(atPath: store.root.path))?.count ?? 0
    check(kept, equals: CorrectionStore.keptVideos, "only the newest videos' corrections are kept")
}

private func testBurnedCaptions() {
    let words: [SessionTranscript.Word] = [
        .init(text: "Bon", start: 1.0, end: 1.3), .init(text: "dia", start: 1.35, end: 1.7),
        .init(text: "a", start: 1.75, end: 1.8), .init(text: "tothom.", start: 1.85, end: 2.4),
        .init(text: "Comencem", start: 2.5, end: 3.0), .init(text: "ara", start: 3.05, end: 3.4),
    ]
    let document = SubtitleDocument(session: SessionTranscript(words: words, duration: 4, startedAt: nil))
    let renderer = CaptionRenderer(cues: document.cues, style: CaptionStyle(font: .helvetica))
    let size = CGSize(width: 1920, height: 1080)
    check(renderer.layers(at: 0.5, pictureSize: size).isEmpty, "no caption before the first line")
    let shown = renderer.layers(at: 1.5, pictureSize: size)
    check(shown.count, equals: 1, "one caption while a line is said")
    if let layer = shown.first {
        check(abs(layer.frame.midX - 960) <= 1, "captions are centred")
        check(layer.frame.maxY < 1080 && layer.frame.minY > 700, "captions sit low in the picture")
    }
    // Captions swap on the frame the next one starts: no fade, never two at once.
    let boundary = document.cues[1].start
    check(renderer.layers(at: boundary - 0.001, pictureSize: size).count, equals: 1, "the first caption until the boundary")
    check(renderer.cueIndex(at: boundary - 0.001), equals: 0, "the first caption until the boundary")
    check(renderer.cueIndex(at: boundary), equals: 1, "the next caption from the boundary on")
    check(renderer.overlay(at: 3.2, pictureSize: size) != nil, "the overlay draws the second line")
    let portrait = renderer.layers(at: 3.2, pictureSize: CGSize(width: 1080, height: 1920)).first
    check((portrait?.frame.maxY ?? 2000) < 1920 * 0.87, "portrait captions sit higher")

    // Two words at a time, never across a sentence end.
    let pairs = document.cues(wordsPerCue: 2).map(\.text)
    check(pairs, equals: ["Bon dia", "a tothom.", "Comencem ara"], "captions of two words within a line")
    check(document.cues(wordsPerCue: 1).count, equals: 6, "one word at a time")
    check(document.cues(wordsPerCue: 3).map(\.text), equals: ["Bon dia a", "tothom.", "Comencem ara"], "three words at a time")
    let grouped = document.cues(wordsPerCue: 2)
    check(zip(grouped, grouped.dropFirst()).allSatisfy { $0.end <= $1.start }, "word captions never overlap")
    check(grouped[0].end, equals: grouped[1].start, "word captions run on to the next")
    let large = CaptionRenderer(document: document, style: CaptionStyle(font: .helvetica, scale: 1.7, wordsPerCue: 1))
    let small = CaptionRenderer(document: document, style: CaptionStyle(font: .helvetica, scale: 0.8, wordsPerCue: 1))
    let largeHeight = large.layers(at: 1.1, pictureSize: size).first?.frame.height ?? 0
    let smallHeight = small.layers(at: 1.1, pictureSize: size).first?.frame.height ?? 0
    check(largeHeight > smallHeight * 1.6, "the size choice changes the caption")

    // Captions sit where the reader put them, never past the picture's edges.
    let raised = CaptionRenderer(document: document, style: CaptionStyle(font: .helvetica, position: CGPoint(x: 0.3, y: 0.2)))
    if let frame = raised.layers(at: 1.5, pictureSize: size).first?.frame {
        check(abs(frame.midY - 1080 * 0.2) <= 1 && abs(frame.midX - 1920 * 0.3) <= 1, "captions move where they are put")
    } else {
        check(false, "a placed caption is drawn")
    }
    let corner = CaptionRenderer(document: document, style: CaptionStyle(font: .helvetica, position: CGPoint(x: 1, y: 1)))
    if let frame = corner.layers(at: 1.5, pictureSize: size).first?.frame {
        let padding = (1080 * CaptionStyle.standardRatio * 0.7).rounded(.up)
        check(frame.maxX - padding <= 1920 + 1 && frame.maxY - padding <= 1080 + 1, "a caption pushed to the corner stays inside the picture")
    }
    // The − and + buttons step by tenths, inside 50–200 %.
    var stepped = CaptionStyle(scale: 1.04)
    check(abs(stepped.scale - 1) < 0.0001, "sizes sit on the buttons' steps")
    stepped.scale = 9
    check(stepped.scale, equals: CaptionStyle.scaleRange.upperBound, "sizes stop at the largest step")
    // Moving the captions moves the same drawing: nothing is drawn again.
    let drawnFirst = raised.layers(at: 1.5, pictureSize: size).first?.image
    let moved = raised.placed(at: CGPoint(x: 0.6, y: 0.5))
    let movedLayer = moved.layers(at: 1.5, pictureSize: size).first
    check(movedLayer?.image === drawnFirst, "a moved caption reuses its drawing")
    check(abs((movedLayer?.frame.midX ?? 0) - 1920 * 0.6) <= 1, "a moved caption goes where it is put")
    if let text = moved.textFrame(at: 1.5, pictureSize: size), let frame = movedLayer?.frame {
        check(text.width < frame.width && abs(text.midX - frame.midX) <= 1, "the text frame is the caption less its shadow room")
    } else {
        check(false, "a caption has a text frame")
    }
    check(moved.textFrame(at: 50, pictureSize: size) != nil, "a pause gives the nearest caption's text to hold")
    let plain = CaptionRenderer(document: document, style: CaptionStyle(font: .helvetica, shadow: false, stroke: false))
    let outlined = CaptionRenderer(document: document, style: CaptionStyle(font: .helvetica, shadow: false, stroke: true))
    check(plain.layers(at: 1.5, pictureSize: size).first?.image.dataProvider?.data != outlined.layers(at: 1.5, pictureSize: size).first?.image.dataProvider?.data, "the outline changes the caption")
    check(CaptionFont.available.contains(.system) && CaptionFont.available.count >= 12, "the system's faces are offered")

    // The `.srt` follows the captions' words per cue.
    let srt = document.subRip(wordsPerCue: 2)
    check(srt.components(separatedBy: " --> ").count - 1, equals: 3, "an .srt cue per caption")
    check(srt.hasPrefix("1\n00:00:01,000 --> 00:00:01,750\nBon dia\n"), "the .srt carries two words to a cue")

    // `SUBTITOL_BURN_TEST=<video>` writes a captioned copy next to the scratch file it names.
    if let source = ProcessInfo.processInfo.environment["SUBTITOL_BURN_TEST"],
       let output = ProcessInfo.processInfo.environment["SUBTITOL_BURN_OUT"] {
        let semaphore = DispatchSemaphore(value: 0)
        let started = Date()
        Task.detached {
            do {
                let long = SubtitleDocument(session: SessionTranscript(words: (0..<40).map { index in
                    SessionTranscript.Word(text: index % 7 == 6 ? "paraula." : "paraula\(index)", start: Double(index) * 0.3, end: Double(index) * 0.3 + 0.25)
                }, duration: 12, startedAt: nil))
                try await CaptionedVideoExport.export(
                    source: URL(fileURLWithPath: source),
                    renderer: CaptionRenderer(cues: long.cues, style: CaptionStyle(font: .helvetica)),
                    to: URL(fileURLWithPath: output)
                ) { _ in }
                print("burnt \(output) in \(Date().timeIntervalSince(started)) s")
            } catch {
                print("FAIL burn: \(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
    }
}

private func testSessionTranscriptKeepsWholeSession() {
    func word(_ id: UInt64, _ text: String, _ start: UInt64, committed: Bool = true, paragraph: Bool = false) -> StableTranscriptWord {
        StableTranscriptWord(
            id: id, text: text, isCommitted: committed, anchor: id,
            startSequence: start, endSequence: start + 4_000, startsParagraph: paragraph
        )
    }
    func snapshot(_ committed: [StableTranscriptWord], _ provisional: [StableTranscriptWord] = [], end: UInt64) -> ReadableTranscriptSnapshot {
        ReadableTranscriptSnapshot(committedWords: committed, provisionalWords: provisional, audioEndSequence: end, sampleRate: 16_000)
    }
    var session = SessionTranscript()
    session.begin(at: Date(timeIntervalSince1970: 0))
    session.observe(snapshot([word(1, "Bon", 0), word(2, "dia.", 8_000)], [word(3, "Avui", 16_000, committed: false)], end: 20_000))
    // The stabiliser's bounded tail lets the first words go; they stay in the session.
    session.observe(snapshot([word(3, "Avui", 16_000), word(4, "plou.", 24_000)], [word(5, "Mmm", 32_000, committed: false)], end: 36_000))
    // A revision replaces the live tail instead of adding to it.
    session.observe(snapshot([word(3, "Avui", 16_000), word(4, "plou.", 24_000)], [word(6, "Molt", 32_000, committed: false, paragraph: true)], end: 40_000))
    check(session.words.map(\.text), equals: ["Bon", "dia.", "Avui", "plou.", "Molt"], "session keeps words that left the snapshot, once")
    check(session.duration, equals: 2.5, "session duration from the audio clock")
    check(TranscriptExport.paragraphs(session), equals: ["Bon dia. Avui plou.", "Molt"], "session paragraphs")
    check(TranscriptExport.plainText(session), equals: "Bon dia. Avui plou.\n\nMolt\n", "plain text export")

    let srt = TranscriptExport.subRip(session)
    check(srt.hasPrefix("1\n00:00:00,000 --> 00:00:00,500\nBon\n\n2\n00:00:00,500 --> 00:00:01,000\ndia.\n"), "srt cues per word, back to back")
    check(srt.components(separatedBy: " --> ").count - 1, equals: 5, "srt has one cue per word")

    var bridged = SessionTranscript()
    bridged.begin()
    bridged.observe(ReadableTranscriptSnapshot(committedWords: [
        StableTranscriptWord(id: 1, text: "a", isCommitted: true, anchor: 1, startSequence: 0, endSequence: 1_600),
        StableTranscriptWord(id: 2, text: "b", isCommitted: true, anchor: 2, startSequence: 3_200, endSequence: 4_800),
        StableTranscriptWord(id: 3, text: "c", isCommitted: true, anchor: 3),
    ], sampleRate: 16_000))
    check(TranscriptExport.subRip(bridged), equals: "1\n00:00:00,000 --> 00:00:00,200\na\n\n2\n00:00:00,200 --> 00:00:00,300\nb\n\n3\n00:00:00,300 --> 00:00:00,600\nc\n", "srt bridges short gaps and places untimed words after the last")

    let markdown = TranscriptExport.markdown(session)
    check(markdown.hasPrefix("# Transcripció · "), "markdown title")
    check(markdown.contains("*duna · 3 s · 5 paraules*"), "markdown metadata")
    check(TranscriptExport.escapedMarkdown("1. *hola* # _a_"), equals: "1\\. \\*hola\\* \\# \\_a\\_", "markdown escapes formatting")
    check(TranscriptExport.escapedMarkdown("- no"), equals: "\\- no", "markdown keeps a leading dash as text")
    check(TranscriptExport.timestamp(3_723.4567), equals: "01:02:03,457", "srt timestamp")
    check(TranscriptExport.durationLabel(252), equals: "4 min 12 s", "duration label")
    check(TranscriptExport.filename(for: session, format: .subtitles).hasSuffix(".srt"), "export filename")

    session.begin()
    check(session.isEmpty, "a new session starts empty")
}

testTranscriptLedger()
testLatestAudioScheduler()
testProfileSwitchMidSessionKeepsText()
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
testAgeGradientFadesWholeLines()
testPhoneAgeGradientEasesTowardTheOrb()
testOrbAnswersTheVoice()
testLanguageCatalogReadsTheManifest()
testLanguageSuggestionFollowsThePhone()
testForwardRollRetainsRowsForTheAnimationStart()
testAppendDetectionIgnoresPromotionState()
testCommittedWordIdentity()
testLedgerTailWords()
testLiveStreamKeepsSettledTextStill()
testMidHypothesisRevisionKeepsLinesIntact()
private func testSpeechModelCatalog() {
    let manifestURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../Sources/SubtitolLive/Resources/ModelManifest.json")
        .standardizedFileURL
    guard let data = try? Data(contentsOf: manifestURL),
          let catalog = try? JSONDecoder().decode(SpeechModelCatalog.self, from: data) else {
        check(false, "installed manifest decodes as a speech model catalogue")
        return
    }
    check(
        catalog.models.map(\.id),
        equals: ["conformer", "fastconformer-es", "fastconformer-en", "los-gl", "hitz-eu"],
        "one speech model per language"
    )
    check(
        catalog.models.filter(\.writesPunctuation).map(\.id),
        equals: ["fastconformer-es", "fastconformer-en", "los-gl"],
        "the models that write their own punctuation"
    )
    if let languages = try? JSONDecoder().decode(LanguageCatalog.self, from: data) {
        check(
            languages.languages.allSatisfy { catalog.model(id: $0.model) != nil },
            "every language names a model the manifest pins"
        )
    }
    check(catalog.defaultDescriptor.id, equals: "conformer", "the Conformer is the app's model")
    check(catalog.defaultDescriptor.filename, equals: "catalan-conformer-q8.gguf", "the Conformer file")
    check(catalog.models.allSatisfy { $0.sha256.count == 64 }, "every model pins a SHA-256")
    check(catalog.defaultDescriptor.liveWindowSeconds, equals: 7, "Conformer listens to 7 s")
    check(
        catalog.defaultDescriptor.liveWindowSeconds, equals: LiveWindowPolicy.liveWindowSeconds,
        "the manifest and the default window agree"
    )

    let model = { (id: String) in
        SpeechModelDescriptor(id: id, displayName: id, filename: "\(id).gguf", sha256: "", sizeBytes: 1)
    }
    check(
        (try? SpeechModelCatalog(defaultModel: "b", models: [model("a")])) == nil,
        "catalogue rejects an unknown default"
    )
    check(
        (try? SpeechModelCatalog(defaultModel: "a", models: [model("a"), model("a")])) == nil,
        "catalogue rejects duplicate identifiers"
    )
}

private func testCatalanElisionRepair() {
    func words(_ text: String) -> [RecognizedWord] {
        text.split(separator: " ").enumerated().map { index, word in
            RecognizedWord(
                text: String(word),
                startMilliseconds: Int32(index * 100),
                endMilliseconds: Int32(index * 100 + 80),
                confidence: nil
            )
        }
    }
    func repaired(_ text: String) -> String {
        CatalanElisionRepair.repair(words(text)).map(\.text).joined(separator: " ")
    }
    check(repaired("afició per l acordió"), equals: "afició per l'acordió", "article before a vowel")
    check(repaired("és que m encanta"), equals: "és que m'encanta", "pronoun before a vowel")
    check(repaired("ens fa d escapada"), equals: "ens fa d'escapada", "preposition before a vowel")
    check(repaired("m ho diu"), equals: "m'ho diu", "pronoun before h")
    check(repaired("s havia n hi ha t estimo"), equals: "s'havia n'hi ha t'estimo", "s n t elide")
    check(repaired("L Empordà"), equals: "L'Empordà", "case is preserved")
    check(repaired("la m de mare"), equals: "la m de mare", "a letter before a consonant stays")
    check(repaired("m'agrada molt"), equals: "m'agrada molt", "correct elisions are untouched")
    check(repaired("el que a mi"), equals: "el que a mi", "ordinary words are untouched")
    check(repaired("fins a la l"), equals: "fins a la l", "a trailing letter waits for the next window")
    check(repaired("parlem de l l'scratch"), equals: "parlem de l'scratch", "a stuttered elided letter is dropped")
    check(repaired("se n va cap a casa"), equals: "se'n va cap a casa", "a reduced pronoun leans on the one before")
    check(repaired("me l menjo"), equals: "me'l menjo", "reduced article after me")
    check(repaired("la n de nas"), equals: "la n de nas", "a letter after an ordinary word stays")
    let merged = CatalanElisionRepair.repair(words("per l acordió"))
    check(merged.count, equals: 2, "merge removes one word")
    check(merged[1].startMilliseconds, equals: 100, "merged word starts at the elided letter")
    check(merged[1].endMilliseconds, equals: 280, "merged word ends with the host word")
    check(CatalanElisionRepair.repair(text: "per l acordió"), equals: "per l'acordió", "plain-text repair")
}

/// Deterministic stand-in for the Core ML model: each word's label comes from a table.
private final class TablePunctuationPredictor: PunctuationPredicting {
    let table: [String: String]
    private(set) var calls = 0
    init(_ table: [String: String]) { self.table = table }
    func predictions(for words: [String]) -> [PunctuationPrediction]? {
        calls += 1
        return words.map { PunctuationPrediction(certain: PunctuationLabel(modelLabel: table[$0] ?? "l") ?? .plain) }
    }
}

private func testTranscriptFormatter() {
    let spoken = "el vint-i-tres d'abril per sant jordi vam anar a la rambla hi havia molta gent".split(separator: " ").map(String.init)
    let predictor = TablePunctuationPredictor([
        "d'abril": ",l", "sant": "u", "jordi": ",u", "rambla": ".u", "vint-i-tres": "l",
    ])
    func snapshot(heard: Int, committed: Int) -> ReadableTranscriptSnapshot {
        let words = spoken.prefix(heard).enumerated().map { index, text in
            StableTranscriptWord(id: UInt64(index + 1), text: text, isCommitted: index < committed, anchor: UInt64(index))
        }
        return ReadableTranscriptSnapshot(
            committedWords: Array(words.prefix(committed)),
            provisionalWords: Array(words.dropFirst(committed))
        )
    }

    var formatter = TranscriptFormatter()
    var firstFrozenText: [UInt64: String] = [:]
    var everChanged = false
    var lastVisible: [UInt64: String] = [:]
    for heard in 1...spoken.count {
        let formatted = formatter.format(snapshot(heard: heard, committed: max(0, heard - 2)), predictor: predictor)
        for word in formatted.words {
            // A word whose text already carried formatting must never change again.
            if let previous = lastVisible[word.id], previous != word.text, firstFrozenText[word.id] != nil {
                everChanged = true
            }
            if word.text != spoken[Int(word.id) - 1] || word.text.first?.isUppercase == true || word.text.contains(",") {
                firstFrozenText[word.id] = firstFrozenText[word.id] ?? word.text
            }
            lastVisible[word.id] = word.text
        }
    }
    check(!everChanged, "formatted words never change once shown")

    let live = formatter.format(snapshot(heard: spoken.count, committed: spoken.count - 2), predictor: predictor)
    check(live.text, equals: "El 23 d'abril, per Sant Jordi, vam anar a la Rambla. Hi havia molta gent",
          "live text freezes words with three words heard after them")
    check(live.words.count, equals: spoken.count, "a single-word number hides nothing")

    let final = formatter.format(snapshot(heard: spoken.count, committed: spoken.count), isFinal: true, predictor: predictor)
    check(final.text, equals: "El 23 d'abril, per Sant Jordi, vam anar a la Rambla. Hi havia molta gent",
          "final formatting freezes the tail with the model's labels")

    // A multi-word number becomes digits only once it is closed, hiding the absorbed words.
    let year = "l'any mil nou-cents noranta-dos barcelona va organitzar els jocs".split(separator: " ").map(String.init)
    var yearFormatter = TranscriptFormatter()
    let yearPredictor = TablePunctuationPredictor(["barcelona": "u", "jocs": ".l"])
    func yearSnapshot(_ heard: Int) -> ReadableTranscriptSnapshot {
        let words = year.prefix(heard).enumerated().map { index, text in
            StableTranscriptWord(id: UInt64(100 + index), text: text, isCommitted: true, anchor: UInt64(index))
        }
        return ReadableTranscriptSnapshot(committedWords: Array(words))
    }
    let open = yearFormatter.format(yearSnapshot(7), predictor: yearPredictor)
    check(open.text.contains("noranta-dos"), "an unclosed number stays in words")
    let closed = yearFormatter.format(yearSnapshot(9), predictor: yearPredictor)
    check(closed.text, equals: "L'any 1992 Barcelona va organitzar els jocs", "a closed year becomes digits")
    check(closed.words.map(\.id).prefix(3), equals: [100, 101, 104], "absorbed number words are hidden, identities kept")

    // The stabiliser keeps a bounded window. When a number's first word scrolls out, the
    // rest of the number stays hidden: read again from its second word, "mil nou-cents
    // noranta-dos" became "1992 992" on screen and rebuilt the reading pane.
    func scrolled(_ dropped: Int) -> ReadableTranscriptSnapshot {
        let words = year.prefix(9).enumerated().dropFirst(dropped).map { index, text in
            StableTranscriptWord(id: UInt64(100 + index), text: text, isCommitted: true, anchor: UInt64(index))
        }
        return ReadableTranscriptSnapshot(committedWords: Array(words))
    }
    check(yearFormatter.format(scrolled(1), predictor: yearPredictor).text, equals: "1992 Barcelona va organitzar els jocs",
          "a settled number keeps its digits when the words before it scroll out")
    check(yearFormatter.format(scrolled(2), predictor: yearPredictor).text, equals: "Barcelona va organitzar els jocs",
          "the rest of a number stays hidden when its first word scrolls out")
    check(yearFormatter.format(scrolled(3), predictor: yearPredictor).text, equals: "Barcelona va organitzar els jocs",
          "a number's last word stays hidden too")

    // Only marks start sentences: a stray capital after a comma is dropped.
    let comma = "llibres de montserrat roig la meva germana treballa a barcelona i viu".split(separator: " ").map(String.init)
    var commaFormatter = TranscriptFormatter()
    let commaPredictor = TablePunctuationPredictor(["montserrat": "u", "roig": ",u", "la": "u", "barcelona": "u", "viu": ".l"])
    let commaWords = comma.enumerated().map { StableTranscriptWord(id: UInt64(200 + $0.offset), text: $0.element, isCommitted: true, anchor: UInt64($0.offset)) }
    check(commaFormatter.format(ReadableTranscriptSnapshot(committedWords: commaWords), isFinal: true, predictor: commaPredictor).text,
          equals: "Llibres de Montserrat Roig, la meva germana treballa a Barcelona i viu.",
          "an ordinary word capitalised after a comma is lowered; proper nouns keep capitals")
    check(LanguageRules.catalan.isOrdinaryWord("L'ukelele"), "elided words are ordinary")
    check(!LanguageRules.catalan.isOrdinaryWord("Barcelona"), "proper nouns are not ordinary")

    // Without a model the text passes through untouched.
    var bare = TranscriptFormatter()
    check(bare.format(snapshot(heard: 5, committed: 3), predictor: nil).text, equals: "El vint-i-tres d'abril per sant",
          "without a model only the session's first word is capitalised")
}

private func testTranscriptAnnouncer() {
    func word(_ id: UInt64, _ text: String, paragraph: Bool = false) -> StableTranscriptWord {
        StableTranscriptWord(id: id, text: text, isCommitted: true, startsParagraph: paragraph)
    }
    var announcer = TranscriptAnnouncer()
    let onScreen = [word(1, "Ja"), word(2, "hi"), word(3, "era.")]
    announcer.reset(markingSpoken: onScreen)
    check(announcer.observe(committed: onScreen), equals: [], "announcer skips what was on screen")

    var words = onScreen + [word(4, "Bon"), word(5, "dia")]
    check(announcer.observe(committed: words), equals: [], "announcer waits for the phrase to end")
    words += [word(6, "a"), word(7, "tothom.")]
    check(announcer.observe(committed: words), equals: ["Bon dia a tothom."], "announcer reads a sentence once")
    check(announcer.observe(committed: words), equals: [], "announcer never repeats")

    words += [word(8, "Hola"), word(9, "Com", paragraph: true), word(10, "estàs?")]
    check(announcer.observe(committed: words), equals: ["Hola", "Com estàs?"], "a new paragraph closes the phrase")

    words += [word(11, "i"), word(12, "ara")]
    check(announcer.observe(committed: words), equals: [], "an open phrase waits")
    check(announcer.flush(), equals: "i ara", "a quiet moment reads the rest")
    check(announcer.flush(), equals: nil, "nothing left after a flush")

    // The stabiliser drops words from the front; those that remain are still spoken.
    let long = (100..<130).map { word(UInt64($0), "w\($0)") }
    let phrases = announcer.observe(committed: Array(long.suffix(20)))
    check(phrases.count, equals: 1, "a long run is split into phrases")
    check(phrases.first?.split(separator: " ").count, equals: TranscriptAnnouncer.maximumWords, "phrases are bounded")
    check(announcer.flush()?.split(separator: " ").count, equals: 20 - TranscriptAnnouncer.maximumWords, "the rest follows")
}


testReadingFontIsInterMedium()
testReadingTypefacesResolveDistinctFonts()
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
testShortSettledWordsDriftingAFrameAreNotRepeated()
testLastWordBeforeSilenceIsNotRepeated()
testReadableTranscriptPreservesRepeatedBoundaryWords()
testEmptyFinalDropsOnlyStaleProvisionalText()
testReadableTranscriptBoundsLongSessionSnapshots()
testSessionTranscriptKeepsWholeSession()
testSubtitleDocument()
testBurnedCaptions()
testShaderMotionDynamics()
testAudioLevelPeakAccumulator()
testSpeechModelCatalog()
testCatalanElisionRepair()
testTranscriptFormatter()
testRecognizerPunctuation()
testSpanishNumbers()
testGalicianNumbers()
testEnglishNumbers()
testBasqueNumbers()
testFormatterBreaksLinesAtLongPauses()
testSilentWordFilter()
testSilentWordFilterInSteadyNoise()
testNumbersSettleOnlyWhenComplete()
testSilenceTracker()
testFormatterParagraphsAndPauses()
testSpeakerTurns()
testRollUpLayoutParagraphs()
testCatalanNumberNormalizer()
testPartialObservationDoesNotSkipHeardWords()
testOverdueUndecidedWordIsCommittedNotLost()
testUndecidedWordWithoutAgreementIsDropped()
testSpeechPresenceMapDropsWordsWhereNobodySpoke()
testCommittedWordsCarryTheRecognisersConfidence()
testDoubtfulWordsStayUnseenAndGo()
testVocabularyCasingWritesTermsAsGiven()
testTranscriptAnnouncer()
testFilePauseRuleWeighsThePauseMore()
testFileTranscriptionWindowsTileTheRecording()
do {
    try testFileTranscriptionKeepsEveryWordOnce()
    try testFileTranscriptionDropsWordsInSilence()
    try testFileTranscriptionRepairsSkippedSpeech()
    try testFileTranscriptionHearsAnEmptyWindowAgain()
} catch {
    check(false, "file transcription threw \(error)")
}
testFileTranscriptionCanBeCancelled()
testDigitsLastUntilTheirLastSpokenWord()
testPCMRecordingRoundTrip()
testRepairWindowsNeverOverlap()

if testState.failures == 0 {
    print("PASS SubtitolLiveTests")
} else {
    print("FAILED SubtitolLiveTests: \(testState.failures) failure(s)")
    exit(1)
}
