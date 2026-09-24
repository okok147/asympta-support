import AppKit
import ScreenCaptureKit
import CoreGraphics
import QuartzCore
import ApplicationServices
import CoreImage

private let appBundleID = "com.asympta.breathe"

private let ciContext = CIContext(
    options: [
        .useSoftwareRenderer: false
    ]
)

private struct TargetWindow {
    let windowID: CGWindowID
    let cgFrame: CGRect
    let appKitFrame: CGRect
}

private struct VisibleWindowTarget {
    let app: NSRunningApplication
    let appName: String
    let bundleID: String
    let window: TargetWindow
}

private struct CapturedWindow {
    let target: VisibleWindowTarget
    let scWindow: SCWindow
    let image: CGImage
    let scale: CGFloat
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

private func resetTCCService(
    _ service: String
) -> Bool {
    let process = Process()
    process.executableURL = URL(
        fileURLWithPath: "/usr/bin/tccutil"
    )
    process.arguments = [
        "reset",
        service,
        Bundle.main.bundleIdentifier
            ?? appBundleID
    ]

    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

private func resetAsymptaPermissions() -> Bool {
    let screenReset =
        resetTCCService("ScreenCapture")
    let accessibilityReset =
        resetTCCService("Accessibility")

    return screenReset && accessibilityReset
}

private func verifyScreenCaptureCapability(
    forceProbe: Bool
) async -> Bool {
    if !forceProbe
        && !CGPreflightScreenCaptureAccess() {
        return false
    }

    do {
        _ =
            try await SCShareableContent
                .excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
        return true
    } catch {
        return false
    }
}

private func stableAppColor(
    bundleID: String
) -> NSColor {
    let palette: [NSColor] = [
        .systemBlue,
        .systemPurple,
        .systemPink,
        .systemOrange,
        .systemGreen,
        .systemTeal,
        .systemIndigo,
        .systemYellow
    ]

    var hash: UInt64 =
        1469598103934665603

    for byte in bundleID.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1099511628211
    }

    return palette[
        Int(
            hash
            % UInt64(palette.count)
        )
    ]
}

private func makeAlphaEdgeImage(
    from image: CGImage,
    color: NSColor
) -> CGImage? {
    let input = CIImage(
        cgImage: image
    )

    let alphaVector =
        CIVector(
            x: 0,
            y: 0,
            z: 0,
            w: 1
        )

    let alphaImage =
        input.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector":
                    alphaVector,
                "inputGVector":
                    alphaVector,
                "inputBVector":
                    alphaVector,
                "inputAVector":
                    alphaVector
            ]
        )

    let edge =
        alphaImage.applyingFilter(
            "CIMorphologyGradient",
            parameters: [
                "inputRadius": 2.2
            ]
        )

    let rgb =
        color.usingColorSpace(
            .deviceRGB
        )
        ?? color

    let tinted =
        edge.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector":
                    CIVector(
                        x: rgb.redComponent,
                        y: 0,
                        z: 0,
                        w: 0
                    ),
                "inputGVector":
                    CIVector(
                        x: 0,
                        y: rgb.greenComponent,
                        z: 0,
                        w: 0
                    ),
                "inputBVector":
                    CIVector(
                        x: 0,
                        y: 0,
                        z: rgb.blueComponent,
                        w: 0
                    ),
                "inputAVector":
                    CIVector(
                        x: 0,
                        y: 0,
                        z: 0,
                        w: 1
                    )
            ]
        )

    return ciContext.createCGImage(
        tinted,
        from: input.extent
    )
}

@MainActor
private final class BreathOverlayView: NSView {
    let baseImageView = NSImageView()
    let borderImageView = NSImageView()
    let focusImageView = NSImageView()

    var onClick: (() -> Void)?

    override init(
        frame frameRect: NSRect
    ) {
        super.init(
            frame: frameRect
        )

        wantsLayer = true
        layer?.backgroundColor =
            NSColor.clear.cgColor
        layer?.masksToBounds = false

        for imageView in [
            baseImageView,
            borderImageView,
            focusImageView
        ] {
            imageView.frame = bounds
            imageView.autoresizingMask = [
                .width,
                .height
            ]
            imageView.imageScaling =
                .scaleAxesIndependently
            imageView.imageAlignment =
                .alignCenter
            imageView.wantsLayer = true
            addSubview(imageView)
        }

        baseImageView.alphaValue = 1
        borderImageView.alphaValue = 1
        focusImageView.alphaValue = 1
        focusImageView.isHidden = true
    }

    required init?(
        coder: NSCoder
    ) {
        fatalError(
            "init(coder:) has not been implemented"
        )
    }

    override func acceptsFirstMouse(
        for event: NSEvent?
    ) -> Bool {
        true
    }

    override func mouseDown(
        with event: NSEvent
    ) {
        onClick?()
    }

    func install(
        image: CGImage,
        borderColor: NSColor
    ) {
        baseImageView.image =
            NSImage(
                cgImage: image,
                size: bounds.size
            )

        if let border =
            makeAlphaEdgeImage(
                from: image,
                color: borderColor
            ) {
            borderImageView.image =
                NSImage(
                    cgImage: border,
                    size: bounds.size
                )
        }
    }

    func setBaseImage(
        _ image: CGImage
    ) {
        baseImageView.image =
            NSImage(
                cgImage: image,
                size: bounds.size
            )
    }

    func showFocusedRegion(
        image: CGImage,
        localRect: CGRect
    ) {
        focusImageView.image =
            NSImage(
                cgImage: image,
                size: bounds.size
            )

        let padded =
            localRect.insetBy(
                dx: -5,
                dy: -5
            )
            .intersection(bounds)

        guard
            !padded.isNull,
            padded.width > 1,
            padded.height > 1
        else {
            focusImageView.isHidden = true
            focusImageView.layer?.mask = nil
            return
        }

        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.path =
            CGPath(
                roundedRect: padded,
                cornerWidth: 7,
                cornerHeight: 7,
                transform: nil
            )
        mask.fillColor =
            NSColor.white.cgColor

        focusImageView.layer?.mask =
            mask
        focusImageView.isHidden = false
    }

    func hideFocusedRegion() {
        focusImageView.isHidden = true
        focusImageView.layer?.mask = nil
    }
}

private final class BreathPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

@MainActor
private final class FadeSession {
    let captured: [CapturedWindow]
    let panels: [BreathPanel]
    let views: [BreathOverlayView]

    let typingPID: pid_t?

    var displacements: [AppDisplacement] = []
    var inhalingPIDs: Set<pid_t> = []
    var restoredPIDs: Set<pid_t> = []

    var typingTimer: Timer?
    var typingRefreshInFlight = false

    init(
        captured: [CapturedWindow],
        panels: [BreathPanel],
        views: [BreathOverlayView],
        typingPID: pid_t?
    ) {
        self.captured = captured
        self.panels = panels
        self.views = views
        self.typingPID = typingPID
    }

    var allPIDs: Set<pid_t> {
        Set(
            captured.map {
                $0.target.app
                    .processIdentifier
            }
        )
    }

    var remainingPIDs:
        Set<pid_t> {
        allPIDs.subtracting(
            restoredPIDs
        )
    }

    func stopTypingTimer() {
        typingTimer?.invalidate()
        typingTimer = nil
        typingRefreshInFlight = false
    }
}

