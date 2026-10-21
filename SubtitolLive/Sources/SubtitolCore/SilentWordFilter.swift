import Foundation

/// Drops words the recogniser wrote where the microphone heard nobody.
///
/// The Conformer, trained on Catalan and Spanish, fills silence with short Spanish words:
/// seven seconds of digital silence gave "muy", steady noise at -45 to -60 dBFS gave
/// "más. Más. Más." all along, and a laptop's room tone gave whole invented phrases.
/// Speech always rises above the room: on the founder's recordings a vowel stands 20 to
/// 35 dB over the quietest tenth of the window, while room tone never passes +9 dB. So a
/// word is kept when the loudest 10 ms frame around it stands at least `marginDecibels`
/// above that floor. 10 dB is the widest margin that kept every real word of the
/// founder's recordings and of five diagnostic sessions (12 dB lost one, 15 dB eleven).
///
/// Loud steady noise (a fan, traffic, a video's noise bed) is the exception: under pink
/// noise at 5 dB SNR, 13% of a podcast's real words never reach +10 dB, and a lower
/// plain margin would keep the noise, whose 10 ms frames swing 8 to 13 dB over its own
/// floor (its power sits in the lowest frequencies, a cycle or two per frame). Weighed
/// as speech carries sound (`emphasis`) and averaged over 30 ms, the same noise stays
/// within about 1 dB of its floor while the voice still stands several dB over it. So a
/// frame also counts as voice when it stands `steadyMarginDecibels` over the floor and
/// its emphasised level rises `spreadFactor` times the noise's own spread (the floor
/// over the quietest 1%), and at least `minimumRiseDecibels`, above the emphasised
/// floor. In a room or a clean recording the spread is wide and this asks for more than
/// the plain margin; in steady noise it lets the voice through (86% → 98% of the words
/// kept at 5 dB SNR). Pink noise, white noise, a low hum, babble, tones and silence on
/// their own passed it nowhere the plain margin did not already; the 5 dB plain margin
/// is what keeps white noise out, whose emphasised level swings up to 1.9 dB.
public enum SilentWordFilter {
    static let frameSeconds = 0.01
    static let floorQuantile = 0.1
    static let marginDecibels: Float = 10
    /// The second test: the plain margin it still asks for, and how far the emphasised
    /// level must rise over its floor, in multiples of the spread and at least in dB.
    static let steadyMarginDecibels: Float = 5
    static let spreadQuantile = 0.01
    static let spreadFactor: Float = 5
    static let minimumRiseDecibels: Float = 1.5
    /// First difference weighting (the usual speech pre-emphasis), and the frames the
    /// emphasised level is averaged over.
    static let emphasis: Float = 0.97
    static let presenceFrames = 3
    /// Where the loudest frame is looked for around a word's timestamps. The Conformer
    /// stamps a word that opens a phrase 60-100 ms before its sound starts ("la", "a",
    /// "que" after a pause), so the search reaches further after the word than before.
    static let searchBeforeSeconds = 0.05
    static let searchAfterSeconds = 0.25

    /// Words of one recognition window, with times in milliseconds from the window's
    /// first sample. The first `leadingPaddingSamples` samples are padding, not audio.
    public static func voicedWords(
        _ words: [RecognizedWord],
        samples: [Float],
        sampleRate: Int32,
        leadingPaddingSamples: Int = 0
    ) -> [RecognizedWord] {
        let kept = voicedIndices(words, samples: samples, sampleRate: sampleRate, leadingPaddingSamples: leadingPaddingSamples)
        return words.indices.filter(kept.contains).map { words[$0] }
    }

