import SubtitolCore

private func word(_ text: String, _ start: UInt64, _ end: UInt64) -> TranscriptObservationWord {
    TranscriptObservationWord(text: text, startSequence: start, endSequence: end, confidence: nil)
}

func testRecognizerPunctuation() {
    // Marks written as words of their own join their word; capitals become casing.
    let stripper = RecognizerPunctuation()
    let bare = stripper.strip(
        [word("Esto", 0, 200), word("es", 250, 300), word("verdad", 350, 600), word(",", 620, 640),
         word("¿", 700, 710), word("cierto?", 720, 900), word("La", 1_000, 1_100), word("ONU.", 1_150, 1_400)],
        windowStart: 0, windowEnd: 3_000, sampleRate: 1_000, includesSessionStart: true, isFinal: true
    )
    check(bare.map(\.text), equals: ["esto", "es", "verdad", "cierto", "la", "onu"], "recogniser marks come off the words")
    let labels = stripper.predictions(
        for: bare.map(\.text),
        spans: bare.map { ($0.startSequence, $0.endSequence) }
    )?.map(\.best)
    check(labels?[2].mark, equals: .comma, "a standalone comma closes the word before it")
    check(labels?[3].opening, equals: .question, "a standalone ¿ opens the word after it")
    check(labels?[3].mark, equals: .question, "the question mark stays on its word")
    check(labels?[5].casing, equals: .allCaps, "an acronym keeps its capitals")

    // A full stop the window's edge put on "del" is not the one read: the next window
    // hears "del clima." with the word well inside.
    let marks = RecognizerPunctuation()
    var stabilizer = ReadableTranscriptStabilizer()
    var formatter = TranscriptFormatter(rules: .spanish)
    let windows: [(end: UInt64, words: [TranscriptObservationWord])] = [
        (2_000, [word("Se", 100, 200), word("recomienda", 300, 800), word("cualquier", 900, 1_100),
                 word("riesgo", 1_200, 1_500), word("del.", 1_900, 2_000)]),
        (2_600, [word("Se", 100, 200), word("recomienda", 300, 800), word("cualquier", 900, 1_100),
                 word("riesgo", 1_200, 1_500), word("del", 1_900, 1_980), word("clima.", 2_100, 2_500)]),
        (3_400, [word("Se", 100, 200), word("recomienda", 300, 800), word("cualquier", 900, 1_100),
                 word("riesgo", 1_200, 1_500), word("del", 1_900, 1_980), word("clima.", 2_100, 2_500),
                 word("¿Vendrás?", 2_700, 3_200)]),
    ]
    var formatted = ReadableTranscriptSnapshot()
    for window in windows {
        let words = marks.strip(
            window.words, windowStart: 0, windowEnd: window.end, sampleRate: 1_000, includesSessionStart: true
        )
        let readable = stabilizer.observe(words, audioEndSequence: window.end, sampleRate: 1_000, windowStartSequence: 0)
        formatted = formatter.format(readable, predictor: marks)
    }
    let final = stabilizer.finalize(
        marks.strip(windows[2].words, windowStart: 0, windowEnd: 3_400, sampleRate: 1_000,
                    includesSessionStart: true, isFinal: true),
        audioEndSequence: 3_400, sampleRate: 1_000
    )
    formatted = formatter.format(final, isFinal: true, predictor: marks)
    check(
        formatted.text,
        equals: "Se recomienda cualquier riesgo del clima. ¿Vendrás?",
        "the recogniser's own marks, read from where each word was heard in context"
    )
}