@MainActor
private final class PermissionGateController:
    NSWindowController {

    var onReady:
        ((Bool, Bool) -> Void)?

    private let screenIcon =
        NSImageView()
    private let screenStatus =
        NSTextField(
            labelWithString:
                "Checking…"
        )
    private let screenButton =
        NSButton(
            title: "Allow",
            target: nil,
            action: nil
        )

    private let accessibilityIcon =
        NSImageView()
    private let accessibilityStatus =
        NSTextField(
            labelWithString:
                "Checking…"
        )
    private let accessibilityButton =
        NSButton(
            title: "Allow",
            target: nil,
            action: nil
        )

    private let resetButton =
        NSButton(
            title:
                "Reset & Re-Approve",
            target: nil,
            action: nil
        )

    private let refreshButton =
        NSButton(
            title:
                "Refresh Permissions",
            target: nil,
            action: nil
        )

    private let footerStatus =
        NSTextField(
            labelWithString:
                "Both permissions must be verified before Asympta Breathe can start."
        )

    private var pollTimer: Timer?
    private var didDeliverReady =
        false
    private var refreshInProgress =
        false

    private var screenVerified =
        false
    private var accessibilityVerified =
        false

    init() {
        let window = NSWindow(
            contentRect:
                NSRect(
                    x: 0,
                    y: 0,
                    width: 560,
                    height: 405
                ),
            styleMask: [
                .titled
            ],
            backing: .buffered,
            defer: false
        )

        window.title =
            "Asympta Breathe"
        window.isReleasedWhenClosed =
            false
        window.center()

        super.init(
            window: window
        )

        configureUI()
        startMonitoring()
    }

    required init?(
        coder: NSCoder
    ) {
        fatalError(
            "init(coder:) has not been implemented"
        )
    }

    deinit {
        pollTimer?.invalidate()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        close()
    }

    private func configureUI() {
        guard
            let contentView =
                window?.contentView
        else {
            return
        }

        let title =
            NSTextField(
                labelWithString:
                    "Permissions"
            )
        title.font =
            .systemFont(
                ofSize: 24,
                weight: .semibold
            )

        let subtitle =
            NSTextField(
                wrappingLabelWithString:
                    "Asympta Breathe verifies Screen Recording and Accessibility before starting. "
                    + "The page refreshes automatically, or you can verify immediately."
            )
        subtitle.textColor =
            .secondaryLabelColor
        subtitle.font =
            .systemFont(
                ofSize: 13
            )

        let screenRow =
            permissionRow(
                symbol:
                    "rectangle.inset.filled.and.person.filled",
                title:
                    "Screen Recording",
                detail:
                    "Verified with an actual ScreenCaptureKit capability probe.",
                icon:
                    screenIcon,
                status:
                    screenStatus,
                button:
                    screenButton,
                action:
                    #selector(
                        allowScreenRecording
                    )
            )

        let accessibilityRow =
            permissionRow(
                symbol:
                    "hand.raised.fill",
                title:
                    "Accessibility",
                detail:
                    "Verified directly with AXIsProcessTrusted().",
                icon:
                    accessibilityIcon,
                status:
                    accessibilityStatus,
                button:
                    accessibilityButton,
                action:
                    #selector(
                        allowAccessibility
                    )
            )

        resetButton.target = self
        resetButton.action =
            #selector(
                resetAndReapprove
            )
        resetButton.bezelStyle =
            .rounded

        refreshButton.target = self
        refreshButton.action =
            #selector(
                refreshNow
            )
        refreshButton.bezelStyle =
            .rounded
        refreshButton.keyEquivalent =
            "\r"

        footerStatus.font =
            .systemFont(
                ofSize: 12,
                weight: .medium
            )
        footerStatus.textColor =
            .secondaryLabelColor

        let quit =
            NSButton(
                title: "Quit",
                target: self,
                action:
                    #selector(
                        quitApp
                    )
            )
        quit.bezelStyle =
            .rounded

        let footer =
            NSStackView(
                views: [
                    footerStatus,
                    NSView(),
                    resetButton,
                    refreshButton,
                    quit
                ]
            )
        footer.orientation =
            .horizontal
        footer.alignment =
            .centerY
        footer.spacing = 10

        let stack =
            NSStackView(
                views: [
                    title,
                    subtitle,
                    separator(),
                    screenRow,
                    accessibilityRow,
                    separator(),
                    footer
                ]
            )
        stack.orientation =
            .vertical
        stack.alignment =
            .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints =
            false

        contentView.addSubview(
            stack
        )

        NSLayoutConstraint.activate([
            stack.leadingAnchor
                .constraint(
                    equalTo:
                        contentView
                            .leadingAnchor,
                    constant: 26
                ),
            stack.trailingAnchor
                .constraint(
                    equalTo:
                        contentView
                            .trailingAnchor,
                    constant: -26
                ),
            stack.topAnchor
                .constraint(
                    equalTo:
                        contentView
                            .topAnchor,
                    constant: 26
                ),
            stack.bottomAnchor
                .constraint(
                    lessThanOrEqualTo:
                        contentView
                            .bottomAnchor,
                    constant: -22
                ),
            subtitle.widthAnchor
                .constraint(
                    equalTo:
                        stack.widthAnchor
                ),
            screenRow.widthAnchor
                .constraint(
                    equalTo:
                        stack.widthAnchor
                ),
            accessibilityRow.widthAnchor
                .constraint(
                    equalTo:
                        stack.widthAnchor
                ),
            footer.widthAnchor
                .constraint(
                    equalTo:
                        stack.widthAnchor
                )
        ])

        Task { [weak self] in
            await self?.refresh(
                forceScreenProbe:
                    false
            )
        }
    }

    private func permissionRow(
        symbol: String,
        title: String,
        detail: String,
        icon: NSImageView,
        status: NSTextField,
        button: NSButton,
        action: Selector
    ) -> NSView {
        icon.image =
            NSImage(
                systemSymbolName:
                    symbol,
                accessibilityDescription:
                    title
            )
        icon.symbolConfiguration =
            NSImage
                .SymbolConfiguration(
                    pointSize: 19,
                    weight: .medium
                )
        icon.translatesAutoresizingMaskIntoConstraints =
            false

        let titleField =
            NSTextField(
                labelWithString:
                    title
            )
        titleField.font =
            .systemFont(
                ofSize: 15,
                weight: .semibold
            )

        let detailField =
            NSTextField(
                wrappingLabelWithString:
                    detail
            )
        detailField.textColor =
            .secondaryLabelColor
        detailField.font =
            .systemFont(
                ofSize: 12
            )

        status.font =
            .systemFont(
                ofSize: 12,
                weight: .medium
            )

        let textStack =
            NSStackView(
                views: [
                    titleField,
                    detailField,
                    status
                ]
            )
        textStack.orientation =
            .vertical
        textStack.alignment =
            .leading
        textStack.spacing = 3

        button.target = self
        button.action = action
        button.bezelStyle =
            .rounded

        let row =
            NSStackView(
                views: [
                    icon,
                    textStack,
                    NSView(),
                    button
                ]
            )
        row.orientation =
            .horizontal
        row.alignment =
            .centerY
        row.spacing = 12

        NSLayoutConstraint.activate([
            icon.widthAnchor
                .constraint(
                    equalToConstant:
                        28
                ),
            icon.heightAnchor
                .constraint(
                    equalToConstant:
                        28
                ),
            button.widthAnchor
                .constraint(
                    greaterThanOrEqualToConstant:
                        82
                )
        ])

        return row
    }

    private func separator()
        -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func startMonitoring() {
        pollTimer?.invalidate()

        pollTimer =
            Timer.scheduledTimer(
                withTimeInterval:
                    0.50,
                repeats: true
            ) {
                [weak self] _ in

                Task { @MainActor in
                    await self?.refresh(
                        forceScreenProbe:
                            false
                    )
                }
            }
    }

    private func refresh(
        forceScreenProbe: Bool
    ) async {
        guard
            !refreshInProgress
        else {
            return
        }

        refreshInProgress = true

        resetButton.isEnabled =
            false
        refreshButton.isEnabled =
            false

        accessibilityStatus
            .stringValue =
                "Checking…"
        screenStatus.stringValue =
            forceScreenProbe
            ? "Verifying capture access…"
            : "Checking…"

        let accessibilityAllowed =
            AXIsProcessTrusted()

        let screenAllowed: Bool

        if CGPreflightScreenCaptureAccess()
            || forceScreenProbe {
            screenAllowed =
                await
                    verifyScreenCaptureCapability(
                        forceProbe:
                            true
                    )
        } else {
            screenAllowed =
                false
        }

        screenVerified =
            screenAllowed
        accessibilityVerified =
            accessibilityAllowed

        updatePermission(
            allowed:
                screenVerified,
            icon:
                screenIcon,
            status:
                screenStatus,
            button:
                screenButton
        )

        updatePermission(
            allowed:
                accessibilityVerified,
            icon:
                accessibilityIcon,
            status:
                accessibilityStatus,
            button:
                accessibilityButton
        )

        refreshInProgress =
            false
        resetButton.isEnabled =
            true
        refreshButton.isEnabled =
            true

        if screenVerified
            && accessibilityVerified {
            footerStatus.stringValue =
                "Verified. Opening Asympta Breathe…"
            footerStatus.textColor =
                .systemGreen

            guard
                !didDeliverReady
            else {
                return
            }

            didDeliverReady =
                true

            pollTimer?.invalidate()
            pollTimer = nil

            DispatchQueue.main
                .asyncAfter(
                    deadline:
                        .now()
                        + 0.25
                ) { [weak self] in
                    guard
                        let self
                    else {
                        return
                    }

                    self.onReady?(
                        self.screenVerified,
                        self.accessibilityVerified
                    )
                }
        } else {
            footerStatus.stringValue =
                "Both permissions must be verified before Asympta Breathe can start."
            footerStatus.textColor =
                .secondaryLabelColor
        }
    }

    private func updatePermission(
        allowed: Bool,
        icon: NSImageView,
        status: NSTextField,
        button: NSButton
    ) {
        if allowed {
            icon.contentTintColor =
                .systemGreen
            status.stringValue =
                "Verified"
            status.textColor =
                .systemGreen
            button.title =
                "Allowed"
            button.isEnabled =
                false
        } else {
            icon.contentTintColor =
                .secondaryLabelColor
            status.stringValue =
                "Not verified"
            status.textColor =
                .secondaryLabelColor
            button.title =
                "Allow"
            button.isEnabled =
                true
        }
    }

    @objc
    private func refreshNow() {
        Task { [weak self] in
            await self?.refresh(
                forceScreenProbe:
                    true
            )
        }
    }

    @objc
    private func resetAndReapprove() {
        let alert = NSAlert()
        alert.messageText =
            "Reset permissions?"
        alert.informativeText =
            "This removes Asympta Breathe's current Screen Recording "
            + "and Accessibility approvals, then asks macOS for both again."
        alert.alertStyle =
            .warning
        alert.addButton(
            withTitle:
                "Reset & Re-Approve"
        )
        alert.addButton(
            withTitle:
                "Cancel"
        )

        guard
            alert.runModal()
                == .alertFirstButtonReturn
        else {
            return
        }

        pollTimer?.invalidate()
        pollTimer = nil

        didDeliverReady =
            false
        screenVerified =
            false
        accessibilityVerified =
            false

        footerStatus.stringValue =
            "Removing existing approvals…"
        footerStatus.textColor =
            .secondaryLabelColor

        let resetSucceeded =
            resetAsymptaPermissions()

        if !resetSucceeded {
            footerStatus.stringValue =
                "macOS could not reset one or more approvals. Remove Asympta Breathe "
                + "manually in Privacy & Security, then press Refresh Permissions."
            footerStatus.textColor =
                .systemRed
            startMonitoring()
            return
        }

        screenStatus.stringValue =
            "Reset — approval required"
        accessibilityStatus.stringValue =
            "Reset — approval required"
        footerStatus.stringValue =
            "Reset complete. Approve both permissions again."

        startMonitoring()

        DispatchQueue.main
            .asyncAfter(
                deadline:
                    .now()
                    + 0.30
            ) { [weak self] in
                guard
                    let self
                else {
                    return
                }

                _ =
                    CGRequestScreenCaptureAccess()

                let key =
                    kAXTrustedCheckOptionPrompt
                        .takeUnretainedValue()
                    as String
                let options =
                    [key: true]
                    as CFDictionary

                _ =
                    AXIsProcessTrustedWithOptions(
                        options
                    )

                Task { @MainActor in
                    await self.refresh(
                        forceScreenProbe:
                            true
                    )
                }
            }
    }

    @objc
    private func allowScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            let granted =
                CGRequestScreenCaptureAccess()

            if !granted {
                openPrivacyPane(
                    "Privacy_ScreenCapture"
                )
            }
        }

        DispatchQueue.main
            .asyncAfter(
                deadline:
                    .now()
                    + 0.35
            ) { [weak self] in
                Task { @MainActor in
                    await self?.refresh(
                        forceScreenProbe:
                            true
                    )
                }
            }
    }

    @objc
    private func allowAccessibility() {
        let key =
            kAXTrustedCheckOptionPrompt
                .takeUnretainedValue()
            as String
        let options =
            [key: true]
            as CFDictionary

        _ =
            AXIsProcessTrustedWithOptions(
                options
            )

        DispatchQueue.main
            .asyncAfter(
                deadline:
                    .now()
                    + 0.45
            ) { [weak self] in
                guard
                    let self
                else {
                    return
                }

                if !AXIsProcessTrusted() {
                    self.openPrivacyPane(
                        "Privacy_Accessibility"
                    )
                }

                Task { @MainActor in
                    await self.refresh(
                        forceScreenProbe:
                            false
                    )
                }
            }
    }

    private func openPrivacyPane(
        _ anchor: String
    ) {
        guard
            let url =
                URL(
                    string:
                        "x-apple.systempreferences:"
                        + "com.apple.preference.security?"
                        + anchor
                )
        else {
            return
        }

        NSWorkspace.shared.open(
            url
        )
    }

    @objc
    private func quitApp() {
        NSApp.terminate(nil)
    }
}

