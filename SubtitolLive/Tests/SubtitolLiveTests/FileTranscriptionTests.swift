import Foundation
import SubtitolCore

/// A synthetic recording: a 300 Hz tone for every word, near-silence between them.
private struct SpokenScript {
    struct Word {
        let text: String
        let start: Int
        let end: Int
    }

    let recording: PCMRecording
    let words: [Word]

    /// `gaps[i]` seconds of silence after word i (0.15 s when not given).
    init(count: Int, wordSeconds: Double = 0.35, gaps: [Int: Double] = [:], sampleRate: Int32 = 16_000) {
        let rate = Double(sampleRate)
        var samples: [Float] = []
        var words: [Word] = []
        var noise: UInt32 = 12_345
        func quiet(_ seconds: Double) {
            for _ in 0..<Int(seconds * rate) {
                noise = noise &* 1_103_515_245 &+ 12_345
                samples.append((Float(noise >> 16 & 0x7fff) / 32_768 - 0.5) * 0.000_6)
            }
        }
        quiet(0.5)
        for index in 0..<count {
            let start = samples.count
            for sample in 0..<Int(wordSeconds * rate) {
                samples.append(0.3 * sin(2 * .pi * 300 * Float(sample) / Float(rate)))
            }
            words.append(Word(text: "w\(index)", start: start, end: samples.count))
            quiet(gaps[index] ?? 0.15)
        }
        quiet(0.5)
        self.recording = PCMRecording(floats: samples, sampleRate: sampleRate)
        self.words = words
    }

    /// What a perfect recogniser hears in `samples`, given where the window starts: every
    /// word whose sound it contains at least half of, timed from the window's start.
    func recognize(_ samples: [Float], windowStart: Int) -> [RecognizedWord] {
        let rate = Int(recording.sampleRate)
        let end = windowStart + samples.count
        return words.compactMap { word in
            let heard = min(word.end, end) - max(word.start, windowStart)
            guard heard * 2 >= word.end - word.start else { return nil }
            let start = max(word.start, windowStart) - windowStart
            let finish = min(word.end, end) - windowStart
            return RecognizedWord(
                text: word.text,
                startMilliseconds: Int32(start * 1_000 / rate),
                endMilliseconds: Int32(finish * 1_000 / rate),
                confidence: nil
            )
        }
    }
}

func testFileTranscriptionWindowsTileTheRecording() {
    let script = SpokenScript(count: 120)
    let transcriber = FileTranscriber(rules: .catalan)
    let windows = transcriber.windows(for: script.recording)
    check(windows.count > 1, "a long recording is cut into several windows")
    check(windows.first?.keep.lowerBound, equals: 0, "the first window keeps from the start")
    check(windows.last?.keep.upperBound, equals: script.recording.count, "the last window keeps to the end")
    for (previous, next) in zip(windows, windows.dropFirst()) {
        check(previous.keep.upperBound, equals: next.keep.lowerBound, "kept stretches meet without gap or overlap")
    }
    let rate = Double(script.recording.sampleRate)
    for window in windows {
        let seconds = Double(window.audio.count) / rate
        check(seconds <= transcriber.configuration.windowSeconds + 0.01, "no window hears more than its length")
        check(window.audio.lowerBound <= window.keep.lowerBound && window.audio.upperBound >= window.keep.upperBound,
              "a window hears everything it keeps")
    }
    // Every window has the same length: the runtime keeps a graph per length it sees.
    let length = Int(transcriber.configuration.windowSeconds * rate)
    check(Set(windows.map(\.audio.count)), equals: [length], "every window is heard at one length")
    // Every cut falls between two words, never inside one.
    for window in windows.dropLast() {
        let cut = window.keep.upperBound
        check(!script.words.contains { $0.start < cut && cut < $0.end }, "cut at \(cut) falls between words")
    }

    // A clear pause near the ideal cut is where the cut goes.
    let paused = SpokenScript(count: 40, gaps: [18: 0.8])
    let pause = paused.words[18].end..<paused.words[19].start
    let first = transcriber.windows(for: paused.recording).first
    check(first.map { pause.contains($0.keep.upperBound) } ?? false, "the cut takes the long pause")

    check(transcriber.windows(for: SpokenScript(count: 3).recording).count, equals: 1, "a short clip is one window")
    check(transcriber.windows(for: PCMRecording(samples: [], sampleRate: 16_000)).isEmpty, "silence of no length has no window")
}