    /// The indices of the words the energy test keeps. In a reverberant hall with an
    /// audience the gaps between words stay loud and real words fail this test, so where
    /// the voice detector has listened its verdict replaces it (`SpeechPresenceMap`).
    public static func voicedIndices(
        _ words: [RecognizedWord],
        samples: [Float],
        sampleRate: Int32,
        leadingPaddingSamples: Int = 0
    ) -> Set<Int> {
        guard !words.isEmpty, sampleRate > 0 else { return Set(words.indices) }
        let frameLength = max(1, Int(Double(sampleRate) * frameSeconds))
        let firstReal = min(max(0, leadingPaddingSamples), samples.count)
        let levels = samples.withUnsafeBufferPointer { buffer in
            FrameLevels(UnsafeBufferPointer(rebasing: buffer[firstReal...]), frameLength: frameLength) { Double($0) }
        }
        let frameCount = levels.count
        guard frameCount > 0 else { return Set(words.indices) }
        let voice = VoiceThresholds(levels, frames: 0..<frameCount)
        let before = Int(searchBeforeSeconds / frameSeconds)
        let after = Int(searchAfterSeconds / frameSeconds)

        return Set(words.indices.filter { index in
            let word = words[index]
            let startSample = Int(Int64(word.startMilliseconds) * Int64(sampleRate) / 1_000)
            let endSample = Int(Int64(word.endMilliseconds) * Int64(sampleRate) / 1_000)
            let first = max(0, (startSample - firstReal) / frameLength - before)
            let last = min(frameCount - 1, (endSample - firstReal) / frameLength + after)
            // A word outside the real audio is judged by the others' rules elsewhere.
            guard first <= last else { return true }
            return (first...last).contains { voice.isVoice(levels, frame: $0) }
        })
    }

    /// The two levels of every 10 ms frame, in dB: `loudness` (mean square) and
    /// `presence` (mean square after `emphasis`, averaged over `presenceFrames`).
    struct FrameLevels {
        var loudness: [Float]
        var presence: [Float]
        var count: Int { loudness.count }

        init<Sample>(_ samples: UnsafeBufferPointer<Sample>, frameLength: Int, value: (Sample) -> Double) {
            let count = samples.count / frameLength
            let weight = Double(SilentWordFilter.emphasis)
            var loud = [Float](repeating: -120, count: count)
            var emphasised = [Double](repeating: 0, count: count)
            var previous = 0.0
            for frame in 0..<count {
                var sum = 0.0
                var sumEmphasised = 0.0
                for index in (frame * frameLength)..<((frame + 1) * frameLength) {
                    let current = value(samples[index])
                    let difference = current - weight * previous
                    sum += current * current
                    sumEmphasised += difference * difference
                    previous = current
                }
                loud[frame] = Float(10 * log10(sum / Double(frameLength) + 1e-12))
                emphasised[frame] = sumEmphasised / Double(frameLength)
            }
            let reach = SilentWordFilter.presenceFrames / 2
            loudness = loud
            presence = (0..<count).map { frame in
                let around = max(0, frame - reach)...min(count - 1, frame + reach)
                let mean = around.reduce(0) { $0 + emphasised[$1] } / Double(around.count)
                return Float(10 * log10(mean + 1e-12))
            }
        }
    }

    /// What counts as voice among `frames`, set by their own quietest frames.
    struct VoiceThresholds {
        let loud: Float
        let steady: Float
        let presence: Float

        init(_ levels: FrameLevels, frames: Range<Int>) {
            let loudness = levels.loudness[frames].sorted()
            let presence = levels.presence[frames].sorted()
            func quantile(_ sorted: [Float], _ q: Double) -> Float {
                sorted[Int(q * Double(sorted.count - 1))]
            }
            let floor = quantile(loudness, SilentWordFilter.floorQuantile)
            let presenceFloor = quantile(presence, SilentWordFilter.floorQuantile)
            let spread = presenceFloor - quantile(presence, SilentWordFilter.spreadQuantile)
            loud = floor + SilentWordFilter.marginDecibels
            steady = floor + SilentWordFilter.steadyMarginDecibels
            self.presence = presenceFloor + max(SilentWordFilter.minimumRiseDecibels, SilentWordFilter.spreadFactor * spread)
        }

        func isVoice(_ levels: FrameLevels, frame: Int) -> Bool {
            let loudness = levels.loudness[frame]
            return loudness >= loud || (loudness >= steady && levels.presence[frame] >= presence)
        }
    }
}
