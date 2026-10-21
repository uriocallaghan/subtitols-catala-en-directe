import Foundation
import SubtitolCore
import SubtitolEngine

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL \(message)\n", stderr)
        exit(1)
    }
}

let configuredPath = CommandLine.arguments.dropFirst().first
    ?? "../models/catalan-conformer-q8.gguf"
let modelURL = URL(fileURLWithPath: configuredPath)
require(FileManager.default.fileExists(atPath: modelURL.path), "model fixture exists")

do {
    // The Conformer writes short Spanish words into silence ("muy", "más"); the app keeps
    // only words the microphone heard (SilentWordFilter). Checked at every window length
    // around the live one, on digital silence, on steady noise at -45 to -70 dBFS and on a
    // loud low hum (most of its power under 300 Hz, like a fan or traffic), where the
    // filter's steady-noise test lets softer voices through.
    let engine = try ASREngine(modelURL: modelURL)
    let sampleRate: Int32 = 16_000
    var state: UInt64 = 0x5EED_CAFE
    func noise(_ count: Int, decibels: Float) -> [Float] {
        let amplitude = powf(10, decibels / 20) * sqrtf(3)
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return (Float((state >> 40) & 0xFFFFFF) / Float(0xFFFFFF) * 2 - 1) * amplitude
        }
    }
    func hum(_ count: Int, decibels: Float) -> [Float] {
        var integrated: Float = 0
        let raw = noise(count, decibels: 0).map { sample -> Float in
            integrated = 0.95 * integrated + sample
            return integrated
        }
        let rms = sqrtf(raw.reduce(0) { $0 + $1 * $1 } / Float(max(1, count)))
        return raw.map { $0 / rms * powf(10, decibels / 20) }
    }
    let windows = Set([4.0, 6.0, LiveWindowPolicy.liveWindowSeconds, LiveWindowPolicy.finalWindowSeconds, 8.0]).sorted()
    for seconds in windows {
        let count = Int(Double(sampleRate) * seconds)
        let cases: [(String, [Float])] = [("digital silence", [Float](repeating: 0, count: count))]
            + [-45, -50, -60, -70].map { ("noise at \(Int($0)) dBFS", noise(count, decibels: $0)) }
            + [-25, -40].map { ("low hum at \(Int($0)) dBFS", hum(count, decibels: $0)) }
        for (name, samples) in cases {
            let result = try engine.transcribe(samples: samples, sampleRate: sampleRate)
            let shown = SilentWordFilter.voicedWords(result.words, samples: samples, sampleRate: sampleRate)
            require(shown.isEmpty, "\(name), \(seconds) s shows no words (heard \"\(result.text)\")")
        }
    }
    print("PASS SubtitolEngineIntegrationTests")
} catch {
    fputs("FAIL real engine integration: \(error.localizedDescription)\n", stderr)
    exit(1)
}