func testFileTranscriptionKeepsEveryWordOnce() throws {
    let script = SpokenScript(count: 150, gaps: [30: 0.9, 77: 1.2])
    let transcriber = FileTranscriber(rules: .catalan)
    var progressCalls = 0
    var lastFraction = 0.0
    let result = try transcriber.transcribe(
        script.recording,
        recognize: { samples, start in script.recognize(samples, windowStart: start) },
        predictor: PlainPunctuation(),
        progress: { progress in
            progressCalls += 1
            check(progress.fraction >= lastFraction, "progress only moves forward")
            lastFraction = progress.fraction
        }
    )
    check(result.heardWords, equals: script.words.map(\.text), "every word is kept once, in order")
    check(lastFraction, equals: 1, "progress ends at the whole recording")
    check(progressCalls, equals: transcriber.windows(for: script.recording).count, "one report per window")

    let session = result.session
    check(session.wordCount, equals: script.words.count, "the session holds every word")
    let rate = Double(script.recording.sampleRate)
    let timesMatch = zip(session.words, script.words).allSatisfy { spoken, truth in
        guard let start = spoken.start, let end = spoken.end else { return false }
        return abs(start - Double(truth.start) / rate) < 0.002 && abs(end - Double(truth.end) / rate) < 0.002
    }
    check(timesMatch, "every word keeps its own time")
    // Long pauses end sentences for an unpunctuated language, so paragraphs start there.
    check(session.words[78].startsParagraph || session.words[78].startsLine, "a long pause breaks the text")
    let subtitles = TranscriptExport.subRip(session)
    check(subtitles.components(separatedBy: " --> ").count - 1, equals: script.words.count, "one cue per word")
}

func testFileTranscriptionDropsWordsInSilence() throws {
    let script = SpokenScript(count: 20, gaps: [9: 3])
    let ghost = script.words[9].end + Int(1.5 * Double(script.recording.sampleRate))
    let transcriber = FileTranscriber(rules: .catalan)
    let result = try transcriber.transcribe(
        script.recording,
        recognize: { samples, start in
            var words = script.recognize(samples, windowStart: start)
            if (start..<(start + samples.count)).contains(ghost) {
                let at = Int32((ghost - start) * 1_000 / Int(script.recording.sampleRate))
                words.append(RecognizedWord(text: "más", startMilliseconds: at, endMilliseconds: at + 200, confidence: nil))
                words.sort { $0.startMilliseconds < $1.startMilliseconds }
            }
            return words
        },
        predictor: PlainPunctuation()
    )
    check(!result.heardWords.contains("más"), "a word written into silence is dropped")
    check(result.heardWords.count, equals: 20, "the real words stay")
}

func testFileTranscriptionCanBeCancelled() {
    let script = SpokenScript(count: 120)
    let transcriber = FileTranscriber(rules: .catalan)
    var calls = 0
    do {
        _ = try transcriber.transcribe(
            script.recording,
            recognize: { _, _ in calls += 1; return [] },
            predictor: PlainPunctuation(),
            isCancelled: { calls >= 2 }
        )
        check(false, "a cancelled transcription throws")
    } catch {
        check(calls, equals: 2, "no window runs after cancelling")
    }
}

