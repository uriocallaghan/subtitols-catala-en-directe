import AVFoundation
import Darwin
import Foundation
import SubtitolCore
import SubtitolEngine
import SubtitolPunctuation
import SubtitolSpeakers

private struct Fixture {
    let samples: [Float]
    let sampleRate: Int32

    var duration: Double { Double(samples.count) / Double(sampleRate) }
}

private struct StrategyResult {
    let name: String
    let snapshot: LatencyDistribution
    let inference: LatencyDistribution
    let wordToFrame: LatencyDistribution
    let stableWordToFrame: LatencyDistribution
    let updates: Int
    let cpuPercent: Double
    let transcript: String
    /// The session's words in order: everything settled, then the last provisional ones.
    let sessionWords: [StableTranscriptWord]
    let committedPrefixViolations: Int
    let provisionalRevisions: Int
    let visibleABAAlternations: Int
    let maximumProvisionalWords: Int
    /// The session as the reader finally sees it, punctuated; empty without a model.
    let formattedTranscript: String
    let formatting: LatencyDistribution
    let reading: ReadingStabilityMeter
}

/// Replays what the reading pane would draw, update by update, and counts every change
/// a reader could notice in text already on screen. Widths are one unit per character
/// in a column `columnCharacters` wide; the layout is the app's own.
private struct ReadingStabilityMeter {
    let columnCharacters: Int
    private var layout = RollUpTranscriptLayout()
    private var previous: [UInt64: RollUpTranscriptLayout.Placement] = [:]
    private(set) var updates = 0
    /// A word already shown changed line.
    private(set) var settledLineJumps = 0
    private(set) var tailLineJumps = 0
    /// A word already shown slid along its line.
    private(set) var settledShifts = 0
    private(set) var tailShifts = 0
    /// A word already shown changed its text.
    private(set) var settledRewrites = 0
    private(set) var tailRewrites = 0
    /// A word already shown disappeared.
    private(set) var settledRemovals = 0
    private(set) var tailRemovals = 0
    /// Updates in which at least one settled word moved: the whole block was rebuilt.
    private(set) var rebuilds = 0
    /// Live words the lane had no room for in an update, summed over updates.
    private(set) var clippedTailWords = 0

    init(columnCharacters: Int) {
        self.columnCharacters = columnCharacters
    }

    mutating func observe(_ snapshot: ReadableTranscriptSnapshot) {
        let words = snapshot.words
        guard !words.isEmpty else { return }
        updates += 1
        let widths = words.map { CGFloat($0.text.count) }
        let placements = layout.update(
            words: words,
            widths: widths,
            metrics: .init(maxWidth: CGFloat(columnCharacters), wordSpacing: 1, fontSize: 1)
        )
        let placedIDs = Set(placements.map(\.id))
        clippedTailWords += words.filter { !$0.isCommitted && !placedIDs.contains($0.id) }.count
        var current: [UInt64: RollUpTranscriptLayout.Placement] = [:]
        var settledMoved = false
        for placement in placements {
            current[placement.id] = placement
            guard let old = previous[placement.id] else { continue }
            if old.line != placement.line {
                if old.isSettled { settledLineJumps += 1; settledMoved = true } else { tailLineJumps += 1 }
            } else if old.x != placement.x {
                if old.isSettled { settledShifts += 1; settledMoved = true } else { tailShifts += 1 }
            }
            if old.text != placement.text {
                if old.isSettled { settledRewrites += 1 } else { tailRewrites += 1 }
            }
        }
        // Only words inside the retained block count; the oldest scroll away by design.
        let oldestAnchor = placements.first?.anchor ?? 0
        for (id, old) in previous where current[id] == nil && old.anchor >= oldestAnchor {
            if old.isSettled { settledRemovals += 1 } else { tailRemovals += 1 }
        }
        if settledMoved { rebuilds += 1 }
        previous = current
    }

    var summary: String {
        "fix: salts de línia \(settledLineJumps) · desplaçaments \(settledShifts) · reescrites \(settledRewrites) · esborrades \(settledRemovals) · reconstruccions \(rebuilds)\n"
            + "                      cua: salts de línia \(tailLineJumps) · desplaçaments \(tailShifts) · reescrites \(tailRewrites) · esborrades \(tailRemovals) · sense lloc \(clippedTailWords) · \(updates) actualitzacions"
    }
}

private enum HarnessError: LocalizedError {
    case usage
    case audio(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            "Ús: SubtitolLatencyHarness MODEL.gguf AUDIO.wav [--profile reliable|balanced|immediate] [--reference-file TEXT] [--max-seconds N] [--refresh-hz N] [--transcript-out FILE] [--fixed-clock] [--skip-baseline] [--window-seconds N] [--punctuation DIR] [--speakers DIR] [--speaker-changes-out FILE] [--formatted-out FILE] [--column-chars N] [--decisions-out FILE] [--batch LIST] [--policy HOP,SHOW,REPLACE,AGE,COMMIT,LAG,OVERDUE[,SHARE[,JUDGE[,RIGHTCONTEXT[,CONFIDENCE]]]]] [--no-speech-gate] [--boost a,b,c] [--enforce]"
        case .audio(let message):
            message
        }
    }
}

private func loadFixture(at url: URL, maximumSeconds: Double) throws -> Fixture {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let maximumFrames = AVAudioFramePosition(maximumSeconds * format.sampleRate)
    let frames = AVAudioFrameCount(min(file.length, maximumFrames))
    guard frames > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
        throw HarnessError.audio("El fitxer d’àudio és buit o incompatible.")
    }
    try file.read(into: buffer, frameCount: frames)
    guard let channels = buffer.floatChannelData else {
        throw HarnessError.audio("El fitxer no es pot llegir com a PCM Float32.")
    }

    let frameCount = Int(buffer.frameLength)
    let channelCount = Int(format.channelCount)
    var mono = [Float](repeating: 0, count: frameCount)
    for frame in 0..<frameCount {
        var value: Float = 0
        for channel in 0..<channelCount {
            value += channels[channel][frame]
        }
        mono[frame] = value / Float(channelCount)
    }
    return Fixture(samples: mono, sampleRate: Int32(format.sampleRate.rounded()))
}

