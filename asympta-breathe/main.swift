import AppKit
import ScreenCaptureKit
import CoreGraphics
import QuartzCore
import ApplicationServices
import CoreImage

private let appBundleID = "com.asympta.breathe"
private let permissionResetPendingKey = "permissionResetPending"
private let lastPermissionResetVersionKey = "lastPermissionResetVersion"
private let didShowWelcomeKey = "didShowWelcomeAfterPermissions"

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
    let contentImage: CGImage
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

    let contentImageView =
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
                contentImageView,
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

        // Back layer is always present. The front app-content layer
        // breathes between resting opacity and full opacity.
        coverImageView
            .alphaValue =
                1

        contentImageView
            .alphaValue =
                1

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
        content:
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

        contentImageView.image =
            NSImage(
                cgImage:
                    content,
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

    func setContentImage(
        _ image:
            CGImage
    ) {
        contentImageView.image =
            NSImage(
                cgImage:
                    image,
                size:
                    bounds.size
            )
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

    func setOcclusionMask(
        windowFrame:
            CGRect,
        frontWindowFrames:
            [CGRect]
    ) {
        let path =
            CGMutablePath()

        path.addRect(
            bounds
        )

        for frontFrame
            in frontWindowFrames {
            let overlap =
                windowFrame
                    .intersection(
                        frontFrame
                    )

            guard
                !overlap.isNull,
                overlap.width > 0,
                overlap.height > 0
            else {
                continue
            }

            let local =
                CGRect(
                    x:
                        overlap.minX
                        - windowFrame.minX,
                    y:
                        overlap.minY
                        - windowFrame.minY,
                    width:
                        overlap.width,
                    height:
                        overlap.height
                )

            path.addRect(
                local
            )
        }

        let mask =
            CAShapeLayer()

        mask.frame =
            bounds

        mask.path =
            path

        mask.fillRule =
            .evenOdd

        mask.fillColor =
            NSColor.white
                .cgColor

        layer?.mask =
            mask
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

    var hoverTimer:
        Timer?

    var hoveredWindowID:
        CGWindowID?

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

        hoverTimer?
            .invalidate()

        hoverTimer =
            nil

        hoveredWindowID =
            nil
    }
}

@MainActor
private final class WelcomeWindowController:
    NSWindowController {

    var onDone:
        (() -> Void)?

    init() {
        let window =
            NSWindow(
                contentRect:
                    NSRect(
                        x: 0,
                        y: 0,
                        width: 540,
                        height: 360
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

    func stop() {
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

        let iconView =
            NSImageView()

        iconView.image =
            NSApp
                .applicationIconImage

        iconView
            .imageScaling =
                .scaleProportionallyUpOrDown

        iconView
            .translatesAutoresizingMaskIntoConstraints =
                false

        let eyebrow =
            NSTextField(
                labelWithString:
                    "WELCOME"
            )

        eyebrow.font =
            .systemFont(
                ofSize:
                    12,
                weight:
                    .semibold
            )

        eyebrow
            .textColor =
                .secondaryLabelColor

        let title =
            NSTextField(
                labelWithString:
                    "Welcome to Asympta Breathe"
            )

        title.font =
            .systemFont(
                ofSize:
                    27,
                weight:
                    .semibold
            )

        let body =
            NSTextField(
                wrappingLabelWithString:
                    "Enjoy a calmer desktop. When you pause, your open windows breathe out. "
                    + "Move the pointer over a resting window to preview it more clearly, "
                    + "then click the app you want to bring back."
            )

        body.font =
            .systemFont(
                ofSize:
                    14
            )

        body
            .textColor =
                .secondaryLabelColor

        let hint =
            NSTextField(
                wrappingLabelWithString:
                    "Resting opacity and all three timing phases are adjustable from the menu bar."
            )

        hint.font =
            .systemFont(
                ofSize:
                    12,
                weight:
                    .medium
            )

        hint
            .textColor =
                .secondaryLabelColor

        let startButton =
            NSButton(
                title:
                    "Enjoy Asympta Breathe",
                target:
                    self,
                action:
                    #selector(
                        finishWelcome
                    )
            )

        startButton
            .bezelStyle =
                .rounded

        startButton
            .controlSize =
                .large

        startButton
            .keyEquivalent =
                "\r"

        let stack =
            NSStackView(
                views: [
                    eyebrow,
                    title,
                    body,
                    hint,
                    NSView(),
                    startButton
                ]
            )

        stack.orientation =
            .vertical

        stack.alignment =
            .leading

        stack.spacing =
            14

        stack
            .translatesAutoresizingMaskIntoConstraints =
                false

        contentView
            .addSubview(
                iconView
            )

        contentView
            .addSubview(
                stack
            )

        NSLayoutConstraint
            .activate([
                iconView
                    .leadingAnchor
                    .constraint(
                        equalTo:
                            contentView
                                .leadingAnchor,
                        constant:
                            30
                    ),
                iconView
                    .topAnchor
                    .constraint(
                        equalTo:
                            contentView
                                .topAnchor,
                        constant:
                            32
                    ),
                iconView
                    .widthAnchor
                    .constraint(
                        equalToConstant:
                            70
                    ),
                iconView
                    .heightAnchor
                    .constraint(
                        equalToConstant:
                            70
                    ),
                stack
                    .leadingAnchor
                    .constraint(
                        equalTo:
                            iconView
                                .trailingAnchor,
                        constant:
                            22
                    ),
                stack
                    .trailingAnchor
                    .constraint(
                        equalTo:
                            contentView
                                .trailingAnchor,
                        constant:
                            -30
                    ),
                stack
                    .topAnchor
                    .constraint(
                        equalTo:
                            contentView
                                .topAnchor,
                        constant:
                            32
                    ),
                stack
                    .bottomAnchor
                    .constraint(
                        equalTo:
                            contentView
                                .bottomAnchor,
                        constant:
                            -28
                    ),
                body
                    .widthAnchor
                    .constraint(
                        equalTo:
                            stack
                                .widthAnchor
                    ),
                hint
                    .widthAnchor
                    .constraint(
                        equalTo:
                            stack
                                .widthAnchor
                    ),
                startButton
                    .widthAnchor
                    .constraint(
                        greaterThanOrEqualToConstant:
                            205
                    )
            ])
    }

    @objc
    private func finishWelcome() {
        onDone?()
    }
}

private enum PermissionStep:
    Equatable {
    case screenRecording
    case accessibility
}

@MainActor
private final class PermissionGateController:
    NSWindowController {

    let step:
        PermissionStep

    var onPermissionStateMayHaveChanged:
        (() -> Void)?

    private let stepLabel =
        NSTextField(
            labelWithString:
                ""
        )

    private let titleLabel =
        NSTextField(
            labelWithString:
                ""
        )

    private let bodyLabel =
        NSTextField(
            wrappingLabelWithString:
                ""
        )

    private let statusLabel =
        NSTextField(
            wrappingLabelWithString:
                ""
        )

    private let approveButton =
        NSButton(
            title:
                "Approve",
            target:
                nil,
            action:
                nil
        )

    private var didRequestNativePrompt =
        false

    private var activationObserver:
        NSObjectProtocol?

    init(
        step:
            PermissionStep
    ) {
        self.step =
            step

        let window =
            NSWindow(
                contentRect:
                    NSRect(
                        x: 0,
                        y: 0,
                        width: 520,
                        height: 330
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
        installActivationObserver()
    }

    required init?(
        coder:
            NSCoder
    ) {
        fatalError(
            "init(coder:) has not been implemented"
        )
    }

    func stop() {
        removeActivationObserver()
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

        stepLabel.font =
            .systemFont(
                ofSize:
                    12,
                weight:
                    .semibold
            )

        stepLabel
            .textColor =
                .secondaryLabelColor

        titleLabel.font =
            .systemFont(
                ofSize:
                    26,
                weight:
                    .semibold
            )

        bodyLabel.font =
            .systemFont(
                ofSize:
                    14
            )

        bodyLabel
            .textColor =
                .secondaryLabelColor

        statusLabel.font =
            .systemFont(
                ofSize:
                    12,
                weight:
                    .medium
            )

        statusLabel
            .textColor =
                .secondaryLabelColor

        approveButton.target =
            self

        approveButton.action =
            #selector(
                approveCurrentStep
            )

        approveButton
            .bezelStyle =
                .rounded

        approveButton
            .controlSize =
                .large

        approveButton
            .keyEquivalent =
                "\r"

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

        quit
            .bezelStyle =
                .rounded

        let buttonRow =
            NSStackView(
                views: [
                    approveButton,
                    NSView(),
                    quit
                ]
            )

        buttonRow.orientation =
            .horizontal

        buttonRow.alignment =
            .centerY

        let stack =
            NSStackView(
                views: [
                    stepLabel,
                    titleLabel,
                    bodyLabel,
                    statusLabel,
                    NSView(),
                    buttonRow
                ]
            )

        stack.orientation =
            .vertical

        stack.alignment =
            .leading

        stack.spacing =
            14

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
                            30
                    ),
                stack
                    .trailingAnchor
                    .constraint(
                        equalTo:
                            contentView
                                .trailingAnchor,
                        constant:
                            -30
                    ),
                stack
                    .topAnchor
                    .constraint(
                        equalTo:
                            contentView
                                .topAnchor,
                        constant:
                            28
                    ),
                stack
                    .bottomAnchor
                    .constraint(
                        equalTo:
                            contentView
                                .bottomAnchor,
                        constant:
                            -24
                    ),
                bodyLabel
                    .widthAnchor
                    .constraint(
                        equalTo:
                            stack
                                .widthAnchor
                    ),
                statusLabel
                    .widthAnchor
                    .constraint(
                        equalTo:
                            stack
                                .widthAnchor
                    ),
                buttonRow
                    .widthAnchor
                    .constraint(
                        equalTo:
                            stack
                                .widthAnchor
                    ),
                approveButton
                    .widthAnchor
                    .constraint(
                        greaterThanOrEqualToConstant:
                            220
                    )
            ])

        renderStep()
    }

    private func renderStep() {
        switch step {
        case .screenRecording:
            stepLabel
                .stringValue =
                    "STEP 1 OF 2"

            titleLabel
                .stringValue =
                    "Allow Screen Recording"

            bodyLabel
                .stringValue =
                    "Breathe needs Screen Recording to reproduce the desktop behind each app. "
                    + "Click Approve once. macOS will register Asympta Breathe and show its Screen Recording permission dialog. "
                    + "Choose Open System Settings, enable the app, then reopen it if macOS asks."

            statusLabel
                .stringValue =
                    "Waiting for Screen Recording approval."

            approveButton.title =
                "Approve Screen Recording"

        case .accessibility:
            stepLabel
                .stringValue =
                    "STEP 2 OF 2"

            titleLabel
                .stringValue =
                    "Allow Accessibility"

            bodyLabel
                .stringValue =
                    "Accessibility lets Breathe identify the focused text field and preserve live typing. "
                    + "After Screen Recording is ready, click Approve once. macOS will register Asympta Breathe under Accessibility. "
                    + "Choose Open System Settings, then enable the app."

            statusLabel
                .stringValue =
                    "Screen Recording is ready. One final approval."

            approveButton.title =
                "Approve Accessibility"
        }
    }

    private func installActivationObserver() {
        activationObserver =
            NotificationCenter
                .default
                .addObserver(
                    forName:
                        NSApplication
                            .didBecomeActiveNotification,
                    object:
                        NSApp,
                    queue:
                        .main
                ) {
                    [weak self]
                    _ in

                    Task {
                        @MainActor in

                        self?
                            .onPermissionStateMayHaveChanged?()
                    }
                }
    }

    private func removeActivationObserver() {
        if let activationObserver {
            NotificationCenter
                .default
                .removeObserver(
                    activationObserver
                )

            self.activationObserver =
                nil
        }
    }

    @objc
    private func approveCurrentStep() {
        approveButton
            .isEnabled =
                false

        if didRequestNativePrompt {
            switch step {
            case .screenRecording:
                openPrivacyPane(
                    "Privacy_ScreenCapture"
                )

            case .accessibility:
                openPrivacyPane(
                    "Privacy_Accessibility"
                )
            }

            approveButton
                .isEnabled =
                    true

            return
        }

        didRequestNativePrompt =
            true

        switch step {
        case .screenRecording:
            statusLabel
                .stringValue =
                    "macOS is registering Asympta Breathe for Screen Recording. "
                    + "Choose Open System Settings in the macOS dialog, then enable the app."

            // This native request is required for macOS to register the app
            // in Privacy & Security → Screen Recording.
            let granted =
                CGRequestScreenCaptureAccess()

            if granted {
                onPermissionStateMayHaveChanged?()
                return
            }

            approveButton.title =
                "Open Screen Recording Settings"

        case .accessibility:
            statusLabel
                .stringValue =
                    "macOS is registering Asympta Breathe for Accessibility. "
                    + "Choose Open System Settings in the macOS dialog, then enable the app."

            // This native request is required for macOS to register the app
            // in Privacy & Security → Accessibility.
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

            if AXIsProcessTrusted() {
                onPermissionStateMayHaveChanged?()
                return
            }

            approveButton.title =
                "Open Accessibility Settings"
        }

        DispatchQueue
            .main
            .asyncAfter(
                deadline:
                    .now()
                    + 1.0
            ) {
                [weak self] in

                self?
                    .approveButton
                    .isEnabled =
                        true
            }
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

        NSWorkspace
            .shared
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

    private var welcomeController:
        WelcomeWindowController?

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

    private var inhaleSeconds:
        Double {
        get {
            let value =
                UserDefaults
                    .standard
                    .double(
                        forKey:
                            "inhaleSeconds"
                    )

            return
                value > 0
                ? min(
                    max(
                        value,
                        0.2
                    ),
                    10
                )
                : 1.8
        }

        set {
            UserDefaults
                .standard
                .set(
                    min(
                        max(
                            newValue,
                            0.2
                        ),
                        10
                    ),
                    forKey:
                        "inhaleSeconds"
                )

            rebuildMenu()
        }
    }

    private var restingOpacity:
        Double {
        get {
            guard
                UserDefaults
                    .standard
                    .object(
                        forKey:
                            "restingOpacity"
                    )
                != nil
            else {
                return 0.10
            }

            return
                min(
                    max(
                        UserDefaults
                            .standard
                            .double(
                                forKey:
                                    "restingOpacity"
                            ),
                        0.02
                    ),
                    0.80
                )
        }

        set {
            UserDefaults
                .standard
                .set(
                    min(
                        max(
                            newValue,
                            0.02
                        ),
                        0.80
                    ),
                    forKey:
                        "restingOpacity"
                )

            if let session {
                applyLayerOcclusion(
                    session:
                        session
                )

                for overlay
                    in session
                        .overlays {
                    let pid =
                        overlay
                            .target
                            .app
                            .processIdentifier

                    guard
                        session
                            .remainingPIDs
                            .contains(
                                pid
                            )
                    else {
                        continue
                    }

                    overlay
                        .view
                        .contentImageView
                        .alphaValue =
                            CGFloat(
                                restingOpacity
                            )
                }
            }

            rebuildMenu()
        }
    }

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

            await beginPermissionFlow()
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

        welcomeController?
            .stop()

        breatheInImmediately()
    }

    private func beginPermissionFlow() async {
        let defaults =
            UserDefaults.standard

        let currentVersion =
            Bundle.main
                .object(
                    forInfoDictionaryKey:
                        "CFBundleShortVersionString"
                ) as? String
            ?? "unknown"

        let lastResetVersion =
            defaults.string(
                forKey:
                    lastPermissionResetVersionKey
            )

        if lastResetVersion
            != currentVersion {
            // First launch of THIS app version:
            // clear both old TCC approvals exactly once.
            //
            // The version is recorded before opening System Settings so that
            // a macOS-requested reopen of the same build does not erase the
            // permission the user just granted.
            defaults.set(
                currentVersion,
                forKey:
                    lastPermissionResetVersionKey
            )

            defaults.set(
                true,
                forKey:
                    permissionResetPendingKey
            )

            _ =
                resetAsymptaPermissions()

            screenPermission =
                false

            accessibilityPermission =
                false

            showPermissionGate(
                step:
                    .screenRecording
            )

            return
        }

        // Same version being reopened: never reset again.
        // Preserve whatever the user approved and continue the sequence.
        await evaluatePermissionFlow()
    }

    private func evaluatePermissionFlow() async {
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

        let accessibilityVerified =
            AXIsProcessTrusted()

        if screenVerified
            && accessibilityVerified {
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

        if !screenVerified {
            showPermissionGate(
                step:
                    .screenRecording
            )

            return
        }

        showPermissionGate(
            step:
                .accessibility
        )
    }

    private func showPermissionGate(
        step:
            PermissionStep
    ) {
        if let existing =
            permissionGate {
            if existing.step
                == step {
                existing
                    .showWindow(
                        nil
                    )

                existing
                    .window?
                    .makeKeyAndOrderFront(
                        nil
                    )

                return
            }

            existing.stop()

            permissionGate =
                nil
        }

        preparationTask?
            .cancel()

        preparationTask =
            nil

        welcomeController?
            .stop()

        welcomeController =
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
            PermissionGateController(
                step:
                    step
            )

        gate
            .onPermissionStateMayHaveChanged = {
                [weak self] in

                Task {
                    @MainActor in

                    guard
                        let self
                    else {
                        return
                    }

                    await self
                        .evaluatePermissionFlow()
                }
            }

        permissionGate =
            gate

        gate.showWindow(
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
            Task {
                @MainActor in

                await evaluatePermissionFlow()
            }

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

        showWelcomeIfNeeded()
    }

    private func showWelcomeIfNeeded() {
        guard
            !UserDefaults
                .standard
                .bool(
                    forKey:
                        didShowWelcomeKey
                ),
            welcomeController
                == nil
        else {
            return
        }

        let welcome =
            WelcomeWindowController()

        welcome.onDone = {
            [weak self,
             weak welcome]
            in

            UserDefaults
                .standard
                .set(
                    true,
                    forKey:
                        didShowWelcomeKey
                )

            welcome?
                .stop()

            if self?
                .welcomeController
                === welcome {
                self?
                    .welcomeController =
                        nil
            }
        }

        welcomeController =
            welcome

        welcome
            .showWindow(
                nil
            )

        welcome
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

        screenPermission =
            screen

        accessibilityPermission =
            accessibility

        guard
            mainStarted
        else {
            return
        }

        if !screenPermission {
            showPermissionGate(
                step:
                    .screenRecording
            )
        } else if !accessibilityPermission {
            showPermissionGate(
                step:
                    .accessibility
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

        menu.addItem(
            makeValueMenu(
                title:
                    "Inhale duration",
                current:
                    inhaleSeconds,
                values: [
                    0.6,
                    1.2,
                    1.8,
                    3,
                    5
                ],
                selector:
                    #selector(
                        setInhaleDuration(
                            _:
                        )
                    )
            )
        )

        menu.addItem(
            makePercentMenu(
                title:
                    "Resting content",
                current:
                    restingOpacity,
                values: [
                    0.05,
                    0.10,
                    0.15,
                    0.20,
                    0.30,
                    0.40
                ],
                selector:
                    #selector(
                        setRestingOpacity(
                            _:
                        )
                    )
            )
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
                    current.rounded() == current
                    ? "\(title): \(Int(current))s"
                    : "\(title): \(String(format: "%.1f", current))s",
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
                        value.rounded() == value
                        ? "\(Int(value)) seconds"
                        : "\(String(format: "%.1f", value)) seconds",
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

    private func makePercentMenu(
        title:
            String,
        current:
            Double,
        values:
            [Double],
        selector:
            Selector
    ) -> NSMenuItem {
        let percent =
            Int(
                round(
                    current
                    * 100
                )
            )

        let parent =
            NSMenuItem(
                title:
                    "\(title): \(percent)%",
                action:
                    nil,
                keyEquivalent:
                    ""
            )

        let submenu =
            NSMenu()

        for value
            in values {
            let item =
                NSMenuItem(
                    title:
                        "\(Int(round(value * 100)))%",
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
    private func setInhaleDuration(
        _ sender:
            NSMenuItem
    ) {
        if let value =
            sender
                .representedObject
            as? Double {
            inhaleSeconds =
                value
        }
    }

    @objc
    private func setRestingOpacity(
        _ sender:
            NSMenuItem
    ) {
        if let value =
            sender
                .representedObject
            as? Double {
            restingOpacity =
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
                "This clears Asympta Breathe's Screen Recording and Accessibility approvals. "
                + "You will approve Screen Recording first, then Accessibility."

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
            step:
                .screenRecording
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

                        guard
                            let content =
                                try? await self
                                    .captureWindowImage(
                                        target:
                                            target,
                                        scWindow:
                                            scWindow
                                    )
                        else {
                            continue
                        }

                        let border =
                            makeAlphaEdgeImage(
                                from:
                                    content,
                                color:
                                    stableAppColor(
                                        bundleID:
                                            target
                                                .bundleID
                                    )
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
                                contentImage:
                                    content,
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
                            .showPermissionGate(
                                step:
                                    .screenRecording
                            )
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

    private func captureWindowImage(
        target:
            VisibleWindowTarget,
        scWindow:
            SCWindow
    ) async throws
        -> CGImage {
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
                content:
                    item
                        .contentImage,
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

        applyLayerOcclusion(
            session:
                newSession
        )

        installClickMonitor(
            session:
                newSession
        )

        startHoverTracking(
            session:
                newSession
        )

        startFocusTracking(
            session:
                newSession
        )

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
                        .contentImageView
                        .animator()
                        .alphaValue =
                            CGFloat(
                                restingOpacity
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

    private func applyLayerOcclusion(
        session:
            FadeSession
    ) {
        // Real CGWindow order is front-to-back. Each Breathe overlay gets a
        // layer mask that removes portions physically covered by windows above it.
        // This prevents a back overlay from painting over a front window.
        let realWindows =
            collectVisibleWindows()

        let indexByWindowID =
            Dictionary(
                uniqueKeysWithValues:
                    realWindows
                        .enumerated()
                        .map {
                            (
                                $0.element
                                    .window
                                    .windowID,
                                $0.offset
                            )
                        }
            )

        for overlay
            in session
                .overlays {
            guard
                let index =
                    indexByWindowID[
                        overlay
                            .target
                            .window
                            .windowID
                    ]
            else {
                continue
            }

            let frontFrames =
                realWindows
                    .prefix(
                        index
                    )
                    .map {
                        $0.window
                            .appKitFrame
                    }

            overlay
                .view
                .setOcclusionMask(
                    windowFrame:
                        overlay
                            .target
                            .window
                            .appKitFrame,
                    frontWindowFrames:
                        frontFrames
                )
        }
    }

    private func topmostRealAppPID(
        at appKitPoint:
            CGPoint
    ) -> pid_t? {
        let mainHeight =
            CGDisplayBounds(
                CGMainDisplayID()
            )
            .height

        let cgPoint =
            CGPoint(
                x:
                    appKitPoint.x,
                y:
                    mainHeight
                    - appKitPoint.y
            )

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
            return nil
        }

        let ownPID =
            ProcessInfo
                .processInfo
                .processIdentifier

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
                let bounds =
                    info[
                        kCGWindowBounds
                            as String
                    ]
                    as? NSDictionary,
                let frame =
                    CGRect(
                        dictionaryRepresentation:
                            bounds
                                as CFDictionary
                    ),
                frame
                    .contains(
                        cgPoint
                    )
            else {
                continue
            }

            return pid
        }

        return nil
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
                            let pid =
                                self
                                    .topmostRealAppPID(
                                        at:
                                            point
                                    ),
                            session
                                .remainingPIDs
                                .contains(
                                    pid
                                )
                        else {
                            return
                        }

                        self
                            .breatheIn(
                                pid:
                                    pid
                            )
                    }
                }
    }

    private func startHoverTracking(
        session:
            FadeSession
    ) {
        updateHoverPreview(
            session:
                session
        )

        session.hoverTimer =
            Timer
                .scheduledTimer(
                    withTimeInterval:
                        0.06,
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

                        self
                            .updateHoverPreview(
                                session:
                                    session
                            )
                    }
                }
    }

    private func updateHoverPreview(
        session:
            FadeSession
    ) {
        let point =
            NSEvent
                .mouseLocation

        let topPID =
            topmostRealAppPID(
                at:
                    point
            )

        let hovered =
            session
                .overlays
                .first(
                    where: {
                        guard
                            let topPID,
                            session
                                .remainingPIDs
                                .contains(
                                    topPID
                                )
                        else {
                            return false
                        }

                        return
                            $0
                                .target
                                .app
                                .processIdentifier
                            == topPID

                            && $0
                                .panel
                                .frame
                                .contains(
                                    point
                                )
                    }
                )

        let newHoveredWindowID =
            hovered?
                .target
                .window
                .windowID

        guard
            newHoveredWindowID
            != session
                .hoveredWindowID
        else {
            return
        }

        session
            .hoveredWindowID =
                newHoveredWindowID

        let hoverContentOpacity =
            min(
                0.70,
                max(
                    0.30,
                    restingOpacity
                    + 0.20
                )
            )

        NSAnimationContext
            .runAnimationGroup {
                context in

                context.duration =
                    0.16

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
                    in session
                        .overlays {
                    let pid =
                        overlay
                            .target
                            .app
                            .processIdentifier

                    guard
                        session
                            .remainingPIDs
                            .contains(
                                pid
                            )
                    else {
                        continue
                    }

                    let isHovered =
                        overlay
                            .target
                            .window
                            .windowID
                        == newHoveredWindowID

                    overlay
                        .view
                        .contentImageView
                        .animator()
                        .alphaValue =
                            CGFloat(
                                isHovered
                                ? hoverContentOpacity
                                : restingOpacity
                            )

                    overlay
                        .view
                        .borderImageView
                        .animator()
                        .alphaValue =
                            isHovered
                            ? 0.96
                            : 0.72
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

            overlay
                .view
                .setContentImage(
                    image
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
                .isEmpty,
            let targetApp =
                overlays
                    .first?
                    .target
                    .app
        else {
            return
        }

        current
            .inhalingPIDs
            .insert(
                pid
            )

        if let hoveredID =
            current
                .hoveredWindowID,
           overlays
            .contains(
                where: {
                    $0
                        .target
                        .window
                        .windowID
                    == hoveredID
                }
            ) {
            current
                .hoveredWindowID =
                    nil
        }

        // Keep all still-resting overlays above their own apps, but below
        // the app the user just selected.
        for remainingOverlay
            in current
                .overlays {
            let remainingPID =
                remainingOverlay
                    .target
                    .app
                    .processIdentifier

            guard
                remainingPID
                    != pid,
                current
                    .remainingPIDs
                    .contains(
                        remainingPID
                    )
            else {
                continue
            }

            remainingOverlay
                .panel
                .level =
                    .normal

            remainingOverlay
                .panel
                .orderFrontRegardless()
        }

        // The selected overlay itself goes to the very front for the inhale
        // transition. Its real app is activated underneath it at the same time.
        for overlay
            in overlays {
            overlay
                .panel
                .level =
                    .screenSaver

            overlay
                .panel
                .orderFrontRegardless()

            // Selection no longer needs the resting outline.
            // Remove the border immediately. The front app-content layer now
            // breathes from resting opacity back to full opacity.
            overlay
                .view
                .borderImageView
                .alphaValue =
                    0
        }

        _ =
            targetApp
                .activate(
                    options: []
                )

        DispatchQueue
            .main
            .asyncAfter(
                deadline:
                    .now()
                    + 0.06
            ) {
                [weak self,
                 weak current]
                in

                guard
                    let self,
                    let current,
                    self
                        .session
                        === current
                else {
                    return
                }

                self
                    .applyLayerOcclusion(
                        session:
                            current
                    )
            }

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
                        .textImageView
                        .isHidden =
                            true

                    overlay
                        .view
                        .contentImageView
                        .animator()
                        .alphaValue =
                            1
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

                    // Reassert foreground ownership only after the selected
                    // overlay is gone. The user now sees the live app itself.
                    _ =
                        targetApp
                            .activate(
                                options: []
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
