import Foundation
import SubtitolEngine

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL \(message)\n", stderr)
        exit(1)
    }
}

private func deterministicLowNoise(sampleCount: Int) -> [Float] {
    var state: UInt64 = 0x5EED_CAFE
    return (0..<sampleCount).map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1
        let normalized = Float((state >> 40) & 0xFFFFFF) / Float(0xFFFFFF)
        return (normalized * 2 - 1) * 0.002
    }
}

let configuredPath = CommandLine.arguments.dropFirst().first
    ?? "../models/catalan-parakeet-q8.gguf"
let modelURL = URL(fileURLWithPath: configuredPath)
require(FileManager.default.fileExists(atPath: modelURL.path), "model fixture exists")

do {
    let engine = try ASREngine(modelURL: modelURL)
    let sampleRate: Int32 = 16_000
    let sampleCount = Int(sampleRate) * 4
    let silence = try engine.transcribe(
        samples: [Float](repeating: 0, count: sampleCount),
        sampleRate: sampleRate
    )
    require(silence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "silence has no transcript")
    require(silence.words.isEmpty, "silence has no word insertions")

    let noise = try engine.transcribe(
        samples: deterministicLowNoise(sampleCount: sampleCount),
        sampleRate: sampleRate
    )
    require(noise.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "soft deterministic noise has no transcript")
    require(noise.words.isEmpty, "soft deterministic noise has no word insertions")
    print("PASS SubtitolEngineIntegrationTests")
} catch {
    fputs("FAIL real engine integration: \(error.localizedDescription)\n", stderr)
    exit(1)
}