private func snapshot(
    fixture: Fixture,
    endingAt seconds: Double,
    windowSeconds: Double
) -> [Float] {
    let windowCount = Int(windowSeconds * Double(fixture.sampleRate))
    let end = min(fixture.samples.count, Int(seconds * Double(fixture.sampleRate)))
    let realCount = min(end, windowCount)
    var output = [Float](repeating: 0, count: windowCount)
    if realCount > 0 {
        output.replaceSubrange(
            (windowCount - realCount)..<windowCount,
            with: fixture.samples[(end - realCount)..<end]
        )
    }
    return output
}

private func run(
    name: String,
    fixture: Fixture,
    engine: ASREngine? = nil,
    recognize: (([Float], Int, Int) throws -> ASREngine.Transcription)? = nil,
    firstUpdate: Double,
    interval: Double,
    adaptive: Bool,
    refreshHz: Double,
    profile: TranscriptionProfile? = nil,
    fixedClock: Bool = false,
    liveWindowSeconds: Double = LiveWindowPolicy.liveWindowSeconds,
    punctuation: PunctuationPredicting? = nil,
    speakers: SpeakerSegmentationModel? = nil,
    columnCharacters: Int = 34,
    decisionsPath: String? = nil,
    speakerChangesPath: String? = nil,
    language: LanguageRules = .catalan,
    recognizer: RecognizerPunctuation? = nil,
    policyOverride: TranscriptStabilityPolicy? = nil,
    speechGate: Bool = true,
    cache: RecognitionCache? = nil
) throws -> StrategyResult {
    // The recogniser's answers may come from a cache (`--recognition-cache`), keyed by
    // the window's first sample and length, so formatting replays without the GPU.
    let recognize: ([Float], Int, Int) throws -> ASREngine.Transcription = recognize ?? { samples, _, _ in
        guard let engine else { throw HarnessError.audio("Sense motor ni memòria cau de reconeixement.") }
        return try engine.transcribe(samples: samples, sampleRate: fixture.sampleRate)
    }
    // A recogniser that writes its own marks is its own punctuation.
    let punctuation: PunctuationPredicting? = recognizer ?? punctuation
    var reading = ReadingStabilityMeter(columnCharacters: columnCharacters)
    // SUBTITOL_TRACE=FROM-TO (seconds) prints what the recogniser heard and what was shown.
    let traceRange: ClosedRange<Double>? = ProcessInfo.processInfo.environment["SUBTITOL_TRACE"].flatMap { value in
        let parts = value.split(separator: "-").compactMap { Double($0) }
        return parts.count == 2 ? parts[0]...parts[1] : nil
    }
    var position = firstUpdate
    var snapshotTimes: [Double] = []
    var inferenceTimes: [Double] = []
    var wordToFrameTimes: [Double] = []
    var stableWordToFrameTimes: [Double] = []
    var updates = 0
    var newestObservedWordEnd = -Double.infinity
    var latestTranscript = ""
    var stabilizer = policyOverride.map { ReadableTranscriptStabilizer(policy: $0) }
        ?? profile.map { ReadableTranscriptStabilizer(policy: $0) }
        ?? ReadableTranscriptStabilizer()
    var speechGateDrops = 0
    var previousSnapshot = ReadableTranscriptSnapshot()
    var committedPrefixViolations = 0
    var provisionalRevisions = 0
    var visibleABAAlternations = 0
    var previousDistinctVisibleState: [String]?
    var stateBeforePreviousDistinct: [String]?
    var maximumProvisionalWords = 0
    var newestMeasuredCommittedEnd: UInt64 = 0
    // The stabilizer only retains its most recent committed words, so the full session
    // text is rebuilt here from every word the moment it first commits.
    var sessionCommittedWords: [StableTranscriptWord] = []
    var sessionCommittedIDs = Set<UInt64>()
    // What the reader sees: the last formatted text of every word, and which words a
    // number absorbed. Frozen words never change, so the last text seen is final.
    var formatter = TranscriptFormatter(rules: language)
    if decisionsPath != nil { formatter.decisions = [] }
    var formattedText: [UInt64: String] = [:]
    var hiddenIDs = Set<UInt64>()
    var paragraphIDs = Set<UInt64>()
    var formattingTimes: [Double] = []
    var silenceTracker = SilenceTracker()
    var speakerTracker = SpeakerTurnTracker()
    var confirmedChanges = Set<UInt64>()
    func recordFormatted(_ raw: ReadableTranscriptSnapshot, isFinal: Bool) {
        guard let punctuation else {
            reading.observe(raw)
            return
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let formatted = formatter.format(
            raw,
            silences: silenceTracker.map,
            speakers: speakers == nil ? nil : speakerTracker.map,
            isFinal: isFinal,
            predictor: punctuation
        )
        formattingTimes.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        reading.observe(formatted)
        let shown = Set(formatted.words.map(\.id))
        for word in raw.words where !shown.contains(word.id) { hiddenIDs.insert(word.id) }
        for word in formatted.words {
            hiddenIDs.remove(word.id)
            formattedText[word.id] = word.text
            if word.startsParagraph { paragraphIDs.insert(word.id) } else { paragraphIDs.remove(word.id) }
        }
    }
    let wallStarted = DispatchTime.now().uptimeNanoseconds
    let cpuStarted = processCPUSeconds()

    while position <= fixture.duration {
        let window = adaptive
            ? liveWindowSeconds
            : LiveWindowPolicy.finalWindowSeconds
        let snapshotStart = DispatchTime.now().uptimeNanoseconds
        let samples = snapshot(fixture: fixture, endingAt: position, windowSeconds: window)
        let snapshotEnd = DispatchTime.now().uptimeNanoseconds
        snapshotTimes.append(Double(snapshotEnd - snapshotStart) / 1_000_000)

        let windowSampleCount = Int(window * Double(fixture.sampleRate))
        let result = try recognize(samples, Int(position * Double(fixture.sampleRate)) - windowSampleCount, windowSampleCount)
        inferenceTimes.append(result.inferenceMilliseconds)
        if adaptive {
            let endSequence = UInt64(min(
                fixture.samples.count,
                Int(position * Double(fixture.sampleRate))
            ))
            silenceTracker.append(
                fixture.samples[0..<Int(endSequence)],
                endSequence: endSequence,
                sampleRate: fixture.sampleRate
            )
            if let speakers {
                speakerTracker.append(
                    fixture.samples[0..<Int(endSequence)],
                    endSequence: endSequence,
                    sampleRate: fixture.sampleRate
                )
                if let window = speakerTracker.nextWindow(),
                   let classes = cache?.frameClasses(key: "\(window.endSequence)", window.samples, classify: speakers.frameClasses)
                    ?? speakers.frameClasses(window.samples) {
                    speakerTracker.ingest(frameClasses: classes, of: window)
                    confirmedChanges.formUnion(speakerTracker.map.changes)
                }
            }
            let windowSamples = UInt64(window * Double(fixture.sampleRate))
            let realSamples = min(endSequence, windowSamples)
            let sourceStart = endSequence - realSamples
            let paddingMilliseconds = Int32(
                Double(windowSamples - realSamples) / Double(fixture.sampleRate) * 1_000
            )
            let energyKept = SilentWordFilter.voicedIndices(
                result.words,
                samples: samples,
                sampleRate: fixture.sampleRate,
                leadingPaddingSamples: Int(windowSamples - realSamples)
            )
            if ProcessInfo.processInfo.environment["SUBTITOL_TRACE_WORDS"] != nil {
                print("text:", result.text); print("recognised:", result.words.map { "\($0.text)[\($0.startMilliseconds)-\($0.endMilliseconds)]" }.joined(separator: " "), "pad", Int(windowSamples - realSamples), "end", endSequence)
            }
            let adjustedWords = result.words.enumerated().compactMap { index, word -> (word: RecognizedWord, index: Int)? in
                let end = word.endMilliseconds - paddingMilliseconds
                guard end > 0 else { return nil }
                return (RecognizedWord(
                    text: word.text,
                    startMilliseconds: max(0, word.startMilliseconds - paddingMilliseconds),
                    endMilliseconds: end,
                    confidence: word.confidence
                ), index)
            }
            let observed = adjustedWords.map { word, _ in
                TranscriptObservationWord(
                    text: word.text,
                    startSequence: min(
                        sourceStart + UInt64(max(0, word.startMilliseconds))
                            * UInt64(fixture.sampleRate) / 1_000,
                        endSequence
                    ),
                    endSequence: min(
                        sourceStart + UInt64(max(0, word.endMilliseconds))
                            * UInt64(fixture.sampleRate) / 1_000,
                        endSequence
                    ),
                    confidence: word.confidence
                )
            }
            // As in the app: the voice detector decides where it has listened, the energy
            // test elsewhere (`--no-speech-gate` leaves the energy test alone).
            let energyKeptHere = Set(adjustedWords.indices.filter { energyKept.contains(adjustedWords[$0].index) })
            let withVoice = speakers != nil && speechGate
                ? speakerTracker.speech.voicedWords(observed, energyKept: energyKeptHere)
                : observed.indices.filter(energyKeptHere.contains).map { observed[$0] }
            if withVoice.count != observed.count {
                speechGateDrops += observed.count - withVoice.count
                if ProcessInfo.processInfo.environment["SUBTITOL_TRACE_SILENT"] != nil {
                    let kept = Set(withVoice.map(\.startSequence))
                    print("dropped:", observed.filter { !kept.contains($0.startSequence) }.map(\.text), "at", String(format: "%.1f", position))
                }
            }
            let heard = recognizer?.strip(
                withVoice,
                windowStart: sourceStart,
                windowEnd: endSequence,
                sampleRate: fixture.sampleRate,
                includesSessionStart: sourceStart == 0
            ) ?? withVoice
            let snapshot = stabilizer.observe(
                heard,
                audioEndSequence: endSequence,
                sampleRate: fixture.sampleRate,
                windowStartSequence: sourceStart
            )
            if let range = traceRange, range.contains(position) {
                let rate = Double(fixture.sampleRate)
                print(String(format: "t=%.2f heard: ", position) + heard.map { String(format: "%@@%.2f-%.2f", $0.text, Double($0.startSequence) / rate, Double($0.endSequence) / rate) }.joined(separator: " "))
                func stamp(_ word: StableTranscriptWord) -> String {
                    guard let start = word.startSequence, let end = word.endSequence else { return word.text }
                    return String(format: "%@@%.2f-%.2f", word.text, Double(start) / rate, Double(end) / rate)
                }
                print("       shown: " + snapshot.committedWords.suffix(8).map(stamp).joined(separator: " ") + " | " + snapshot.provisionalWords.map(stamp).joined(separator: " "))
            }
            let oldCommitted = previousSnapshot.committedWords
            let newCommitted = snapshot.committedWords
            let oldByID = Dictionary(uniqueKeysWithValues: oldCommitted.map { ($0.id, $0) })
            let sharedWordsChanged = newCommitted.contains { word in
                oldByID[word.id].map { $0 != word } ?? false
            }
            let newIDs = Set(newCommitted.map(\.id))
            let sharedCount = oldCommitted.reduce(0) { count, word in
                count + (newIDs.contains(word.id) ? 1 : 0)
            }
            let retainedOverlapIsSuffixPrefix: Bool
            if oldCommitted.isEmpty {
                retainedOverlapIsSuffixPrefix = true
            } else if sharedCount == 0 {
                retainedOverlapIsSuffixPrefix = newCommitted.first.map {
                    $0.anchor > (oldCommitted.last?.anchor ?? 0)
                } ?? true
            } else {
                retainedOverlapIsSuffixPrefix =
                    oldCommitted.suffix(sharedCount).map(\.id)
                    == newCommitted.prefix(sharedCount).map(\.id)
            }
            let anchors = newCommitted.map(\.anchor)
            let orderIsMonotonic = zip(anchors, anchors.dropFirst()).allSatisfy(<)
            if sharedWordsChanged || !retainedOverlapIsSuffixPrefix || !orderIsMonotonic {
                committedPrefixViolations += 1
            }
            let oldProvisional = previousSnapshot.provisionalWords.map(\.text)
            let newProvisional = snapshot.provisionalWords.map(\.text)
            if !oldProvisional.isEmpty,
               oldProvisional != newProvisional,
               !newProvisional.starts(with: oldProvisional) {
                provisionalRevisions += 1
            }
            if previousDistinctVisibleState != newProvisional {
                if newProvisional == stateBeforePreviousDistinct,
                   newProvisional != previousDistinctVisibleState {
                    visibleABAAlternations += 1
                }
                stateBeforePreviousDistinct = previousDistinctVisibleState
                previousDistinctVisibleState = newProvisional
            }
            maximumProvisionalWords = max(
                maximumProvisionalWords,
                snapshot.provisionalWords.count
            )
            if let visibleEnd = snapshot.latestVisibleEndSequence,
               visibleEnd > newestMeasuredCommittedEnd {
                newestMeasuredCommittedEnd = visibleEnd
                stableWordToFrameTimes.append(
                    Double(endSequence - visibleEnd) / Double(fixture.sampleRate) * 1_000
                        + result.inferenceMilliseconds
                        + 1 / refreshHz * 1_000
                )
            }
            previousSnapshot = snapshot
            recordFormatted(snapshot, isFinal: false)
            for word in snapshot.committedWords where sessionCommittedIDs.insert(word.id).inserted {
                sessionCommittedWords.append(word)
            }
            latestTranscript = (sessionCommittedWords + snapshot.provisionalWords)
                .map(\.text)
                .joined(separator: " ")
        } else {
            latestTranscript = result.text
        }
        updates += 1

        if let newestWord = result.words.last {
            let absoluteWordEnd = position - window + Double(newestWord.endMilliseconds) / 1_000
            if absoluteWordEnd > newestObservedWordEnd + 0.001 {
                newestObservedWordEnd = absoluteWordEnd
                let visibleAt = position
                    + result.inferenceMilliseconds / 1_000
                    + 1 / refreshHz
                wordToFrameTimes.append(max(0, (visibleAt - absoluteWordEnd) * 1_000))
            }
        }

        let inferenceSeconds = result.inferenceMilliseconds / 1_000
        // A fixed clock replays identical windows regardless of machine load, so two
        // models can be compared on the same observations.
        position += fixedClock ? interval : max(interval, inferenceSeconds)
    }

    if adaptive, ProcessInfo.processInfo.environment["SUBTITOL_TRACE"] != nil {
        print("  respostes parcials ignorades \(stabilizer.ignoredPartialObservations) · paraules consolidades per edat \(stabilizer.overdueCommits)")
    }
    recordFormatted(previousSnapshot, isFinal: true)
    if let speakerChangesPath {
        let seconds = confirmedChanges.sorted().map { String(format: "%.3f", Double($0) / Double(fixture.sampleRate)) }
        try (seconds.joined(separator: "\n") + "\n").write(toFile: speakerChangesPath, atomically: true, encoding: .utf8)
    }
    if let decisionsPath, let decisions = formatter.decisions {
        try writeDecisions(decisions, to: decisionsPath)
    }
    let formattedTranscript = punctuation == nil ? "" : (sessionCommittedWords + previousSnapshot.provisionalWords)
        .filter { !hiddenIDs.contains($0.id) }
        .map { (paragraphIDs.contains($0.id) ? "¶ " : "") + (formattedText[$0.id] ?? $0.text) }
        .joined(separator: " ")
    let wallFinished = DispatchTime.now().uptimeNanoseconds
    let wallSeconds = Double(wallFinished - wallStarted) / 1_000_000_000
    let cpuSeconds = processCPUSeconds() - cpuStarted
    if adaptive, speechGateDrops > 0 || stabilizer.overdueDrops > 0 || stabilizer.overdueCommits > 0 {
        print("  filtres: detector de veu \(speechGateDrops) paraules descartades · indecises descartades \(stabilizer.overdueDrops) · indecises consolidades \(stabilizer.overdueCommits)")
    }
    return StrategyResult(
        name: name,
        snapshot: LatencyDistribution(samples: snapshotTimes),
        inference: LatencyDistribution(samples: inferenceTimes),
        wordToFrame: LatencyDistribution(samples: wordToFrameTimes),
        stableWordToFrame: LatencyDistribution(samples: stableWordToFrameTimes),
        updates: updates,
        cpuPercent: wallSeconds > 0 ? cpuSeconds / wallSeconds * 100 : 0,
        transcript: latestTranscript,
        sessionWords: sessionCommittedWords + previousSnapshot.provisionalWords,
        committedPrefixViolations: committedPrefixViolations,
        provisionalRevisions: provisionalRevisions,
        visibleABAAlternations: visibleABAAlternations,
        maximumProvisionalWords: maximumProvisionalWords,
        formattedTranscript: formattedTranscript,
        formatting: LatencyDistribution(samples: formattingTimes),
        reading: reading
    )
}

/// What the recogniser and the voice change detector answered for one recording, saved
/// so formatting can be replayed without the GPU (`--recognition-cache DIR`). Only the
/// models' answers are saved: everything after them runs as in the app. Recognition is
/// keyed by the window's first sample and length; the detector is asked in order.
private final class RecognitionCache: @unchecked Sendable {
    private let url: URL
    private var windows: [String: [[String]]] = [:]
    private var speakers: [String?] = []
    private var speakersByKey: [String: String] = [:]
    private var speakerIndex = 0
    private var changed = false
    private let lock = NSLock()

    init(directory: String, name: String) {
        url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".cache.json")
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            windows = object["windows"] as? [String: [[String]]] ?? [:]
            speakers = (object["speakers"] as? [Any])?.map { $0 as? String } ?? []
            speakersByKey = object["speakersByKey"] as? [String: String] ?? [:]
        }
    }

    /// The detector's answer for the window ending at `key`, for the live replay, whose
    /// windows depend on the hop.
    func frameClasses(key: String, _ samples: [Float], classify: ([Float]) -> [Int]?) -> [Int]? {
        lock.lock()
        let saved = speakersByKey[key]
        lock.unlock()
        if let saved { return saved.compactMap { $0.wholeNumberValue } }
        guard let classes = classify(samples) else { return nil }
        precondition(classes.allSatisfy { (0...9).contains($0) })
        lock.lock()
        speakersByKey[key] = classes.map(String.init).joined()
        changed = true
        lock.unlock()
        return classes
    }

    func words(offset: Int, count: Int, recognize: () throws -> [RecognizedWord]) rethrows -> [RecognizedWord] {
        let key = "\(offset):\(count)"
        if let saved = windows[key] {
            return saved.map { RecognizedWord(text: $0[0], startMilliseconds: Int32($0[1]) ?? 0, endMilliseconds: Int32($0[2]) ?? 0, confidence: Float($0[3])) }
        }
        let words = try recognize()
        windows[key] = words.map { [$0.text, String($0.startMilliseconds), String($0.endMilliseconds), $0.confidence.map { String($0) } ?? ""] }
        changed = true
        return words
    }

    func frameClasses(_ samples: [Float], classify: ([Float]) -> [Int]?) -> [Int]? {
        lock.lock()
        let index = speakerIndex
        speakerIndex += 1
        let saved = index < speakers.count ? speakers[index] : nil
        lock.unlock()
        if index < speakers.count {
            return saved.map { $0.compactMap { $0.wholeNumberValue } }
        }
        let classes = classify(samples)
        // Classes are 0...6 (pyannote's powerset), one digit each.
        precondition(classes?.allSatisfy { (0...9).contains($0) } ?? true)
        lock.lock()
        speakers.append(classes.map { $0.map(String.init).joined() })
        changed = true
        lock.unlock()
        return classes
    }

    func save() throws {
        guard changed else { return }
        let object: [String: Any] = ["windows": windows, "speakers": speakers.map { $0 as Any? ?? NSNull() }, "speakersByKey": speakersByKey]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
}

