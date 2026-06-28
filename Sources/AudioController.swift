import CoreAudio
import AudioToolbox
import Foundation

/// Wraps Core Audio to provide a single "master" volume for the current
/// default output device — including aggregate / multi-output devices, which
/// do not expose their own volume control. For those, the volume change is
/// applied to every controllable channel of every sub-device.
final class AudioController {

    /// Called whenever the underlying default output device changes, so the UI
    /// can refresh (device name, current volume, etc).
    var onDeviceChanged: (() -> Void)?

    private let outputScope = kAudioObjectPropertyScopeOutput
    private let mainElement = kAudioObjectPropertyElementMain

    init() {
        installDefaultDeviceListener()
    }

    // MARK: - Default output device

    var defaultOutputDevice: AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: mainElement)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return deviceID
    }

    var deviceName: String {
        name(of: defaultOutputDevice)
    }

    func name(of device: AudioDeviceID) -> String {
        guard device != 0 else { return "No Output Device" }
        var nameRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: mainElement)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &nameRef)
        guard status == noErr, let nameRef else { return "Output Device" }
        return nameRef.takeRetainedValue() as String
    }

    /// True when the current default device is an aggregate / multi-output device.
    var isMultiOutput: Bool {
        transportType(of: defaultOutputDevice) == kAudioDeviceTransportTypeAggregate
    }

    private func transportType(of device: AudioDeviceID) -> UInt32 {
        var type = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: mainElement)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &type)
        return type
    }

    // MARK: - Target devices (handles aggregate fan-out)

    /// The concrete devices whose channels we actually drive. For a normal
    /// device that is just the device itself; for an aggregate/multi-output it
    /// is the list of sub-devices.
    private func targetDevices(for device: AudioDeviceID) -> [AudioDeviceID] {
        guard transportType(of: device) == kAudioDeviceTransportTypeAggregate else {
            return [device]
        }
        let subs = subDeviceUIDs(of: device).compactMap { deviceID(forUID: $0) }
        return subs.isEmpty ? [device] : subs
    }

    private func subDeviceUIDs(of device: AudioDeviceID) -> [String] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: mainElement)
        var arrayRef: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &arrayRef)
        guard status == noErr, let array = arrayRef?.takeRetainedValue() else { return [] }
        return (array as? [String]) ?? []
    }

    private func deviceID(forUID uid: String) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID = uid as CFString
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: mainElement)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr,
                UInt32(MemoryLayout<CFString>.size), uidPtr,
                &size, &deviceID)
        }
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    // MARK: - Controllable volume elements

    /// The channel elements on `device` that have a settable scalar volume.
    /// Prefers the master element (0); falls back to the preferred stereo pair
    /// or an explicit channel scan.
    private func controllableElements(of device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        if isVolumeSettable(device, mainElement) { return [mainElement] }

        var elements: [AudioObjectPropertyElement] = []
        for ch in preferredStereoChannels(of: device) where isVolumeSettable(device, ch) {
            elements.append(ch)
        }
        if !elements.isEmpty { return elements }

        // Last resort: scan the first 32 channels.
        for ch in 1...32 where isVolumeSettable(device, AudioObjectPropertyElement(ch)) {
            elements.append(AudioObjectPropertyElement(ch))
        }
        return elements
    }

    private func preferredStereoChannels(of device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var channels: [UInt32] = [1, 2]
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: outputScope,
            mElement: mainElement)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &channels)
        return channels.map { AudioObjectPropertyElement($0) }
    }

    private func isVolumeSettable(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: outputScope,
            mElement: element)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    // MARK: - Get / set volume (0.0 ... 1.0)

    /// Reads a representative current volume from the first controllable element.
    var volume: Float {
        let device = defaultOutputDevice
        for target in targetDevices(for: device) {
            if let element = controllableElements(of: target).first {
                return readScalar(target, element)
            }
        }
        return 0
    }

    @discardableResult
    func setVolume(_ value: Float) -> Bool {
        let clamped = max(0, min(1, value))
        let device = defaultOutputDevice
        var didSet = false
        for target in targetDevices(for: device) {
            for element in controllableElements(of: target) {
                if writeScalar(target, element, clamped) { didSet = true }
            }
        }
        // Unmute when the user raises volume above zero.
        if clamped > 0 { setMuted(false) }
        return didSet
    }

    private func readScalar(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement) -> Float {
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: outputScope,
            mElement: element)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        return Float(value)
    }

    @discardableResult
    private func writeScalar(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement, _ value: Float) -> Bool {
        var newValue = Float32(value)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: outputScope,
            mElement: element)
        return AudioObjectSetPropertyData(
            device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &newValue) == noErr
    }

    // MARK: - Mute

    var isMuted: Bool {
        let device = defaultOutputDevice
        for target in targetDevices(for: device) {
            var muted = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: outputScope,
                mElement: mainElement)
            if AudioObjectHasProperty(target, &addr),
               AudioObjectGetPropertyData(target, &addr, 0, nil, &size, &muted) == noErr {
                return muted != 0
            }
        }
        return false
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        let device = defaultOutputDevice
        var value = UInt32(muted ? 1 : 0)
        for target in targetDevices(for: device) {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: outputScope,
                mElement: mainElement)
            var settable: DarwinBoolean = false
            if AudioObjectHasProperty(target, &addr),
               AudioObjectIsPropertySettable(target, &addr, &settable) == noErr,
               settable.boolValue {
                AudioObjectSetPropertyData(
                    target, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
            } else if muted {
                // Device has no mute control (common for aggregates): emulate by
                // dropping volume to zero. Unmute is handled by restoring volume.
                for element in controllableElements(of: target) {
                    writeScalar(target, element, 0)
                }
            }
        }
    }

    // MARK: - Default device change listener

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    private func installDefaultDeviceListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: mainElement)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.onDeviceChanged?() }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }
}
