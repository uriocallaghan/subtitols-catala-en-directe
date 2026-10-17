import CoreML
import Foundation
import SubtitolCore
import SubtitolPunctuation

/// Parity checks against the Python reference, one line of input per line of output.
///
///   tokens  MODEL_DIR FILE   token ids of every word, space-separated, words split by " | "
///   labels  MODEL_DIR FILE   the model label of every word
///   numbers FILE             CatalanNumberNormalizer.normalize of every line
///   compile PACKAGE OUTPUT   compiles an .mlpackage to OUTPUT (.mlmodelc) without Xcode
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("Ús: SubtitolPunctuationCheck tokens|labels MODEL_DIR FILE · numbers FILE\n".utf8))
    exit(2)
}
func lines(_ path: String) -> [String] {
    (try? String(contentsOfFile: path, encoding: .utf8))?
        .split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? []
}
switch arguments[0] {
case "compile":
    guard arguments.count >= 3 else { exit(2) }
    let compiled = try MLModel.compileModel(at: URL(fileURLWithPath: arguments[1]))
    let destination = URL(fileURLWithPath: arguments[2])
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: compiled, to: destination)
    print(destination.path)
case "numbers":
    for line in lines(arguments[1]) { print(CatalanNumberNormalizer.normalize(line)) }
case "tokens":
    let directory = URL(fileURLWithPath: arguments[1])
    let tokenizer = try ByteLevelBPETokenizer(
        vocabularyURL: directory.appendingPathComponent("vocab.json"),
        mergesURL: directory.appendingPathComponent("merges.txt")
    )
    for line in lines(arguments[2]) {
        print(line.split(separator: " ").map { tokenizer.tokens(forWord: String($0)).map(String.init).joined(separator: " ") }.joined(separator: " | "))
    }
case "labels":
    let model = try PunctuationModel(directory: URL(fileURLWithPath: arguments[1]))
    let started = Date()
    var calls = 0
    for line in lines(arguments[2]) {
        let words = line.split(separator: " ").map(String.init)
        guard !words.isEmpty else { print(""); continue }
        guard let labels = model.labels(for: words) else { print("ERROR"); continue }
        calls += 1
        print(labels.map { $0.mark.rawValue + String($0.casing.rawValue) }.joined(separator: " "))
    }
    FileHandle.standardError.write(Data(String(format: "%d calls · %.1f ms per call\n", calls, Date().timeIntervalSince(started) * 1000 / Double(max(calls, 1))).utf8))
default:
    exit(2)
}