/// One JSON line per frozen word: the model's view, the pause after it and the label.
private func writeDecisions(_ decisions: [TranscriptFormatter.Decision], to path: String) throws {
    let lines = decisions.map { decision -> String in
        let marks = PunctuationLabel.Mark.allCases.map { mark in
            String(format: "\"%@\":%.5f", mark.rawValue, decision.prediction.probability(of: mark))
        }.joined(separator: ",")
        let pause = decision.pauseAfter.map { String(format: "%.3f", $0) } ?? "null"
        let word = decision.word.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
        let span = "\"start\":\(decision.startSequence.map(String.init) ?? "null"),\"end\":\(decision.endSequence.map(String.init) ?? "null"),"
        return "{\"word\":\"\(word)\",\(span)\"best\":\"\(decision.prediction.best.mark.rawValue)\(decision.prediction.best.casing.rawValue)\",\"label\":\"\(decision.label.mark.rawValue)\(decision.label.casing.rawValue)\",\"pause\":\(pause),\"after\":\(decision.wordsHeardAfter),\"turn\":\(decision.turnEnds),\"marks\":{\(marks)}}"
    }
    try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
}

private func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

private func processCPUSeconds() -> Double {
    var time = timespec()
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time)
    return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
}

private func format(_ value: Double?) -> String {
    value.map { String(format: "%.1f", $0) } ?? "n/a"
}