/// "dos mil vint" becomes "2020", and its subtitle lasts until "vint" ends.
func testDigitsLastUntilTheirLastSpokenWord() {
    let texts = ["l'any", "dos", "mil", "vint", "va", "ser", "llarg"]
    let words = texts.enumerated().map { index, text in
        StableTranscriptWord(
            id: UInt64(index + 1), text: text, isCommitted: true, anchor: UInt64(index + 1),
            startSequence: UInt64(index * 1_000), endSequence: UInt64(index * 1_000 + 800)
        )
    }
    var formatter = TranscriptFormatter(rules: .catalan)
    let formatted = formatter.format(
        ReadableTranscriptSnapshot(committedWords: words, audioEndSequence: 8_000, sampleRate: 1_000),
        isFinal: true,
        predictor: PlainPunctuation()
    )
    let number = formatted.words.first { $0.text.hasPrefix("2020") }
    check(number?.startSequence, equals: 1_000, "the number starts with its first word")
    check(number?.endSequence, equals: 3_800, "the number ends with its last word")
}

func testPCMRecordingRoundTrip() {
    let recording = PCMRecording(floats: [0, 0.5, -0.5, 1, -1, 2], sampleRate: 16_000)
    let back = recording.floats(0..<6)
    check(abs(back[1] - 0.5) < 0.001 && abs(back[2] + 0.5) < 0.001, "samples survive 16 bits")
    check(back[5] <= 1, "loud samples are clipped, not wrapped")
    check(recording.floats(4..<10).count, equals: 2, "ranges past the end are clamped")
}

/// A long window that comes back with a stretch of speech missing is heard again in
/// short windows, and nothing is lost.
func testFileTranscriptionRepairsSkippedSpeech() throws {
    let script = SpokenScript(count: 150)
    let rate = Int(script.recording.sampleRate)
    let skipped = (20 * rate)..<(27 * rate)
    let transcriber = FileTranscriber(rules: .catalan)
    let result = try transcriber.transcribe(
        script.recording,
        recognize: { samples, start in
            let words = script.recognize(samples, windowStart: start)
            // Long windows lose everything said in `skipped`; short ones do not.
            guard samples.count > 10 * rate else { return words }
            return words.filter { !skipped.contains(start + Int($0.startMilliseconds) * rate / 1_000) }
        },
        predictor: PlainPunctuation()
    )
    check(result.heardWords, equals: script.words.map(\.text), "skipped speech is heard again and kept once")
    check(result.repairedWords > 10, "the missing words come from the second hearing")

    // The decoder often stretches the word before a skipped stretch over it; beyond
    // the longest a word lasts, the stretch is still heard again.
    let stretched = (14 * rate)..<(18 * rate)
    let stretchedResult = try transcriber.transcribe(
        script.recording,
        recognize: { samples, start in
            let words = script.recognize(samples, windowStart: start)
            guard samples.count > 10 * rate else { return words }
            let at = { (word: RecognizedWord) in start + Int(word.startMilliseconds) * rate / 1_000 }
            let kept = words.filter { !stretched.contains(at($0)) }
            return kept.map { word in
                guard at(word) < stretched.lowerBound, !kept.contains(where: { at($0) > at(word) && at($0) < stretched.lowerBound }) else { return word }
                return RecognizedWord(
                    text: word.text,
                    startMilliseconds: word.startMilliseconds,
                    endMilliseconds: Int32((stretched.upperBound - start) * 1_000 / rate),
                    confidence: nil
                )
            }
        },
        predictor: PlainPunctuation()
    )
    let stretchedWord = script.words.last { $0.start < stretched.lowerBound }!
    let covered = stretchedWord.start..<(stretchedWord.start + Int(1.5 * Double(rate)))
    let audible = script.words.filter { $0.start == stretchedWord.start || !covered.contains($0.start) }
    check(stretchedResult.heardWords, equals: audible.map(\.text), "speech under a stretched word is heard again")

    // Whatever the recogniser is given has one of the window lengths, the second
    // hearings' included, and a clip shorter than a window is heard at that length.
    var lengths = Set<Int>()
    _ = try transcriber.transcribe(
        SpokenScript(count: 8).recording,
        recognize: { samples, _ in lengths.insert(samples.count); return [] },
        predictor: PlainPunctuation()
    )
    let allowed = Set(([transcriber.configuration.windowSeconds] + FileTranscriber.repairRounds).map { Int($0 * Double(rate)) })
    check(lengths.isSubset(of: allowed), "a short clip is heard at the usual lengths, got \(lengths)")

    // Pauses without voice are not holes: nothing is heard twice.
    var calls = 0
    let paused = SpokenScript(count: 40, gaps: [10: 2, 25: 3])
    _ = try transcriber.transcribe(
        paused.recording,
        recognize: { samples, start in calls += 1; return paused.recognize(samples, windowStart: start) },
        predictor: PlainPunctuation()
    )
    check(calls, equals: transcriber.windows(for: paused.recording).count, "silence is not heard again")
}

