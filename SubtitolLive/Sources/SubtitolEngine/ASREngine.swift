import CNemoSpeech
import Foundation
import SubtitolCore

public final class ASREngine: @unchecked Sendable {
    public struct Transcription: Sendable {
        public let text: String
        public let words: [RecognizedWord]
        public let audioDuration: TimeInterval
        public let inferenceMilliseconds: Double

        public init(text: String, words: [RecognizedWord], audioDuration: TimeInterval, inferenceMilliseconds: Double) {
            self.text = text
            self.words = words
            self.audioDuration = audioDuration
            self.inferenceMilliseconds = inferenceMilliseconds
        }
    }

    public enum EngineError: LocalizedError {
        case message(String)

        public var errorDescription: String? {
            switch self {
            case .message(let text): text
            }
        }
    }

    private let handle: OpaquePointer
    /// Catalan elisions the recogniser splits ("l' empordà") are joined again; other
    /// languages' words pass untouched.
    private let repairsCatalanElisions: Bool
    /// The boosted phrases are read by every transcription and replaced from the main
    /// thread, so the two never overlap.
    private let phraseLock = NSLock()

    public init(modelURL: URL, repairsCatalanElisions: Bool = true) throws {
        self.repairsCatalanElisions = repairsCatalanElisions
        var errorBuffer = [CChar](repeating: 0, count: 2_048)
        let created = modelURL.path.withCString { modelPath in
            stl_engine_create(modelPath, &errorBuffer, errorBuffer.count)
        }
        guard let created else {
            throw EngineError.message(String(cString: errorBuffer))
        }
        handle = created
        Self.live.add()
    }

    deinit {
        stl_engine_destroy(handle)
        Self.live.remove()
    }

    /// Engines alive in this process. ggml frees its Metal device in a C++ static
    /// destructor at `exit()` and aborts while any model still holds GPU memory, so the
    /// app quits only once every engine is gone.
    private static let live = LiveEngines()

    /// Waits up to `timeout` for every engine to be released; says whether none is left.
    public static func waitUntilAllReleased(timeout: TimeInterval) -> Bool {
        live.waitUntilEmpty(before: Date(timeIntervalSinceNow: timeout))
    }

    public func transcribe(samples: [Float], sampleRate: Int32) throws -> Transcription {
        var errorBuffer = [CChar](repeating: 0, count: 2_048)
        var inferenceMilliseconds = 0.0
        var result: OpaquePointer?

        phraseLock.lock()
        defer { phraseLock.unlock() }
        let status = samples.withUnsafeBufferPointer { buffer in
            stl_engine_transcribe(
                handle,
                buffer.baseAddress,
                buffer.count,
                sampleRate,
                &result,
                &inferenceMilliseconds,
                &errorBuffer,
                errorBuffer.count
            )
        }

        guard status == 0 else {
            throw EngineError.message(String(cString: errorBuffer))
        }
        guard let result else {
            throw EngineError.message(localized("El motor no ha retornat cap transcripció."))
        }
        defer { stl_result_destroy(result) }

        let wordCount = stl_result_word_count(result)
        var words: [RecognizedWord] = []
        words.reserveCapacity(wordCount)
        for index in 0..<wordCount {
            words.append(RecognizedWord(
                // Some models emit the typographic apostrophe; everything downstream
                // (elision repair, punctuation, number rules) expects the plain one.
                text: String(cString: stl_result_word_text(result, index))
                    .replacingOccurrences(of: "\u{2019}", with: "'"),
                startMilliseconds: stl_result_word_start_time(result, index),
                endMilliseconds: stl_result_word_end_time(result, index),
                // The posterior of the word's least sure piece (our runtime patch
                // 0004); a runtime without it answers 1.0 for every word, and a
                // decoder without posteriors 0.
                confidence: Self.confidence(stl_result_word_confidence(result, index))
            ))
        }

        let text = String(cString: stl_result_transcript(result)).replacingOccurrences(of: "\u{2019}", with: "'")
        return Transcription(
            text: repairsCatalanElisions ? CatalanElisionRepair.repair(text: text) : text,
            words: repairsCatalanElisions ? CatalanElisionRepair.repair(words) : words,
            audioDuration: TimeInterval(stl_result_audio_processed(result)),
            inferenceMilliseconds: inferenceMilliseconds
        )
    }

    private static func confidence(_ raw: Float) -> Float? {
        raw > 0 && raw <= 1 ? raw : nil
    }

    /// Words and short phrases to favour from the next transcription on: names, places
    /// and terms of the day. An empty list turns boosting off. `boost` is the runtime's
    /// strength, 1 to 10.
    public func setBoostedPhrases(_ phrases: [String], boost: Float = 4) {
        // The Conformer's vocabulary is lowercase ("Korotkoff" tokenised into pieces it
        // never writes and came out "khorod kovolls"; "korotkoff" came out right), while
        // the cased FastConformers may want the capitals: both forms go in.
        let trimmed = phrases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var kept: [String] = []
        for phrase in trimmed {
            let lowered = phrase.lowercased()
            if !kept.contains(lowered) { kept.append(lowered) }
            if lowered != phrase, !kept.contains(phrase) { kept.append(phrase) }
        }
        let pointers: [UnsafePointer<CChar>?] = kept.map { UnsafePointer(strdup($0)) }
        defer { pointers.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        phraseLock.lock()
        defer { phraseLock.unlock() }
        pointers.withUnsafeBufferPointer { buffer in
            stl_engine_set_phrases(handle, buffer.baseAddress, kept.count, boost)
        }
    }

    /// Runs silence through every window length the session will use, so the first real
    /// update does not pay for building the GPU pipelines.
    public func warmUp(windowSeconds: [TimeInterval] = LiveWindowPolicy.warmupWindowSeconds) throws {
        for duration in windowSeconds {
            let silence = [Float](repeating: 0, count: Int(duration * 16_000))
            _ = try transcribe(samples: silence, sampleRate: 16_000)
        }
    }
}

private final class LiveEngines: @unchecked Sendable {
    private let condition = NSCondition()
    private var count = 0

    func add() {
        condition.lock(); count += 1; condition.unlock()
    }

    func remove() {
        condition.lock()
        count -= 1
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilEmpty(before deadline: Date) -> Bool {
        condition.lock(); defer { condition.unlock() }
        while count > 0 {
            guard condition.wait(until: deadline) else { return count == 0 }
        }
        return true
    }
}
