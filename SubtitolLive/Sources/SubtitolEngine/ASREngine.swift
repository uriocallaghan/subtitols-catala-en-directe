import CNemoSpeech
import Foundation
import SubtitolCore

public final class ASREngine: @unchecked Sendable {
    public struct Transcription: Sendable {
        public let text: String
        public let words: [RecognizedWord]
        public let audioDuration: TimeInterval
        public let inferenceMilliseconds: Double
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

    public init(modelURL: URL) throws {
        var errorBuffer = [CChar](repeating: 0, count: 2_048)
        let created = modelURL.path.withCString { modelPath in
            stl_engine_create(modelPath, &errorBuffer, errorBuffer.count)
        }
        guard let created else {
            throw EngineError.message(String(cString: errorBuffer))
        }
        handle = created
    }

    deinit {
        stl_engine_destroy(handle)
    }

    public func transcribe(samples: [Float], sampleRate: Int32) throws -> Transcription {
        var errorBuffer = [CChar](repeating: 0, count: 2_048)
        var inferenceMilliseconds = 0.0
        var result: OpaquePointer?

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
            throw EngineError.message("El motor no ha retornat cap transcripció.")
        }
        defer { stl_result_destroy(result) }

        let wordCount = stl_result_word_count(result)
        var words: [RecognizedWord] = []
        words.reserveCapacity(wordCount)
        for index in 0..<wordCount {
            words.append(RecognizedWord(
                text: String(cString: stl_result_word_text(result, index)),
                startMilliseconds: stl_result_word_start_time(result, index),
                endMilliseconds: stl_result_word_end_time(result, index),
                // The current RNNT decoder emits the constant 1.0 rather than a
                // calibrated probability. Expose that measurement as unavailable.
                confidence: nil
            ))
        }

        return Transcription(
            text: String(cString: stl_result_transcript(result)),
            words: words,
            audioDuration: TimeInterval(stl_result_audio_processed(result)),
            inferenceMilliseconds: inferenceMilliseconds
        )
    }

    public func warmUp() throws {
        for duration in LiveWindowPolicy.warmupWindowSeconds {
            let silence = [Float](repeating: 0, count: Int(duration * 16_000))
            _ = try transcribe(samples: silence, sampleRate: 16_000)
        }
    }
}
