#if os(macOS)
import Combine
import CoreAudio
import Foundation
import SubtitolCore

/// A device the Mac can record from: the built-in microphone, a USB interface, a
/// headset, an iPhone used as a microphone, or a virtual device fed by a mixer.
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    /// Stable across launches and reconnections, unlike `id`.
    let uid: String
    let name: String
    let transport: UInt32

    var transportLabel: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: localized("Integrat")
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeThunderbolt: "Thunderbolt"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: localized("Pantalla")
        case kAudioDeviceTransportTypeAggregate: localized("Agregat")
        case kAudioDeviceTransportTypeVirtual: localized("Virtual")
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: "iPhone"
        default: localized("Extern")
        }
    }

    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: "laptopcomputer"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt: "cable.connector"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "display"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: "iphone"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual: "waveform"
        default: "mic.fill"
        }
    }
}

/// The Mac's audio inputs, read from Core Audio.
enum AudioInputs {
    static func all() -> [AudioInputDevice] {
        let ids: [AudioDeviceID] = arrayProperty(
            of: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        )
        return ids.compactMap { id in
            let hidden: UInt32 = scalarProperty(of: id, selector: kAudioDevicePropertyIsHidden) ?? 0
            guard hidden == 0,
                  inputChannelCount(of: id) > 0,
                  let uid = stringProperty(of: id, selector: kAudioDevicePropertyDeviceUID),
                  // Core Audio's own aggregate appears while an app records, and is
                  // nothing a person can choose.
                  !uid.hasPrefix("CADefaultDeviceAggregate") else { return nil }
            let name = stringProperty(of: id, selector: kAudioObjectPropertyName) ?? uid
            let transport: UInt32 = scalarProperty(of: id, selector: kAudioDevicePropertyTransportType) ?? 0
            return AudioInputDevice(id: id, uid: uid, name: name, transport: transport)
        }
    }

    static func defaultDeviceID() -> AudioDeviceID? {
        let id: AudioDeviceID? = scalarProperty(
            of: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice
        )
        return id == kAudioObjectUnknown ? nil : id
    }

    /// The device to record from: the chosen one while it is connected, otherwise
    /// whatever the system uses.
    static func resolve(preferredUID: String?) -> AudioDeviceID? {
        if let preferredUID, let device = all().first(where: { $0.uid == preferredUID }) {
            return device.id
        }
        return defaultDeviceID()
    }

    /// Calls `handler` on the main queue whenever a device comes or goes or the
    /// system input changes. Returns what `stopObserving` needs.
    static func observeChanges(_ handler: @escaping () -> Void) -> AudioObjectPropertyListenerBlock {
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        for selector in observedSelectors {
            var address = globalAddress(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
        return block
    }

    static func stopObserving(_ block: @escaping AudioObjectPropertyListenerBlock) {
        for selector in observedSelectors {
            var address = globalAddress(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    private static let observedSelectors = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice,
    ]

    // MARK: - Core Audio properties

    private static func globalAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func scalarProperty<T>(of object: AudioObjectID, selector: AudioObjectPropertySelector) -> T? {
        var address = globalAddress(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.load(as: T.self)
    }

    private static func arrayProperty<T>(of object: AudioObjectID, selector: AudioObjectPropertySelector) -> [T] {
        var address = globalAddress(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let capacity = Int(size) / MemoryLayout<T>.stride
        return [T](unsafeUninitializedCapacity: capacity) { buffer, initialized in
            var filled = size
            guard let base = buffer.baseAddress,
                  AudioObjectGetPropertyData(object, &address, 0, nil, &filled, base) == noErr else {
                initialized = 0
                return
            }
            initialized = Int(filled) / MemoryLayout<T>.stride
        }
    }

    private static func stringProperty(of object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = globalAddress(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func inputChannelCount(of device: AudioDeviceID) -> Int {
        var address = globalAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// The inputs for the settings bar, kept current as devices are plugged in and out.
@MainActor
final class AudioInputDeviceList: ObservableObject {
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var systemDefaultUID: String?

    private var listener: AudioObjectPropertyListenerBlock?

    init() {
        refresh()
        listener = AudioInputs.observeChanges { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let listener { AudioInputs.stopObserving(listener) }
    }

    var systemDefault: AudioInputDevice? {
        devices.first { $0.uid == systemDefaultUID }
    }

    private func refresh() {
        let devices = AudioInputs.all()
        let defaultID = AudioInputs.defaultDeviceID()
        let defaultUID = devices.first { $0.id == defaultID }?.uid
        if devices != self.devices { self.devices = devices }
        if defaultUID != systemDefaultUID { systemDefaultUID = defaultUID }
    }
}
#endif

#if os(macOS)
import AVFoundation

/// Listens to one microphone just to show how loud it is, so a microphone can be checked
/// in the picker before and while listening. Nothing is kept: each buffer only updates the
/// loudest level heard since the meter last looked.
@MainActor
final class InputLevelMonitor: ObservableObject {
    enum Status: Equatable {
        case listening
        /// Waiting for the reader to answer the permission prompt.
        case asking
        case denied
        /// The microphone would not open.
        case unavailable
    }

    /// Never silent about why the meter is still: a still bar has to mean silence.
    @Published private(set) var status: Status = .asking

    private var engine: AVAudioEngine?
    private var deviceID: AudioDeviceID?
    private let peak = PeakStore()

    /// Opens `deviceID`, or does nothing when it is already the one open. Every rebuild
    /// of the app is a new app to macOS, so the permission may not have been asked yet;
    /// opening the microphone picker is a fair moment to ask.
    func listen(to deviceID: AudioDeviceID?) {
        guard deviceID != self.deviceID || engine == nil else { return }
        stop()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            status = .asking
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted { self.listen(to: deviceID) } else { self.status = .denied }
                }
            }
            return
        default:
            status = .denied
            return
        }
        guard let deviceID else {
            status = .unavailable
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        var id = deviceID
        guard let unit = input.audioUnit,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            status = .unavailable
            return
        }
        // After choosing a device only the input side reports its real format.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            status = .unavailable
            return
        }
        let peak = peak
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let frames = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            var sum: Float = 0
            for channel in 0..<channelCount {
                let samples = channels[channel]
                for frame in 0..<frames { sum += samples[frame] * samples[frame] }
            }
            peak.observe((sum / Float(frames * channelCount)).squareRoot())
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            status = .unavailable
            return
        }
        self.engine = engine
        self.deviceID = deviceID
        status = .listening
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        deviceID = nil
        _ = peak.take()
        lastLevel = 0
    }

    /// The loudest level since the last call, 0...1 on a decibel scale: -60 dBFS and
    /// below is empty, -10 dBFS full, so speech sits across the middle of the bar.
    func level() -> Float {
        // The screen asks more often than buffers arrive; between them the last level holds.
        guard let rms = peak.take() else { return lastLevel }
        let decibels = 20 * log10(max(rms, 1e-6))
        lastLevel = min(1, max(0, (decibels + 60) / 50))
        return lastLevel
    }

    private var lastLevel: Float = 0

    private final class PeakStore: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Float?

        func observe(_ rms: Float) {
            lock.lock()
            value = max(value ?? 0, rms)
            lock.unlock()
        }

        /// `nil` when no buffer has arrived since the last call.
        func take() -> Float? {
            lock.lock()
            defer { value = nil; lock.unlock() }
            return value
        }
    }
}
#endif