private func printResult(_ result: StrategyResult) {
    print("\(result.name): \(result.updates) actualitzacions")
    print("  captura→snapshot  P50 \(format(result.snapshot.p50)) ms · P95 \(format(result.snapshot.p95)) ms · max \(format(result.snapshot.maximum)) ms")
    print("  inferència         P50 \(format(result.inference.p50)) ms · P95 \(format(result.inference.p95)) ms · max \(format(result.inference.maximum)) ms")
    print("  paraula→frame      P50 \(format(result.wordToFrame.p50)) ms · P95 \(format(result.wordToFrame.p95)) ms · max \(format(result.wordToFrame.maximum)) ms")
    if result.stableWordToFrame.count > 0 {
        print("  estable→frame       P50 \(format(result.stableWordToFrame.p50)) ms · P95 \(format(result.stableWordToFrame.p95)) ms · max \(format(result.stableWordToFrame.maximum)) ms")
    }
    print("  estabilitat visual  prefix \(result.committedPrefixViolations) · revisions cua \(result.provisionalRevisions) · A/B/A \(result.visibleABAAlternations) · cua màx \(result.maximumProvisionalWords)")
    print(String(format: "  CPU procés         %.1f%% · GPU Metal", result.cpuPercent))
    if result.reading.updates > 0 {
        print("  lectura (\(result.reading.columnCharacters) car.) \(result.reading.summary)")
    }
    if result.formatting.count > 0 {
        print("  puntuació          P50 \(format(result.formatting.p50)) ms · P95 \(format(result.formatting.p95)) ms · max \(format(result.formatting.maximum)) ms")
    }
}

