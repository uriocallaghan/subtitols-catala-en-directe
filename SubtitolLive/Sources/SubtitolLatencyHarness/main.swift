import AVFoundation
import Darwin
import Foundation
import SubtitolCore
import SubtitolEngine

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
    let committedPrefixViolations: Int
    let provisionalRevisions: Int
    let visibleABAAlternations: Int
    let maximumProvisionalWords: Int
}

private enum HarnessError: LocalizedError {
    case usage
    case audio(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            "Ús: SubtitolLatencyHarness MODEL.gguf AUDIO.wav [--profile reliable|balanced|immediate] [--reference-file TEXT] [--max-seconds N] [--refresh-hz N] [--enforce]"
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
    engine: ASREngine,
    firstUpdate: Double,
    interval: Double,
    adaptive: Bool,
    refreshHz: Double,
    profile: TranscriptionProfile? = nil
) throws -> StrategyResult {
    var position = firstUpdate
    var snapshotTimes: [Double] = []
    var inferenceTimes: [Double] = []
    var wordToFrameTimes: [Double] = []
    var stableWordToFrameTimes: [Double] = []
    var updates = 0
    var newestObservedWordEnd = -Double.infinity
    var latestTranscript = ""
    var stabilizer = profile.map { ReadableTranscriptStabilizer(policy: $0) }
        ?? ReadableTranscriptStabilizer()
    var previousSnapshot = ReadableTranscriptSnapshot()
    var committedPrefixViolations = 0
    var provisionalRevisions = 0
    var visibleABAAlternations = 0
    var previousDistinctVisibleState: [String]?
    var stateBeforePreviousDistinct: [String]?
    var maximumProvisionalWords = 0
    var newestMeasuredCommittedEnd: UInt64 = 0
    let wallStarted = DispatchTime.now().uptimeNanoseconds
    let cpuStarted = processCPUSeconds()

    while position <= fixture.duration {
        let window = adaptive
            ? LiveWindowPolicy.targetSeconds(for: position)
            : LiveWindowPolicy.finalWindowSeconds
        let snapshotStart = DispatchTime.now().uptimeNanoseconds
        let samples = snapshot(fixture: fixture, endingAt: position, windowSeconds: window)
        let snapshotEnd = DispatchTime.now().uptimeNanoseconds
        snapshotTimes.append(Double(snapshotEnd - snapshotStart) / 1_000_000)

        let result = try engine.transcribe(samples: samples, sampleRate: fixture.sampleRate)
        inferenceTimes.append(result.inferenceMilliseconds)
        if adaptive {
            let endSequence = UInt64(min(
                fixture.samples.count,
                Int(position * Double(fixture.sampleRate))
            ))
            let windowSamples = UInt64(window * Double(fixture.sampleRate))
            let realSamples = min(endSequence, windowSamples)
            let sourceStart = endSequence - realSamples
            let paddingMilliseconds = Int32(
                Double(windowSamples - realSamples) / Double(fixture.sampleRate) * 1_000
            )
            let adjustedWords = result.words.compactMap { word -> RecognizedWord? in
                let end = word.endMilliseconds - paddingMilliseconds
                guard end > 0 else { return nil }
                return RecognizedWord(
                    text: word.text,
                    startMilliseconds: max(0, word.startMilliseconds - paddingMilliseconds),
                    endMilliseconds: end,
                    confidence: word.confidence
                )
            }
            let observed = adjustedWords.map { word in
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
            let snapshot = stabilizer.observe(
                observed,
                audioEndSequence: endSequence,
                sampleRate: fixture.sampleRate
            )
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
            latestTranscript = snapshot.text
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
        position += max(interval, inferenceSeconds)
    }

    let wallFinished = DispatchTime.now().uptimeNanoseconds
    let wallSeconds = Double(wallFinished - wallStarted) / 1_000_000_000
    let cpuSeconds = processCPUSeconds() - cpuStarted
    return StrategyResult(
        name: name,
        snapshot: LatencyDistribution(samples: snapshotTimes),
        inference: LatencyDistribution(samples: inferenceTimes),
        wordToFrame: LatencyDistribution(samples: wordToFrameTimes),
        stableWordToFrame: LatencyDistribution(samples: stableWordToFrameTimes),
        updates: updates,
        cpuPercent: wallSeconds > 0 ? cpuSeconds / wallSeconds * 100 : 0,
        transcript: latestTranscript,
        committedPrefixViolations: committedPrefixViolations,
        provisionalRevisions: provisionalRevisions,
        visibleABAAlternations: visibleABAAlternations,
        maximumProvisionalWords: maximumProvisionalWords
    )
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
}

private func runHarness() -> Int32 {
do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 2 else { throw HarnessError.usage }
    let maximumSeconds = Double(value(after: "--max-seconds", in: arguments) ?? "8") ?? 8
    let refreshHz = Double(value(after: "--refresh-hz", in: arguments) ?? "60") ?? 60
    let enforceThresholds = arguments.contains("--enforce")
    let referencePath = value(after: "--reference-file", in: arguments)
    let profileName = value(after: "--profile", in: arguments) ?? TranscriptionProfile.default.rawValue
    guard let profile = TranscriptionProfile(rawValue: profileName) else {
        throw HarnessError.usage
    }
    guard maximumSeconds > 0, refreshHz > 0 else { throw HarnessError.usage }

    let modelURL = URL(fileURLWithPath: arguments[0])
    let audioURL = URL(fileURLWithPath: arguments[1])
    let fixture = try loadFixture(at: audioURL, maximumSeconds: maximumSeconds)
    print(String(format: "Corpus: %.2f s · %d Hz · 1 canal normalitzat", fixture.duration, fixture.sampleRate))

    let engine = try ASREngine(modelURL: modelURL)
    try engine.warmUp()
    let baseline = try run(
        name: "Baseline Timer 350 ms / finestra 6 s",
        fixture: fixture,
        engine: engine,
        firstUpdate: 0.35,
        interval: 0.35,
        adaptive: false,
        refreshHz: refreshHz
    )
    let latestWins = try run(
        name: "Perfil \(profile.displayName) / context fix 4 s / histèresi",
        fixture: fixture,
        engine: engine,
        firstUpdate: LiveWindowPolicy.minimumAudioSeconds,
        interval: profile.policy.minimumHopSeconds,
        adaptive: true,
        refreshHz: refreshHz,
        profile: profile
    )

    printResult(baseline)
    printResult(latestWins)
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
    if let oldP50 = baseline.wordToFrame.p50,
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
        let baselineWER = WordErrorRate.score(
            reference: reference,
            hypothesis: baseline.transcript
        )
        let finalWER = WordErrorRate.score(reference: reference, hypothesis: final.text)
        let degradationPoints = (provisionalWER - finalWER) * 100
        print(String(
            format: "WER baseline %.2f%% · nova %.2f%% · final 6 s %.2f%% · nova-final %.2f punts",
            baselineWER * 100,
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
