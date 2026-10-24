import AppKit
import MetalKit
import ServiceManagement
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SPUStandardUserDriverDelegate {
    private var window: OverlayWindow!
    private var view: MTKView!
    private var simulation: SnowSimulation!
    private var renderer: Renderer!
    private let tracker = WindowTracker()
    private let sceneLight = SceneLight()
    private var snowOnWindows = true
    private var statusItem: NSStatusItem!
    private var snowfallItems: [NSMenuItem] = []
    private var accumulateItem: NSMenuItem!
    private var meltItem: NSMenuItem!
    private var snowOnWindowsItem: NSMenuItem!
    private var behindWindowsItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var observers: [NSObjectProtocol] = []
    private var screensAsleep = false
    private var screenLocked = false
    private var sessionInactive = false
    private var updater: SPUStandardUpdaterController!
    private var welcome: WelcomeController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppMover.moveIfNeeded() {
            NSApp.terminate(nil)
            return
        }
        Preferences.registerDefaults()
        guard let screen = NSScreen.screens.first, let device = MTLCreateSystemDefaultDevice() else {
            NSApp.terminate(nil)
            return
        }

        simulation = SnowSimulation(
            width: Float(screen.frame.width),
            height: Float(screen.frame.height),
            snowfall: Preferences.snowfall
        )
        simulation.thaws = Preferences.meltSnow
        simulation.accumulates = Preferences.accumulate
        snowOnWindows = Preferences.snowOnWindows
        do {
            renderer = try Renderer(device: device, pixelFormat: .bgra8Unorm, simulation: simulation)
        } catch {
            NSLog("Snowhush: Metal setup failed: \(error)")
            NSApp.terminate(nil)
            return
        }

        window = OverlayWindow(screen: screen)
        window.behindWindows = Preferences.behindWindows
        view = makeView(device: device, size: screen.frame.size)
        renderer.cursorLocation = { [unowned self] in
            let mouse = NSEvent.mouseLocation
            let origin = window.frame.origin
            return SIMD2(Float(mouse.x - origin.x), Float(mouse.y - origin.y))
        }
        renderer.windowSurfaces = { [unowned self] now in
            snowOnWindows && !window.behindWindows ? tracker.poll(now: now, eager: NSEvent.pressedMouseButtons != 0) : nil
        }
        renderer.sceneLight = { [unowned self] now in
            sceneLight.update(screen: window.screen, now: now)
            return (sceneLight.light, sceneLight.shadowTint)
        }
        measure(screen)
        view.delegate = renderer
        window.contentView = view
        window.orderFrontRegardless()

        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        statusItem = makeStatusItem()
        updateStatusIcon()
        observeSystem()
        if !Preferences.welcomed {
            simulation.snowfallHeld = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.showWelcome() }
        }
    }

    // A menu bar app has no Dock icon to badge, so update reminders are left to Sparkle's own gentle alerts.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    private func showWelcome() {
        let welcome = WelcomeController()
        welcome.scatter = { [weak self] pieces in self?.simulation.scatter(pieces) }
        welcome.overlayOrigin = { [weak self] in self?.window.frame.origin ?? .zero }
        welcome.skipped = { [weak self] in self?.simulation.snowfallHeld = false }
        welcome.finished = { [weak self] in
            Preferences.welcomed = true
            self?.welcome = nil
        }
        self.welcome = welcome
        welcome.show()
    }

    private func makeView(device: MTLDevice, size: CGSize) -> MTKView {
        let view = MTKView(frame: CGRect(origin: .zero, size: size), device: device)
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 30
        view.autoresizingMask = [.width, .height]
        view.autoResizeDrawable = false
        Renderer.fitDrawable(of: view)
        return view
    }

    // MARK: - Menu

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Snowhush")

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        menu.addItem(.sectionHeader(title: "Snowfall"))
        snowfallItems = Snowfall.allCases.map { snowfall in
            let entry = add(snowfall.title, #selector(selectSnowfall(_:)), to: menu)
            entry.tag = snowfall.rawValue
            return entry
        }
        menu.addItem(.separator())
        accumulateItem = add("Accumulate", #selector(toggleAccumulate), to: menu)
        meltItem = add("Melt Snow", #selector(toggleMeltSnow), to: menu)
        snowOnWindowsItem = add("Snow on Windows", #selector(toggleSnowOnWindows), to: menu)
        menu.addItem(.separator())
        behindWindowsItem = add("Behind Windows", #selector(toggleBehindWindows), to: menu)
        loginItem = add("Open at Login", #selector(toggleOpenAtLogin), to: menu)
        menu.addItem(.separator())
        let updates = menu.addItem(withTitle: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updates.target = updater
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
        return item
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in snowfallItems {
            item.state = item.tag == simulation.snowfall.rawValue ? .on : .off
        }
        accumulateItem.state = simulation.accumulates ? .on : .off
        meltItem.state = simulation.thaws ? .on : .off
        meltItem.isEnabled = simulation.accumulates
        snowOnWindowsItem.state = snowOnWindows ? .on : .off
        snowOnWindowsItem.isEnabled = !window.behindWindows
        behindWindowsItem.state = window.behindWindows ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func selectSnowfall(_ sender: NSMenuItem) {
        guard let snowfall = Snowfall(rawValue: sender.tag) else { return }
        simulation.snowfall = snowfall
        Preferences.snowfall = snowfall
        updateStatusIcon()
    }

    @objc private func toggleAccumulate() {
        simulation.accumulates.toggle()
        Preferences.accumulate = simulation.accumulates
    }

    @objc private func toggleMeltSnow() {
        simulation.thaws.toggle()
        Preferences.meltSnow = simulation.thaws
    }

    @objc private func toggleSnowOnWindows() {
        snowOnWindows.toggle()
        Preferences.snowOnWindows = snowOnWindows
        if !snowOnWindows { dropWindowSnow() }
    }

    @objc private func toggleBehindWindows() {
        window.behindWindows.toggle()
        Preferences.behindWindows = window.behindWindows
        if window.behindWindows { dropWindowSnow() }
    }

    private func dropWindowSnow() {
        simulation.updateWindows([], interval: 0.1)
        tracker.reset()
    }

    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Snowhush: login item change failed: \(error)")
        }
    }

    private func updateStatusIcon() {
        statusItem.button?.appearsDisabled = simulation.snowfall == .off
    }

    // MARK: - System

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false }
        observe(.default, NSWindow.didChangeOcclusionStateNotification, object: window) { _ in }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.fitToScreen() }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) {
            $0.simulation.spaceChanged()
            $0.sceneLight.invalidate()
            $0.tracker.watchClosely(now: CACurrentMediaTime())
        }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.tracker.watchClosely(now: CACurrentMediaTime()) }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        object: AnyObject? = nil,
        _ change: @escaping (AppDelegate) -> Void
    ) {
        observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            guard let self else { return }
            change(self)
            self.updateActivity()
        })
    }

    private func updateActivity() {
        let active = window.occlusionState.contains(.visible) && !screensAsleep && !screenLocked && !sessionInactive
        guard view.isPaused == active else { return }
        view.isPaused = !active
        if active { renderer.resetClock() }
    }

    private func fitToScreen() {
        guard let screen = NSScreen.screens.first else { return }
        window.setFrame(screen.frame, display: true)
        Renderer.fitDrawable(of: view)
        simulation.resize(width: Float(screen.frame.width), height: Float(screen.frame.height))
        measure(screen)
    }

    private func measure(_ screen: NSScreen) {
        tracker.screen = CGRect(origin: .zero, size: screen.frame.size)
        tracker.menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        tracker.reset()
    }
}