private func runHarness() -> Int32 {
do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 2 else { throw HarnessError.usage }
    let maximumSeconds = Double(value(after: "--max-seconds", in: arguments) ?? "8") ?? 8
    let refreshHz = Double(value(after: "--refresh-hz", in: arguments) ?? "60") ?? 60
    let enforceThresholds = arguments.contains("--enforce")
    let fixedClock = arguments.contains("--fixed-clock")
    let skipBaseline = arguments.contains("--skip-baseline")
    let punctuation = try value(after: "--punctuation", in: arguments).map {
        try PunctuationModel(directory: URL(fileURLWithPath: $0))
    }
    let speakers = try value(after: "--speakers", in: arguments).map {
        try SpeakerSegmentationModel(directory: URL(fileURLWithPath: $0))
    }
    let liveWindowSeconds = Double(value(after: "--window-seconds", in: arguments) ?? "")
        ?? LiveWindowPolicy.liveWindowSeconds
    let referencePath = value(after: "--reference-file", in: arguments)
    let profileName = value(after: "--profile", in: arguments) ?? TranscriptionProfile.default.rawValue
    guard let profile = TranscriptionProfile(rawValue: profileName) else {
        throw HarnessError.usage
    }
    // --policy HOP,SHOW,REPLACE,AGE,COMMIT,LAG,OVERDUE replaces the profile's thresholds
    // (seconds and counts), to try others without changing the app.
    let policyOverride: TranscriptStabilityPolicy? = value(after: "--policy", in: arguments).flatMap { text in
        let parts = text.split(separator: ",").compactMap { Double($0) }
        guard (7...11).contains(parts.count) else { return nil }
        return TranscriptStabilityPolicy(
            minimumHopSeconds: parts[0], initialEvidenceRequired: Int(parts[1]), replacementEvidenceRequired: Int(parts[2]),
            minimumWordAgeSeconds: parts[3], commitEvidenceRequired: Int(parts[4]), commitLagSeconds: parts[5],
            overdueEvidenceRequired: Int(parts[6]), overdueMajorityShare: parts.count >= 8 ? parts[7] : 0,
            overdueHearingsToJudge: parts.count >= 9 ? Int(parts[8]) : 2,
            minimumRightContextSeconds: parts.count >= 10 ? parts[9] : 0,
            minimumConfidence: parts.count == 11 ? Float(parts[10]) : 0
        )
    }
    let speechGate = !arguments.contains("--no-speech-gate")
    let hopSeconds = policyOverride?.minimumHopSeconds ?? profile.policy.minimumHopSeconds
    guard maximumSeconds > 0, refreshHz > 0, liveWindowSeconds > 0 else { throw HarnessError.usage }

    // --punctuation-bench: milliseconds per call of the punctuation model, by length.
    if arguments.contains("--punctuation-bench"), let punctuation {
        let words = "el que volem dir és que la llengua catalana té moltes paraules i no pas poques".split(separator: " ").map(String.init)
        for round in 0..<2 {
            var line = "ronda \(round):"
            for length in stride(from: 20, through: 80, by: 3) {
                let input = (0..<length).map { words[$0 % words.count] }
                let started = DispatchTime.now().uptimeNanoseconds
                _ = punctuation.predictions(for: input)
                line += String(format: " %d:%.0f", length, Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            }
            print(line)
        }
        return 0
    }
    let language = LanguageRules.forLanguage(value(after: "--language", in: arguments) ?? "ca")
    // The model writes its own marks and capitals (es, en, gl): they are read instead
    // of a punctuation model.
    let readsRecognizerPunctuation = arguments.contains("--recognizer-punctuation")
    let modelURL = URL(fileURLWithPath: arguments[0])
    // Batch: AUDIO is a list of "WAV<TAB>OUTPUT_PREFIX" lines, replayed with one model load.
    // Each writes PREFIX.txt (formatted), PREFIX_raw.txt and, with punctuation, PREFIX.jsonl.
    if let batchPath = value(after: "--batch", in: arguments) {
        // Loaded when first needed: a replay from --recognition-cache never needs it.
        var loadedEngine: ASREngine?
        // --boost "nom,terme,…": the vocabulary of the day, as the app's panel sets it.
        let boosted = value(after: "--boost", in: arguments)?.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } ?? []
        func engine() throws -> ASREngine {
            if let loadedEngine { return loadedEngine }
            let engine = try ASREngine(modelURL: modelURL, repairsCatalanElisions: language.id == "ca")
            try engine.warmUp(windowSeconds: [liveWindowSeconds, LiveWindowPolicy.finalWindowSeconds])
            if !boosted.isEmpty {
                engine.setBoostedPhrases(boosted, boost: Float(value(after: "--boost-strength", in: arguments) ?? "") ?? 4)
            }
            loadedEngine = engine
            return engine
        }
        let jobs = try String(contentsOfFile: batchPath, encoding: .utf8).split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
        // --file-mode: the whole-file transcriber the app's import runs, instead of the
        // live replay. --file-window SECONDS sets its window.
        if arguments.contains("--file-mode") {
            var configuration = FileTranscriber.Configuration()
            if let seconds = value(after: "--file-window", in: arguments).flatMap(Double.init) {
                configuration.windowSeconds = seconds
            }
            if let seconds = value(after: "--file-context", in: arguments).flatMap(Double.init) {
                configuration.contextSeconds = seconds
            }
            if value(after: "--pause-rule", in: arguments) == "live" {
                configuration.pauseRule = .live
            }
            var transcriber = FileTranscriber(rules: language, configuration: configuration)
            if ProcessInfo.processInfo.environment["SUBTITOL_TRACE_HOLES"] != nil {
                transcriber.trace = { print($0) }
            }
            for job in jobs where job.count == 2 {
                let fixture = try loadFixture(at: URL(fileURLWithPath: job[0]), maximumSeconds: maximumSeconds)
                let recording = PCMRecording(floats: fixture.samples, sampleRate: fixture.sampleRate)
                let started = DispatchTime.now().uptimeNanoseconds
                var recognitionSeconds = 0.0
                let cache = value(after: "--recognition-cache", in: arguments).map {
                    RecognitionCache(directory: $0, name: URL(fileURLWithPath: job[1]).lastPathComponent)
                }
                transcriber.decisions = arguments.contains("--decisions") ? [] : nil
                let result = try transcriber.transcribe(
                    recording,
                    recognize: { samples, offset in
                        let hear = {
                            let transcription = try engine().transcribe(samples: samples, sampleRate: fixture.sampleRate)
                            recognitionSeconds += transcription.inferenceMilliseconds / 1_000
                            return transcription.words
                        }
                        return try cache?.words(offset: offset, count: samples.count, recognize: hear) ?? hear()
                    },
                    predictor: punctuation ?? (readsRecognizerPunctuation ? nil : PlainPunctuation()),
                    recognizerMarks: readsRecognizerPunctuation ? RecognizerPunctuation() : nil,
                    speakers: speakers.map { model in
                        { samples in
                            guard let cache else { return model.frameClasses(samples) }
                            return cache.frameClasses(samples) { model.frameClasses($0) }
                        }
                    }
                )
                try cache?.save()
                if let decisions = result.decisions {
                    try writeDecisions(decisions, to: job[1] + ".jsonl")
                }
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
                let formatted = result.session.words
                    .map { ($0.startsParagraph ? "¶ " : "") + $0.text }
                    .joined(separator: " ")
                try (formatted + "\n").write(toFile: job[1] + ".txt", atomically: true, encoding: .utf8)
                try (result.heardWords.joined(separator: " ") + "\n").write(toFile: job[1] + "_raw.txt", atomically: true, encoding: .utf8)
                try TranscriptExport.subRip(result.session).write(toFile: job[1] + ".srt", atomically: true, encoding: .utf8)
                print(String(
                    format: "%@ · %.1f s d'àudio en %.2f s (reconeixement %.2f s) · %.0f× temps real · %d paraules recuperades · %d finestres (%d normals)",
                    job[1], recording.duration, seconds, recognitionSeconds, recording.duration / max(seconds, 0.001), result.repairedWords, result.decodedWindows, transcriber.windows(for: recording).count
                ))
            }
            return 0
        }
        for job in jobs where job.count == 2 {
            let fixture = try loadFixture(at: URL(fileURLWithPath: job[0]), maximumSeconds: maximumSeconds)
            let cache = value(after: "--recognition-cache", in: arguments).map {
                RecognitionCache(directory: $0, name: URL(fileURLWithPath: job[1]).lastPathComponent)
            }
            let recognize: ([Float], Int, Int) throws -> ASREngine.Transcription = { samples, offset, count in
                let hear = { try engine().transcribe(samples: samples, sampleRate: fixture.sampleRate) }
                guard let cache else { return try hear() }
                var milliseconds = 0.0
                let words = try cache.words(offset: offset, count: count) {
                    let heard = try hear()
                    milliseconds = heard.inferenceMilliseconds
                    return heard.words
                }
                return ASREngine.Transcription(
                    text: words.map(\.text).joined(separator: " "), words: words,
                    audioDuration: Double(count) / Double(fixture.sampleRate), inferenceMilliseconds: milliseconds
                )
            }
            let result = try run(
                name: job[0], fixture: fixture, recognize: recognize,
                firstUpdate: LiveWindowPolicy.minimumAudioSeconds, interval: hopSeconds,
                adaptive: true, refreshHz: refreshHz, profile: profile, fixedClock: fixedClock,
                liveWindowSeconds: liveWindowSeconds, punctuation: punctuation, speakers: speakers,
                decisionsPath: punctuation == nil && !readsRecognizerPunctuation ? nil : job[1] + ".jsonl",
                language: language,
                recognizer: readsRecognizerPunctuation ? RecognizerPunctuation() : nil,
                policyOverride: policyOverride, speechGate: speechGate, cache: cache
            )
            try cache?.save()
            try (result.formattedTranscript + "\n").write(toFile: job[1] + ".txt", atomically: true, encoding: .utf8)
            try (result.transcript + "\n").write(toFile: job[1] + "_raw.txt", atomically: true, encoding: .utf8)
            // Every word the reader finally has, with the recogniser's confidence, for calibration.
            let rate = Double(fixture.sampleRate)
            let lines = result.sessionWords.map { word -> String in
                let text = word.text.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
                return String(format: "{\"word\":\"%@\",\"start\":%.3f,\"end\":%.3f,\"confidence\":%@}",
                              text, Double(word.startSequence ?? 0) / rate, Double(word.endSequence ?? 0) / rate,
                              word.confidence.map { String(format: "%.4f", $0) } ?? "null")
            }
            try (lines.joined(separator: "\n") + "\n").write(toFile: job[1] + "_words.jsonl", atomically: true, encoding: .utf8)
            print(String(format: "%@ · inferència P50 %.0f ms · %d actualitzacions", job[1], result.inference.p50 ?? 0, result.updates))
        }
        return 0
    }
    let audioURL = URL(fileURLWithPath: arguments[1])
    let fixture = try loadFixture(at: audioURL, maximumSeconds: maximumSeconds)
    print(String(format: "Corpus: %.2f s · %d Hz · 1 canal normalitzat", fixture.duration, fixture.sampleRate))

    let engine = try ASREngine(modelURL: modelURL, repairsCatalanElisions: language.id == "ca")
    try engine.warmUp(windowSeconds: [liveWindowSeconds, LiveWindowPolicy.finalWindowSeconds])
    let baseline: StrategyResult? = skipBaseline ? nil : try run(
        name: "Baseline Timer 350 ms / finestra 6 s",
        fixture: fixture,
        engine: engine,
        firstUpdate: 0.35,
        interval: 0.35,
        adaptive: false,
        refreshHz: refreshHz,
        fixedClock: fixedClock
    )
    let latestWins = try run(
        name: String(format: "Perfil %@ / context fix %.1f s / histèresi", profile.displayName, liveWindowSeconds),
        fixture: fixture,
        engine: engine,
        firstUpdate: LiveWindowPolicy.minimumAudioSeconds,
        interval: hopSeconds,
        adaptive: true,
        refreshHz: refreshHz,
        profile: profile,
        fixedClock: fixedClock,
        liveWindowSeconds: liveWindowSeconds,
        punctuation: punctuation,
        speakers: speakers,
        columnCharacters: Int(value(after: "--column-chars", in: arguments) ?? "34") ?? 34,
        decisionsPath: value(after: "--decisions-out", in: arguments),
        speakerChangesPath: value(after: "--speaker-changes-out", in: arguments),
        language: language,
        recognizer: readsRecognizerPunctuation ? RecognizerPunctuation() : nil,
        policyOverride: policyOverride, speechGate: speechGate
    )

    if let baseline { printResult(baseline) }
    printResult(latestWins)
    if let formattedPath = value(after: "--formatted-out", in: arguments) {
        try (latestWins.formattedTranscript + "\n").write(toFile: formattedPath, atomically: true, encoding: .utf8)
    }
    if let transcriptPath = value(after: "--transcript-out", in: arguments) {
        try (latestWins.transcript + "\n").write(
            toFile: transcriptPath,
            atomically: true,
            encoding: .utf8
        )
    }
    var failedThreshold = false
    if latestWins.committedPrefixViolations > 0 || latestWins.maximumProvisionalWords > 3 {
        fputs("AVÍS: s'ha trencat un invariant visual del transcript estable.\n", stderr)
        failedThreshold = true
    }
    if profile == .reliable, latestWins.visibleABAAlternations > 0 {
        fputs("AVÍS: el perfil Fiable ha mostrat una alternança visible A/B/A.\n", stderr)
        failedThreshold = true
    }
    let targetP95: Double = switch profile {
    case .reliable: 1_200
    case .balanced: 800
    case .immediate: 500
    }
    if let stableP95 = latestWins.stableWordToFrame.p95, stableP95 > targetP95 {
        fputs("AVÍS: la latència P95 fins a text visible supera l'objectiu del perfil (\(Int(targetP95)) ms).\n", stderr)
        failedThreshold = true
    } else if enforceThresholds, latestWins.stableWordToFrame.p95 == nil {
        fputs("AVÍS: no hi ha mostres de latència visible per validar.\n", stderr)
        failedThreshold = true
    }
    if let baseline,
       let oldP50 = baseline.wordToFrame.p50,
       let newP50 = latestWins.wordToFrame.p50,
       let oldP95 = baseline.wordToFrame.p95,
       let newP95 = latestWins.wordToFrame.p95 {
        let p50Reduction = (oldP50 - newP50) / oldP50 * 100
        let p95Reduction = (oldP95 - newP95) / oldP95 * 100
        print(String(format: "Reducció paraula→frame: P50 %.1f%% · P95 %.1f%%", p50Reduction, p95Reduction))
        if p50Reduction < 30 || p95Reduction < 40 {
            fputs("AVÍS: el corpus/dispositiu no arriba als llindars 30%%/40%%.\n", stderr)
            failedThreshold = true
        }
    } else if enforceThresholds {
        fputs("AVÍS: no hi ha prou mostres per comparar latència baseline/nova.\n", stderr)
        failedThreshold = true
    }
    if let referencePath {
        guard fixture.duration <= LiveWindowPolicy.finalWindowSeconds else {
            throw HarnessError.audio(
                "La referència WER ha de correspondre a un segment de 6 s o menys."
            )
        }
        let reference = try String(contentsOfFile: referencePath, encoding: .utf8)
        let finalSamples = Array(fixture.samples.suffix(
            Int(min(fixture.duration, LiveWindowPolicy.finalWindowSeconds) * Double(fixture.sampleRate))
        ))
        let final = try engine.transcribe(samples: finalSamples, sampleRate: fixture.sampleRate)
        let provisionalWER = WordErrorRate.score(
            reference: reference,
            hypothesis: latestWins.transcript
        )
        let baselineWER = baseline.map {
            String(format: "%.2f%%", WordErrorRate.score(reference: reference, hypothesis: $0.transcript) * 100)
        } ?? "n/a"
        let finalWER = WordErrorRate.score(reference: reference, hypothesis: final.text)
        let degradationPoints = (provisionalWER - finalWER) * 100
        print(String(
            format: "WER baseline %@ · nova %.2f%% · final 6 s %.2f%% · nova-final %.2f punts",
            baselineWER,
            provisionalWER * 100,
            finalWER * 100,
            degradationPoints
        ))
        if degradationPoints > 2 {
            fputs("AVÍS: la WER provisional empitjora més de 2 punts absoluts.\n", stderr)
            failedThreshold = true
        }
    }
    print("Overruns d’àudio: 0 (injecció PCM determinista; l’app compta discontinuïtats reals)")
    if enforceThresholds && failedThreshold { return 2 }
    return 0
} catch {
    fputs("ERROR: \(error.localizedDescription)\n", stderr)
    return 1
}
}

exit(runHarness())
