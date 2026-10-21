import CoreML
import Foundation
import SubtitolCore

/// The Catalan punctuation and capitalisation model, run with Core ML.
///
/// Expects a directory holding the model (`puntuacio.mlmodelc`, or a
/// `puntuacio.mlpackage` that is compiled on first load) and its tokenizer:
/// `vocab.json`, `merges.txt` and `labels.json`. Core ML ships with macOS and iOS, so
/// the same code serves the iPhone.
public final class PunctuationModel: PunctuationPredicting, @unchecked Sendable {
    public enum ModelError: LocalizedError {
        case missingFile(String)
        case invalidLabels

        public var errorDescription: String? {
            switch self {
            case .missingFile(let name): "Falta el fitxer del model de puntuació: \(name)."
            case .invalidLabels: "Els rètols del model de puntuació no són vàlids."
            }
        }
    }

    /// The traced model accepts 4 to 256 tokens, special tokens included.
    public static let minimumTokens = 4
    public static let maximumTokens = 256
    private static let padding: Int32 = 1

    private let model: MLModel
    private let tokenizer: ByteLevelBPETokenizer
    private let labelTable: [PunctuationLabel]
    private let lock = NSLock()

    public init(directory: URL) throws {
        func file(_ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ModelError.missingFile(name) }
            return url
        }
        let compiled = directory.appendingPathComponent("puntuacio.mlmodelc")
        let modelURL: URL
        if FileManager.default.fileExists(atPath: compiled.path) {
            modelURL = compiled
        } else {
            modelURL = try Self.cachedCompilation(of: try file("puntuacio.mlpackage"))
        }
        let configuration = MLModelConfiguration()
        // A few milliseconds per call on the CPU, and it leaves the GPU to speech.
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        tokenizer = try ByteLevelBPETokenizer(
            vocabularyURL: try file("vocab.json"),
            mergesURL: try file("merges.txt")
        )
        let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: try file("labels.json")))
        let table = names.compactMap(PunctuationLabel.init(modelLabel:))
        guard table.count == names.count, !table.isEmpty else { throw ModelError.invalidLabels }
        labelTable = table
    }

    /// Compiles `package` once into the user's cache and reuses it while the package is
    /// unchanged. `MLModel.compileModel` writes a fresh 60 MB copy to the temporary
    /// directory on every call and never removes it: the harness and the checks, which
    /// load the source `.mlpackage`, left 11 GB of copies behind in a day.
    /// The speaker segmentation model uses it too.
    public static func cachedCompilation(of package: URL) throws -> URL {
        let manager = FileManager.default
        // Name the copy after every file's path, size and modification date.
        var key = ""
        if let files = manager.enumerator(at: package, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) {
            for case let url as URL in files {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = values.fileSize else { continue }
                let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                key += "\(url.path.dropFirst(package.path.count))|\(size)|\(modified)\n"
            }
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        let cache = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SubtitolPunctuation", isDirectory: true)
        let name = package.deletingPathExtension().lastPathComponent
        let destination = cache.appendingPathComponent("\(name)-\(String(hash, radix: 16)).mlmodelc", isDirectory: true)
        if manager.fileExists(atPath: destination.appendingPathComponent("coremldata.bin").path) {
            return destination
        }
        let compiled = try MLModel.compileModel(at: package)
        defer { try? manager.removeItem(at: compiled) }
        // Older copies belong to an earlier version of the package.
        try manager.createDirectory(at: cache, withIntermediateDirectories: true)
        for old in (try? manager.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("\(name)-") && old != destination {
            try? manager.removeItem(at: old)
        }
        // Another process may have finished the same copy first; either result is complete.
        do {
            try manager.moveItem(at: compiled, to: destination)
        } catch where manager.fileExists(atPath: destination.appendingPathComponent("coremldata.bin").path) {}
        return destination
    }

    public func predictions(for words: [String]) -> [PunctuationPrediction]? {
        guard !words.isEmpty else { return [] }
        // Keep the newest words that fit; older ones only ever serve as context.
        var first = 0
        var budget = Self.maximumTokens - 2
        var index = words.count - 1
        while index >= 0 {
            let count = max(1, tokenizer.tokens(forWord: words[index]).count)
            guard count <= budget else { break }
            budget -= count
            first = index
            index -= 1
        }
        let kept = Array(words[first...])
        let (ids, positions) = tokenizer.encode(words: kept)
        var input = ids
        while input.count < Self.minimumTokens { input.append(Self.padding) }

        lock.lock()
        defer { lock.unlock() }
        // Core ML hands its results back autoreleased. A file's job calls this for
        // minutes on one thread that never drains a pool, so each call drains its own.
        return autoreleasepool { () -> [PunctuationPrediction]? in
            do {
                let array = try MLMultiArray(shape: [1, NSNumber(value: input.count)], dataType: .int32)
                for (offset, id) in input.enumerated() { array[offset] = NSNumber(value: id) }
                let features = try MLDictionaryFeatureProvider(dictionary: ["input_ids": MLFeatureValue(multiArray: array)])
                guard let logits = try model.prediction(from: features).featureValue(for: "logits")?.multiArrayValue,
                      logits.shape.count == 3, logits.shape[2].intValue == labelTable.count else {
                    return nil
                }
                let classes = labelTable.count
                let rowStride = logits.strides[1].intValue
                let classStride = logits.strides[2].intValue
                var scores = [Float](repeating: 0, count: classes)
                func read<T>(_ type: T.Type, _ convert: (T) -> Float) -> [PunctuationPrediction] {
                    let values = logits.dataPointer.assumingMemoryBound(to: type)
                    return positions.map { position in
                        for label in 0..<classes {
                            scores[label] = convert(values[position * rowStride + label * classStride])
                        }
                        return Self.prediction(logits: scores, labels: labelTable)
                    }
                }
                let predicted: [PunctuationPrediction]
                switch logits.dataType {
                case .float32: predicted = read(Float.self) { $0 }
                case .double: predicted = read(Double.self) { Float($0) }
                case .float16: predicted = read(Float16.self) { Float($0) }
                default: return nil
                }
                return Array(repeating: PunctuationPrediction(certain: .plain), count: first) + predicted
            } catch {
                return nil
            }
        }
    }

    /// Softmax over one word's logits.
    private static func prediction(logits: [Float], labels: [PunctuationLabel]) -> PunctuationPrediction {
        let top = logits.max() ?? 0
        let exponentials = logits.map { exp($0 - top) }
        let total = exponentials.reduce(0, +)
        return PunctuationPrediction(labels: labels, probabilities: exponentials.map { $0 / total })
    }
}
