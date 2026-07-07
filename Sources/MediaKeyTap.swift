import Cocoa
import ApplicationServices

/// Intercepts the hardware volume keys (F10/F11/F12 and Touch Bar) via a
/// CGEventTap on NSSystemDefined events. When a key is handled the event is
/// swallowed so macOS does not also run its own (broken-for-aggregates)
/// volume handling. Requires Accessibility permission.
final class MediaKeyTap {

    /// The `fine` flag is true when Option+Shift is held, matching macOS's
    /// quarter-step fine volume adjustment.
    var onVolumeUp: ((_ fine: Bool) -> Void)?
    var onVolumeDown: ((_ fine: Bool) -> Void)?
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

    /// True once a working event tap has been installed.
    var isRunning: Bool { eventTap != nil }

    /// Whether this process is currently trusted for Accessibility. A CGEventTap
    /// on keyboard/system events only *delivers* events when the process is
    /// trusted, and — critically — trust is evaluated when the tap is created.
    /// So we must not create the tap until this is true, and must (re)create it
    /// once the user grants permission rather than assuming a relaunch.
    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Installs the event tap. Idempotent: a no-op once already running.
    /// Returns false (without side effects) when the process is not yet trusted,
    /// so the caller can prompt for permission and retry later.
    @discardableResult
    func start() -> Bool {
        if eventTap != nil { return true }

        // Creating the tap while untrusted yields a dead tap that never revives,
        // even after permission is later granted. Refuse until we're trusted.
        guard AXIsProcessTrusted() else { return false }

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
            NSLog("MediaKeyTap: tapCreate failed even though the process is trusted.")
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("MediaKeyTap: media key tap installed.")
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable the tap if the system disabled it (e.g. after a timeout).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            runOnMain { self.stopRepeating() }   // don't ramp on past a lost key-up
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
        let keyIsDown = keyState == 0x0A          // 0x0A = down, 0x0B = up
        let keyIsRepeat = (keyFlags & 0x1) != 0   // system auto-repeat of a held key

        // Only intercept the three keys we handle; let everything else pass.
        guard keyCode == keyTypeSoundUp
                || keyCode == keyTypeSoundDown
                || keyCode == keyTypeMute else {
            return Unmanaged.passUnretained(event)
        }

        if keyCode == keyTypeMute {
            // Toggle once per physical press; ignore repeats and the key-up.
            if keyIsDown && !keyIsRepeat {
                runOnMain { self.onMute?() }
            }
            return nil
        }

        // Volume up/down: drive our own smooth auto-repeat while held, rather
        // than one step per tap. We ignore the system's repeat events and run a
        // timer instead, so the ramp rate is consistent and quick.
        if keyIsDown {
            if !keyIsRepeat {
                // Option+Shift = fine (quarter-step) adjustment, matching macOS.
                let flags = event.flags
                let fine = flags.contains(.maskAlternate) && flags.contains(.maskShift)
                let action = keyCode == keyTypeSoundUp ? onVolumeUp : onVolumeDown
                runOnMain { self.beginRepeating(action, fine: fine) }
            }
        } else {
            runOnMain { self.stopRepeating() }
        }
        return nil
    }

    /// The event-tap callback already runs on the main thread, so run the work
    /// synchronously to avoid a run-loop-cycle of latency — and to keep working
    /// while a menu's tracking loop is up (which doesn't drain the main queue).
    /// Falls back to an async hop only in the unexpected off-main case.
    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - Press-and-hold auto-repeat

    private var repeatTimer: Timer?
    private var heldAction: ((Bool) -> Void)?
    private var heldFine = false
    private var repeatCount = 0

    /// Interval between steps once the key has been held past the initial delay.
    /// ~28 steps/s → full range in roughly half a second.
    private let repeatInterval: TimeInterval = 0.035
    /// Delay before a held key starts ramping, so a quick tap is a single step.
    private let repeatDelay: TimeInterval = 0.25
    /// Safety cap (~15 s of ramping) so a missed key-up can't run away.
    private let maxRepeats = 400

    private func beginRepeating(_ action: ((Bool) -> Void)?, fine: Bool) {
        guard let action else { return }
        stopRepeating()
        heldAction = action
        heldFine = fine
        repeatCount = 0

        action(fine)   // immediate first step

        // Add timers in .common mode so the ramp keeps firing even while a menu
        // is open (its tracking run-loop mode otherwise starves .default timers).
        let delayTimer = Timer(timeInterval: repeatDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            let ticker = Timer(timeInterval: self.repeatInterval, repeats: true) { [weak self] _ in
                guard let self, let held = self.heldAction else { return }
                self.repeatCount += 1
                if self.repeatCount > self.maxRepeats { self.stopRepeating(); return }
                held(self.heldFine)
            }
            self.repeatTimer = ticker
            RunLoop.main.add(ticker, forMode: .common)
        }
        repeatTimer = delayTimer
        RunLoop.main.add(delayTimer, forMode: .common)
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        heldAction = nil
    }
}
