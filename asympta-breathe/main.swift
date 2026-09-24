import AppKit
import ScreenCaptureKit
import CoreGraphics
import QuartzCore
import ApplicationServices

private let appBundleID = "com.asympta.breathe"

private struct TargetWindow {
    let windowID: CGWindowID
    let cgFrame: CGRect
    let appKitFrame: CGRect
}

private struct VisibleWindowTarget {
    let app: NSRunningApplication
    let appName: String
    let window: TargetWindow
}

private struct CapturedWindow {
    let target: VisibleWindowTarget
    let image: CGImage
}

private struct AXWindowState {
    let element: AXUIElement
    let originalPosition: CGPoint
}

private struct AppDisplacement {
    let app: NSRunningApplication
    let axWindows: [AXWindowState]
    let hiddenFallback: Bool
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

        // Deliberately no synthetic border or fixed corner radius.
        // The ScreenCaptureKit image already contains the native window alpha
        // shape, including Safari's exact rounded corners.
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
    let captured: [CapturedWindow]
    let panels: [BreathPanel]
    let views: [BreathOverlayView]
    var displacements: [AppDisplacement] = []
    var isInhaling = false

    init(
        captured: [CapturedWindow],
        panels: [BreathPanel],
        views: [BreathOverlayView]
    ) {
        self.captured = captured
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

    private var screenPermission = false
    private var accessibilityPermission = false

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

    private let restingOpacity = 0.10
    private let inhaleSeconds = 0.72

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        screenPermission = CGPreflightScreenCaptureAccess()
        accessibilityPermission = AXIsProcessTrusted()

        buildStatusItem()

        tickTimer = Timer.scheduledTimer(
            withTimeInterval: 0.12,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }

            if !self.screenPermission {
                _ = CGRequestScreenCaptureAccess()
            }

            if !self.accessibilityPermission {
                self.requestAccessibility()
            }

            self.refreshPermissions()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tickTimer?.invalidate()
        captureTask?.cancel()
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

    private func refreshPermissions() {
        let newScreen = CGPreflightScreenCaptureAccess()
        let newAccessibility = AXIsProcessTrusted()

        if newScreen != screenPermission
            || newAccessibility != accessibilityPermission {
            screenPermission = newScreen
            accessibilityPermission = newAccessibility
            rebuildMenu()
        }
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

        let version =
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String
            ?? "—"

        let versionItem = NSMenuItem(
            title: "Version \(version)",
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let statusText: String

        if !screenPermission {
            statusText = "Screen Recording permission needed"
        } else if !accessibilityPermission {
            statusText = "Accessibility permission needed"
        } else if let session {
            statusText = session.isInhaling
                ? "Breathing in"
                : "Resting at 10% · click a faded app to return"
        } else {
            let count = collectVisibleWindows().count
            statusText = enabled
                ? "Watching \(count) visible window\(count == 1 ? "" : "s")"
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
            title: "Breathe Visible Apps Now",
            action: #selector(breatheNow),
            keyEquivalent: ""
        )
        breathe.target = self
        breathe.isEnabled =
            screenPermission
            && accessibilityPermission
            && session == nil
            && captureTask == nil
            && !collectVisibleWindows().isEmpty
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

        let screenPermissionItem = NSMenuItem(
            title: screenPermission
                ? "Screen Recording: Allowed"
                : "Grant Screen Recording…",
            action: screenPermission
                ? nil
                : #selector(requestScreenRecording),
            keyEquivalent: ""
        )
        screenPermissionItem.target = self
        screenPermissionItem.isEnabled = !screenPermission
        menu.addItem(screenPermissionItem)

        let accessibilityItem = NSMenuItem(
            title: accessibilityPermission
                ? "Accessibility: Allowed"
                : "Grant Accessibility…",
            action: accessibilityPermission
                ? nil
                : #selector(requestAccessibilityFromMenu),
            keyEquivalent: ""
        )
        accessibilityItem.target = self
        accessibilityItem.isEnabled = !accessibilityPermission
        menu.addItem(accessibilityItem)

        menu.addItem(.separator())

        let activityHint = NSMenuItem(
            title: "Before fade: mouse, scroll and typing all count as active",
            action: nil,
            keyEquivalent: ""
        )
        activityHint.isEnabled = false
        menu.addItem(activityHint)

        let wakeHint = NSMenuItem(
            title: "After fade: only clicking a faded app breathes it back in",
            action: nil,
            keyEquivalent: ""
        )
        wakeHint.isEnabled = false
        menu.addItem(wakeHint)

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

    private func tick() {
        refreshPermissions()

        guard enabled else { return }

        // Once apps are resting, mouse movement and typing intentionally do
        // nothing. Only an actual click on one of the faded app overlays
        // invokes breatheIn().
        if session != nil {
            return
        }

        guard captureTask == nil else { return }
        guard screenPermission, accessibilityPermission else { return }

        let idle = secondsSinceRelevantInput()
        guard idle >= idleSeconds else { return }

        let targets = collectVisibleWindows()
        guard !targets.isEmpty else { return }

        startBreatheOut(targets: targets)
    }

    private func secondsSinceRelevantInput() -> Double {
        let types: [CGEventType] = [
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

        return types
            .map {
                CGEventSource.secondsSinceLastEventType(
                    .combinedSessionState,
                    eventType: $0
                )
            }
            .min()
            ?? .greatestFiniteMagnitude
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
    }

    @objc private func breatheNow() {
        guard session == nil, captureTask == nil else { return }

        refreshPermissions()

        guard screenPermission, accessibilityPermission else {
            if !screenPermission {
                _ = CGRequestScreenCaptureAccess()
            }
            if !accessibilityPermission {
                requestAccessibility()
            }
            return
        }

        let targets = collectVisibleWindows()
        guard !targets.isEmpty else { return }

        startBreatheOut(targets: targets)
    }

    @objc private func breatheInNow() {
        breatheIn(preferredApp: nil)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refreshPermissions()
        }
    }

    @objc private func requestAccessibilityFromMenu() {
        requestAccessibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refreshPermissions()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func startBreatheOut(
        targets: [VisibleWindowTarget]
    ) {
        guard session == nil, captureTask == nil else { return }

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

                for target in targets {
                    guard let scWindow = shareableByID[target.window.windowID] else {
                        continue
                    }

                    let filter = SCContentFilter(
                        desktopIndependentWindow: scWindow
                    )

                    let config = SCStreamConfiguration()
                    let scale = self.backingScale(
                        for: target.window.appKitFrame
                    )

                    config.width = max(
                        1,
                        Int(target.window.cgFrame.width * scale)
                    )
                    config.height = max(
                        1,
                        Int(target.window.cgFrame.height * scale)
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
                            target: target,
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
                    return
                }

                self.captureTask = nil
                self.presentBreatheOut(captured: captured)

            } catch {
                self.captureTask = nil
                self.rebuildMenu()
            }
        }
    }

    private func presentBreatheOut(
        captured: [CapturedWindow]
    ) {
        guard session == nil else { return }

        var panels: [BreathPanel] = []
        var views: [BreathOverlayView] = []

        for item in captured {
            let panel = BreathPanel(
                contentRect: item.target.window.appKitFrame,
                styleMask: [
                    .borderless,
                    .nonactivatingPanel
                ],
                backing: .buffered,
                defer: false
            )

            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
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
                    size: item.target.window.appKitFrame.size
                )
            )

            overlay.imageView.image = NSImage(
                cgImage: item.image,
                size: item.target.window.appKitFrame.size
            )

            panel.contentView = overlay

            panels.append(panel)
            views.append(overlay)
        }

        let newSession = FadeSession(
            captured: captured,
            panels: panels,
            views: views
        )

        for (index, view) in views.enumerated() {
            let app = captured[index].target.app

            view.onClick = { [weak self, weak newSession, weak app] in
                Task { @MainActor in
                    guard
                        let self,
                        let newSession,
                        self.session === newSession
                    else {
                        return
                    }

                    self.breatheIn(preferredApp: app)
                }
            }
        }

        session = newSession

        // CGWindowList is front-to-back. Ordering in reverse preserves the
        // same visible stacking when our overlays are brought forward.
        for panel in panels.reversed() {
            panel.orderFrontRegardless()
        }

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

            let displacements =
                self.displaceOriginalWindows(
                    captured: captured
                )

            guard !displacements.isEmpty else {
                self.closeSessionWithoutRestoring(newSession)
                self.rebuildMenu()
                return
            }

            newSession.displacements = displacements

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

    private func breatheIn(
        preferredApp: NSRunningApplication?
    ) {
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
        } completionHandler: { [weak self, weak current, weak preferredApp] in
            Task { @MainActor in
                guard
                    let self,
                    let current,
                    self.session === current
                else {
                    return
                }

                self.restoreOriginalWindows(current.displacements)

                if let preferredApp {
                    _ = preferredApp.activate(options: [])
                }

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
                    self.rebuildMenu()
                }
            }
        }
    }

