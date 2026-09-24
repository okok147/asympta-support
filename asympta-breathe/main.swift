import AppKit
import ScreenCaptureKit
import CoreGraphics
import QuartzCore
import ApplicationServices
import CoreImage

private let appBundleID = "com.asympta.breathe"
private let permissionResetPendingKey = "permissionResetPending"

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

private struct PreparedOverlay {
    let target: VisibleWindowTarget
    let scWindow: SCWindow
    let scale: CGFloat
    let backgroundImage: CGImage
    let borderImage: CGImage?
}

@MainActor
private final class WindowOverlay {
    let target: VisibleWindowTarget
    let scWindow: SCWindow
    let scale: CGFloat
    let panel: BreathPanel
    let view: BreathOverlayView

    init(
        target: VisibleWindowTarget,
        scWindow: SCWindow,
        scale: CGFloat,
        panel: BreathPanel,
        view: BreathOverlayView
    ) {
        self.target = target
        self.scWindow = scWindow
        self.scale = scale
        self.panel = panel
        self.view = view
    }
}

private func resetTCCService(
    _ service: String
) -> Bool {
    let process = Process()

    process.executableURL =
        URL(
            fileURLWithPath:
                "/usr/bin/tccutil"
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

        return
            process.terminationStatus
            == 0
    } catch {
        return false
    }
}

private func resetAsymptaPermissions()
    -> Bool {
    let screenReset =
        resetTCCService(
            "ScreenCapture"
        )

    let accessibilityReset =
        resetTCCService(
            "Accessibility"
        )

    return
        screenReset
        && accessibilityReset
}

private func verifyScreenCaptureCapability()
    async -> Bool {
    do {
        _ =
            try await
                SCShareableContent
                    .excludingDesktopWindows(
                        false,
                        onScreenWindowsOnly:
                            true
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

    var hash:
        UInt64 =
            1469598103934665603

    for byte in bundleID.utf8 {
        hash ^= UInt64(byte)
        hash &*=
            1099511628211
    }

    return
        palette[
            Int(
                hash
                % UInt64(
                    palette.count
                )
            )
        ]
}

private func makeAlphaEdgeImage(
    from image: CGImage,
    color: NSColor
) -> CGImage? {
    let input =
        CIImage(
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
                "inputRadius":
                    1.15
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
                        x:
                            rgb.redComponent,
                        y: 0,
                        z: 0,
                        w: 0
                    ),
                "inputGVector":
                    CIVector(
                        x:
                            rgb.greenComponent,
                        y: 0,
                        z: 0,
                        w: 0
                    ),
                "inputBVector":
                    CIVector(
                        x:
                            rgb.blueComponent,
                        y: 0,
                        z: 0,
                        w: 0
                    ),
                "inputAVector":
                    CIVector(
                        x: 0.58,
                        y: 0,
                        z: 0,
                        w: 0
                    )
            ]
        )

    return
        ciContext.createCGImage(
            tinted,
            from:
                input.extent
        )
}

private func makeTextOnlyImage(
    from image: CGImage,
    focusRect: CGRect
) -> CGImage? {
    let full =
        CIImage(
            cgImage: image
        )

    let clipped =
        focusRect
            .intersection(
                full.extent
            )
            .insetBy(
                dx: 2,
                dy: 2
            )

    guard
        !clipped.isNull,
        clipped.width > 4,
        clipped.height > 4
    else {
        return nil
    }

    let focus =
        full
            .cropped(
                to: clipped
            )

    // Detect high-frequency foreground detail inside the editable control.
    // This keeps glyphs/caret visible while leaving the field background covered.
    let mono =
        focus
            .applyingFilter(
                "CIPhotoEffectMono"
            )

    let edges =
        mono
            .applyingFilter(
                "CIEdges",
                parameters: [
                    "inputIntensity": 2.6
                ]
            )
            .cropped(
                to: clipped
            )

    let boosted =
        edges
            .applyingFilter(
                "CIColorControls",
                parameters: [
                    "inputSaturation": 0,
                    "inputBrightness": -0.12,
                    "inputContrast": 4.2
                ]
            )
            .cropped(
                to: clipped
            )

    let mask =
        boosted
            .applyingFilter(
                "CIMorphologyMaximum",
                parameters: [
                    "inputRadius": 1.35
                ]
            )
            .cropped(
                to: clipped
            )

    let clearFocus =
        CIImage(
            color: .clear
        )
        .cropped(
            to: clipped
        )

    let revealed =
        focus
            .applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey:
                        clearFocus,
                    kCIInputMaskImageKey:
                        mask
                ]
            )
            .cropped(
                to: clipped
            )

    let clearFull =
        CIImage(
            color: .clear
        )
        .cropped(
            to: full.extent
        )

    let composed =
        revealed
            .composited(
                over: clearFull
            )

    return
        ciContext
            .createCGImage(
                composed,
                from: full.extent
            )
}

@MainActor
private final class BreathOverlayView:
    NSView {

    let coverImageView =
        NSImageView()

    let textImageView =
        NSImageView()

    let borderImageView =
        NSImageView()

    override init(
        frame frameRect:
            NSRect
    ) {
        super.init(
            frame:
                frameRect
        )

        wantsLayer =
            true

        layer?
            .backgroundColor =
                NSColor.clear
                    .cgColor

        for imageView
            in [
                coverImageView,
                textImageView,
                borderImageView
            ] {
            imageView.frame =
                bounds

            imageView
                .autoresizingMask = [
                    .width,
                    .height
                ]

            imageView
                .imageScaling =
                    .scaleAxesIndependently

            imageView
                .imageAlignment =
                    .alignCenter

            imageView
                .wantsLayer =
                    true

            addSubview(
                imageView
            )
        }

        coverImageView
            .alphaValue =
                0

        textImageView
            .alphaValue =
                1

        textImageView
            .isHidden =
                true

        borderImageView
            .alphaValue =
                0
    }

    required init?(
        coder:
            NSCoder
    ) {
        fatalError(
            "init(coder:) has not been implemented"
        )
    }

    func install(
        background:
            CGImage,
        border:
            CGImage?
    ) {
        coverImageView.image =
            NSImage(
                cgImage:
                    background,
                size:
                    bounds.size
            )

        if let border {
            borderImageView.image =
                NSImage(
                    cgImage:
                        border,
                    size:
                        bounds.size
                )
        } else {
            borderImageView.image =
                nil
        }
    }

    func setTextReveal(
        _ image:
            CGImage?
    ) {
        guard
            let image
        else {
            textImageView
                .isHidden =
                    true

            textImageView.image =
                nil

            return
        }

        textImageView.image =
            NSImage(
                cgImage:
                    image,
                size:
                    bounds.size
            )

        textImageView
            .isHidden =
                false
    }
}

