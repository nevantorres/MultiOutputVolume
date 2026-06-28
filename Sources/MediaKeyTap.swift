import Cocoa

/// Intercepts the hardware volume keys (F10/F11/F12 and Touch Bar) via a
/// CGEventTap on NSSystemDefined events. When a key is handled the event is
/// swallowed so macOS does not also run its own (broken-for-aggregates)
/// volume handling. Requires Accessibility permission.
final class MediaKeyTap {

    var onVolumeUp: (() -> Void)?
    var onVolumeDown: (() -> Void)?
    var onMute: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Media key codes carried in NSSystemDefined.data1.
    private let keyTypeSoundUp: Int = 0
    private let keyTypeSoundDown: Int = 1
    private let keyTypeMute: Int = 7
    private let systemDefinedSubtype: Int16 = 8

    /// CGEventType has no public case for system-defined events; the raw value is 14.
    private let systemDefinedEventType = CGEventType(rawValue: 14)!

    @discardableResult
    func start() -> Bool {
        let mask = CGEventMask(1 << 14)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon!).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable the tap if the system disabled it (e.g. after a timeout).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == systemDefinedSubtype else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let keyIsPressed = keyState == 0x0A   // 0x0A = down, 0x0B = up

        guard keyIsPressed else { return Unmanaged.passUnretained(event) }

        switch keyCode {
        case keyTypeSoundUp:
            DispatchQueue.main.async { self.onVolumeUp?() }
            return nil
        case keyTypeSoundDown:
            DispatchQueue.main.async { self.onVolumeDown?() }
            return nil
        case keyTypeMute:
            DispatchQueue.main.async { self.onMute?() }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
