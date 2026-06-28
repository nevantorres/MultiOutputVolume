import Cocoa
import CoreAudio
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let audio = AudioController()
    private let mediaKeys = MediaKeyTap()
    private let hud = VolumeHUD()

    private var statusItem: NSStatusItem!
    private var slider: NSSlider!
    private var deviceMenuItem: NSMenuItem!
    private var muteMenuItem: NSMenuItem!
    private var loginMenuItem: NSMenuItem!
    private var deviceSubmenu: NSMenu!

    /// Keyboard step: 1/16, matching macOS's default volume increment.
    private let step: Float = 1.0 / 16.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Allow enabling login-at-launch from the command line (used by the
        // installer/build step) without the user opening the menu.
        if CommandLine.arguments.contains("--enable-login") {
            setLaunchAtLogin(true)
        }

        setupStatusItem()
        setupMediaKeys()

        audio.onDeviceChanged = { [weak self] in
            self?.refreshUI()
        }
        refreshUI()
    }

    // MARK: - Status item & menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()

        // Slider row
        let sliderItem = NSMenuItem()
        sliderItem.view = makeSliderView()
        menu.addItem(sliderItem)

        menu.addItem(.separator())

        deviceMenuItem = NSMenuItem(title: "Controlling: —", action: nil, keyEquivalent: "")
        deviceMenuItem.isEnabled = false
        menu.addItem(deviceMenuItem)

        let deviceParent = NSMenuItem(title: "Control Device", action: nil, keyEquivalent: "")
        deviceSubmenu = NSMenu()
        deviceSubmenu.delegate = self
        deviceParent.submenu = deviceSubmenu
        menu.addItem(deviceParent)

        muteMenuItem = NSMenuItem(title: "Mute", action: #selector(toggleMute), keyEquivalent: "")
        muteMenuItem.target = self
        menu.addItem(muteMenuItem)

        menu.addItem(.separator())

        loginMenuItem = NSMenuItem(title: "Launch at Login",
                                   action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginMenuItem.target = self
        menu.addItem(loginMenuItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Device dropdown (NSMenuDelegate)

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === deviceSubmenu {
            rebuildDeviceSubmenu()
        } else {
            // Main menu opening — make sure the slider matches the live volume.
            refreshUI()
        }
    }

    private func rebuildDeviceSubmenu() {
        deviceSubmenu.removeAllItems()

        let follow = NSMenuItem(title: "Follow Default Output",
                                action: #selector(selectFollowDefault), keyEquivalent: "")
        follow.target = self
        follow.state = (audio.manualDeviceID == nil) ? .on : .off
        deviceSubmenu.addItem(follow)
        deviceSubmenu.addItem(.separator())

        for device in audio.allOutputDevices() {
            let suffix = audio.isAggregate(device) ? "  (multi-output)" : ""
            let item = NSMenuItem(title: audio.name(of: device) + suffix,
                                  action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(device)
            item.state = (audio.manualDeviceID == device) ? .on : .off
            deviceSubmenu.addItem(item)
        }
    }

    @objc private func selectFollowDefault() {
        audio.manualDeviceID = nil
        refreshUI()
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        audio.manualDeviceID = AudioDeviceID(sender.tag)
        refreshUI()
    }

    private func makeSliderView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))

        let speakerLow = NSImageView(frame: NSRect(x: 12, y: 9, width: 18, height: 18))
        speakerLow.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil)
        speakerLow.contentTintColor = .secondaryLabelColor
        container.addSubview(speakerLow)

        slider = NSSlider(value: 0, minValue: 0, maxValue: 1,
                          target: self, action: #selector(sliderChanged(_:)))
        slider.frame = NSRect(x: 36, y: 7, width: 148, height: 22)
        slider.isContinuous = true
        container.addSubview(slider)

        let speakerHigh = NSImageView(frame: NSRect(x: 190, y: 9, width: 20, height: 18))
        speakerHigh.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)
        speakerHigh.contentTintColor = .secondaryLabelColor
        container.addSubview(speakerHigh)

        return container
    }

    // MARK: - Media keys

    private func setupMediaKeys() {
        mediaKeys.onVolumeUp = { [weak self] in self?.nudge(up: true) }
        mediaKeys.onVolumeDown = { [weak self] in self?.nudge(up: false) }
        mediaKeys.onMute = { [weak self] in self?.toggleMute() }

        if !mediaKeys.start() {
            promptForAccessibility()
        }
    }

    private func nudge(up: Bool) {
        let current = audio.volume
        let next = up ? current + step : current - step
        audio.setVolume(next)
        refreshUI()
        hud.show(volume: audio.volume, muted: audio.isMuted)
    }

    // MARK: - Actions

    @objc private func sliderChanged(_ sender: NSSlider) {
        audio.setVolume(Float(sender.doubleValue))
        updateStatusIcon()
    }

    @objc private func toggleMute() {
        audio.toggleMute()
        refreshUI()
        hud.show(volume: audio.volume, muted: audio.isMuted)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Launch at login

    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("Launch at login change failed: \(error)")
        }
    }

    @objc private func toggleLaunchAtLogin() {
        setLaunchAtLogin(!isLaunchAtLoginEnabled)
        refreshLoginItemState()
    }

    private func refreshLoginItemState() {
        loginMenuItem.state = isLaunchAtLoginEnabled ? .on : .off
    }

    // MARK: - UI refresh

    private func refreshUI() {
        let volume = audio.volume
        let muted = audio.isMuted
        slider.doubleValue = Double(volume)

        let suffix = audio.isMultiOutput ? "  (multi-output)" : ""
        let mode = audio.manualDeviceID == nil ? "  ·  following default" : ""
        deviceMenuItem.title = "Controlling: \(audio.deviceName)\(suffix)\(mode)"
        muteMenuItem.title = muted ? "Unmute" : "Mute"
        muteMenuItem.state = muted ? .on : .off

        refreshLoginItemState()
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let volume = audio.volume
        let muted = audio.isMuted
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
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Volume")
    }

    // MARK: - Permissions

    private func promptForAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Needed"
        alert.informativeText = """
            To use the keyboard volume keys, grant this app access in
            System Settings → Privacy & Security → Accessibility,
            then quit and relaunch.

            The menu-bar slider works without this permission.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }
}