    private func breatheInImmediately() {
        captureTask?.cancel()
        captureTask = nil

        guard let current = session else { return }

        restoreOriginalWindows(current.displacements)

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
        restoreOriginalWindows(current.displacements)

        current.panels.forEach {
            $0.orderOut(nil)
            $0.close()
        }

        if session === current {
            session = nil
        }
    }

    private func displaceOriginalWindows(
        captured: [CapturedWindow]
    ) -> [AppDisplacement] {
        var windowsByPID: [pid_t: [TargetWindow]] = [:]
        var appsByPID: [pid_t: NSRunningApplication] = [:]
        var pidOrder: [pid_t] = []

        for item in captured {
            let pid = item.target.app.processIdentifier

            if windowsByPID[pid] == nil {
                windowsByPID[pid] = []
                appsByPID[pid] = item.target.app
                pidOrder.append(pid)
            }

            windowsByPID[pid]?.append(item.target.window)
        }

        var results: [AppDisplacement] = []

        for pid in pidOrder {
            guard
                let app = appsByPID[pid],
                let visibleWindows = windowsByPID[pid]
            else {
                continue
            }

            let states = collectAXWindowStates(
                for: pid,
                matching: visibleWindows
            )

            var movedCount = 0

            for (index, state) in states.enumerated() {
                let destination = CGPoint(
                    x: -12_000 - CGFloat(index * 48),
                    y: state.originalPosition.y
                )

                if setAXPoint(
                    element: state.element,
                    attribute: kAXPositionAttribute as CFString,
                    value: destination
                ) {
                    movedCount += 1
                }
            }

            let useHideFallback =
                movedCount < visibleWindows.count

            if useHideFallback {
                _ = app.hide()
            }

            results.append(
                AppDisplacement(
                    app: app,
                    axWindows: states,
                    hiddenFallback: useHideFallback
                )
            )
        }

        return results
    }

