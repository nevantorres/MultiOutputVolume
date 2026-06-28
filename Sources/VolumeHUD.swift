import Cocoa

/// A small borderless overlay shown briefly when the volume changes via the
/// keyboard, replacing the system HUD that we suppress.
final class VolumeHUD {

    private var window: NSWindow?
    private let bar = NSProgressIndicator()
    private let icon = NSImageView()
    private var hideTimer: Timer?

    private func makeWindowIfNeeded() {
        guard window == nil else { return }

        let size = NSSize(width: 200, height: 200)
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let visual = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 18
        visual.layer?.masksToBounds = true

        icon.frame = NSRect(x: 60, y: 70, width: 80, height: 80)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .labelColor
        visual.addSubview(icon)

        bar.frame = NSRect(x: 24, y: 36, width: size.width - 48, height: 8)
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.style = .bar
        visual.addSubview(bar)

        win.contentView = visual
        positionWindow(win)
        window = win
    }

    private func positionWindow(_ win: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        let size = win.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + 140
        win.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func show(volume: Float, muted: Bool) {
        makeWindowIfNeeded()
        guard let window else { return }

        let symbol: String
        if muted || volume == 0 {
            symbol = "speaker.slash.fill"
        } else if volume < 0.34 {
            symbol = "speaker.wave.1.fill"
        } else if volume < 0.67 {
            symbol = "speaker.wave.2.fill"
        } else {
            symbol = "speaker.wave.3.fill"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Volume")
        bar.doubleValue = muted ? 0 : Double(volume)

        positionWindow(window)
        window.alphaValue = 1
        window.orderFrontRegardless()

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.fadeOut()
        }
    }

    private func fadeOut() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
        })
    }
}
