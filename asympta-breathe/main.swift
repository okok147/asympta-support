import AppKit
import ScreenCaptureKit
import CoreGraphics
import QuartzCore

private let appBundleID = "com.asympta.breathe"

private struct TargetWindow {
    let windowID: CGWindowID
    let cgFrame: CGRect
    let appKitFrame: CGRect
}

private struct AppTarget {
    let app: NSRunningApplication
    let windows: [TargetWindow]
    let appName: String
}

private struct CapturedWindow {
    let target: TargetWindow
    let image: CGImage
}

private final class WakePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class FadeSession {
    let target: AppTarget
    let imagePanels: [NSPanel]
    let shieldPanels: [WakePanel]

    init(target: AppTarget, imagePanels: [NSPanel], shieldPanels: [WakePanel]) {
        self.target = target
        self.imagePanels = imagePanels
        self.shieldPanels = shieldPanels
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var tickTimer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?

    private var session: FadeSession?
    private var captureTask: Task<Void, Never>?

    private var lastActivityAt = ProcessInfo.processInfo.systemUptime
    private var wakeArmedAt: TimeInterval = 0
    private var lastExternalPID: pid_t?
    private var lastExternalAppName: String?

    private var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "enabled") == nil { return true }
            return UserDefaults.standard.bool(forKey: "enabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "enabled")
            if !newValue { restoreNow() }
            lastActivityAt = ProcessInfo.processInfo.systemUptime
            rebuildMenu()
        }
    }

    private var idleSeconds: Double {
        get {
            let value = UserDefaults.standard.double(forKey: "idleSeconds")
            return value > 0 ? value : 4
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "idleSeconds")
            lastActivityAt = ProcessInfo.processInfo.systemUptime
            rebuildMenu()
        }
    }

    private var fadeSeconds: Double {
        get {
            let value = UserDefaults.standard.double(forKey: "fadeSeconds")
            return value > 0 ? value : 9
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "fadeSeconds")
            rebuildMenu()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalPID = app.processIdentifier
            lastExternalAppName = app.localizedName
        }

        buildStatusItem()
        installActivityMonitors()
        installWorkspaceObserver()

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            if !CGPreflightScreenCaptureAccess() {
                _ = CGRequestScreenCaptureAccess()
            }
            self.rebuildMenu()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tickTimer?.invalidate()
        captureTask?.cancel()

        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }

        restoreNow()
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "circle.lefthalf.filled",
                accessibilityDescription: "Asympta Breathe"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Asympta Breathe"
        }

        rebuildMenu()
    }

    private func rebuildMenu() {
        guard statusItem != nil else { return }

        let menu = NSMenu()

        let title = NSMenuItem(title: "Asympta Breathe", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let statusText: String
        if !CGPreflightScreenCaptureAccess() {
            statusText = "Screen Recording permission needed"
        } else if session != nil {
            statusText = "Breathing out"
        } else if let appName = currentExternalAppName() ?? lastExternalAppName {
            statusText = enabled ? "Watching · \(appName)" : "Disabled"
        } else {
            statusText = enabled ? "Waiting for an app" : "Disabled"
        }

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())

        let enabledItem = NSMenuItem(
            title: "Enabled",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        enabledItem.target = self
        enabledItem.state = enabled ? .on : .off
        menu.addItem(enabledItem)

        let breathe = NSMenuItem(
            title: "Breathe Current App Now",
            action: #selector(breatheNow),
            keyEquivalent: ""
        )
        breathe.target = self
        breathe.isEnabled = CGPreflightScreenCaptureAccess() && session == nil && lastExternalPID != nil
        menu.addItem(breathe)

        menu.addItem(.separator())
        menu.addItem(
            makeValueMenu(
                title: "Idle delay",
                current: idleSeconds,
                values: [2, 4, 8, 15, 30],
                selector: #selector(setIdleDelay(_:))
            )
        )
        menu.addItem(
            makeValueMenu(
                title: "Fade duration",
                current: fadeSeconds,
                values: [3, 6, 9, 15, 30],
                selector: #selector(setFadeDuration(_:))
            )
        )

        let permissionAllowed = CGPreflightScreenCaptureAccess()
        let permission = NSMenuItem(
            title: permissionAllowed ? "Screen Recording: Allowed" : "Grant Screen Recording…",
            action: permissionAllowed ? nil : #selector(requestScreenRecording),
            keyEquivalent: ""
        )
        permission.target = self
        permission.isEnabled = !permissionAllowed
        menu.addItem(permission)

        menu.addItem(.separator())

        let scope = NSMenuItem(
            title: "Automatic · any frontmost app",
            action: nil,
            keyEquivalent: ""
        )
        scope.isEnabled = false
        menu.addItem(scope)

        let quit = NSMenuItem(
            title: "Quit Asympta Breathe",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        self.menu = menu
        statusItem.menu = menu
    }

    private func makeValueMenu(
        title: String,
        current: Double,
        values: [Double],
        selector: Selector
    ) -> NSMenuItem {
        let parent = NSMenuItem(
            title: "\(title): \(Int(current))s",
            action: nil,
            keyEquivalent: ""
        )

        let submenu = NSMenu()

        for value in values {
            let item = NSMenuItem(
                title: "\(Int(value)) seconds",
                action: selector,
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = value
            item.state = abs(value - current) < 0.001 ? .on : .off
            submenu.addItem(item)
        }

        parent.submenu = submenu
        return parent
    }

    private func installActivityMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel,
            .keyDown,
            .flagsChanged
        ]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in
                self?.noteUserActivity()
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }

            let now = ProcessInfo.processInfo.systemUptime

            if self.session != nil && now >= self.wakeArmedAt {
                Task { @MainActor in
                    self.restoreNow()
                }

                switch event.type {
                case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown:
                    return nil
                default:
                    return event
                }
            }

            self.noteUserActivity()
            return event
        }
    }

    private func installWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self, self.session == nil else { return }

                guard
                    let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                    app.activationPolicy == .regular
                else {
                    return
                }

                self.lastExternalPID = app.processIdentifier
                self.lastExternalAppName = app.localizedName
                self.lastActivityAt = ProcessInfo.processInfo.systemUptime
                self.rebuildMenu()
            }
        }
    }

    private func noteUserActivity() {
        let now = ProcessInfo.processInfo.systemUptime

        if session != nil {
            if now >= wakeArmedAt {
                restoreNow()
            }
            return
        }

        lastActivityAt = now

        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           app.activationPolicy == .regular {
            lastExternalPID = app.processIdentifier
            lastExternalAppName = app.localizedName
        }
    }

    private func tick() {
        guard enabled else { return }
        guard session == nil, captureTask == nil else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let idleFor = now - lastActivityAt

        guard idleFor >= idleSeconds else { return }
        guard let target = currentFrontmostTarget() else { return }

        startFade(target: target, manual: false)
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
    }

    @objc private func breatheNow() {
        guard session == nil, captureTask == nil else { return }

        let pid = lastExternalPID
        let target: AppTarget?

        if let current = currentFrontmostTarget() {
            target = current
        } else if let pid {
            target = targetForPID(pid)
        } else {
            target = nil
        }

        guard let target else {
            NSSound.beep()
            return
        }

        startFade(target: target, manual: true)
    }

    @objc private func setIdleDelay(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double {
            idleSeconds = value
        }
    }

    @objc private func setFadeDuration(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double {
            fadeSeconds = value
        }
    }

    @objc private func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        rebuildMenu()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func startFade(target: AppTarget, manual: Bool) {
        guard session == nil, captureTask == nil else { return }
        guard enabled || manual else { return }

        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            rebuildMenu()
            return
        }

        captureTask = Task { [weak self] in
            guard let self else { return }

            do {
                let shareable = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )

                let scWindowsByID = Dictionary(
                    uniqueKeysWithValues: shareable.windows.map { ($0.windowID, $0) }
                )

                var captured: [CapturedWindow] = []

                for window in target.windows {
                    guard let scWindow = scWindowsByID[window.windowID] else { continue }

                    let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                    let config = SCStreamConfiguration()
                    let scale = self.backingScale(for: window.appKitFrame)

                    config.width = max(1, Int(window.cgFrame.width * scale))
                    config.height = max(1, Int(window.cgFrame.height * scale))
                    config.showsCursor = false
                    config.queueDepth = 1
                    config.shouldBeOpaque = false

                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: filter,
                        configuration: config
                    )

                    captured.append(
                        CapturedWindow(target: window, image: image)
                    )
                }

                if Task.isCancelled {
                    self.captureTask = nil
                    return
                }

                guard !captured.isEmpty else {
                    self.captureTask = nil
                    NSSound.beep()
                    return
                }

                self.captureTask = nil
                self.presentFade(target: target, captured: captured, manual: manual)

            } catch {
                self.captureTask = nil
                NSSound.beep()
                self.rebuildMenu()
            }
        }
    }

    private func presentFade(
        target: AppTarget,
        captured: [CapturedWindow],
        manual: Bool
    ) {
        guard session == nil else { return }

        var imagePanels: [NSPanel] = []

        for item in captured {
            let panel = NSPanel(
                contentRect: item.target.appKitFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )

            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.alphaValue = 1
            panel.ignoresMouseEvents = true
            panel.level = .screenSaver
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary,
                .ignoresCycle
            ]
            panel.animationBehavior = .none

            let imageView = NSImageView(
                frame: NSRect(origin: .zero, size: item.target.appKitFrame.size)
            )
            imageView.image = NSImage(
                cgImage: item.image,
                size: item.target.appKitFrame.size
            )
            imageView.imageScaling = .scaleAxesIndependently
            imageView.imageAlignment = .alignCenter
            panel.contentView = imageView

            imagePanels.append(panel)
        }

        let shieldPanels = NSScreen.screens.map { screen -> WakePanel in
            let shield = WakePanel(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            shield.isOpaque = false
            shield.backgroundColor = .clear
            shield.hasShadow = false
            shield.alphaValue = 1
            shield.ignoresMouseEvents = false
            shield.acceptsMouseMovedEvents = true
            shield.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            shield.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary,
                .ignoresCycle
            ]
            shield.animationBehavior = .none
            shield.contentView = NSView(
                frame: NSRect(origin: .zero, size: screen.frame.size)
            )
            return shield
        }

        let newSession = FadeSession(
            target: target,
            imagePanels: imagePanels,
            shieldPanels: shieldPanels
        )

        session = newSession

        // Manual mode needs a longer grace period because the click that chose
        // "Breathe Current App Now" can generate trailing mouse events.
        wakeArmedAt = ProcessInfo.processInfo.systemUptime + (manual ? 0.85 : 0.22)

        imagePanels.forEach { $0.orderFrontRegardless() }
        shieldPanels.forEach { $0.orderFrontRegardless() }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self, weak newSession] in
            guard let self, let newSession, self.session === newSession else { return }

            guard target.app.hide() else {
                self.session = nil
                imagePanels.forEach {
                    $0.orderOut(nil)
                    $0.close()
                }
                shieldPanels.forEach {
                    $0.orderOut(nil)
                    $0.close()
                }
                NSSound.beep()
                self.rebuildMenu()
                return
            }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = self.fadeSeconds
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.37,
                    0.0,
                    0.63,
                    1.0
                )
                context.allowsImplicitAnimation = true

                for panel in imagePanels {
                    panel.animator().alphaValue = 0
                }
            }
        }

        rebuildMenu()
    }

    private func restoreNow() {
        guard let current = session else {
            lastActivityAt = ProcessInfo.processInfo.systemUptime
            return
        }

        session = nil
        captureTask?.cancel()
        captureTask = nil

        current.imagePanels.forEach { $0.alphaValue = 1 }

        _ = current.target.app.unhide()
        _ = current.target.app.activate(options: [])

        current.shieldPanels.forEach { $0.orderOut(nil) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            current.imagePanels.forEach {
                $0.orderOut(nil)
                $0.close()
            }
            current.shieldPanels.forEach { $0.close() }
        }

        lastActivityAt = ProcessInfo.processInfo.systemUptime
        lastExternalPID = current.target.app.processIdentifier
        lastExternalAppName = current.target.appName
        rebuildMenu()
    }

    private func currentFrontmostTarget() -> AppTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            if let pid = lastExternalPID {
                return targetForPID(pid)
            }
            return nil
        }

        guard app.activationPolicy == .regular else { return nil }
        guard app.bundleIdentifier != appBundleID else { return nil }

        lastExternalPID = app.processIdentifier
        lastExternalAppName = app.localizedName

        return targetForPID(app.processIdentifier)
    }

    private func targetForPID(_ pid: pid_t) -> AppTarget? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        guard !app.isTerminated, app.activationPolicy == .regular else { return nil }
        guard app.bundleIdentifier != appBundleID else { return nil }

        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements
        ]

        guard
            let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]]
        else {
            return nil
        }

        var windows: [TargetWindow] = []

        for info in list {
            guard
                let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                ownerPID == pid,
                let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                layer == 0,
                let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                alpha > 0.01,
                let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                let cgFrame = CGRect(
                    dictionaryRepresentation: bounds as CFDictionary
                ),
                cgFrame.width >= 120,
                cgFrame.height >= 80
            else {
                continue
            }

            windows.append(
                TargetWindow(
                    windowID: CGWindowID(number),
                    cgFrame: cgFrame,
                    appKitFrame: appKitFrame(fromCGWindowFrame: cgFrame)
                )
            )
        }

        guard !windows.isEmpty else { return nil }

        return AppTarget(
            app: app,
            windows: windows,
            appName: app.localizedName ?? "Current App"
        )
    }

    private func currentExternalAppName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return lastExternalAppName
        }
        guard app.activationPolicy == .regular else { return nil }
        return app.localizedName
    }

    private func appKitFrame(fromCGWindowFrame frame: CGRect) -> CGRect {
        let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height

        return CGRect(
            x: frame.minX,
            y: mainDisplayHeight - frame.minY - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    private func backingScale(for rect: CGRect) -> CGFloat {
        let center = CGPoint(x: rect.midX, y: rect.midY)

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return screen.backingScaleFactor
        }

        return NSScreen.main?.backingScaleFactor ?? 2
    }
}

@main
struct AsymptaBreatheMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        _ = delegate
    }
}
