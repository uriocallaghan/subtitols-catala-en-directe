import Foundation
import SubtitolCore

/// Explicitly opt-in diagnostic capture. Unless `SUBTITOL_DIAGNOSTICS_DIR` is set,
/// this type is not created and neither audio nor hypotheses touch disk.
final class DiagnosticCapture: @unchecked Sendable {
    private struct WordRecord: Codable {
        let text: String
        let startSequence: UInt64
        let endSequence: UInt64
        let confidence: Float?
    }

    private struct ObservationRecord: Codable {
        let recordedAt: Date
        let origin: String
        let windowStartSequence: UInt64
        let windowEndSequence: UInt64
        let windowIncludesSessionStart: Bool
        let sampleRate: Int32
        let timingQuality: String
        let captureToSnapshotMilliseconds: Double
        let inferenceMilliseconds: Double
        let audioQuality: AudioQualityMetrics
        let wordsDuringLowEnergyAudio: Int
        let words: [WordRecord]
    }

    private struct SessionRecord: Codable {
        let schemaVersion: Int
        let startedAt: Date
        let profile: String
        let audioFormat: String
        let privacy: String
    }

    private let rootURL: URL
    private let queue = DispatchQueue(label: "cat.subtitollive.diagnostics", qos: .utility)
    private let encoder: JSONEncoder
    private var audioHandle: FileHandle?
    private var observationHandle: FileHandle?
    private var lastAudioSequence: UInt64 = 0

    static func configuredFromEnvironment() -> DiagnosticCapture? {
        guard let path = ProcessInfo.processInfo.environment["SUBTITOL_DIAGNOSTICS_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return DiagnosticCapture(rootURL: URL(fileURLWithPath: path, isDirectory: true))
    }

    init(rootURL: URL) {
        self.rootURL = rootURL
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    func begin(profile: TranscriptionProfile) -> Bool {
        queue.sync {
            closeFiles()
            do {
                try FileManager.default.createDirectory(
                    at: rootURL,
                    withIntermediateDirectories: true
                )
                let directory = rootURL.appendingPathComponent(
                    "session-\(UUID().uuidString)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                let audioURL = directory.appendingPathComponent("audio.f32le")
                let observationsURL = directory.appendingPathComponent("observations.jsonl")
                FileManager.default.createFile(
                    atPath: audioURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
                FileManager.default.createFile(
                    atPath: observationsURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
                audioHandle = try FileHandle(forWritingTo: audioURL)
                observationHandle = try FileHandle(forWritingTo: observationsURL)
                lastAudioSequence = 0
                let session = SessionRecord(
                    schemaVersion: 1,
                    startedAt: Date(),
                    profile: profile.rawValue,
                    audioFormat: "mono Float32 little-endian; sample rate in every observation",
                    privacy: "Explicit opt-in via SUBTITOL_DIAGNOSTICS_DIR"
                )
                let sessionRecordURL = directory.appendingPathComponent("session.json")
                try encoder.encode(session).write(
                    to: sessionRecordURL,
                    options: .atomic
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: sessionRecordURL.path
                )
                return true
            } catch {
                closeFiles()
                return false
            }
        }
    }

    /// Writes only samples that were not present in the preceding rolling snapshot.
    /// Called outside the Core Audio tap, so diagnostic I/O cannot perturb capture.
    func recordAudio(_ audio: CapturedAudio) {
        guard audio.realSampleCount > 0, audio.sampleRate > 0 else { return }
        queue.async { [weak self] in
            guard let self, let audioHandle = self.audioHandle else { return }
            let firstSequence = max(self.lastAudioSequence, audio.sourceStartSequence)
            guard firstSequence < audio.sequence else { return }
            let offsetFromRealStart = Int(firstSequence - audio.sourceStartSequence)
            let firstIndex = audio.leadingPaddingSampleCount + offsetFromRealStart
            let endIndex = min(
                audio.samples.count,
                audio.leadingPaddingSampleCount + audio.realSampleCount
            )
            guard firstIndex < endIndex else { return }
            let unwritten = Array(audio.samples[firstIndex..<endIndex])
            let data = unwritten.withUnsafeBytes { Data($0) }
            do {
                try audioHandle.write(contentsOf: data)
                self.lastAudioSequence = audio.sequence
            } catch {
                self.closeFiles()
            }
        }
    }

    func record(update: LiveRecognitionUpdate) {
        let record = ObservationRecord(
            recordedAt: Date(),
            origin: update.origin.rawValue,
            windowStartSequence: update.windowStartSequence,
            windowEndSequence: update.audioEndSequence,
            windowIncludesSessionStart: update.windowIncludesSessionStart,
            sampleRate: update.sampleRate,
            timingQuality: update.timingQuality.rawValue,
            captureToSnapshotMilliseconds: update.captureToSnapshotMilliseconds,
            inferenceMilliseconds: update.inferenceMilliseconds,
            audioQuality: update.audioQuality,
            wordsDuringLowEnergyAudio: update.audioQuality.energySpeechDetected
                ? 0 : update.words.count,
            words: update.words.map {
                WordRecord(
                    text: $0.text,
                    startSequence: $0.startSequence,
                    endSequence: $0.endSequence,
                    confidence: $0.confidence
                )
            }
        )
        queue.async { [weak self] in
            guard let self, let handle = self.observationHandle else { return }
            do {
                var data = try self.encoder.encode(record)
                data.append(0x0A)
                try handle.write(contentsOf: data)
            } catch {
                self.closeFiles()
            }
        }
    }

    func finishAndWait() {
        queue.sync { closeFiles() }
    }

    private func closeFiles() {
        try? audioHandle?.close()
        try? observationHandle?.close()
        audioHandle = nil
        observationHandle = nil
        lastAudioSequence = 0
    }
}