func testRepairWindowsNeverOverlap() {
    let rate: Int32 = 16_000
    let second = Int(rate)
    let holes = [(1 * second)..<(2 * second), (2 * second + 800)..<(3 * second), (5 * second)..<(19 * second), (19 * second + 100)..<(20 * second)]
    let windows = FileTranscriber.repairWindows(for: holes, total: 30 * second, sampleRate: rate)
    for (previous, next) in zip(windows, windows.dropFirst()) {
        check(previous.keep.upperBound <= next.keep.lowerBound, "second hearings keep separate stretches")
    }
    for hole in holes {
        let covered = windows.reduce(0) { $0 + $1.keep.clamped(to: hole).count }
        check(covered, equals: hole.count, "every hole is heard again whole")
    }
    check(Set(windows.map(\.audio.count)), equals: [Int(FileTranscriber.repairWindowSeconds * Double(rate))], "second hearings have one length")
}

/// The Conformer now and then returns no word at all for a whole window, speech
/// included, and the same speech whole from a window that starts a little later. Such
/// a window is heard again from later on, at its usual length.
func testFileTranscriptionHearsAnEmptyWindowAgain() throws {
    let script = SpokenScript(count: 150, gaps: [40: 0.9, 90: 1.2])
    let rate = Int(script.recording.sampleRate)
    let transcriber = FileTranscriber(rules: .catalan)
    var lengths = Set<Int>()
    var emptied = 0
    let result = try transcriber.transcribe(
        script.recording,
        recognize: { samples, start in
            lengths.insert(samples.count)
            // A window that starts in a word comes back empty.
            guard !samples.prefix(rate / 10).contains(where: { abs($0) > 0.01 }) else {
                emptied += 1
                return []
            }
            let lead = samples.prefix { $0 == 0 }.count
            return script.recognize(Array(samples[lead...]), windowStart: start + lead).map {
                RecognizedWord(
                    text: $0.text,
                    startMilliseconds: $0.startMilliseconds + Int32(lead * 1_000 / rate),
                    endMilliseconds: $0.endMilliseconds + Int32(lead * 1_000 / rate),
                    confidence: nil
                )
            }
        },
        predictor: PlainPunctuation()
    )
    check(emptied > 3, "some windows start in a word")
    check(result.heardWords, equals: script.words.map(\.text), "an empty window is heard again and nothing is lost")
    check(result.repairedWords, equals: 0, "hearing it again from later on is enough")
    let allowed = Set(([transcriber.configuration.windowSeconds] + FileTranscriber.repairRounds).map { Int($0 * Double(rate)) })
    check(lengths.isSubset(of: allowed), "the second hearing keeps the usual lengths, got \(lengths)")

    // Where nothing is said, an empty window is not heard again.
    var calls = 0
    let silent = PCMRecording(samples: ContiguousArray(repeating: 0, count: 40 * rate), sampleRate: script.recording.sampleRate)
    _ = try transcriber.transcribe(silent, recognize: { _, _ in calls += 1; return [] }, predictor: PlainPunctuation())
    check(calls, equals: transcriber.windows(for: silent).count, "silence is heard once")
}