private final class BreathPanel:
    NSPanel {

    override var canBecomeKey:
        Bool {
        false
    }

    override var canBecomeMain:
        Bool {
        false
    }
}

@MainActor
private final class FadeSession {
    var overlays:
        [WindowOverlay]

    var restoredPIDs:
        Set<pid_t> =
            []

    var inhalingPIDs:
        Set<pid_t> =
            []

    var clickMonitor:
        Any?

    var focusTimer:
        Timer?

    var focusRefreshInFlight =
        false

    init(
        overlays:
            [WindowOverlay]
    ) {
        self.overlays =
            overlays
    }

    var allPIDs:
        Set<pid_t> {
        Set(
            overlays.map {
                $0.target
                    .app
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

    func cleanupMonitors() {
        if let clickMonitor {
            NSEvent
                .removeMonitor(
                    clickMonitor
                )

            self.clickMonitor =
                nil
        }

        focusTimer?
            .invalidate()

        focusTimer =
            nil
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
            title:
                "Allow",
            target:
                nil,
            action:
                nil
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
            title:
                "Allow",
            target:
                nil,
            action:
                nil
        )

    private let resetButton =
        NSButton(
            title:
                "Reset & Re-Approve",
            target:
                nil,
            action:
                nil
        )

    private let refreshButton =
        NSButton(
            title:
                "Check Permissions",
            target:
                nil,
            action:
                nil
        )

    private let footerStatus =
        NSTextField(
            labelWithString:
                "Both permissions must be verified before Asympta Breathe can start."
        )

    private var pollTimer:
        Timer?

    private var refreshInProgress =
        false

    private var didDeliverReady =
        false

    private var screenVerified =
        false

    private var accessibilityVerified =
        false

    init() {
        let window =
            NSWindow(
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
                backing:
                    .buffered,
                defer:
                    false
            )

        window.title =
            "Asympta Breathe"

        window
            .isReleasedWhenClosed =
                false

        window.center()

        super.init(
            window:
                window
        )

        configureUI()
    }

    required init?(
        coder:
            NSCoder
    ) {
        fatalError(
            "init(coder:) has not been implemented"
        )
    }

    deinit {
        pollTimer?
            .invalidate()
    }

    func stop() {
        pollTimer?
            .invalidate()

        pollTimer =
            nil

        close()
    }

    private func configureUI() {
        guard
            let contentView =
                window?
                    .contentView
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
                ofSize:
                    24,
                weight:
                    .semibold
            )

        let subtitle =
            NSTextField(
                wrappingLabelWithString:
                    "Asympta Breathe requires Screen Recording and Accessibility. "
                    + "There is no automatic refresh: approve both, then click Check Permissions, "
                    + "or reopen the app if macOS asks you to."
            )

        subtitle
            .textColor =
                .secondaryLabelColor

        subtitle.font =
            .systemFont(
                ofSize:
                    13
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

        resetButton.target =
            self

        resetButton.action =
            #selector(
                resetAndReapprove
            )

        resetButton
            .bezelStyle =
                .rounded

        refreshButton.target =
            self

        refreshButton.action =
            #selector(
                refreshNow
            )

        refreshButton
            .bezelStyle =
                .rounded

        refreshButton
            .keyEquivalent =
                "\r"

        footerStatus.font =
            .systemFont(
                ofSize:
                    12,
                weight:
                    .medium
            )

        footerStatus
            .textColor =
                .secondaryLabelColor

        let quit =
            NSButton(
                title:
                    "Quit",
                target:
                    self,
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

        footer.spacing =
            10

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

        stack.spacing =
            16

        stack
            .translatesAutoresizingMaskIntoConstraints =
                false

        contentView
            .addSubview(
                stack
            )

        NSLayoutConstraint
            .activate([
                stack
                    .leadingAnchor
                    .constraint(
                        equalTo:
                            contentView
                                .leadingAnchor,
                        constant:
                            26
                    ),
                stack
                    .trailingAnchor
                    .constraint(
                        equalTo:
                            contentView
                                .trailingAnchor,
                        constant:
                            -26
                    ),
                stack
                    .topAnchor
                    .constraint(
                        equalTo:
                            contentView
                                .topAnchor,
                        constant:
                            26
                    ),
                stack
                    .bottomAnchor
                    .constraint(
                        lessThanOrEqualTo:
                            contentView
                                .bottomAnchor,
                        constant:
                            -22
                    ),
                subtitle
                    .widthAnchor
                    .constraint(
                        equalTo:
                            stack
                                .widthAnchor
                    ),
                screenRow
                    .widthAnchor
                    .constraint(
                        equalTo:
                            stack
                                .widthAnchor
                    ),
                accessibilityRow
                    .widthAnchor
                    .constraint(
                        equalTo:
                            stack
                                .widthAnchor
                    ),
                footer
                    .widthAnchor
                    .constraint(
                        equalTo:
                            stack
                                .widthAnchor
                    )
            ])

        loadCurrentStatus()
    }

    private func permissionRow(
        symbol:
            String,
        title:
            String,
        detail:
            String,
        icon:
            NSImageView,
        status:
            NSTextField,
        button:
            NSButton,
        action:
            Selector
    ) -> NSView {
        icon.image =
            NSImage(
                systemSymbolName:
                    symbol,
                accessibilityDescription:
                    title
            )

        icon
            .symbolConfiguration =
                NSImage
                    .SymbolConfiguration(
                        pointSize:
                            19,
                        weight:
                            .medium
                    )

        icon
            .translatesAutoresizingMaskIntoConstraints =
                false

        let titleField =
            NSTextField(
                labelWithString:
                    title
            )

        titleField.font =
            .systemFont(
                ofSize:
                    15,
                weight:
                    .semibold
            )

        let detailField =
            NSTextField(
                wrappingLabelWithString:
                    detail
            )

        detailField
            .textColor =
                .secondaryLabelColor

        detailField.font =
            .systemFont(
                ofSize:
                    12
            )

        status.font =
            .systemFont(
                ofSize:
                    12,
                weight:
                    .medium
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

        textStack.spacing =
            3

        button.target =
            self

        button.action =
            action

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

        row.spacing =
            12

        NSLayoutConstraint
            .activate([
                icon
                    .widthAnchor
                    .constraint(
                        equalToConstant:
                            28
                    ),
                icon
                    .heightAnchor
                    .constraint(
                        equalToConstant:
                            28
                    ),
                button
                    .widthAnchor
                    .constraint(
                        greaterThanOrEqualToConstant:
                            82
                    )
            ])

        return row
    }

    private func separator()
        -> NSView {
        let box =
            NSBox()

        box.boxType =
            .separator

        return box
    }

    private func loadCurrentStatus() {
        let screenAllowed =
            CGPreflightScreenCaptureAccess()

        let accessibilityAllowed =
            AXIsProcessTrusted()

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

        footerStatus
            .stringValue =
                "Approve both permissions, then click Check Permissions. "
                + "If macOS asks you to reopen the app, reopen it."
    }

    func beginApprovalRequests() {
        footerStatus
            .stringValue =
                "Previous approvals were cleared. Requesting fresh permissions…"

        DispatchQueue
            .main
            .asyncAfter(
                deadline:
                    .now()
                    + 0.25
            ) {
                [weak self] in

                guard
                    let self
                else {
                    return
                }

                if !CGPreflightScreenCaptureAccess() {
                    _ =
                        CGRequestScreenCaptureAccess()
                }

                if !AXIsProcessTrusted() {
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
                }

                self
                    .loadCurrentStatus()
            }
    }

    private func refresh()
        async {
        guard
            !refreshInProgress
        else {
            return
        }

        refreshInProgress =
            true

        resetButton
            .isEnabled =
                false

        refreshButton
            .isEnabled =
                false

        screenStatus
            .stringValue =
                "Verifying…"

        accessibilityStatus
            .stringValue =
                "Checking…"

        async let screenCheck =
            verifyScreenCaptureCapability()

        let accessibilityAllowed =
            AXIsProcessTrusted()

        let screenAllowed =
            await screenCheck

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

        resetButton
            .isEnabled =
                true

        refreshButton
            .isEnabled =
                true

        if screenVerified
            && accessibilityVerified {
            footerStatus
                .stringValue =
                    "Verified. Opening Asympta Breathe…"

            footerStatus
                .textColor =
                    .systemGreen

            guard
                !didDeliverReady
            else {
                return
            }

            didDeliverReady =
                true

            pollTimer?
                .invalidate()

            pollTimer =
                nil

            DispatchQueue
                .main
                .asyncAfter(
                    deadline:
                        .now()
                        + 0.25
                ) {
                    [weak self]
                    in

                    guard
                        let self
                    else {
                        return
                    }

                    self
                        .onReady?(
                            self
                                .screenVerified,
                            self
                                .accessibilityVerified
                        )
                }
        } else {
            footerStatus
                .stringValue =
                    "Not fully verified yet. Approve the missing permission, then click Check Permissions."

            footerStatus
                .textColor =
                    .secondaryLabelColor
        }
    }

    private func updatePermission(
        allowed:
            Bool,
        icon:
            NSImageView,
        status:
            NSTextField,
        button:
            NSButton
    ) {
        if allowed {
            icon
                .contentTintColor =
                    .systemGreen

            status
                .stringValue =
                    "Verified"

            status
                .textColor =
                    .systemGreen

            button.title =
                "Allowed"

            button
                .isEnabled =
                    false
        } else {
            icon
                .contentTintColor =
                    .secondaryLabelColor

            status
                .stringValue =
                    "Not verified"

            status
                .textColor =
                    .secondaryLabelColor

            button.title =
                "Allow"

            button
                .isEnabled =
                    true
        }
    }

    @objc
    private func refreshNow() {
        Task {
            [weak self]
            in

            await self?
                .refresh()
        }
    }

    @objc
    private func resetAndReapprove() {
        let alert =
            NSAlert()

        alert.messageText =
            "Reset permissions?"

        alert
            .informativeText =
                "This removes Asympta Breathe's current Screen Recording and Accessibility approvals, then asks macOS for both again."

        alert.alertStyle =
            .warning

        alert
            .addButton(
                withTitle:
                    "Reset & Re-Approve"
            )

        alert
            .addButton(
                withTitle:
                    "Cancel"
            )

        guard
            alert.runModal()
                == .alertFirstButtonReturn
        else {
            return
        }

        pollTimer?
            .invalidate()

        pollTimer =
            nil

        didDeliverReady =
            false

        screenVerified =
            false

        accessibilityVerified =
            false

        footerStatus
            .stringValue =
                "Removing existing approvals…"

        footerStatus
            .textColor =
                .secondaryLabelColor

        let succeeded =
            resetAsymptaPermissions()

        if !succeeded {
            footerStatus
                .stringValue =
                    "macOS could not reset one or more approvals. Remove Asympta Breathe manually in Privacy & Security, then press Refresh Permissions."

            footerStatus
                .textColor =
                    .systemRed

            return
        }

        screenStatus
            .stringValue =
                "Reset — approval required"

        accessibilityStatus
            .stringValue =
                "Reset — approval required"

        footerStatus
            .stringValue =
                "Reset complete. Approve both permissions again."


        DispatchQueue
            .main
            .asyncAfter(
                deadline:
                    .now()
                    + 0.30
            ) {
                [weak self]
                in

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

                Task {
                    @MainActor in

                    await self
                        .refresh()
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

        screenStatus
            .stringValue =
                "Requested — click Check Permissions or reopen the app"
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

        accessibilityStatus
            .stringValue =
                "Requested — click Check Permissions or reopen the app"
    }

    private func openPrivacyPane(
        _ anchor:
            String
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

        NSWorkspace.shared
            .open(
                url
            )
    }

    @objc
    private func quitApp() {
        NSApp
            .terminate(
                nil
            )
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

    private var preparationTask:
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

    private var enabled:
        Bool {
        get {
            if UserDefaults
                .standard
                .object(
                    forKey:
                        "enabled"
                ) == nil {
                return true
            }

            return
                UserDefaults
                    .standard
                    .bool(
                        forKey:
                            "enabled"
                    )
        }

        set {
            UserDefaults
                .standard
                .set(
                    newValue,
                    forKey:
                        "enabled"
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
                UserDefaults
                    .standard
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
            UserDefaults
                .standard
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
                UserDefaults
                    .standard
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
            UserDefaults
                .standard
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
        NSApp
            .setActivationPolicy(
                .regular
            )

        Task {
            @MainActor in

            let accessibility =
                AXIsProcessTrusted()

            let screenPreflight =
                CGPreflightScreenCaptureAccess()

            let screenVerified:
                Bool

            if screenPreflight {
                screenVerified =
                    await verifyScreenCaptureCapability()
            } else {
                screenVerified =
                    false
            }

            if screenVerified
                && accessibility {
                UserDefaults
                    .standard
                    .removeObject(
                        forKey:
                            permissionResetPendingKey
                    )

                enterMainMode(
                    screenVerified:
                        true,
                    accessibilityVerified:
                        true
                )

                return
            }

            let resetAlreadyPerformed =
                UserDefaults
                    .standard
                    .bool(
                        forKey:
                            permissionResetPendingKey
                    )

            var shouldRequest =
                false

            if !resetAlreadyPerformed {
                _ =
                    resetAsymptaPermissions()

                UserDefaults
                    .standard
                    .set(
                        true,
                        forKey:
                            permissionResetPendingKey
                    )

                shouldRequest =
                    true
            }

            showPermissionGate(
                autoRequest:
                    shouldRequest
            )
        }
    }

    func applicationWillTerminate(
        _ notification:
            Notification
    ) {
        tickTimer?
            .invalidate()

        preparationTask?
            .cancel()

        permissionGate?
            .stop()

        breatheInImmediately()
    }

    private func showPermissionGate(
        autoRequest:
            Bool = false
    ) {
        if permissionGate != nil {
            permissionGate?
                .showWindow(nil)

            if autoRequest {
                permissionGate?
                    .beginApprovalRequests()
            }

            return
        }

        preparationTask?
            .cancel()

        preparationTask =
            nil

        breatheInImmediately()

        tickTimer?
            .invalidate()

        tickTimer =
            nil

        if let statusItem {
            NSStatusBar
                .system
                .removeStatusItem(
                    statusItem
                )

            self.statusItem =
                nil
        }

        mainStarted =
            false

        NSApp
            .setActivationPolicy(
                .regular
            )

        let gate =
            PermissionGateController()

        gate.onReady = {
            [weak self,
             weak gate]
            screenVerified,
            accessibilityVerified
            in

            Task {
                @MainActor in

                guard
                    let self
                else {
                    return
                }

                gate?
                    .stop()

                if self
                    .permissionGate
                    === gate {
                    self
                        .permissionGate =
                            nil
                }

                UserDefaults
                    .standard
                    .removeObject(
                        forKey:
                            permissionResetPendingKey
                    )

                self
                    .enterMainMode(
                        screenVerified:
                            screenVerified,
                        accessibilityVerified:
                            accessibilityVerified
                    )
            }
        }

        permissionGate =
            gate

        gate
            .showWindow(
                nil
            )

        gate
            .window?
            .makeKeyAndOrderFront(
                nil
            )

        _ =
            NSRunningApplication
                .current
                .activate(
                    options: []
                )

        if autoRequest {
            gate
                .beginApprovalRequests()
        }
    }

    private func enterMainMode(
        screenVerified:
            Bool,
        accessibilityVerified:
            Bool
    ) {
        screenPermission =
            screenVerified

        accessibilityPermission =
            accessibilityVerified

        guard
            screenPermission,
            accessibilityPermission
        else {
            showPermissionGate()
            return
        }

        permissionGate?
            .stop()

        permissionGate =
            nil

        NSApp
            .setActivationPolicy(
                .accessory
            )

        if statusItem == nil {
            buildStatusItem()
        }

        if tickTimer == nil {
            tickTimer =
                Timer
                    .scheduledTimer(
                        withTimeInterval:
                            0.12,
                        repeats:
                            true
                    ) {
                        [weak self]
                        _ in

                        Task {
                            @MainActor in

                            self?
                                .tick()
                        }
                    }
        }

        mainStarted =
            true

        rebuildMenu()
    }

    private func buildStatusItem() {
        statusItem =
            NSStatusBar
                .system
                .statusItem(
                    withLength:
                        NSStatusItem
                            .squareLength
                )

        if let button =
            statusItem
                .button {
            let image =
                NSImage(
                    systemSymbolName:
                        "circle.lefthalf.filled",
                    accessibilityDescription:
                        "Asympta Breathe"
                )

            image?
                .isTemplate =
                    true

            button.image =
                image

            button.toolTip =
                "Asympta Breathe"
        }

        rebuildMenu()
    }

    private func refreshPermissions() {
        let screen =
            CGPreflightScreenCaptureAccess()

        let accessibility =
            AXIsProcessTrusted()

        if screen {
            screenPermission =
                true
        }

        accessibilityPermission =
            accessibility

        if mainStarted
            && !accessibilityPermission {
            showPermissionGate(
                autoRequest:
                    false
            )
        }
    }

    private func rebuildMenu() {
        guard
            statusItem != nil
        else {
            return
        }

        let menu =
            NSMenu()

        let title =
            NSMenuItem(
                title:
                    "Asympta Breathe",
                action:
                    nil,
                keyEquivalent:
                    ""
            )

        title.isEnabled =
            false

        menu.addItem(
            title
        )

        let version =
            Bundle
                .main
                .object(
                    forInfoDictionaryKey:
                        "CFBundleShortVersionString"
                )
            as? String
            ?? "—"

        let versionItem =
            NSMenuItem(
                title:
                    "Version \(version)",
                action:
                    nil,
                keyEquivalent:
                    ""
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
                ? "1 app resting · click it to return"
                : "\(remaining) apps resting · click one to return"
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
                action:
                    nil,
                keyEquivalent:
                    ""
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
                title:
                    "Enabled",
                action:
                    #selector(
                        toggleEnabled
                    ),
                keyEquivalent:
                    ""
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
                keyEquivalent:
                    ""
            )

        breathe.target =
            self

        breathe.isEnabled =
            screenPermission
            && accessibilityPermission
            && session == nil
            && preparationTask == nil
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
                    keyEquivalent:
                        ""
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
                    "Resting content: 10%",
                action:
                    nil,
                keyEquivalent:
                    ""
            )

        resting.isEnabled =
            false

        menu.addItem(
            resting
        )

        let reset =
            NSMenuItem(
                title:
                    "Reset & Re-Approve Permissions…",
                action:
                    #selector(
                        resetPermissionsFromMenu
                    ),
                keyEquivalent:
                    ""
            )

        reset.target =
            self

        menu.addItem(
            reset
        )

        menu.addItem(
            .separator()
        )

        let activityHint =
            NSMenuItem(
                title:
                    "Before fade: mouse, scroll and typing count as active",
                action:
                    nil,
                keyEquivalent:
                    ""
            )

        activityHint.isEnabled =
            false

        menu.addItem(
            activityHint
        )

        let wakeHint =
            NSMenuItem(
                title:
                    "After fade: only clicking a faded app restores that app",
                action:
                    nil,
                keyEquivalent:
                    ""
            )

        wakeHint.isEnabled =
            false

        menu.addItem(
            wakeHint
        )

        let typingHint =
            NSMenuItem(
                title:
                    "Focused typing remains live and fully visible while resting",
                action:
                    nil,
                keyEquivalent:
                    ""
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

        self.menu =
            menu

        statusItem.menu =
            menu
    }

    private func makeValueMenu(
        title:
            String,
        current:
            Double,
        values:
            [Double],
        selector:
            Selector
    ) -> NSMenuItem {
        let parent =
            NSMenuItem(
                title:
                    "\(title): \(Int(current))s",
                action:
                    nil,
                keyEquivalent:
                    ""
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
                    keyEquivalent:
                        ""
                )

            item.target =
                self

            item
                .representedObject =
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
            preparationTask == nil
        else {
            return
        }

        let idle =
            secondsSinceRelevantInput()

        guard
            idle
            >= idleSeconds
        else {
            return
        }

        let targets =
            collectVisibleWindows()

        guard
            !targets
                .isEmpty
        else {
            return
        }

        startBreatheOut(
            targets:
                targets
        )
    }

    private func secondsSinceRelevantInput()
        -> Double {
        let types:
            [CGEventType] = [
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
                            eventType:
                                $0
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
            preparationTask == nil
        else {
            return
        }

        let targets =
            collectVisibleWindows()

        guard
            !targets
                .isEmpty
        else {
            return
        }

        startBreatheOut(
            targets:
                targets
        )
    }

    @objc
    private func breatheInNow() {
        breatheInAll()
    }

    @objc
    private func setIdleDelay(
        _ sender:
            NSMenuItem
    ) {
        if let value =
            sender
                .representedObject
            as? Double {
            idleSeconds =
                value
        }
    }

    @objc
    private func setFadeDuration(
        _ sender:
            NSMenuItem
    ) {
        if let value =
            sender
                .representedObject
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

        alert
            .informativeText =
                "This removes Asympta Breathe's current Screen Recording and Accessibility approvals, then returns to permission setup."

        alert.alertStyle =
            .warning

        alert
            .addButton(
                withTitle:
                    "Reset & Re-Approve"
            )

        alert
            .addButton(
                withTitle:
                    "Cancel"
            )

        guard
            alert.runModal()
                == .alertFirstButtonReturn
        else {
            return
        }

        preparationTask?
            .cancel()

        preparationTask =
            nil

        breatheInImmediately()

        _ =
            resetAsymptaPermissions()

        UserDefaults
            .standard
            .set(
                true,
                forKey:
                    permissionResetPendingKey
            )

        screenPermission =
            false

        accessibilityPermission =
            false

        mainStarted =
            false

        showPermissionGate(
            autoRequest:
                true
        )
    }

    @objc
    private func quitApp() {
        NSApp
            .terminate(
                nil
            )
    }

    private func startBreatheOut(
        targets:
            [VisibleWindowTarget]
    ) {
        guard
            session == nil,
            preparationTask == nil
        else {
            return
        }

        preparationTask =
            Task {
                [weak self]
                in

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

                    let scWindowByID =
                        Dictionary(
                            uniqueKeysWithValues:
                                shareable
                                    .windows
                                    .map {
                                        (
                                            $0.windowID,
                                            $0
                                        )
                                    }
                        )

                    let matched:
                        [
                            (
                                VisibleWindowTarget,
                                SCWindow
                            )
                        ] =
                            targets.compactMap {
                                target in

                                guard
                                    let window =
                                        scWindowByID[
                                            target
                                                .window
                                                .windowID
                                        ]
                                else {
                                    return nil
                                }

                                return (
                                    target,
                                    window
                                )
                            }

                    let excludedWindows =
                        matched.map {
                            $0.1
                        }

                    var prepared:
                        [PreparedOverlay] =
                            []

                    for (
                        target,
                        scWindow
                    ) in matched {
                        guard
                            let display =
                                self
                                    .display(
                                        for:
                                            target
                                                .window
                                                .cgFrame,
                                        from:
                                            shareable
                                                .displays
                                    )
                        else {
                            continue
                        }

                        guard
                            let background =
                                try await self
                                    .captureBackgroundPatch(
                                        target:
                                            target,
                                        display:
                                            display,
                                        excluding:
                                            excludedWindows
                                    )
                        else {
                            continue
                        }

                        let border =
                            try? await self
                                .captureBorderImage(
                                    target:
                                        target,
                                    scWindow:
                                        scWindow
                                )

                        prepared.append(
                            PreparedOverlay(
                                target:
                                    target,
                                scWindow:
                                    scWindow,
                                scale:
                                    self.backingScale(
                                        for:
                                            target
                                                .window
                                                .appKitFrame
                                    ),
                                backgroundImage:
                                    background,
                                borderImage:
                                    border
                            )
                        )
                    }

                    if Task
                        .isCancelled {
                        self
                            .preparationTask =
                                nil
                        return
                    }

                    self
                        .preparationTask =
                            nil

                    guard
                        !prepared
                            .isEmpty
                    else {
                        return
                    }

                    self
                        .presentBreatheOut(
                            prepared:
                                prepared
                        )
                } catch {
                    self
                        .preparationTask =
                            nil

                    if !CGPreflightScreenCaptureAccess() {
                        self
                            .screenPermission =
                                false

                        self
                            .showPermissionGate()
                    }
                }
            }
    }

    private func display(
        for windowFrame:
            CGRect,
        from displays:
            [SCDisplay]
    ) -> SCDisplay? {
        let center =
            CGPoint(
                x:
                    windowFrame
                        .midX,
                y:
                    windowFrame
                        .midY
            )

        if let containing =
            displays
                .first(
                    where: {
                        $0
                            .frame
                            .contains(
                                center
                            )
                    }
                ) {
            return containing
        }

        return
            displays
                .max(
                    by: {
                        lhs,
                        rhs in

                        lhs.frame
                            .intersection(
                                windowFrame
                            )
                            .width
                            * lhs.frame
                                .intersection(
                                    windowFrame
                                )
                                .height

                        <

                        rhs.frame
                            .intersection(
                                windowFrame
                            )
                            .width
                            * rhs.frame
                                .intersection(
                                    windowFrame
                                )
                                .height
                    }
                )
    }

    private func captureBackgroundPatch(
        target:
            VisibleWindowTarget,
        display:
            SCDisplay,
        excluding:
            [SCWindow]
    ) async throws
        -> CGImage? {
        let frame =
            target
                .window
                .cgFrame

        let intersection =
            frame
                .intersection(
                    display
                        .frame
                )

        guard
            !intersection
                .isNull,
            intersection.width
                >= frame.width
                - 1,
            intersection.height
                >= frame.height
                - 1
        else {
            // Avoid stretching a clipped image over a window spanning displays.
            return nil
        }

        let localRect =
            CGRect(
                x:
                    frame.minX
                    - display
                        .frame
                        .minX,
                y:
                    frame.minY
                    - display
                        .frame
                        .minY,
                width:
                    frame.width,
                height:
                    frame.height
            )

        let scale =
            backingScale(
                for:
                    target
                        .window
                        .appKitFrame
            )

        let filter =
            SCContentFilter(
                display:
                    display,
                excludingWindows:
                    excluding
            )

        let config =
            SCStreamConfiguration()

        config.sourceRect =
            localRect

        config.width =
            max(
                1,
                Int(
                    frame.width
                    * scale
                )
            )

        config.height =
            max(
                1,
                Int(
                    frame.height
                    * scale
                )
            )

        config.showsCursor =
            false

        config.queueDepth =
            1

        config.shouldBeOpaque =
            true

        config.ignoreShadowsDisplay =
            true

        return
            try await
                SCScreenshotManager
                    .captureImage(
                        contentFilter:
                            filter,
                        configuration:
                            config
                    )
    }

    private func captureBorderImage(
        target:
            VisibleWindowTarget,
        scWindow:
            SCWindow
    ) async throws
        -> CGImage? {
        let frame =
            target
                .window
                .cgFrame

        let scale =
            backingScale(
                for:
                    target
                        .window
                        .appKitFrame
            )

        let filter =
            SCContentFilter(
                desktopIndependentWindow:
                    scWindow
            )

        let config =
            SCStreamConfiguration()

        config.width =
            max(
                1,
                Int(
                    frame.width
                    * scale
                )
            )

        config.height =
            max(
                1,
                Int(
                    frame.height
                    * scale
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

        let image =
            try await
                SCScreenshotManager
                    .captureImage(
                        contentFilter:
                            filter,
                        configuration:
                            config
                    )

        return
            makeAlphaEdgeImage(
                from:
                    image,
                color:
                    stableAppColor(
                        bundleID:
                            target
                                .bundleID
                    )
            )
    }

    private func presentBreatheOut(
        prepared:
            [PreparedOverlay]
    ) {
        guard
            session == nil
        else {
            return
        }

        var overlays:
            [WindowOverlay] =
                []

        for item in prepared {
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

            // Critical: all real mouse interaction continues to the actual app.
            panel.ignoresMouseEvents =
                true

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

            let view =
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

            view.install(
                background:
                    item
                        .backgroundImage,
                border:
                    item
                        .borderImage
            )

            panel.contentView =
                view

            overlays.append(
                WindowOverlay(
                    target:
                        item
                            .target,
                    scWindow:
                        item
                            .scWindow,
                    scale:
                        item
                            .scale,
                    panel:
                        panel,
                    view:
                        view
                )
            )
        }

        let newSession =
            FadeSession(
                overlays:
                    overlays
            )

        session =
            newSession

        // Target list follows CGWindow front-to-back order.
        // Put back windows up first so our overlay z-order matches.
        for overlay
            in overlays
                .reversed() {
            overlay
                .panel
                .orderFrontRegardless()
        }

        installClickMonitor(
            session:
                newSession
        )

        startFocusTracking(
            session:
                newSession
        )

        let coverAlpha =
            1
            - restingOpacity

        NSAnimationContext
            .runAnimationGroup {
                context in

                context.duration =
                    fadeSeconds

                context.timingFunction =
                    CAMediaTimingFunction(
                        controlPoints:
                            0.37,
                        0,
                        0.63,
                        1
                    )

                context
                    .allowsImplicitAnimation =
                        true

                for overlay
                    in overlays {
                    overlay
                        .view
                        .coverImageView
                        .animator()
                        .alphaValue =
                            CGFloat(
                                coverAlpha
                            )

                    overlay
                        .view
                        .borderImageView
                        .animator()
                        .alphaValue =
                            0.72
                }
            }

        rebuildMenu()
    }

    private func installClickMonitor(
        session:
            FadeSession
    ) {
        session.clickMonitor =
            NSEvent
                .addGlobalMonitorForEvents(
                    matching: [
                        .leftMouseDown,
                        .rightMouseDown,
                        .otherMouseDown
                    ]
                ) {
                    [weak self,
                     weak session]
                    _ in

                    Task {
                        @MainActor in

                        guard
                            let self,
                            let session,
                            self
                                .session
                                === session
                        else {
                            return
                        }

                        let point =
                            NSEvent
                                .mouseLocation

                        guard
                            let overlay =
                                session
                                    .overlays
                                    .first(
                                        where: {
                                            session
                                                .remainingPIDs
                                                .contains(
                                                    $0
                                                        .target
                                                        .app
                                                        .processIdentifier
                                                )
                                            && $0
                                                .panel
                                                .frame
                                                .contains(
                                                    point
                                                )
                                        }
                                    )
                        else {
                            return
                        }

                        self
                            .breatheIn(
                                pid:
                                    overlay
                                        .target
                                        .app
                                        .processIdentifier
                            )
                    }
                }
    }

    private func startFocusTracking(
        session:
            FadeSession
    ) {
        Task {
            @MainActor in

            await updateTextReveal(
                session:
                    session
            )
        }

        session.focusTimer =
            Timer
                .scheduledTimer(
                    withTimeInterval:
                        0.08,
                    repeats:
                        true
                ) {
                    [weak self,
                     weak session]
                    _ in

                    Task {
                        @MainActor in

                        guard
                            let self,
                            let session,
                            self
                                .session
                                === session
                        else {
                            return
                        }

                        await self
                            .updateTextReveal(
                                session:
                                    session
                            )
                    }
                }
    }

    private func updateTextReveal(
        session:
            FadeSession
    ) async {
        guard
            !session
                .focusRefreshInFlight
        else {
            return
        }

        session
            .focusRefreshInFlight =
                true

        defer {
            session
                .focusRefreshInFlight =
                    false
        }

        guard
            let active =
                NSWorkspace
                    .shared
                    .frontmostApplication
        else {
            clearTextReveals(
                session:
                    session
            )
            return
        }

        let activePID =
            active
                .processIdentifier

        guard
            session
                .remainingPIDs
                .contains(
                    activePID
                ),
            let focused =
                focusedEditableElementFrame(
                    for:
                        activePID
                )
        else {
            clearTextReveals(
                session:
                    session
            )
            return
        }

        guard
            let overlay =
                session
                    .overlays
                    .first(
                        where: {
                            $0
                                .target
                                .app
                                .processIdentifier
                            == activePID

                            && $0
                                .target
                                .window
                                .cgFrame
                                .intersects(
                                    focused
                                )
                        }
                    )
        else {
            clearTextReveals(
                session:
                    session
            )
            return
        }

        let windowFrame =
            overlay
                .target
                .window
                .cgFrame

        let localX =
            focused.minX
            - windowFrame.minX

        let localTop =
            focused.minY
            - windowFrame.minY

        let localRectPoints =
            CGRect(
                x:
                    localX,
                y:
                    windowFrame.height
                    - localTop
                    - focused.height,
                width:
                    focused.width,
                height:
                    focused.height
            )

        let windowArea =
            max(
                1,
                windowFrame.width
                * windowFrame.height
            )

        let focusArea =
            localRectPoints.width
            * localRectPoints.height

        guard
            focusArea
            < windowArea
                * 0.45
        else {
            clearTextReveals(
                session:
                    session
            )
            return
        }

        let config =
            SCStreamConfiguration()

        config.width =
            max(
                1,
                Int(
                    windowFrame.width
                    * overlay.scale
                )
            )

        config.height =
            max(
                1,
                Int(
                    windowFrame.height
                    * overlay.scale
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
                        overlay
                            .scWindow
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
                    .contains(
                        activePID
                    )
            else {
                return
            }

            let pixelRect =
                CGRect(
                    x:
                        localRectPoints.minX
                        * overlay.scale,
                    y:
                        localRectPoints.minY
                        * overlay.scale,
                    width:
                        localRectPoints.width
                        * overlay.scale,
                    height:
                        localRectPoints.height
                        * overlay.scale
                )

            let textOnly =
                makeTextOnlyImage(
                    from:
                        image,
                    focusRect:
                        pixelRect
                )

            for item
                in session
                    .overlays {
                if item
                    === overlay {
                    item
                        .view
                        .setTextReveal(
                            textOnly
                        )
                } else {
                    item
                        .view
                        .setTextReveal(
                            nil
                        )
                }
            }
        } catch {
            // Keep the app breathed out. A transient text-layer capture failure
            // must never wake the app or block real keyboard input.
        }
    }

    private func clearTextReveals(
        session:
            FadeSession
    ) {
        for overlay
            in session
                .overlays {
            overlay
                .view
                .setTextReveal(
                    nil
                )
        }
    }

    private func focusedEditableElementFrame(
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
            )
                == AXUIElementGetTypeID()
        else {
            return nil
        }

        let focused =
            focusedRaw
            as! AXUIElement

        var roleRaw:
            CFTypeRef?

        guard
            AXUIElementCopyAttributeValue(
                focused,
                kAXRoleAttribute
                    as CFString,
                &roleRaw
            ) == .success,
            let role =
                roleRaw
                as? String
        else {
            return nil
        }

        let editableRoles:
            Set<String> = [
                kAXTextFieldRole
                    as String,
                kAXTextAreaRole
                    as String,
                kAXComboBoxRole
                    as String
            ]

        guard
            editableRoles
                .contains(
                    role
                )
        else {
            return nil
        }

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
            size.width
                > 2,
            size.height
                > 2
        else {
            return nil
        }

        return
            CGRect(
                origin:
                    position,
                size:
                    size
            )
    }

    private func breatheIn(
        pid:
            pid_t
    ) {
        guard
            let current =
                session,
            current
                .remainingPIDs
                .contains(
                    pid
                ),
            !current
                .inhalingPIDs
                .contains(
                    pid
                )
        else {
            return
        }

        let overlays =
            current
                .overlays
                .filter {
                    $0
                        .target
                        .app
                        .processIdentifier
                    == pid
                }

        guard
            !overlays
                .isEmpty
        else {
            return
        }

        current
            .inhalingPIDs
            .insert(
                pid
            )

        NSAnimationContext
            .runAnimationGroup {
                context in

                context.duration =
                    inhaleSeconds

                context
                    .timingFunction =
                        CAMediaTimingFunction(
                            controlPoints:
                                0.22,
                            1,
                            0.36,
                            1
                        )

                context
                    .allowsImplicitAnimation =
                        true

                for overlay
                    in overlays {
                    overlay
                        .view
                        .coverImageView
                        .animator()
                        .alphaValue =
                            0

                    overlay
                        .view
                        .textImageView
                        .animator()
                        .alphaValue =
                            0

                    overlay
                        .view
                        .borderImageView
                        .animator()
                        .alphaValue =
                            0
                }
            } completionHandler: {
                [weak self,
                 weak current]
                in

                Task {
                    @MainActor in

                    guard
                        let self,
                        let current,
                        self
                            .session
                            === current
                    else {
                        return
                    }

                    for overlay
                        in overlays {
                        overlay
                            .panel
                            .orderOut(
                                nil
                            )

                        overlay
                            .panel
                            .close()
                    }

                    current
                        .inhalingPIDs
                        .remove(
                            pid
                        )

                    current
                        .restoredPIDs
                        .insert(
                            pid
                        )

                    if current
                        .remainingPIDs
                        .isEmpty {
                        current
                            .cleanupMonitors()

                        self
                            .session =
                                nil
                    }

                    self
                        .rebuildMenu()
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

        for pid
            in pids {
            breatheIn(
                pid:
                    pid
            )
        }
    }

    private func breatheInImmediately() {
        preparationTask?
            .cancel()

        preparationTask =
            nil

        guard
            let current =
                session
        else {
            return
        }

        current
            .cleanupMonitors()

        for overlay
            in current
                .overlays {
            overlay
                .panel
                .orderOut(
                    nil
                )

            overlay
                .panel
                .close()
        }

        session =
            nil

        rebuildMenu()
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

        let ignoredBundleIDs:
            Set<String> = [
                "com.apple.dock",
                "com.apple.systemuiserver",
                "com.apple.controlcenter",
                "com.apple.WindowManager",
                "com.apple.notificationcenterui"
            ]

        var targets:
            [VisibleWindowTarget] =
                []

        for info
            in list {
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
                pid
                    != ownPID,

                let layer =
                    (
                        info[
                            kCGWindowLayer
                                as String
                        ]
                        as? NSNumber
                    )?
                    .intValue,
                layer
                    == 0,

                let alpha =
                    (
                        info[
                            kCGWindowAlpha
                                as String
                        ]
                        as? NSNumber
                    )?
                    .doubleValue,
                alpha
                    > 0.02,

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
                    >= 16,
                cgFrame.height
                    >= 16,

                let app =
                    NSRunningApplication(
                        processIdentifier:
                            pid
                    ),

                !app.isTerminated,
                app
                    .activationPolicy
                    != .prohibited
            else {
                continue
            }

            let bundleID =
                app
                    .bundleIdentifier
                ?? "pid:\(pid)"

            guard
                bundleID
                    != appBundleID,
                !ignoredBundleIDs
                    .contains(
                        bundleID
                    )
            else {
                continue
            }

            targets.append(
                VisibleWindowTarget(
                    app:
                        app,
                    appName:
                        app
                            .localizedName
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

    private func appKitFrame(
        fromCGWindowFrame frame:
            CGRect
    ) -> CGRect {
        let mainHeight =
            CGDisplayBounds(
                CGMainDisplayID()
            )
            .height

        return
            CGRect(
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
            NSScreen
                .screens
                .first(
                    where: {
                        $0
                            .frame
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
            NSScreen
                .main?
                .backingScaleFactor
            ?? 2
    }
}

@main
struct AsymptaBreatheMain {
    @MainActor
    static func main() {
        let app =
            NSApplication
                .shared

        let delegate =
            AppDelegate()

        app.delegate =
            delegate

        app.run()

        _ =
            delegate
    }
}
