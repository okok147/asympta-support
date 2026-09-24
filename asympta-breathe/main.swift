import AppKit
import ScreenCaptureKit
import CoreGraphics
import QuartzCore

private let appBundleID = "com.asympta.breathe"
private let anyInputEvent = CGEventType(rawValue: UInt32.max)!

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

@MainActor
private final class BreathOverlayView: NSView {
    let imageView: NSImageView
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        imageView = NSImageView(frame: frameRect)
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 1.25
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.38).cgColor
        layer?.cornerRadius = 11
        layer?.masksToBounds = true

        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.alphaValue = 1

        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

private final class BreathPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class FadeSession {
    let target: AppTarget
    let panels: [BreathPanel]
    let views: [BreathOverlayView]
    var isInhaling = false

    init(
        target: AppTarget,
        panels: [BreathPanel],
        views: [BreathOverlayView]
    ) {
        self.target = target
        self.panels = panels
        self.views = views
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var tickTimer: Timer?
    private var captureTask: Task<Void, Never>?
    private var session: FadeSession?
    private var workspaceObserver: NSObjectProtocol?

    private var lastExternalPID: pid_t?
    private var lastExternalAppName: String?

    private var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "enabled") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "enabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "enabled")
            if !newValue {
                breatheInImmediately()
            }
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

    private var restingOpacity: Double {
        0.10
    }

    private var inhaleSeconds: Double {
        0.70
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalPID = app.processIdentifier
            lastExternalAppName = app.localizedName
        }

        buildStatusItem()
        installWorkspaceObserver()

        tickTimer = Timer.scheduledTimer(
            withTimeInterval: 0.15,
            repeats: true
        ) { [weak self] _ in
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

        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }

