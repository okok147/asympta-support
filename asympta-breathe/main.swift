import AppKit
import ScreenCaptureKit
import CoreGraphics
import QuartzCore

private let appBundleID = "com.asympta.breathe"
private let anyInputEvent = CGEventType(rawValue: UInt32.max)!

private struct TargetWindow {
    let app: NSRunningApplication
    let windowID: CGWindowID
    let cgFrame: CGRect
    let appKitFrame: CGRect
    let appName: String
}

private final class WakePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class FadeSession {
    let target: TargetWindow
    let imagePanel: NSPanel
    let shieldPanel: WakePanel
    let startedAt: TimeInterval

    init(target: TargetWindow, imagePanel: NSPanel, shieldPanel: WakePanel) {
        self.target = target
        self.imagePanel = imagePanel
        self.shieldPanel = shieldPanel
        self.startedAt = ProcessInfo.processInfo.systemUptime
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var timer: Timer?
    private var localMonitor: Any?
    private var session: FadeSession?
    private var captureTask: Task<Void, Never>?
    private var lastEligibleTarget: TargetWindow?
    private var wakeArmedAt: TimeInterval = 0
    private var isLaunching = true

    private var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "enabled") == nil { return true }
            return UserDefaults.standard.bool(forKey: "enabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "enabled")
            if !newValue { restoreNow() }
            rebuildMenu()
        }
    }

    private var idleSeconds: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "idleSeconds")
            return v > 0 ? v : 4
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "idleSeconds")
            rebuildMenu()
        }
    }

    private var fadeSeconds: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "fadeSeconds")
            return v > 0 ? v : 9
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "fadeSeconds")
            rebuildMenu()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        installLocalWakeMonitor()

        timer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            self.isLaunching = false
            if !CGPreflightScreenCaptureAccess() {
                _ = CGRequestScreenCaptureAccess()
            }
            self.rebuildMenu()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        captureTask?.cancel()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        restoreNow()
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "Asympta Breathe")
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

        let stateText: String
        if !CGPreflightScreenCaptureAccess() {
            stateText = "Screen Recording permission needed"
        } else if session != nil {
            stateText = "Breathing out"
        } else if let target = lastEligibleTarget {
            stateText = "Ready · \(target.appName)"
        } else {
            stateText = "Ready"
        }
        let state = NSMenuItem(title: stateText, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())

        let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = enabled ? .on : .off
        menu.addItem(enabledItem)

        let breathe = NSMenuItem(title: "Breathe Current App Now", action: #selector(breatheNow), keyEquivalent: "")
        breathe.target = self
        breathe.isEnabled = CGPreflightScreenCaptureAccess() && session == nil && lastEligibleTarget != nil
        menu.addItem(breathe)

        menu.addItem(.separator())
        menu.addItem(makeValueMenu(title: "Idle delay", current: idleSeconds, values: [2, 4, 8, 15, 30], selector: #selector(setIdleDelay(_:))))
        menu.addItem(makeValueMenu(title: "Fade duration", current: fadeSeconds, values: [3, 6, 9, 15, 30], selector: #selector(setFadeDuration(_:))))

        let permission = NSMenuItem(
            title: CGPreflightScreenCaptureAccess() ? "Screen Recording: Allowed" : "Grant Screen Recording…",
            action: CGPreflightScreenCaptureAccess() ? nil : #selector(requestScreenRecording),
            keyEquivalent: ""
        )
        permission.target = self
        permission.isEnabled = !CGPreflightScreenCaptureAccess()
        menu.addItem(permission)

        menu.addItem(.separator())
        let scope = NSMenuItem(title: "Works with the frontmost app window (Safari, Chrome, etc.)", action: nil, keyEquivalent: "")
        scope.isEnabled = false
        menu.addItem(scope)

        let quit = NSMenuItem(title: "Quit Asympta Breathe", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        self.menu = menu
        statusItem.menu = menu
    }

    private func makeValueMenu(title: String, current: Double, values: [Double], selector: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: "\(title): \(Int(current))s", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for value in values {
            let item = NSMenuItem(title: "\(Int(value)) seconds", action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(value - current) < 0.001 ? .on : .off
            sub.addItem(item)
        }
        parent.submenu = sub
        return parent
    }

    private func installLocalWakeMonitor() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .scrollWheel, .keyDown, .flagsChanged
        ]

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            guard self.session != nil else { return event }
            guard ProcessInfo.processInfo.systemUptime >= self.wakeArmedAt else { return event }

            Task { @MainActor in self.restoreNow() }
            return nil
        }
    }

    private func tick() {
        if !isLaunching, session == nil, captureTask == nil {
            if let target = currentFrontmostTarget() {
                if lastEligibleTarget?.app.processIdentifier != target.app.processIdentifier ||
                   lastEligibleTarget?.windowID != target.windowID {
                    lastEligibleTarget = target
                    rebuildMenu()
                }
            }
        }

        guard enabled else { return }

        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEvent)

        if session != nil {
            if ProcessInfo.processInfo.systemUptime >= wakeArmedAt, idle < 0.18 {
                restoreNow()
            }
            return
        }

        guard captureTask == nil, idle >= idleSeconds else { return }
        guard let target = currentFrontmostTarget() else { return }
        startFade(target: target, manual: false)
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
    }

    @objc private func breatheNow() {
        guard let target = lastEligibleTarget ?? currentFrontmostTarget() else { return }
        startFade(target: target, manual: true)
    }

    @objc private func setIdleDelay(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { idleSeconds = v }
    }

    @objc private func setFadeDuration(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { fadeSeconds = v }
    }

    @objc private func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        rebuildMenu()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func startFade(target: TargetWindow, manual: Bool) {
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
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let scWindow = content.windows.first(where: { $0.windowID == target.windowID }) else {
                    self.captureTask = nil
                    return
                }

                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let config = SCStreamConfiguration()
                let scale = self.backingScale(for: target.appKitFrame)
                config.width = max(1, Int(target.cgFrame.width * scale))
                config.height = max(1, Int(target.cgFrame.height * scale))
                config.showsCursor = false
                config.queueDepth = 1
                config.shouldBeOpaque = false

                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                if Task.isCancelled { self.captureTask = nil; return }

                self.captureTask = nil
                self.presentFade(target: target, image: image, manual: manual)
            } catch {
                self.captureTask = nil
                NSSound.beep()
                self.rebuildMenu()
            }
        }
    }

    private func presentFade(target: TargetWindow, image: CGImage, manual: Bool) {
        guard session == nil else { return }

        let nsImage = NSImage(cgImage: image, size: target.appKitFrame.size)
        let imagePanel = NSPanel(
            contentRect: target.appKitFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        imagePanel.isOpaque = false
        imagePanel.backgroundColor = .clear
        imagePanel.hasShadow = false
        imagePanel.alphaValue = 1
        imagePanel.ignoresMouseEvents = true
        imagePanel.level = .screenSaver
        imagePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        imagePanel.animationBehavior = .none

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: target.appKitFrame.size))
        imageView.image = nsImage
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imagePanel.contentView = imageView

        let shieldFrame = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let shield = WakePanel(
            contentRect: shieldFrame,
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
        shield.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        shield.animationBehavior = .none
        shield.contentView = NSView(frame: NSRect(origin: .zero, size: shieldFrame.size))

        let newSession = FadeSession(target: target, imagePanel: imagePanel, shieldPanel: shield)
        session = newSession
        wakeArmedAt = ProcessInfo.processInfo.systemUptime + (manual ? 0.55 : 0.18)

        imagePanel.orderFrontRegardless()
        shield.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak newSession] in
            guard let self, let newSession, self.session === newSession else { return }

            _ = target.app.hide()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = self.fadeSeconds
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.37, 0.0, 0.63, 1.0)
                context.allowsImplicitAnimation = true
                imagePanel.animator().alphaValue = 0.0
            }
        }

        rebuildMenu()
    }

    private func restoreNow() {
        guard let current = session else { return }
        session = nil
        captureTask?.cancel()
        captureTask = nil

        current.imagePanel.alphaValue = 1
        _ = current.target.app.unhide()
        _ = current.target.app.activate(options: [])
        current.shieldPanel.orderOut(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            current.imagePanel.orderOut(nil)
            current.imagePanel.close()
            current.shieldPanel.close()
        }
        rebuildMenu()
    }

    private func currentFrontmostTarget() -> TargetWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return lastEligibleTarget }
        guard app.activationPolicy == .regular else { return nil }

        if let bundle = app.bundleIdentifier,
           bundle == appBundleID || bundle == "com.apple.finder" {
            return nil
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }

        for info in list {
            guard
                let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                pid == app.processIdentifier,
                let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                layer == 0,
                let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                alpha > 0.01,
                let windowNumber = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                let cgFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                cgFrame.width >= 160,
                cgFrame.height >= 100
            else { continue }

            return TargetWindow(
                app: app,
                windowID: CGWindowID(windowNumber),
                cgFrame: cgFrame,
                appKitFrame: appKitFrame(fromCGWindowFrame: cgFrame),
                appName: app.localizedName ?? "Current App"
            )
        }
        return nil
    }

    private func appKitFrame(fromCGWindowFrame frame: CGRect) -> CGRect {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: frame.minX, y: mainHeight - frame.minY - frame.height, width: frame.width, height: frame.height)
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
