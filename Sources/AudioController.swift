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

    /// Cache of each device's settable volume elements — the channel scan in
    /// `controllableElements` is not free and runs on every get/set.
    private var elementCache: [AudioDeviceID: [AudioObjectPropertyElement]] = [:]

    /// Cache of an aggregate's resolved sub-devices — the UID translation in
    /// `targetDevices` is comparatively slow and runs on every get/set.
    private var targetCache: [AudioDeviceID: [AudioDeviceID]] = [:]

    /// Bookkeeping for the emulated mute used on devices with no hardware mute
    /// (aggregates / multi-output). `emulatedMuteDevice` records which device is
    /// currently muted-by-zeroing so we can restore `preMuteVolume` on unmute.
    private var emulatedMuteDevice: AudioDeviceID?
    private var preMuteVolume: Float = 0
    private let defaultUnmuteVolume: Float = 1.0 / 16.0

    /// The level we intend the device to be at. Devices quantise the volume
    /// scalar to their own grid, so reading it back between key steps drifts and
    /// makes a held ramp uneven. We step from this intended value instead and
    /// re-seed it from the device only when something external could change it.
    private var pendingVolume: Float?

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

    /// When non-nil the app controls this specific device instead of following
    /// the system default output. Reset automatically if the device disappears.
    var manualDeviceID: AudioDeviceID? {
        didSet { pendingVolume = nil }   // re-seed the level tracker for the new device
    }

    /// The device the slider / keys actually drive.
    var activeDevice: AudioDeviceID {
        if let id = manualDeviceID, allOutputDevices().contains(id) {
            return id
        }
        return defaultOutputDevice
    }

    var deviceName: String {
        name(of: activeDevice)
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

    /// True when the active device is an aggregate / multi-output device.
    var isMultiOutput: Bool {
        isAggregate(activeDevice)
    }

    func isAggregate(_ device: AudioDeviceID) -> Bool {
        transportType(of: device) == kAudioDeviceTransportTypeAggregate
    }

    /// All devices that have at least one output channel (the candidates for
    /// the control dropdown), in the order Core Audio reports them.
    func allOutputDevices() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: mainElement)
        var size = UInt32(0)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { outputChannelCount(of: $0) > 0 }
    }

    private func outputChannelCount(of device: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: outputScope,
            mElement: mainElement)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, bufferList) == noErr else {
            return 0
        }
        let abl = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
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
        if let cached = targetCache[device] { return cached }
        let result = computeTargetDevices(for: device)
        targetCache[device] = result
        return result
    }

    private func computeTargetDevices(for device: AudioDeviceID) -> [AudioDeviceID] {
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

    /// The channel elements on `device` that have a settable scalar volume,
    /// memoised per device (device configs rarely change, and the cache is
    /// cleared whenever the hardware topology does).
    private func controllableElements(of device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        if let cached = elementCache[device] { return cached }
        let result = computeControllableElements(of: device)
        elementCache[device] = result
        return result
    }

    /// Prefers the master element (0); falls back to the preferred stereo pair
    /// or an explicit channel scan.
    private func computeControllableElements(of device: AudioDeviceID) -> [AudioObjectPropertyElement] {
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
        let device = activeDevice
        for target in targetDevices(for: device) {
            if let element = controllableElements(of: target).first {
                return readScalar(target, element)
            }
        }
        return 0
    }

    /// Sets the volume on every controllable element and returns the value that
    /// was actually applied (clamped), so callers can update the UI without a
    /// second round-trip through Core Audio.
    @discardableResult
    func setVolume(_ value: Float) -> Float {
        let clamped = max(0, min(1, value))
        let device = activeDevice
        for target in targetDevices(for: device) {
            for element in controllableElements(of: target) {
                writeScalar(target, element, clamped)
            }
        }
        pendingVolume = clamped
        // The user set an explicit level, so just drop any mute state — don't
        // restore a saved pre-mute volume over the value we just wrote.
        if clamped > 0 { clearMuteState() }
        return clamped
    }

    /// Steps the volume by `delta` from the intended level (not a re-read of the
    /// device), giving even increments when a key is held down. Returns the new
    /// applied level.
    @discardableResult
    func nudgeVolume(by delta: Float) -> Float {
        let base = pendingVolume ?? volume
        return setVolume(base + delta)
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
        let device = activeDevice
        for target in targetDevices(for: device) {
            var muted = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: outputScope,
                mElement: mainElement)
            if AudioObjectHasProperty(target, &addr),
               AudioObjectGetPropertyData(target, &addr, 0, nil, &size, &muted) == noErr,
               muted != 0 {
                return true
            }
        }
        // No hardware mute reported it as muted — fall back to our emulated state.
        return emulatedMuteDevice == device
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        let device = activeDevice
        let targets = targetDevices(for: device)

        if muted {
            // Capture a representative level before any emulation zeroes it.
            let current = volume
            var emulated = false
            for target in targets where !setHardwareMute(target, true) {
                // No hardware mute (common for aggregates): emulate by zeroing.
                for element in controllableElements(of: target) {
                    writeScalar(target, element, 0)
                }
                emulated = true
            }
            if emulated {
                preMuteVolume = current
                emulatedMuteDevice = device
            }
        } else {
            for target in targets where !setHardwareMute(target, false) {
                // Restore the pre-mute level we emulated our way down from.
                guard emulatedMuteDevice == device else { continue }
                let restore = preMuteVolume > 0 ? preMuteVolume : defaultUnmuteVolume
                for element in controllableElements(of: target) {
                    writeScalar(target, element, restore)
                }
            }
            if emulatedMuteDevice == device { emulatedMuteDevice = nil }
        }
    }

    /// Sets a device's hardware mute if it exposes a settable one. Returns
    /// whether it did — `false` means the device has no hardware mute to control
    /// and the caller should emulate it.
    @discardableResult
    private func setHardwareMute(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: outputScope,
            mElement: mainElement)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectIsPropertySettable(device, &addr, &settable) == noErr,
              settable.boolValue else { return false }
        var value = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(
            device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// Clears mute (hardware and emulated) *without* restoring a saved level —
    /// used when the user has just set an explicit non-zero volume.
    private func clearMuteState() {
        for target in targetDevices(for: activeDevice) {
            setHardwareMute(target, false)
        }
        emulatedMuteDevice = nil
    }

    // MARK: - Default device change listener

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    private func installDefaultDeviceListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: mainElement)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.elementCache.removeAll()
                self?.targetCache.removeAll()
                self?.pendingVolume = nil
                self?.onDeviceChanged?()
            }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }
}