@MainActor
final class AppDelegate:
    NSObject,
    NSApplicationDelegate {

    private var statusItem:
        NSStatusItem!
    private var menu:
        NSMenu!

    private var tickTimer:
        Timer?
    private var captureTask:
        Task<Void, Never>?

    private var session:
        FadeSession?
    private var permissionGate:
        PermissionGateController?

    private var mainStarted =
        false

    private var screenPermission =
        false
    private var accessibilityPermission =
        false

    private var enabled: Bool {
        get {
            if UserDefaults.standard
                .object(
                    forKey: "enabled"
                ) == nil {
                return true
            }

            return
                UserDefaults.standard
                    .bool(
                        forKey: "enabled"
                    )
        }

        set {
            UserDefaults.standard
                .set(
                    newValue,
                    forKey: "enabled"
                )

            if !newValue {
                breatheInImmediately()
            }

            rebuildMenu()
        }
    }

    private var idleSeconds:
        Double {
        get {
            let value =
                UserDefaults.standard
                    .double(
                        forKey:
                            "idleSeconds"
                    )

            return
                value > 0
                ? value
                : 4
        }

        set {
            UserDefaults.standard
                .set(
                    newValue,
                    forKey:
                        "idleSeconds"
                )
            rebuildMenu()
        }
    }

    private var fadeSeconds:
        Double {
        get {
            let value =
                UserDefaults.standard
                    .double(
                        forKey:
                            "fadeSeconds"
                    )

            return
                value > 0
                ? value
                : 9
        }

        set {
            UserDefaults.standard
                .set(
                    newValue,
                    forKey:
                        "fadeSeconds"
                )
            rebuildMenu()
        }
    }

    private let restingOpacity =
        0.10
    private let inhaleSeconds =
        0.72

    func applicationDidFinishLaunching(
        _ notification:
            Notification
    ) {
        screenPermission =
            false
        accessibilityPermission =
            false

        showPermissionGate()
    }

    func applicationWillTerminate(
        _ notification:
            Notification
    ) {
        tickTimer?.invalidate()
        captureTask?.cancel()
        permissionGate?.stop()
        breatheInImmediately()
    }

    private func showPermissionGate() {
        if permissionGate != nil {
            permissionGate?
                .showWindow(nil)
            return
        }

        captureTask?.cancel()
        captureTask = nil

        breatheInImmediately()

        tickTimer?.invalidate()
        tickTimer = nil

        if let statusItem {
            NSStatusBar.system
                .removeStatusItem(
                    statusItem
                )
            self.statusItem =
                nil
        }

        mainStarted = false
        NSApp.setActivationPolicy(
            .regular
        )

        let gate =
            PermissionGateController()

        gate.onReady = {
            [weak self, weak gate]
            screenVerified,
            accessibilityVerified
            in

            Task { @MainActor in
                guard
                    let self
                else {
                    return
                }

                gate?.stop()

                if self.permissionGate
                    === gate {
                    self.permissionGate =
                        nil
                }

                self.enterMainMode(
                    screenVerified:
                        screenVerified,
                    accessibilityVerified:
                        accessibilityVerified
                )
            }
        }

        permissionGate =
            gate

        gate.showWindow(nil)
        gate.window?
            .makeKeyAndOrderFront(
                nil
            )

        _ =
            NSRunningApplication.current
                .activate(
                    options: []
                )
    }

    private func enterMainMode(
        screenVerified: Bool,
        accessibilityVerified: Bool
    ) {
        screenPermission =
            screenVerified
            || CGPreflightScreenCaptureAccess()

        accessibilityPermission =
            accessibilityVerified
            || AXIsProcessTrusted()

        guard
            screenPermission,
            accessibilityPermission
        else {
            showPermissionGate()
            return
        }

        permissionGate?.stop()
        permissionGate = nil

        NSApp.setActivationPolicy(
            .accessory
        )

        if statusItem == nil {
            buildStatusItem()
        }

        if tickTimer == nil {
            tickTimer =
                Timer.scheduledTimer(
                    withTimeInterval:
                        0.12,
                    repeats: true
                ) {
                    [weak self] _ in

                    Task { @MainActor in
                        self?.tick()
                    }
                }
        }

        mainStarted = true
        rebuildMenu()
    }

    private func buildStatusItem() {
        statusItem =
            NSStatusBar.system
                .statusItem(
                    withLength:
                        NSStatusItem
                            .squareLength
                )

        if let button =
            statusItem.button {
            let image =
                NSImage(
                    systemSymbolName:
                        "circle.lefthalf.filled",
                    accessibilityDescription:
                        "Asympta Breathe"
                )

            image?.isTemplate =
                true

            button.image =
                image
            button.toolTip =
                "Asympta Breathe"
        }

        rebuildMenu()
    }

    private func refreshPermissions() {
        let preflightScreen =
            CGPreflightScreenCaptureAccess()
        let newAccessibility =
            AXIsProcessTrusted()

        let oldScreen =
            screenPermission
        let oldAccessibility =
            accessibilityPermission

        if preflightScreen {
            screenPermission =
                true
        }

        accessibilityPermission =
            newAccessibility

        if mainStarted
            && !accessibilityPermission {
            showPermissionGate()
            return
        }

        if (
            oldScreen
                != screenPermission
            || oldAccessibility
                != accessibilityPermission
        )
            && statusItem != nil {
            rebuildMenu()
        }
    }

    private func rebuildMenu() {
        guard
            statusItem != nil
        else {
            return
        }

        let menu = NSMenu()

        let title =
            NSMenuItem(
                title:
                    "Asympta Breathe",
                action: nil,
                keyEquivalent: ""
            )
        title.isEnabled =
            false
        menu.addItem(
            title
        )

        let version =
            Bundle.main.object(
                forInfoDictionaryKey:
                    "CFBundleShortVersionString"
            ) as? String
            ?? "—"

        let versionItem =
            NSMenuItem(
                title:
                    "Version \(version)",
                action: nil,
                keyEquivalent: ""
            )
        versionItem.isEnabled =
            false
        menu.addItem(
            versionItem
        )

        let statusText:
            String

        if !screenPermission {
            statusText =
                "Screen Recording permission needed"
        } else if !accessibilityPermission {
            statusText =
                "Accessibility permission needed"
        } else if let session {
            let remaining =
                session
                    .remainingPIDs
                    .count

            statusText =
                remaining == 1
                ? "1 app resting at 10% · click it to return"
                : "\(remaining) apps resting at 10% · click one to return"
        } else {
            let count =
                collectVisibleWindows()
                    .count

            statusText =
                enabled
                ? "Watching \(count) visible window\(count == 1 ? "" : "s")"
                : "Disabled"
        }

        let status =
            NSMenuItem(
                title:
                    statusText,
                action: nil,
                keyEquivalent: ""
            )
        status.isEnabled =
            false
        menu.addItem(
            status
        )

        menu.addItem(
            .separator()
        )

        let enabledItem =
            NSMenuItem(
                title: "Enabled",
                action:
                    #selector(
                        toggleEnabled
                    ),
                keyEquivalent: ""
            )
        enabledItem.target =
            self
        enabledItem.state =
            enabled
            ? .on
            : .off
        menu.addItem(
            enabledItem
        )

        let breathe =
            NSMenuItem(
                title:
                    "Breathe Visible Apps Now",
                action:
                    #selector(
                        breatheNow
                    ),
                keyEquivalent: ""
            )
        breathe.target =
            self
        breathe.isEnabled =
            screenPermission
            && accessibilityPermission
            && session == nil
            && captureTask == nil
            && !collectVisibleWindows()
                .isEmpty

        menu.addItem(
            breathe
        )

        if session != nil {
            let restore =
                NSMenuItem(
                    title:
                        "Breathe In All Now",
                    action:
                        #selector(
                            breatheInNow
                        ),
                    keyEquivalent: ""
                )
            restore.target =
                self
            menu.addItem(
                restore
            )
        }

        menu.addItem(
            .separator()
        )

        menu.addItem(
            makeValueMenu(
                title:
                    "Idle delay",
                current:
                    idleSeconds,
                values: [
                    2,
                    4,
                    8,
                    15,
                    30
                ],
                selector:
                    #selector(
                        setIdleDelay(
                            _:
                        )
                    )
            )
        )

        menu.addItem(
            makeValueMenu(
                title:
                    "Exhale duration",
                current:
                    fadeSeconds,
                values: [
                    3,
                    6,
                    9,
                    15,
                    30
                ],
                selector:
                    #selector(
                        setFadeDuration(
                            _:
                        )
                    )
            )
        )

        let resting =
            NSMenuItem(
                title:
                    "Resting opacity: 10%",
                action: nil,
                keyEquivalent: ""
            )
        resting.isEnabled =
            false
        menu.addItem(
            resting
        )

        let resetPermissions =
            NSMenuItem(
                title:
                    "Reset & Re-Approve Permissions…",
                action:
                    #selector(
                        resetPermissionsFromMenu
                    ),
                keyEquivalent: ""
            )
        resetPermissions.target =
            self

        menu.addItem(
            resetPermissions
        )

        menu.addItem(
            .separator()
        )

        let activityHint =
            NSMenuItem(
                title:
                    "Before fade: mouse, scroll and typing count as active",
                action: nil,
                keyEquivalent: ""
            )
        activityHint.isEnabled =
            false
        menu.addItem(
            activityHint
        )

        let wakeHint =
            NSMenuItem(
                title:
                    "After fade: only a click restores that specific app",
                action: nil,
                keyEquivalent: ""
            )
        wakeHint.isEnabled =
            false
        menu.addItem(
            wakeHint
        )

        let typingHint =
            NSMenuItem(
                title:
                    "Typing may continue in the app that was active when fading began",
                action: nil,
                keyEquivalent: ""
            )
        typingHint.isEnabled =
            false
        menu.addItem(
            typingHint
        )

        let quit =
            NSMenuItem(
                title:
                    "Quit Asympta Breathe",
                action:
                    #selector(
                        quitApp
                    ),
                keyEquivalent:
                    "q"
            )
        quit.target =
            self
        menu.addItem(
            quit
        )

        self.menu = menu
        statusItem.menu =
            menu
    }

    private func makeValueMenu(
        title: String,
        current: Double,
        values: [Double],
        selector: Selector
    ) -> NSMenuItem {
        let parent =
            NSMenuItem(
                title:
                    "\(title): \(Int(current))s",
                action: nil,
                keyEquivalent: ""
            )

        let submenu =
            NSMenu()

        for value in values {
            let item =
                NSMenuItem(
                    title:
                        "\(Int(value)) seconds",
                    action:
                        selector,
                    keyEquivalent: ""
                )
            item.target =
                self
            item.representedObject =
                value
            item.state =
                abs(
                    value
                    - current
                ) < 0.001
                ? .on
                : .off

            submenu.addItem(
                item
            )
        }

        parent.submenu =
            submenu
        return parent
    }

    private func tick() {
        refreshPermissions()

        guard
            mainStarted,
            screenPermission,
            accessibilityPermission,
            enabled
        else {
            return
        }

        if session != nil {
            return
        }

        guard
            captureTask == nil
        else {
            return
        }

        let idle =
            secondsSinceRelevantInput()

        guard
            idle >= idleSeconds
        else {
            return
        }

        let targets =
            collectVisibleWindows()

        guard
            !targets.isEmpty
        else {
            return
        }

        startBreatheOut(
            targets: targets
        )
    }

    private func secondsSinceRelevantInput()
        -> Double {
        let types: [
            CGEventType
        ] = [
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

        return
            types
                .map {
                    CGEventSource
                        .secondsSinceLastEventType(
                            .combinedSessionState,
                            eventType: $0
                        )
                }
                .min()
            ?? .greatestFiniteMagnitude
    }

    @objc
    private func toggleEnabled() {
        enabled.toggle()
    }

    @objc
    private func breatheNow() {
        guard
            session == nil,
            captureTask == nil
        else {
            return
        }

        let targets =
            collectVisibleWindows()

        guard
            !targets.isEmpty
        else {
            return
        }

        startBreatheOut(
            targets: targets
        )
    }

    @objc
    private func breatheInNow() {
        breatheInAll()
    }

    @objc
    private func setIdleDelay(
        _ sender: NSMenuItem
    ) {
        if let value =
            sender.representedObject
            as? Double {
            idleSeconds =
                value
        }
    }

    @objc
    private func setFadeDuration(
        _ sender: NSMenuItem
    ) {
        if let value =
            sender.representedObject
            as? Double {
            fadeSeconds =
                value
        }
    }

    @objc
    private func resetPermissionsFromMenu() {
        let alert =
            NSAlert()
        alert.messageText =
            "Reset permissions?"
        alert.informativeText =
            "This removes Asympta Breathe's current Screen Recording and "
            + "Accessibility approvals, then returns to permission setup."
        alert.alertStyle =
            .warning
        alert.addButton(
            withTitle:
                "Reset & Re-Approve"
        )
        alert.addButton(
            withTitle:
                "Cancel"
        )

        guard
            alert.runModal()
                == .alertFirstButtonReturn
        else {
            return
        }

        captureTask?.cancel()
        captureTask = nil
        breatheInImmediately()

        _ =
            resetAsymptaPermissions()

        screenPermission =
            false
        accessibilityPermission =
            false
        mainStarted =
            false

        showPermissionGate()
    }

    @objc
    private func quitApp() {
        NSApp.terminate(nil)
    }

    private func startBreatheOut(
        targets:
            [VisibleWindowTarget]
    ) {
        guard
            session == nil,
            captureTask == nil
        else {
            return
        }

        let frontmostPID =
            NSWorkspace.shared
                .frontmostApplication?
                .processIdentifier

        captureTask =
            Task { [weak self] in
                guard
                    let self
                else {
                    return
                }

                do {
                    let shareable =
                        try await
                            SCShareableContent
                                .excludingDesktopWindows(
                                    false,
                                    onScreenWindowsOnly:
                                        true
                                )

                    let shareableByID =
                        Dictionary(
                            uniqueKeysWithValues:
                                shareable.windows
                                    .map {
                                        (
                                            $0.windowID,
                                            $0
                                        )
                                    }
                        )

                    var captured:
                        [CapturedWindow] =
                            []

                    for target in targets {
                        guard
                            let scWindow =
                                shareableByID[
                                    target
                                        .window
                                        .windowID
                                ]
                        else {
                            continue
                        }

                        let filter =
                            SCContentFilter(
                                desktopIndependentWindow:
                                    scWindow
                            )

                        let config =
                            SCStreamConfiguration()

                        let scale =
                            self.backingScale(
                                for:
                                    target
                                        .window
                                        .appKitFrame
                            )

                        config.width =
                            max(
                                1,
                                Int(
                                    target
                                        .window
                                        .cgFrame
                                        .width
                                    * scale
                                )
                            )

                        config.height =
                            max(
                                1,
                                Int(
                                    target
                                        .window
                                        .cgFrame
                                        .height
                                    * scale
                                )
                            )

                        config.showsCursor =
                            false
                        config.queueDepth =
                            1
                        config.shouldBeOpaque =
                            false

                        // This fixes the Safari edge strip / side-bar artifact:
                        // the captured image dimensions now match CGWindow frame
                        // instead of including an extra native shadow.
                        config.ignoreShadowsSingleWindow =
                            true

                        let image =
                            try await
                                SCScreenshotManager
                                    .captureImage(
                                        contentFilter:
                                            filter,
                                        configuration:
                                            config
                                    )

                        captured.append(
                            CapturedWindow(
                                target:
                                    target,
                                scWindow:
                                    scWindow,
                                image:
                                    image,
                                scale:
                                    scale
                            )
                        )
                    }

                    if Task.isCancelled {
                        self.captureTask =
                            nil
                        return
                    }

                    guard
                        !captured.isEmpty
                    else {
                        self.captureTask =
                            nil
                        return
                    }

                    self.captureTask =
                        nil

                    self.presentBreatheOut(
                        captured:
                            captured,
                        typingPID:
                            frontmostPID
                    )
                } catch {
                    self.captureTask =
                        nil

                    if !CGPreflightScreenCaptureAccess() {
                        self.screenPermission =
                            false
                        self.showPermissionGate()
                    } else {
                        self.rebuildMenu()
                    }
                }
            }
    }

    private func presentBreatheOut(
        captured:
            [CapturedWindow],
        typingPID:
            pid_t?
    ) {
        guard
            session == nil
        else {
            return
        }

        var panels:
            [BreathPanel] =
                []
        var views:
            [BreathOverlayView] =
                []

        for item in captured {
            let panel =
                BreathPanel(
                    contentRect:
                        item
                            .target
                            .window
                            .appKitFrame,
                    styleMask: [
                        .borderless,
                        .nonactivatingPanel
                    ],
                    backing:
                        .buffered,
                    defer:
                        false
                )

            panel.isOpaque =
                false
            panel.backgroundColor =
                .clear
            panel.hasShadow =
                false
            panel.alphaValue =
                1
            panel.ignoresMouseEvents =
                false
            panel.level =
                .screenSaver
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary,
                .ignoresCycle
            ]
            panel.animationBehavior =
                .none

            let overlay =
                BreathOverlayView(
                    frame:
                        NSRect(
                            origin:
                                .zero,
                            size:
                                item
                                    .target
                                    .window
                                    .appKitFrame
                                    .size
                        )
                )

            overlay.install(
                image:
                    item.image,
                borderColor:
                    stableAppColor(
                        bundleID:
                            item
                                .target
                                .bundleID
                    )
            )

            panel.contentView =
                overlay

            panels.append(
                panel
            )
            views.append(
                overlay
            )
        }

        let newSession =
            FadeSession(
                captured:
                    captured,
                panels:
                    panels,
                views:
                    views,
                typingPID:
                    typingPID
            )

        for (
            index,
            view
        ) in views.enumerated() {
            let app =
                captured[
                    index
                ]
                .target
                .app

            view.onClick = {
                [weak self,
                 weak newSession,
                 weak app]
                in

                Task { @MainActor in
                    guard
                        let self,
                        let newSession,
                        self.session
                            === newSession
                    else {
                        return
                    }

                    self.breatheIn(
                        pid:
                            app?
                                .processIdentifier,
                        preferredApp:
                            app
                    )
                }
            }
        }

        session =
            newSession

        // CGWindow list is front-to-back.
        // Reverse order preserves original visual stacking.
        for panel in panels
            .reversed() {
            panel.orderFrontRegardless()
        }

        DispatchQueue.main
            .asyncAfter(
                deadline:
                    .now()
                    + 0.055
            ) {
                [weak self,
                 weak newSession]
                in

                guard
                    let self,
                    let newSession,
                    self.session
                        === newSession
                else {
                    return
                }

                let displacements =
                    self
                        .displaceOriginalWindows(
                            captured:
                                captured
                        )

                guard
                    !displacements
                        .isEmpty
                else {
                    self
                        .closeSessionWithoutRestoring(
                            newSession
                        )
                    self.rebuildMenu()
                    return
                }

                newSession.displacements =
                    displacements

                NSAnimationContext
                    .runAnimationGroup {
                        context in

                        context.duration =
                            self.fadeSeconds
                        context.timingFunction =
                            CAMediaTimingFunction(
                                controlPoints:
                                    0.37,
                                0.0,
                                0.63,
                                1.0
                            )
                        context
                            .allowsImplicitAnimation =
                                true

                        for view
                            in views {
                            view
                                .baseImageView
                                .animator()
                                .alphaValue =
                                    CGFloat(
                                        self
                                            .restingOpacity
                                    )
                        }
                    } completionHandler: {
                        [weak self,
                         weak newSession]
                        in

                        Task { @MainActor in
                            guard
                                let self,
                                let newSession,
                                self.session
                                    === newSession
                            else {
                                return
                            }

                            self
                                .startTypingRefresh(
                                    session:
                                        newSession
                                )

                            self
                                .rebuildMenu()
                        }
                    }
            }

        rebuildMenu()
    }

    private func startTypingRefresh(
        session:
            FadeSession
    ) {
        session.stopTypingTimer()

        guard
            let pid =
                session.typingPID,
            session
                .remainingPIDs
                .contains(pid)
        else {
            return
        }

        session.typingTimer =
            Timer.scheduledTimer(
                withTimeInterval:
                    0.085,
                repeats:
                    true
            ) {
                [weak self,
                 weak session]
                _ in

                Task { @MainActor in
                    guard
                        let self,
                        let session,
                        self.session
                            === session,
                        session
                            .remainingPIDs
                            .contains(pid)
                    else {
                        return
                    }

                    await self
                        .refreshTypingVisual(
                            session:
                                session,
                            pid:
                                pid
                        )
                }
            }
    }

    private func refreshTypingVisual(
        session:
            FadeSession,
        pid:
            pid_t
    ) async {
        guard
            !session
                .typingRefreshInFlight
        else {
            return
        }

        session
            .typingRefreshInFlight =
                true

        defer {
            session
                .typingRefreshInFlight =
                    false
        }

        guard
            let focusedFrame =
                focusedElementFrame(
                    for:
                        pid
                )
        else {
            for (
                index,
                item
            ) in session
                .captured
                .enumerated()
            where
                item
                    .target
                    .app
                    .processIdentifier
                == pid {
                session
                    .views[index]
                    .hideFocusedRegion()
            }

            return
        }

        guard
            let index =
                session
                    .captured
                    .firstIndex(
                        where: {
                            $0
                                .target
                                .app
                                .processIdentifier
                            == pid
                            && $0
                                .target
                                .window
                                .cgFrame
                                .intersects(
                                    focusedFrame
                                )
                        }
                    )
        else {
            return
        }

        let item =
            session
                .captured[
                    index
                ]

        let config =
            SCStreamConfiguration()

        config.width =
            max(
                1,
                Int(
                    item
                        .target
                        .window
                        .cgFrame
                        .width
                    * item.scale
                )
            )

        config.height =
            max(
                1,
                Int(
                    item
                        .target
                        .window
                        .cgFrame
                        .height
                    * item.scale
                )
            )

        config.showsCursor =
            false
        config.queueDepth =
            1
        config.shouldBeOpaque =
            false
        config.ignoreShadowsSingleWindow =
            true

        do {
            let filter =
                SCContentFilter(
                    desktopIndependentWindow:
                        item.scWindow
                )

            let image =
                try await
                    SCScreenshotManager
                        .captureImage(
                            contentFilter:
                                filter,
                            configuration:
                                config
                        )

            guard
                self.session
                    === session,
                session
                    .remainingPIDs
                    .contains(pid)
            else {
                return
            }

            let view =
                session
                    .views[
                        index
                    ]

            // Keep the resting app live at 10%, so caret / text layout /
            // animations continue rather than freezing at the original frame.
            view.setBaseImage(
                image
            )

            let windowFrame =
                item
                    .target
                    .window
                    .cgFrame

            let localX =
                focusedFrame.minX
                - windowFrame.minX

            let localTopY =
                focusedFrame.minY
                - windowFrame.minY

            let localRect =
                CGRect(
                    x:
                        localX,
                    y:
                        windowFrame.height
                        - localTopY
                        - focusedFrame.height,
                    width:
                        focusedFrame.width,
                    height:
                        focusedFrame.height
                )

            // The focused input stays fully awake: typed text, caret and
            // native typing animation render at normal color while the rest
            // of the app remains at 10%.
            view.showFocusedRegion(
                image:
                    image,
                localRect:
                    localRect
            )
        } catch {
            // Keep the existing faded representation if a live refresh frame
            // fails; do not wake the app and do not make a sound.
        }
    }

    private func focusedElementFrame(
        for pid:
            pid_t
    ) -> CGRect? {
        let appElement =
            AXUIElementCreateApplication(
                pid
            )

        var focusedRaw:
            CFTypeRef?

        guard
            AXUIElementCopyAttributeValue(
                appElement,
                kAXFocusedUIElementAttribute
                    as CFString,
                &focusedRaw
            ) == .success,
            let focusedRaw,
            CFGetTypeID(
                focusedRaw
            ) == AXUIElementGetTypeID()
        else {
            return nil
        }

        let focused =
            focusedRaw
            as! AXUIElement

        guard
            let position =
                axPoint(
                    element:
                        focused,
                    attribute:
                        kAXPositionAttribute
                        as CFString
                ),
            let size =
                axSize(
                    element:
                        focused,
                    attribute:
                        kAXSizeAttribute
                        as CFString
                ),
            size.width > 2,
            size.height > 2
        else {
            return nil
        }

        return CGRect(
            origin:
                position,
            size:
                size
        )
    }

    private func breatheIn(
        pid:
            pid_t?,
        preferredApp:
            NSRunningApplication?
    ) {
        guard
            let pid,
            let current =
                session,
            current
                .remainingPIDs
                .contains(pid),
            !current
                .inhalingPIDs
                .contains(pid)
        else {
            return
        }

        if current.typingPID
            == pid {
            current.stopTypingTimer()
        }

        let indices =
            current
                .captured
                .indices
                .filter {
                    current
                        .captured[
                            $0
                        ]
                        .target
                        .app
                        .processIdentifier
                    == pid
                }

        guard
            !indices.isEmpty
        else {
            return
        }

        current
            .inhalingPIDs
            .insert(pid)

        for index in indices {
            current
                .views[index]
                .hideFocusedRegion()
        }

        rebuildMenu()

        NSAnimationContext
            .runAnimationGroup {
                context in

                context.duration =
                    inhaleSeconds

                context.timingFunction =
                    CAMediaTimingFunction(
                        controlPoints:
                            0.22,
                        1.0,
                        0.36,
                        1.0
                    )

                context
                    .allowsImplicitAnimation =
                        true

                for index
                    in indices {
                    current
                        .views[
                            index
                        ]
                        .baseImageView
                        .animator()
                        .alphaValue =
                            1
                }
            } completionHandler: {
                [weak self,
                 weak current,
                 weak preferredApp]
                in

                Task { @MainActor in
                    guard
                        let self,
                        let current,
                        self.session
                            === current
                    else {
                        return
                    }

                    if let displacement =
                        current
                            .displacements
                            .first(
                                where: {
                                    $0
                                        .app
                                        .processIdentifier
                                    == pid
                                }
                            ) {
                        self
                            .restoreOriginalWindows(
                                [
                                    displacement
                                ]
                            )
                    }

                    if let preferredApp {
                        _ =
                            preferredApp
                                .activate(
                                    options:
                                        []
                                )
                    }

                    DispatchQueue.main
                        .asyncAfter(
                            deadline:
                                .now()
                                + 0.055
                        ) {
                            [weak self,
                             weak current]
                            in

                            guard
                                let self,
                                let current,
                                self.session
                                    === current
                            else {
                                return
                            }

                            for index
                                in indices {
                                current
                                    .panels[
                                        index
                                    ]
                                    .orderOut(
                                        nil
                                    )
                                current
                                    .panels[
                                        index
                                    ]
                                    .close()
                            }

                            current
                                .inhalingPIDs
                                .remove(pid)

                            current
                                .restoredPIDs
                                .insert(pid)

                            if current
                                .remainingPIDs
                                .isEmpty {
                                current
                                    .stopTypingTimer()
                                self.session =
                                    nil
                            }

                            self
                                .rebuildMenu()
                        }
                }
            }
    }

    private func breatheInAll() {
        guard
            let current =
                session
        else {
            return
        }

        let pids =
            Array(
                current
                    .remainingPIDs
            )

        for pid in pids {
            let app =
                current
                    .captured
                    .first(
                        where: {
                            $0
                                .target
                                .app
                                .processIdentifier
                            == pid
                        }
                    )?
                    .target
                    .app

            breatheIn(
                pid:
                    pid,
                preferredApp:
                    app
            )
        }
    }

    private func breatheInImmediately() {
        captureTask?.cancel()
        captureTask = nil

        guard
            let current =
                session
        else {
            return
        }

        current.stopTypingTimer()

        restoreOriginalWindows(
            current
                .displacements
        )

        current.panels
            .forEach {
                $0.orderOut(nil)
                $0.close()
            }

        session = nil
        rebuildMenu()
    }

    private func closeSessionWithoutRestoring(
        _ current:
            FadeSession
    ) {
        current.stopTypingTimer()

        restoreOriginalWindows(
            current
                .displacements
        )

        current.panels
            .forEach {
                $0.orderOut(nil)
                $0.close()
            }

        if session === current {
            session = nil
        }
    }

    private func displaceOriginalWindows(
        captured:
            [CapturedWindow]
    ) -> [AppDisplacement] {
        var windowsByPID:
            [pid_t: [TargetWindow]] =
                [:]

        var appsByPID:
            [pid_t:
                NSRunningApplication] =
                [:]

        var pidOrder:
            [pid_t] =
                []

        for item in captured {
            let pid =
                item
                    .target
                    .app
                    .processIdentifier

            if windowsByPID[
                pid
            ] == nil {
                windowsByPID[
                    pid
                ] = []

                appsByPID[
                    pid
                ] =
                    item
                        .target
                        .app

                pidOrder.append(
                    pid
                )
            }

            windowsByPID[
                pid
            ]?
                .append(
                    item
                        .target
                        .window
                )
        }

        var results:
            [AppDisplacement] =
                []

        for pid in pidOrder {
            guard
                let app =
                    appsByPID[
                        pid
                    ],
                let visibleWindows =
                    windowsByPID[
                        pid
                    ]
            else {
                continue
            }

            let states =
                collectAXWindowStates(
                    for:
                        pid,
                    matching:
                        visibleWindows
                )

            var movedCount =
                0

            for (
                index,
                state
            ) in states
                .enumerated() {
                let destination =
                    CGPoint(
                        x:
                            -12_000
                            - CGFloat(
                                index
                                * 48
                            ),
                        y:
                            state
                                .originalPosition
                                .y
                    )

                if setAXPoint(
                    element:
                        state.element,
                    attribute:
                        kAXPositionAttribute
                        as CFString,
                    value:
                        destination
                ) {
                    movedCount +=
                        1
                }
            }

            let useHideFallback =
                movedCount
                < visibleWindows
                    .count

            if useHideFallback {
                _ =
                    app.hide()
            }

            results.append(
                AppDisplacement(
                    app:
                        app,
                    axWindows:
                        states,
                    hiddenFallback:
                        useHideFallback
                )
            )
        }

        return results
    }

    private func restoreOriginalWindows(
        _ displacements:
            [AppDisplacement]
    ) {
        for displacement
            in displacements {
            for state
                in displacement
                    .axWindows {
                _ =
                    setAXPoint(
                        element:
                            state
                                .element,
                        attribute:
                            kAXPositionAttribute
                            as CFString,
                        value:
                            state
                                .originalPosition
                    )
            }

            if displacement
                .hiddenFallback {
                _ =
                    displacement
                        .app
                        .unhide()
            }
        }
    }

    private func collectAXWindowStates(
        for pid:
            pid_t,
        matching visibleWindows:
            [TargetWindow]
    ) -> [AXWindowState] {
        let appElement =
            AXUIElementCreateApplication(
                pid
            )

        var rawWindows:
            CFTypeRef?

        let result =
            AXUIElementCopyAttributeValue(
                appElement,
                kAXWindowsAttribute
                    as CFString,
                &rawWindows
            )

        guard
            result
                == .success,
            let windows =
                rawWindows
                as? [AXUIElement]
        else {
            return []
        }

        var states:
            [AXWindowState] =
                []

        for window in windows {
            guard
                let position =
                    axPoint(
                        element:
                            window,
                        attribute:
                            kAXPositionAttribute
                            as CFString
                    ),
                let size =
                    axSize(
                        element:
                            window,
                        attribute:
                            kAXSizeAttribute
                            as CFString
                    )
            else {
                continue
            }

            var minimizedValue:
                CFTypeRef?

            if AXUIElementCopyAttributeValue(
                window,
                kAXMinimizedAttribute
                    as CFString,
                &minimizedValue
            ) == .success,
               let minimized =
                    minimizedValue
                    as? Bool,
               minimized {
                continue
            }

            let matches =
                visibleWindows
                    .contains {
                        target in

                        abs(
                            target
                                .cgFrame
                                .minX
                            - position.x
                        ) <= 8

                        && abs(
                            target
                                .cgFrame
                                .minY
                            - position.y
                        ) <= 8

                        && abs(
                            target
                                .cgFrame
                                .width
                            - size.width
                        ) <= 12

                        && abs(
                            target
                                .cgFrame
                                .height
                            - size.height
                        ) <= 12
                    }

            guard
                matches
            else {
                continue
            }

            states.append(
                AXWindowState(
                    element:
                        window,
                    originalPosition:
                        position
                )
            )
        }

        return states
    }

    private func collectVisibleWindows()
        -> [VisibleWindowTarget] {
        let options:
            CGWindowListOption = [
                .optionOnScreenOnly,
                .excludeDesktopElements
            ]

        guard
            let list =
                CGWindowListCopyWindowInfo(
                    options,
                    kCGNullWindowID
                )
                as? [[String: Any]]
        else {
            return []
        }

        let ownPID =
            ProcessInfo
                .processInfo
                .processIdentifier

        var targets:
            [VisibleWindowTarget] =
                []

        for info in list {
            guard
                let pid =
                    (
                        info[
                            kCGWindowOwnerPID
                            as String
                        ]
                        as? NSNumber
                    )?
                    .int32Value,
                pid != ownPID,

                let layer =
                    (
                        info[
                            kCGWindowLayer
                            as String
                        ]
                        as? NSNumber
                    )?
                    .intValue,
                layer == 0,

                let alpha =
                    (
                        info[
                            kCGWindowAlpha
                            as String
                        ]
                        as? NSNumber
                    )?
                    .doubleValue,
                alpha > 0.01,

                let number =
                    (
                        info[
                            kCGWindowNumber
                            as String
                        ]
                        as? NSNumber
                    )?
                    .uint32Value,

                let bounds =
                    info[
                        kCGWindowBounds
                        as String
                    ]
                    as? NSDictionary,

                let cgFrame =
                    CGRect(
                        dictionaryRepresentation:
                            bounds
                            as CFDictionary
                    ),

                cgFrame.width
                    >= 120,
                cgFrame.height
                    >= 80,

                let app =
                    NSRunningApplication(
                        processIdentifier:
                            pid
                    ),

                !app.isTerminated,
                app.activationPolicy
                    == .regular,
                app.bundleIdentifier
                    != appBundleID
            else {
                continue
            }

            let bundleID =
                app.bundleIdentifier
                ?? "pid:\(pid)"

            targets.append(
                VisibleWindowTarget(
                    app:
                        app,
                    appName:
                        app.localizedName
                        ?? "App",
                    bundleID:
                        bundleID,
                    window:
                        TargetWindow(
                            windowID:
                                CGWindowID(
                                    number
                                ),
                            cgFrame:
                                cgFrame,
                            appKitFrame:
                                appKitFrame(
                                    fromCGWindowFrame:
                                        cgFrame
                                )
                        )
                )
            )
        }

        return targets
    }

    private func axPoint(
        element:
            AXUIElement,
        attribute:
            CFString
    ) -> CGPoint? {
        var raw:
            CFTypeRef?

        guard
            AXUIElementCopyAttributeValue(
                element,
                attribute,
                &raw
            ) == .success,
            let raw,
            CFGetTypeID(
                raw
            )
                == AXValueGetTypeID()
        else {
            return nil
        }

        let value =
            raw
            as! AXValue

        guard
            AXValueGetType(
                value
            ) == .cgPoint
        else {
            return nil
        }

        var point =
            CGPoint.zero

        guard
            AXValueGetValue(
                value,
                .cgPoint,
                &point
            )
        else {
            return nil
        }

        return point
    }

    private func axSize(
        element:
            AXUIElement,
        attribute:
            CFString
    ) -> CGSize? {
        var raw:
            CFTypeRef?

        guard
            AXUIElementCopyAttributeValue(
                element,
                attribute,
                &raw
            ) == .success,
            let raw,
            CFGetTypeID(
                raw
            )
                == AXValueGetTypeID()
        else {
            return nil
        }

        let value =
            raw
            as! AXValue

        guard
            AXValueGetType(
                value
            ) == .cgSize
        else {
            return nil
        }

        var size =
            CGSize.zero

        guard
            AXValueGetValue(
                value,
                .cgSize,
                &size
            )
        else {
            return nil
        }

        return size
    }

    private func setAXPoint(
        element:
            AXUIElement,
        attribute:
            CFString,
        value:
            CGPoint
    ) -> Bool {
        var point =
            value

        guard
            let axValue =
                AXValueCreate(
                    .cgPoint,
                    &point
                )
        else {
            return false
        }

        return
            AXUIElementSetAttributeValue(
                element,
                attribute,
                axValue
            )
            == .success
    }

    private func appKitFrame(
        fromCGWindowFrame frame:
            CGRect
    ) -> CGRect {
        let mainHeight =
            CGDisplayBounds(
                CGMainDisplayID()
            )
            .height

        return CGRect(
            x:
                frame.minX,
            y:
                mainHeight
                - frame.minY
                - frame.height,
            width:
                frame.width,
            height:
                frame.height
        )
    }

    private func backingScale(
        for rect:
            CGRect
    ) -> CGFloat {
        let center =
            CGPoint(
                x:
                    rect.midX,
                y:
                    rect.midY
            )

        if let screen =
            NSScreen.screens
                .first(
                    where: {
                        $0.frame
                            .contains(
                                center
                            )
                    }
                ) {
            return
                screen
                    .backingScaleFactor
        }

        return
            NSScreen.main?
                .backingScaleFactor
            ?? 2
    }
}

@main
struct AsymptaBreatheMain {
    @MainActor
    static func main() {
        let app =
            NSApplication.shared
        let delegate =
            AppDelegate()

        app.delegate =
            delegate

        app.run()

        _ = delegate
    }
}