        breatheInImmediately()
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )

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

        let title = NSMenuItem(
            title: "Asympta Breathe",
            action: nil,
            keyEquivalent: ""
        )
        title.isEnabled = false
        menu.addItem(title)

        let statusText: String

        if !CGPreflightScreenCaptureAccess() {
            statusText = "Screen Recording permission needed"
        } else if let session {
            statusText = session.isInhaling
                ? "Breathing in · \(session.target.appName)"
                : "Resting at 10% · \(session.target.appName)"
        } else if let name = currentExternalAppName() ?? lastExternalAppName {
            statusText = enabled
                ? "Watching · \(name)"
                : "Disabled"
        } else {
            statusText = enabled
                ? "Waiting for an app"
                : "Disabled"
        }

        let status = NSMenuItem(
            title: statusText,
            action: nil,
            keyEquivalent: ""
        )
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
        breathe.isEnabled =
            CGPreflightScreenCaptureAccess()
            && session == nil
            && captureTask == nil
            && (lastExternalPID != nil || currentFrontmostTarget() != nil)
        menu.addItem(breathe)

        if session != nil {
            let restore = NSMenuItem(
                title: "Breathe In Now",
                action: #selector(breatheInNow),
                keyEquivalent: ""
            )
            restore.target = self
            menu.addItem(restore)
        }

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
                title: "Exhale duration",
                current: fadeSeconds,
                values: [3, 6, 9, 15, 30],
                selector: #selector(setFadeDuration(_:))
            )
        )

        let resting = NSMenuItem(
            title: "Resting opacity: 10%",
            action: nil,
            keyEquivalent: ""
        )
        resting.isEnabled = false
        menu.addItem(resting)

        let permissionAllowed = CGPreflightScreenCaptureAccess()
        let permission = NSMenuItem(
            title: permissionAllowed
                ? "Screen Recording: Allowed"
                : "Grant Screen Recording…",
            action: permissionAllowed
                ? nil
                : #selector(requestScreenRecording),
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

        let hint = NSMenuItem(
            title: "Click the faded app to breathe it back in",
            action: nil,
            keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)

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

    private func installWorkspaceObserver() {
        workspaceObserver =
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    guard let self else { return }

                    guard
                        let app =
                            notification.userInfo?[
                                NSWorkspace.applicationUserInfoKey
                            ] as? NSRunningApplication,
                        app.processIdentifier
                            != ProcessInfo.processInfo.processIdentifier,
                        app.activationPolicy == .regular
                    else {
                        return
                    }

                    self.lastExternalPID = app.processIdentifier
                    self.lastExternalAppName = app.localizedName
                    self.rebuildMenu()
                }
            }
    }

    private func tick() {
        guard enabled else { return }
        guard session == nil, captureTask == nil else { return }

        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInputEvent
        )

        guard idle >= idleSeconds else { return }
        guard let target = currentFrontmostTarget() else { return }

        startBreatheOut(target: target)
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
    }

    @objc private func breatheNow() {
        guard session == nil, captureTask == nil else { return }

        let target: AppTarget?

        if let current = currentFrontmostTarget() {
            target = current
        } else if let pid = lastExternalPID {
            target = targetForPID(pid)
        } else {
            target = nil
        }

        guard let target else {
            NSSound.beep()
            return
        }

        startBreatheOut(target: target)
    }

    @objc private func breatheInNow() {
        breatheIn()
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

    private func startBreatheOut(target: AppTarget) {
        guard session == nil, captureTask == nil else { return }

        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            rebuildMenu()
            return
        }

        captureTask = Task { [weak self] in
            guard let self else { return }

            do {
                let shareable =
                    try await SCShareableContent.excludingDesktopWindows(
                        false,
                        onScreenWindowsOnly: true
                    )

                let shareableByID = Dictionary(
                    uniqueKeysWithValues:
                        shareable.windows.map { ($0.windowID, $0) }
                )

                var captured: [CapturedWindow] = []

                for window in target.windows {
                    guard let scWindow = shareableByID[window.windowID] else {
                        continue
                    }

                    let filter =
                        SCContentFilter(
                            desktopIndependentWindow: scWindow
                        )

                    let config = SCStreamConfiguration()
                    let scale =
                        self.backingScale(for: window.appKitFrame)

                    config.width =
                        max(
                            1,
                            Int(window.cgFrame.width * scale)
                        )
                    config.height =
                        max(
                            1,
                            Int(window.cgFrame.height * scale)
                        )
                    config.showsCursor = false
                    config.queueDepth = 1
                    config.shouldBeOpaque = false

                    let image =
                        try await SCScreenshotManager.captureImage(
                            contentFilter: filter,
                            configuration: config
                        )

                    captured.append(
                        CapturedWindow(
                            target: window,
                            image: image
                        )
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
                self.presentBreatheOut(
                    target: target,
                    captured: captured
                )

            } catch {
                self.captureTask = nil
                NSSound.beep()
                self.rebuildMenu()
            }
        }
    }

    private func presentBreatheOut(
        target: AppTarget,
        captured: [CapturedWindow]
    ) {
        guard session == nil else { return }

        var panels: [BreathPanel] = []
        var views: [BreathOverlayView] = []

        for item in captured {
            let panel = BreathPanel(
                contentRect: item.target.appKitFrame,
                styleMask: [
                    .borderless,
                    .nonactivatingPanel
                ],
                backing: .buffered,
                defer: false
            )

            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.alphaValue = 1
            panel.ignoresMouseEvents = false
            panel.level = .screenSaver
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary,
                .ignoresCycle
            ]
            panel.animationBehavior = .none

            let overlay = BreathOverlayView(
                frame: NSRect(
                    origin: .zero,
                    size: item.target.appKitFrame.size
                )
            )

            overlay.imageView.image =
                NSImage(
                    cgImage: item.image,
                    size: item.target.appKitFrame.size
                )

            panel.contentView = overlay

            panels.append(panel)
            views.append(overlay)
        }

        let newSession = FadeSession(
            target: target,
            panels: panels,
            views: views
        )

        for view in views {
            view.onClick = { [weak self, weak newSession] in
                Task { @MainActor in
                    guard let self,
                          let newSession,
                          self.session === newSession
                    else {
                        return
                    }

                    self.breatheIn()
                }
            }
        }

        session = newSession

        panels.forEach { $0.orderFrontRegardless() }

        // The full-opacity captured window is already covering the real app.
        // Hiding the real app after one compositor turn changes nothing
        // visually, then we can fade the captured representation to 10%.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.055
        ) { [weak self, weak newSession] in
            guard
                let self,
                let newSession,
                self.session === newSession
            else {
                return
            }

            guard target.app.hide() else {
                self.closeSessionWithoutRestoring(newSession)
                NSSound.beep()
                return
            }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = self.fadeSeconds
                context.timingFunction =
                    CAMediaTimingFunction(
                        controlPoints: 0.37,
                        0.0,
                        0.63,
                        1.0
                    )
                context.allowsImplicitAnimation = true

                for view in views {
                    view.imageView.animator().alphaValue =
                        CGFloat(self.restingOpacity)
                }
            } completionHandler: { [weak self, weak newSession] in
                Task { @MainActor in
                    guard
                        let self,
                        let newSession,
                        self.session === newSession
                    else {
                        return
                    }

                    self.rebuildMenu()
                }
            }
        }

        rebuildMenu()
    }

    private func breatheIn() {
        guard let current = session else { return }
        guard !current.isInhaling else { return }

        current.isInhaling = true
        rebuildMenu()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = inhaleSeconds
            context.timingFunction =
                CAMediaTimingFunction(
                    controlPoints: 0.22,
                    1.0,
                    0.36,
                    1.0
                )
            context.allowsImplicitAnimation = true

            for view in current.views {
                view.imageView.animator().alphaValue = 1
            }
        } completionHandler: { [weak self, weak current] in
            Task { @MainActor in
                guard
                    let self,
                    let current,
                    self.session === current
                else {
                    return
                }

                _ = current.target.app.unhide()
                _ = current.target.app.activate(options: [])

                DispatchQueue.main.asyncAfter(
                    deadline: .now() + 0.055
                ) { [weak self, weak current] in
                    guard
                        let self,
                        let current,
                        self.session === current
                    else {
                        return
                    }

                    current.panels.forEach {
                        $0.orderOut(nil)
                        $0.close()
                    }

                    self.session = nil
                    self.lastExternalPID =
                        current.target.app.processIdentifier
                    self.lastExternalAppName =
                        current.target.appName
                    self.rebuildMenu()
                }
            }
        }
    }

    private func breatheInImmediately() {
        captureTask?.cancel()
        captureTask = nil

        guard let current = session else { return }

        _ = current.target.app.unhide()

        current.panels.forEach {
            $0.orderOut(nil)
            $0.close()
        }

        session = nil
        rebuildMenu()
    }

    private func closeSessionWithoutRestoring(
        _ current: FadeSession
    ) {
        current.panels.forEach {
            $0.orderOut(nil)
            $0.close()
        }

        if session === current {
            session = nil
        }

        rebuildMenu()
    }

    private func currentFrontmostTarget() -> AppTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        if app.processIdentifier
            == ProcessInfo.processInfo.processIdentifier {
            if let pid = lastExternalPID {
                return targetForPID(pid)
            }
            return nil
        }

        guard app.activationPolicy == .regular else {
            return nil
        }

        guard app.bundleIdentifier != appBundleID else {
            return nil
        }

        lastExternalPID = app.processIdentifier
        lastExternalAppName = app.localizedName

        return targetForPID(app.processIdentifier)
    }

    private func targetForPID(_ pid: pid_t) -> AppTarget? {
        guard
            let app = NSRunningApplication(
                processIdentifier: pid
            )
        else {
            return nil
        }

        guard
            !app.isTerminated,
            app.activationPolicy == .regular,
            app.bundleIdentifier != appBundleID
        else {
            return nil
        }

        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements
        ]

        guard
            let list =
                CGWindowListCopyWindowInfo(
                    options,
                    kCGNullWindowID
                ) as? [[String: Any]]
        else {
            return nil
        }

        var windows: [TargetWindow] = []

        for info in list {
            guard
                let ownerPID =
                    (
                        info[
                            kCGWindowOwnerPID as String
                        ] as? NSNumber
                    )?.int32Value,
                ownerPID == pid,

                let layer =
                    (
                        info[
                            kCGWindowLayer as String
                        ] as? NSNumber
                    )?.intValue,
                layer == 0,

                let alpha =
                    (
                        info[
                            kCGWindowAlpha as String
                        ] as? NSNumber
                    )?.doubleValue,
                alpha > 0.01,

                let number =
                    (
                        info[
                            kCGWindowNumber as String
                        ] as? NSNumber
                    )?.uint32Value,

                let bounds =
                    info[
                        kCGWindowBounds as String
                    ] as? NSDictionary,

                let cgFrame =
                    CGRect(
                        dictionaryRepresentation:
                            bounds as CFDictionary
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
                    appKitFrame:
                        appKitFrame(
                            fromCGWindowFrame: cgFrame
                        )
                )
            )
        }

        guard !windows.isEmpty else {
            return nil
        }

        return AppTarget(
            app: app,
            windows: windows,
            appName:
                app.localizedName
                ?? "Current App"
        )
    }

    private func currentExternalAppName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        if app.processIdentifier
            == ProcessInfo.processInfo.processIdentifier {
            return lastExternalAppName
        }

        guard app.activationPolicy == .regular else {
            return nil
        }

        return app.localizedName
    }

    private func appKitFrame(
        fromCGWindowFrame frame: CGRect
    ) -> CGRect {
        let mainDisplayHeight =
            CGDisplayBounds(
                CGMainDisplayID()
            ).height

        return CGRect(
            x: frame.minX,
            y:
                mainDisplayHeight
                - frame.minY
                - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    private func backingScale(
        for rect: CGRect
    ) -> CGFloat {
        let center = CGPoint(
            x: rect.midX,
            y: rect.midY
        )

        if let screen =
            NSScreen.screens.first(
                where: {
                    $0.frame.contains(center)
                }
            ) {
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