    private func restoreOriginalWindows(
        _ displacements: [AppDisplacement]
    ) {
        for displacement in displacements {
            for state in displacement.axWindows {
                _ = setAXPoint(
                    element: state.element,
                    attribute: kAXPositionAttribute as CFString,
                    value: state.originalPosition
                )
            }

            if displacement.hiddenFallback {
                _ = displacement.app.unhide()
            }
        }
    }

    private func collectAXWindowStates(
        for pid: pid_t,
        matching visibleWindows: [TargetWindow]
    ) -> [AXWindowState] {
        let appElement = AXUIElementCreateApplication(pid)

        var rawWindows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &rawWindows
        )

        guard
            result == .success,
            let windows = rawWindows as? [AXUIElement]
        else {
            return []
        }

        var states: [AXWindowState] = []

        for window in windows {
            guard
                let position = axPoint(
                    element: window,
                    attribute: kAXPositionAttribute as CFString
                ),
                let size = axSize(
                    element: window,
                    attribute: kAXSizeAttribute as CFString
                )
            else {
                continue
            }

            var minimizedValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                window,
                kAXMinimizedAttribute as CFString,
                &minimizedValue
            ) == .success,
               let minimized = minimizedValue as? Bool,
               minimized {
                continue
            }

            let matchesVisibleWindow =
                visibleWindows.contains { target in
                    abs(target.cgFrame.minX - position.x) <= 8
                    && abs(target.cgFrame.minY - position.y) <= 8
                    && abs(target.cgFrame.width - size.width) <= 12
                    && abs(target.cgFrame.height - size.height) <= 12
                }

            guard matchesVisibleWindow else { continue }

            states.append(
                AXWindowState(
                    element: window,
                    originalPosition: position
                )
            )
        }

        return states
    }

    private func collectVisibleWindows() -> [VisibleWindowTarget] {
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
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var targets: [VisibleWindowTarget] = []

        for info in list {
            guard
                let pid =
                    (
                        info[
                            kCGWindowOwnerPID as String
                        ] as? NSNumber
                    )?.int32Value,
                pid != ownPID,

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
                cgFrame.height >= 80,

                let app =
                    NSRunningApplication(
                        processIdentifier: pid
                    ),

                !app.isTerminated,
                app.activationPolicy == .regular,
                app.bundleIdentifier != appBundleID
            else {
                continue
            }

            targets.append(
                VisibleWindowTarget(
                    app: app,
                    appName:
                        app.localizedName
                        ?? "App",
                    window: TargetWindow(
                        windowID: CGWindowID(number),
                        cgFrame: cgFrame,
                        appKitFrame:
                            appKitFrame(
                                fromCGWindowFrame: cgFrame
                            )
                    )
                )
            )
        }

        return targets
    }

    private func axPoint(
        element: AXUIElement,
        attribute: CFString
    ) -> CGPoint? {
        var raw: CFTypeRef?

        guard
            AXUIElementCopyAttributeValue(
                element,
                attribute,
                &raw
            ) == .success,
            let raw,
            CFGetTypeID(raw) == AXValueGetTypeID()
        else {
            return nil
        }

        let value = raw as! AXValue

        guard AXValueGetType(value) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero

        guard AXValueGetValue(
            value,
            .cgPoint,
            &point
        ) else {
            return nil
        }

        return point
    }

    private func axSize(
        element: AXUIElement,
        attribute: CFString
    ) -> CGSize? {
        var raw: CFTypeRef?

        guard
            AXUIElementCopyAttributeValue(
                element,
                attribute,
                &raw
            ) == .success,
            let raw,
            CFGetTypeID(raw) == AXValueGetTypeID()
        else {
            return nil
        }

        let value = raw as! AXValue

        guard AXValueGetType(value) == .cgSize else {
            return nil
        }

        var size = CGSize.zero

        guard AXValueGetValue(
            value,
            .cgSize,
            &size
        ) else {
            return nil
        }

        return size
    }

    private func setAXPoint(
        element: AXUIElement,
        attribute: CFString,
        value: CGPoint
    ) -> Bool {
        var point = value

        guard let axValue = AXValueCreate(
            .cgPoint,
            &point
        ) else {
            return false
        }

        return AXUIElementSetAttributeValue(
            element,
            attribute,
            axValue
        ) == .success
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
