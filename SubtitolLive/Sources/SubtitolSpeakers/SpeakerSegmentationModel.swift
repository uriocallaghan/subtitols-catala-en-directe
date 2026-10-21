import CoreML
import Foundation
import SubtitolCore
import SubtitolPunctuation

/// pyannote segmentation-3.0 (MIT, CNRS), run with Core ML: for 10 s of 16 kHz audio,
/// the class of every 17 ms frame (0 silence, 1-3 one voice, 4-6 two at once).
///
/// It listens to the voice, not the words, so one model serves every language.
/// Expects a directory holding `segmentacio.mlmodelc`, or a `segmentacio.mlpackage`
/// compiled on first load (`scripts/convert-speaker-model.py` makes it).
public final class SpeakerSegmentationModel: @unchecked Sendable {
    public enum ModelError: LocalizedError {
        case missingFile(String)

        public var errorDescription: String? {
            switch self {
            case .missingFile(let name): "Falta el fitxer del detector de veus: \(name)."
            }
        }
    }

    private let model: MLModel
    private let lock = NSLock()

    public init(directory: URL) throws {
        let compiled = directory.appendingPathComponent("segmentacio.mlmodelc")
        let package = directory.appendingPathComponent("segmentacio.mlpackage")
        let modelURL: URL
        if FileManager.default.fileExists(atPath: compiled.path) {
            modelURL = compiled
        } else if FileManager.default.fileExists(atPath: package.path) {
            modelURL = try PunctuationModel.cachedCompilation(of: package)
        } else {
            throw ModelError.missingFile("segmentacio.mlmodelc")
        }
        let configuration = MLModelConfiguration()
        // About 20 ms per window on the CPU, twice a second; the GPU stays with speech.
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
    }

    /// The class of every frame, or `nil` if the model failed.
    public func frameClasses(_ samples: [Float]) -> [Int]? {
        guard samples.count == SpeakerTurnTracker.windowSamples else { return nil }
        lock.lock()
        defer { lock.unlock() }
        // Core ML hands its results back autoreleased, about 0.7 MB a call. A file's
        // voice pass calls this twice a second of audio on a thread that never drains a
        // pool (a 54-minute episode reached 5 GB), so each call drains its own.
        return autoreleasepool { () -> [Int]? in
            do {
                let input = try MLMultiArray(shape: [1, 1, NSNumber(value: samples.count)], dataType: .float32)
                samples.withUnsafeBufferPointer { source in
                    input.dataPointer.assumingMemoryBound(to: Float.self)
                        .update(from: source.baseAddress!, count: source.count)
                }
                let features = try MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: input)])
                guard let logits = try model.prediction(from: features).featureValue(for: "logits")?.multiArrayValue,
                      logits.shape.count == 3, logits.shape[2].intValue == 7 else { return nil }
                let frames = logits.shape[1].intValue
                let rowStride = logits.strides[1].intValue
                let classStride = logits.strides[2].intValue
                func argmax<T: Comparable>(_ type: T.Type) -> [Int] {
                    let values = logits.dataPointer.assumingMemoryBound(to: type)
                    return (0..<frames).map { frame in
                        var best = 0
                        for label in 1..<7 where values[frame * rowStride + label * classStride]
                            > values[frame * rowStride + best * classStride] {
                            best = label
                        }
                        return best
                    }
                }
                switch logits.dataType {
                case .float32: return argmax(Float.self)
                case .float16: return argmax(Float16.self)
                case .double: return argmax(Double.self)
                default: return nil
                }
            } catch {
                return nil
            }
        }
    }
}
