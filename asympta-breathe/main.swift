import AppKit
import ScreenCaptureKit
import CoreGraphics
import QuartzCore
import ApplicationServices
import CoreImage
import CoreMedia
import CoreVideo

private let appBundleID = "com.asympta.breathe"
private let permissionResetPendingKey = "permissionResetPending"
private let lastPermissionResetVersionKey = "lastPermissionResetVersion"
private let didShowWelcomeKey = "didShowWelcomeAfterPermissions"

private enum AsymptaPalette {
    static let paper =
        NSColor(
            calibratedRed: 0.956,
            green: 0.949,
            blue: 0.925,
            alpha: 1
        )

    static let paperCool =
        NSColor(
            calibratedRed: 0.929,
            green: 0.938,
            blue: 0.949,
            alpha: 1
        )

    static let ink =
        NSColor(
            calibratedRed: 0.11,
            green: 0.16,
            blue: 0.23,
            alpha: 1
        )

    static let muted =
        NSColor(
            calibratedRed: 0.35,
            green: 0.42,
            blue: 0.50,
            alpha: 1
        )

    static let quietBlue =
        NSColor(
            calibratedRed: 0.337,
            green: 0.420,
            blue: 0.608,
            alpha: 1
        )

    static let quietBlueSoft =
        NSColor(
            calibratedRed: 0.337,
            green: 0.420,
            blue: 0.608,
            alpha: 0.14
        )

    static let card =
        NSColor(
            calibratedWhite: 1,
            alpha: 0.72
        )

    static let hairline =
        NSColor(
            calibratedWhite: 0.2,
            alpha: 0.08
        )
}


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

private enum ActivityKind {
    case pointer
    case click
    case scroll
    case keyboard
    case other
}

private let activityEventTapCallback:
    CGEventTapCallBack = {
        _,
        type,
        event,
        userInfo in

        guard
            let userInfo
        else {
            return
                Unmanaged
                    .passUnretained(
                        event
                    )
        }

        let monitor =
            Unmanaged<ActivityMonitor>
                .fromOpaque(
                    userInfo
                )
                .takeUnretainedValue()

        monitor.handle(
            type:
                type,
            event:
                event
        )

        return
            Unmanaged
                .passUnretained(
                    event
                )
    }

private final class ActivityMonitor {

    var onActivity:
        ((ActivityKind) -> Void)?

    private var eventTap:
        CFMachPort?

    private var runLoopSource:
        CFRunLoopSource?

    private var lastPointerLocation:
        CGPoint?

    private(set) var isRunning =
        false

    private let pointerJitterSquared:
        CGFloat =
            9

    func start() -> Bool {
        guard
            !isRunning
        else {
            return true
        }

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

        let mask =
            types.reduce(
                CGEventMask(
                    0
                )
            ) {
                partial,
                type in

                partial
                | (
                    CGEventMask(
                        1
                    )
                    << CGEventMask(
                        type
                            .rawValue
                    )
                )
            }

        guard
            let tap =
                CGEvent
                    .tapCreate(
                        tap:
                            .cgSessionEventTap,
                        place:
                            .tailAppendEventTap,
                        options:
                            .listenOnly,
                        eventsOfInterest:
                            mask,
                        callback:
                            activityEventTapCallback,
                        userInfo:
                            Unmanaged
                                .passUnretained(
                                    self
                                )
                                .toOpaque()
                    )
        else {
            return false
        }

        eventTap =
            tap

        let source =
            CFMachPortCreateRunLoopSource(
                kCFAllocatorDefault,
                tap,
                0
            )

        runLoopSource =
            source

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            source,
            .commonModes
        )

        CGEvent
            .tapEnable(
                tap:
                    tap,
                enable:
                    true
            )

        isRunning =
            true

        return true
    }

    func stop() {
        if let eventTap {
            CGEvent
                .tapEnable(
                    tap:
                        eventTap,
                    enable:
                        false
                )
        }

        if let runLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                runLoopSource,
                .commonModes
            )
        }

        eventTap =
            nil

        runLoopSource =
            nil

        isRunning =
            false
    }

    fileprivate func handle(
        type:
            CGEventType,
        event:
            CGEvent
    ) {
        if type
            == .tapDisabledByTimeout
            || type
            == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent
                    .tapEnable(
                        tap:
                            eventTap,
                        enable:
                            true
                    )
            }

            return
        }

        let kind:
            ActivityKind

        switch type {
        case .mouseMoved,
             .leftMouseDragged,
             .rightMouseDragged,
             .otherMouseDragged:
            let point =
                event.location

            if let last =
                lastPointerLocation {
                let dx =
                    point.x
                    - last.x

                let dy =
                    point.y
                    - last.y

                if dx * dx
                    + dy * dy
                    < pointerJitterSquared {
                    return
                }
            }

            lastPointerLocation =
                point

            kind =
                .pointer

        case .leftMouseDown,
             .rightMouseDown,
             .otherMouseDown:
            kind =
                .click

        case .scrollWheel:
            kind =
                .scroll

        case .keyDown,
             .flagsChanged:
            kind =
                .keyboard

        default:
            kind =
                .other
        }

        DispatchQueue
            .main
            .async {
                [weak self] in

                self?
                    .onActivity?(
                        kind
                    )
            }
    }
}

private final class LiveWindowStream:
    NSObject,
    SCStreamOutput {

    private let stream:
        SCStream

    private let sampleQueue =
        DispatchQueue(
            label:
                "com.asympta.breathe.live-window",
            qos:
                .userInteractive
        )

    private let onFrame:
        @MainActor (CGImage) -> Void

    private var stopped =
        false

    init(
        window:
            SCWindow,
        width:
            Int,
        height:
            Int,
        framesPerSecond:
            Int = 30,
        onFrame:
            @escaping @MainActor (CGImage) -> Void
    ) throws {
        self.onFrame =
            onFrame

        let filter =
            SCContentFilter(
                desktopIndependentWindow:
                    window
            )

        let config =
            SCStreamConfiguration()

        config.width =
            max(
                1,
                width
            )

        config.height =
            max(
                1,
                height
            )

        config.showsCursor =
            false

        config.queueDepth =
            2

        config.shouldBeOpaque =
            false

        config.ignoreShadowsSingleWindow =
            true

        config.minimumFrameInterval =
            CMTime(
                value:
                    1,
                timescale:
                    CMTimeScale(
                        max(
                            1,
                            framesPerSecond
                        )
                    )
            )

        self.stream =
            SCStream(
                filter:
                    filter,
                configuration:
                    config,
                delegate:
                    nil
            )

        super.init()

        try self.stream
            .addStreamOutput(
                self,
                type:
                    .screen,
                sampleHandlerQueue:
                    sampleQueue
            )
    }

    func start() {
        Task {
            [weak self] in

            guard
                let self,
                !self.stopped
            else {
                return
            }

            try? await self
                .stream
                .startCapture()
        }
    }

    func stop() {
        guard
            !stopped
        else {
            return
        }

        stopped =
            true

        Task {
            [stream] in

            try? await stream
                .stopCapture()
        }
    }

    func stream(
        _ stream:
            SCStream,
        didOutputSampleBuffer sampleBuffer:
            CMSampleBuffer,
        of outputType:
            SCStreamOutputType
    ) {
        guard
            outputType
                == .screen,
            sampleBuffer
                .isValid,
            CMSampleBufferDataIsReady(
                sampleBuffer
            ),
            let pixelBuffer =
                CMSampleBufferGetImageBuffer(
                    sampleBuffer
                )
        else {
            return
        }

        let image =
            CIImage(
                cvPixelBuffer:
                    pixelBuffer
            )

        guard
            let cgImage =
                ciContext
                    .createCGImage(
                        image,
                        from:
                            image.extent
                    )
        else {
            return
        }

        Task {
            @MainActor
            [weak self] in

            guard
                let self,
                !self.stopped
            else {
                return
            }

            self.onFrame(
                cgImage
            )
        }
    }
}

@MainActor
private final class WindowOverlay {
    let target: VisibleWindowTarget
    let scWindow: SCWindow
    let scale: CGFloat
    let panel: BreathPanel
    let view: BreathOverlayView

    var liveStream:
        LiveWindowStream?

    var textStyleFocusRect:
        CGRect?

    var textStyleColor:
        CIColor?

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

private func stableTextColor(
    from image:
        CGImage,
    focusRect:
        CGRect
) -> CIColor {
    let full =
        CIImage(
            cgImage:
                image
        )

    let clipped =
        focusRect
            .intersection(
                full.extent
            )

    guard
        !clipped.isNull,
        clipped.width > 2,
        clipped.height > 2
    else {
        return
            CIColor(
                red: 0.96,
                green: 0.96,
                blue: 0.96,
                alpha: 1
            )
    }

    let average =
        full
            .cropped(
                to:
                    clipped
            )
            .applyingFilter(
                "CIAreaAverage",
                parameters: [
                    kCIInputExtentKey:
                        CIVector(
                            cgRect:
                                clipped
                        )
                ]
            )

    var rgba =
        [UInt8](
            repeating:
                0,
            count:
                4
        )

    rgba
        .withUnsafeMutableBytes {
            buffer in

            guard
                let base =
                    buffer
                        .baseAddress
            else {
                return
            }

            ciContext
                .render(
                    average,
                    toBitmap:
                        base,
                    rowBytes:
                        4,
                    bounds:
                        CGRect(
                            x: 0,
                            y: 0,
                            width: 1,
                            height: 1
                        ),
                    format:
                        .RGBA8,
                    colorSpace:
                        CGColorSpaceCreateDeviceRGB()
                )
        }

    let r =
        Double(
            rgba[0]
        )
        / 255

    let g =
        Double(
            rgba[1]
        )
        / 255

    let b =
        Double(
            rgba[2]
        )
        / 255

    let luminance =
        0.2126 * r
        + 0.7152 * g
        + 0.0722 * b

    if luminance > 0.56 {
        return
            CIColor(
                red: 0.07,
                green: 0.07,
                blue: 0.07,
                alpha: 1
            )
    }

    return
        CIColor(
            red: 0.97,
            green: 0.97,
            blue: 0.97,
            alpha: 1
        )
}

private func makeTextOnlyImage(
    from image:
        CGImage,
    focusRect:
        CGRect,
    textColor:
        CIColor
) -> CGImage? {
    let full =
        CIImage(
            cgImage:
                image
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
                to:
                    clipped
            )

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
                    "inputIntensity":
                        2.45
                ]
            )
            .cropped(
                to:
                    clipped
            )

    let boosted =
        edges
            .applyingFilter(
                "CIColorControls",
                parameters: [
                    "inputSaturation":
                        0,
                    "inputBrightness":
                        -0.14,
                    "inputContrast":
                        4.0
                ]
            )
            .cropped(
                to:
                    clipped
            )

    let mask =
        boosted
            .applyingFilter(
                "CIMorphologyMaximum",
                parameters: [
                    "inputRadius":
                        1.25
                ]
            )
            .cropped(
                to:
                    clipped
            )

    let clearFocus =
        CIImage(
            color:
                .clear
        )
        .cropped(
            to:
                clipped
        )

    // Only shape/content changes on each refresh.
    // Color/style is frozen for the focused field until focus moves.
    let stableForeground =
        CIImage(
            color:
                textColor
        )
        .cropped(
            to:
                clipped
        )

    let revealed =
        stableForeground
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
                to:
                    clipped
            )

    let clearFull =
        CIImage(
            color:
                .clear
        )
        .cropped(
            to:
                full.extent
        )

    let composed =
        revealed
            .composited(
                over:
                    clearFull
            )

    return
        ciContext
            .createCGImage(
                composed,
                from:
                    full.extent
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

        for overlay
            in overlays {
            overlay
                .liveStream?
                .stop()

            overlay
                .liveStream =
                    nil
        }
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

private final class AsymptaPaperView:
    NSView {

    override func draw(
        _ dirtyRect:
            NSRect
    ) {
        super.draw(
            dirtyRect
        )

        NSGradient(
            starting:
                AsymptaPalette.paper,
            ending:
                AsymptaPalette.paperCool
        )?
        .draw(
            in:
                bounds,
            angle:
                -20
        )

        AsymptaPalette
            .hairline
            .setFill()

        for x
            in stride(
                from:
                    18.0,
                through:
                    Double(
                        bounds.width
                    ),
                by:
                    38
            ) {
            for y
                in stride(
                    from:
                        16.0,
                    through:
                        Double(
                            bounds.height
                        ),
                    by:
                        38
                ) {
                NSBezierPath(
                    ovalIn:
                        CGRect(
                            x:
                                x,
                            y:
                                y,
                            width:
                                1.2,
                            height:
                                1.2
                        )
                )
                .fill()
            }
        }
    }
}

private final class AsymptaCardView:
    NSView {

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
                AsymptaPalette
                    .card
                    .cgColor

        layer?
            .cornerRadius =
                14

        layer?
            .borderWidth =
                1

        layer?
            .borderColor =
                AsymptaPalette
                    .hairline
                    .cgColor
    }

    required init?(
        coder:
            NSCoder
    ) {
        fatalError(
            "init(coder:) has not been implemented"
        )
    }
}

private func asymptaLabel(
    _ text:
        String,
    size:
        CGFloat,
    weight:
        NSFont.Weight =
            .regular,
    color:
        NSColor =
            AsymptaPalette.ink
) -> NSTextField {
    let field =
        NSTextField(
            labelWithString:
                text
        )

    field.font =
        .systemFont(
            ofSize:
                size,
            weight:
                weight
        )

    field.textColor =
        color

    field.backgroundColor =
        .clear

    field.isBordered =
        false

    return field
}

@MainActor
private final class BreatheSettingsController:
    NSWindowController {

    struct Values {
        let idle:
            Double
        let exhale:
            Double
        let inhale:
            Double
        let resting:
            Double
    }

    var onSave:
        ((Values) -> Void)?

    var onClose:
        (() -> Void)?

    private let idleSlider =
        NSSlider(
            value:
                0,
            minValue:
                0,
            maxValue:
                300,
            target:
                nil,
            action:
                nil
        )

    private let exhaleSlider =
        NSSlider(
            value:
                0,
            minValue:
                0,
            maxValue:
                300,
            target:
                nil,
            action:
                nil
        )

    private let inhaleSlider =
        NSSlider(
            value:
                0,
            minValue:
                0,
            maxValue:
                300,
            target:
                nil,
            action:
                nil
        )

    private let restingSlider =
        NSSlider(
            value:
                0,
            minValue:
                0,
            maxValue:
                100,
            target:
                nil,
            action:
                nil
        )

    private let idleValue =
        asymptaLabel(
            "",
            size:
                12,
            weight:
                .medium,
            color:
                AsymptaPalette
                    .muted
        )

    private let exhaleValue =
        asymptaLabel(
            "",
            size:
                12,
            weight:
                .medium,
            color:
                AsymptaPalette
                    .muted
        )

    private let inhaleValue =
        asymptaLabel(
            "",
            size:
                12,
            weight:
                .medium,
            color:
                AsymptaPalette
                    .muted
        )

    private let restingValue =
        asymptaLabel(
            "",
            size:
                12,
            weight:
                .medium,
            color:
                AsymptaPalette
                    .muted
        )

    private var activationObserver:
        NSObjectProtocol?

    init(
        idle:
            Double,
        exhale:
            Double,
        inhale:
            Double,
        resting:
            Double
    ) {
        let window =
            NSWindow(
                contentRect:
                    NSRect(
                        x:
                            0,
                        y:
                            0,
                        width:
                            720,
                        height:
                            560
                    ),
                styleMask: [
                    .titled,
                    .closable,
                    .miniaturizable
                ],
                backing:
                    .buffered,
                defer:
                    false
            )

        window.title =
            "Asympta Breathe Settings"

        window.titlebarAppearsTransparent =
            true

        window.titleVisibility =
            .hidden

        window.isMovableByWindowBackground =
            true

        window.backgroundColor =
            AsymptaPalette.paper

        window.alphaValue =
            1

        // Breathe overlays are normal-level. Settings stays quietly above them.
        window.level =
            .floating

        window.collectionBehavior = [
            .moveToActiveSpace,
            .fullScreenAuxiliary
        ]

        window.isReleasedWhenClosed =
            false

        super.init(
            window:
                window
        )

        update(
            idle:
                idle,
            exhale:
                exhale,
            inhale:
                inhale,
            resting:
                resting
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
        if let activationObserver {
            NotificationCenter
                .default
                .removeObserver(
                    activationObserver
                )

            self.activationObserver =
                nil
        }

        close()
    }

    func update(
        idle:
            Double,
        exhale:
            Double,
        inhale:
            Double,
        resting:
            Double
    ) {
        idleSlider.doubleValue =
            idle

        exhaleSlider.doubleValue =
            exhale

        inhaleSlider.doubleValue =
            inhale

        restingSlider.doubleValue =
            resting
            * 100

        refreshLabels()
    }

    func bringToFront() {
        guard
            let window
        else {
            return
        }

        window.alphaValue =
            1

        window.level =
            .floating

        window
            .makeKeyAndOrderFront(
                nil
            )
    }

    private func configureUI() {
        guard
            let window
        else {
            return
        }

        let root =
            AsymptaPaperView(
                frame:
                    window
                        .contentView?
                        .bounds
                    ?? .zero
            )

        root.autoresizingMask = [
            .width,
            .height
        ]

        window.contentView =
            root

        let brand =
            asymptaLabel(
                "Asympta Breathe",
                size:
                    14,
                weight:
                    .semibold
            )

        brand.frame =
            CGRect(
                x:
                    34,
                y:
                    510,
                width:
                    190,
                height:
                    24
            )

        root.addSubview(
            brand
        )

        let whisper =
            asymptaLabel(
                "less noise · more you",
                size:
                    11,
                weight:
                    .medium,
                color:
                    AsymptaPalette
                        .quietBlue
            )

        whisper.frame =
            CGRect(
                x:
                    34,
                y:
                    487,
                width:
                    185,
                height:
                    20
            )

        root.addSubview(
            whisper
        )

        let note =
            asymptaLabel(
                "When things rest,\nyou think clearer.",
                size:
                    15,
                weight:
                    .medium,
                color:
                    AsymptaPalette
                        .quietBlue
            )

        note.frame =
            CGRect(
                x:
                    34,
                y:
                    305,
                width:
                    175,
                height:
                    58
            )

        note.maximumNumberOfLines =
            3

        root.addSubview(
            note
        )

        let quietInfo =
            asymptaLabel(
                "Three timing phases. One resting visibility. Save only when the rhythm feels right.",
                size:
                    11,
                color:
                    AsymptaPalette
                        .muted
            )

        quietInfo.frame =
            CGRect(
                x:
                    34,
                y:
                    215,
                width:
                    178,
                height:
                    70
            )

        quietInfo.maximumNumberOfLines =
            5

        root.addSubview(
            quietInfo
        )

        let title =
            asymptaLabel(
                "Breathing",
                size:
                    30,
                weight:
                    .semibold
            )

        title.frame =
            CGRect(
                x:
                    260,
                y:
                    490,
                width:
                    300,
                height:
                    42
            )

        root.addSubview(
            title
        )

        let subtitle =
            asymptaLabel(
                "Let unused content rest, so the thing you chose can stay clear.",
                size:
                    13,
                color:
                    AsymptaPalette
                        .muted
            )

        subtitle.frame =
            CGRect(
                x:
                    262,
                y:
                    464,
                width:
                    420,
                height:
                    22
            )

        root.addSubview(
            subtitle
        )

        let timingTitle =
            asymptaLabel(
                "TIMING",
                size:
                    11,
                weight:
                    .semibold,
                color:
                    AsymptaPalette
                        .muted
            )

        timingTitle.frame =
            CGRect(
                x:
                    252,
                y:
                    433,
                width:
                    120,
                height:
                    20
            )

        root.addSubview(
            timingTitle
        )

        let timingCard =
            AsymptaCardView(
                frame:
                    CGRect(
                        x:
                            248,
                        y:
                            224,
                        width:
                            438,
                        height:
                            205
                    )
            )

        root.addSubview(
            timingCard
        )

        addSliderRow(
            parent:
                timingCard,
            y:
                137,
            title:
                "Wait before breathing out",
            detail:
                "Idle delay",
            slider:
                idleSlider,
            value:
                idleValue,
            maxLabel:
                "5 min"
        )

        addSliderRow(
            parent:
                timingCard,
            y:
                75,
            title:
                "Move from full visibility to rest",
            detail:
                "Breathe out",
            slider:
                exhaleSlider,
            value:
                exhaleValue,
            maxLabel:
                "5 min"
        )

        addSliderRow(
            parent:
                timingCard,
            y:
                13,
            title:
                "Return from rest to full visibility",
            detail:
                "Breathe in",
            slider:
                inhaleSlider,
            value:
                inhaleValue,
            maxLabel:
                "5 min"
        )

        let restTitle =
            asymptaLabel(
                "RESTING VISIBILITY",
                size:
                    11,
                weight:
                    .semibold,
                color:
                    AsymptaPalette
                        .muted
            )

        restTitle.frame =
            CGRect(
                x:
                    252,
                y:
                    190,
                width:
                    170,
                height:
                    20
            )

        root.addSubview(
            restTitle
        )

        let restCard =
            AsymptaCardView(
                frame:
                    CGRect(
                        x:
                            248,
                        y:
                            96,
                        width:
                            438,
                        height:
                            88
                    )
            )

        root.addSubview(
            restCard
        )

        addSliderRow(
            parent:
                restCard,
            y:
                18,
            title:
                "How much rested content remains visible",
            detail:
                "0–100%",
            slider:
                restingSlider,
            value:
                restingValue,
            maxLabel:
                "100%"
        )

        let cancel =
            NSButton(
                title:
                    "Cancel",
                target:
                    self,
                action:
                    #selector(
                        cancelSettings
                    )
            )

        cancel.bezelStyle =
            .rounded

        cancel.frame =
            CGRect(
                x:
                    490,
                y:
                    36,
                width:
                    88,
                height:
                    34
            )

        root.addSubview(
            cancel
        )

        let save =
            NSButton(
                title:
                    "Save & Apply",
                target:
                    self,
                action:
                    #selector(
                        saveAndApply
                    )
            )

        save.bezelStyle =
            .rounded

        save.keyEquivalent =
            "\r"

        save.contentTintColor =
            AsymptaPalette
                .quietBlue

        save.frame =
            CGRect(
                x:
                    586,
                y:
                    36,
                width:
                    100,
                height:
                    34
            )

        root.addSubview(
            save
        )

        for slider
            in [
                idleSlider,
                exhaleSlider,
                inhaleSlider,
                restingSlider
            ] {
            slider.isContinuous =
                true

            slider.target =
                self

            slider.action =
                #selector(
                    sliderChanged(
                        _:
                    )
                )
        }
    }

    private func addSliderRow(
        parent:
            NSView,
        y:
            CGFloat,
        title:
            String,
        detail:
            String,
        slider:
            NSSlider,
        value:
            NSTextField,
        maxLabel:
            String
    ) {
        let detailLabel =
            asymptaLabel(
                detail.uppercased(),
                size:
                    9,
                weight:
                    .semibold,
                color:
                    AsymptaPalette
                        .quietBlue
            )

        detailLabel.frame =
            CGRect(
                x:
                    18,
                y:
                    y + 34,
                width:
                    110,
                height:
                    14
            )

        parent.addSubview(
            detailLabel
        )

        let titleLabel =
            asymptaLabel(
                title,
                size:
                    12
            )

        titleLabel.frame =
            CGRect(
                x:
                    18,
                y:
                    y + 17,
                width:
                    280,
                height:
                    18
            )

        parent.addSubview(
            titleLabel
        )

        slider.frame =
            CGRect(
                x:
                    18,
                y:
                    y,
                width:
                    310,
                height:
                    18
            )

        parent.addSubview(
            slider
        )

        value.alignment =
            .right

        value.frame =
            CGRect(
                x:
                    336,
                y:
                    y + 17,
                width:
                    82,
                height:
                    18
            )

        parent.addSubview(
            value
        )

        let maxField =
            asymptaLabel(
                maxLabel,
                size:
                    9,
                color:
                    AsymptaPalette
                        .muted
            )

        maxField.alignment =
            .right

        maxField.frame =
            CGRect(
                x:
                    336,
                y:
                    y,
                width:
                    82,
                height:
                    14
            )

        parent.addSubview(
            maxField
        )
    }

    private func installActivationObserver() {
        activationObserver =
            NotificationCenter
                .default
                .addObserver(
                    forName:
                        NSWindow
                            .didBecomeKeyNotification,
                    object:
                        window,
                    queue:
                        .main
                ) {
                    [weak self]
                    _ in

                    Task {
                        @MainActor in

                        self?
                            .bringToFront()
                    }
                }
    }

    @objc
    private func sliderChanged(
        _ sender:
            NSSlider
    ) {
        if sender
            === idleSlider {
            idleSlider.doubleValue =
                roundedTime(
                    sender.doubleValue
                )
        } else if sender
            === exhaleSlider {
            exhaleSlider.doubleValue =
                roundedTime(
                    sender.doubleValue
                )
        } else if sender
            === inhaleSlider {
            inhaleSlider.doubleValue =
                roundedTime(
                    sender.doubleValue
                )
        } else if sender
            === restingSlider {
            restingSlider.doubleValue =
                min(
                    max(
                        round(
                            sender.doubleValue
                        ),
                        0
                    ),
                    100
                )
        }

        refreshLabels()
    }

    @objc
    private func saveAndApply() {
        onSave?(
            Values(
                idle:
                    roundedTime(
                        idleSlider.doubleValue
                    ),
                exhale:
                    roundedTime(
                        exhaleSlider.doubleValue
                    ),
                inhale:
                    roundedTime(
                        inhaleSlider.doubleValue
                    ),
                resting:
                    min(
                        max(
                            restingSlider.doubleValue
                            / 100,
                            0
                        ),
                        1
                    )
            )
        )

        onClose?()
    }

    @objc
    private func cancelSettings() {
        onClose?()
    }

    private func roundedTime(
        _ value:
            Double
    ) -> Double {
        min(
            max(
                round(
                    value
                    * 10
                )
                / 10,
                0
            ),
            300
        )
    }

    private func refreshLabels() {
        idleValue.stringValue =
            formatTime(
                idleSlider.doubleValue
            )

        exhaleValue.stringValue =
            formatTime(
                exhaleSlider.doubleValue
            )

        inhaleValue.stringValue =
            formatTime(
                inhaleSlider.doubleValue
            )

        restingValue.stringValue =
            "\(Int(round(restingSlider.doubleValue)))%"
    }

    private func formatTime(
        _ seconds:
            Double
    ) -> String {
        if seconds
            >= 60 {
            let whole =
                Int(
                    round(
                        seconds
                    )
                )

            let minutes =
                whole
                / 60

            let remainder =
                whole
                % 60

            if remainder
                == 0 {
                return
                    "\(minutes)m"
            }

            return
                "\(minutes)m \(remainder)s"
        }

        if seconds.rounded()
            == seconds {
            return
                "\(Int(seconds))s"
        }

        return
            String(
                format:
                    "%.1fs",
                seconds
            )
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

    private var idleTimer:
        Timer?

    private let activityMonitor =
        ActivityMonitor()

    private var workspaceObservers:
        [NSObjectProtocol] =
            []

    private var preparationTask:
        Task<Void, Never>?

    private var session:
        FadeSession?

    private var permissionGate:
        PermissionGateController?

    private var welcomeController:
        WelcomeWindowController?

    private var settingsController:
        BreatheSettingsController?

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
                idleTimer?
                    .invalidate()

                idleTimer =
                    nil

                breatheInImmediately()
            } else {
                scheduleIdleTimer()
            }

            rebuildMenu()
        }
    }

    private var idleSeconds:
        Double {
        get {
            guard
                UserDefaults
                    .standard
                    .object(
                        forKey:
                            "idleSeconds"
                    )
                != nil
            else {
                return 4
            }

            return
                min(
                    max(
                        UserDefaults
                            .standard
                            .double(
                                forKey:
                                    "idleSeconds"
                            ),
                        0
                    ),
                    300
                )
        }

        set {
            UserDefaults
                .standard
                .set(
                    min(
                        max(
                            newValue,
                            0
                        ),
                        300
                    ),
                    forKey:
                        "idleSeconds"
                )

            rebuildMenu()
        }
    }

    private var fadeSeconds:
        Double {
        get {
            guard
                UserDefaults
                    .standard
                    .object(
                        forKey:
                            "fadeSeconds"
                    )
                != nil
            else {
                return 9
            }

            return
                min(
                    max(
                        UserDefaults
                            .standard
                            .double(
                                forKey:
                                    "fadeSeconds"
                            ),
                        0
                    ),
                    300
                )
        }

        set {
            UserDefaults
                .standard
                .set(
                    min(
                        max(
                            newValue,
                            0
                        ),
                        300
                    ),
                    forKey:
                        "fadeSeconds"
                )

            rebuildMenu()
        }
    }

    private var inhaleSeconds:
        Double {
        get {
            guard
                UserDefaults
                    .standard
                    .object(
                        forKey:
                            "inhaleSeconds"
                    )
                != nil
            else {
                return 1.8
            }

            return
                min(
                    max(
                        UserDefaults
                            .standard
                            .double(
                                forKey:
                                    "inhaleSeconds"
                            ),
                        0
                    ),
                    300
                )
        }

        set {
            UserDefaults
                .standard
                .set(
                    min(
                        max(
                            newValue,
                            0
                        ),
                        300
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
                        0
                    ),
                    1
                )
        }

        set {
            UserDefaults
                .standard
                .set(
                    min(
                        max(
                            newValue,
                            0
                        ),
                        1
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

                session
                    .hoveredWindowID =
                        nil

                updateHoverPreview(
                    session:
                        session
                )
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
        idleTimer?
            .invalidate()

        activityMonitor
            .stop()

        preparationTask?
            .cancel()

        permissionGate?
            .stop()

        welcomeController?
            .stop()

        settingsController?
            .stop()

        breatheInImmediately()

        for observer
            in workspaceObservers {
            NSWorkspace
                .shared
                .notificationCenter
                .removeObserver(
                    observer
                )
        }

        workspaceObservers
            .removeAll()
    }

    private func beginPermissionFlow() async {
        let defaults =
            UserDefaults.standard

        let shortVersion =
            Bundle.main
                .object(
                    forInfoDictionaryKey:
                        "CFBundleShortVersionString"
                ) as? String
            ?? "unknown"

        let buildVersion =
            Bundle.main
                .object(
                    forInfoDictionaryKey:
                        "CFBundleVersion"
                ) as? String
            ?? "unknown"

        let currentVersionIdentity =
            shortVersion
            + "-"
            + buildVersion

        let lastResetVersion =
            defaults.string(
                forKey:
                    lastPermissionResetVersionKey
            )

        if lastResetVersion
            != currentVersionIdentity {
            // First launch of THIS exact build:
            // clear both old TCC approvals exactly once.
            //
            // The build identity is recorded before opening System Settings so
            // a macOS-requested reopen of the same build never erases the
            // permission the user just granted.
            defaults.set(
                currentVersionIdentity,
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

        settingsController?
            .stop()

        settingsController =
            nil

        breatheInImmediately()

        idleTimer?
            .invalidate()

        idleTimer =
            nil

        activityMonitor
            .stop()

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

        activityMonitor.onActivity = {
            [weak self]
            kind in

            Task {
                @MainActor in

                self?
                    .handleActivity(
                        kind
                    )
            }
        }

        _ =
            activityMonitor
                .start()

        installWorkspaceObservers()
        scheduleIdleTimer()

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

    private func installWorkspaceObservers() {
        guard
            workspaceObservers
                .isEmpty
        else {
            return
        }

        let center =
            NSWorkspace
                .shared
                .notificationCenter

        let activated =
            center
                .addObserver(
                    forName:
                        NSWorkspace
                            .didActivateApplicationNotification,
                    object:
                        nil,
                    queue:
                        .main
                ) {
                    [weak self]
                    note in

                    Task {
                        @MainActor in

                        guard
                            let self,
                            self.mainStarted,
                            !self.settingsWindowVisible,
                            let app =
                                note
                                    .userInfo?[
                                        NSWorkspace
                                            .applicationUserInfoKey
                                    ]
                                as? NSRunningApplication
                        else {
                            return
                        }

                        guard
                            let current =
                                self.session
                        else {
                            self
                                .scheduleIdleTimer()
                            return
                        }

                        let pid =
                            app
                                .processIdentifier

                        if current
                            .remainingPIDs
                            .contains(
                                pid
                            ) {
                            // The user's real app activation is authoritative.
                            // Restore only that app; all other resting apps remain resting.
                            self
                                .breatheIn(
                                    pid:
                                        pid
                                )
                        } else {
                            // A different real foreground app must visually outrank every
                            // remaining resting representation.
                            for overlay
                                in current
                                    .overlays {
                                let overlayPID =
                                    overlay
                                        .target
                                        .app
                                        .processIdentifier

                                guard
                                    current
                                        .remainingPIDs
                                        .contains(
                                            overlayPID
                                        )
                                else {
                                    continue
                                }

                                overlay
                                    .panel
                                    .level =
                                        .normal

                                overlay
                                    .panel
                                    .orderBack(
                                        nil
                                    )
                            }

                            self
                                .applyLayerOcclusion(
                                    session:
                                        current
                                )
                        }
                    }
                }

        let terminated =
            center
                .addObserver(
                    forName:
                        NSWorkspace
                            .didTerminateApplicationNotification,
                    object:
                        nil,
                    queue:
                        .main
                ) {
                    [weak self]
                    note in

                    Task {
                        @MainActor in

                        guard
                            let self,
                            let current =
                                self.session,
                            let app =
                                note
                                    .userInfo?[
                                        NSWorkspace
                                            .applicationUserInfoKey
                                    ]
                                as? NSRunningApplication
                        else {
                            return
                        }

                        let pid =
                            app
                                .processIdentifier

                        guard
                            current
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

        workspaceObservers = [
            activated,
            terminated
        ]
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
            && !settingsWindowVisible
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

        let settings =
            NSMenuItem(
                title:
                    "Settings…",
                action:
                    #selector(
                        openSettings
                    ),
                keyEquivalent:
                    ","
            )

        settings.target =
            self

        menu.addItem(
            settings
        )

        let timingSummary =
            NSMenuItem(
                title:
                    "Idle \(formatSettingTime(idleSeconds)) · Exhale \(formatSettingTime(fadeSeconds)) · Inhale \(formatSettingTime(inhaleSeconds)) · Rest \(Int(round(restingOpacity * 100)))%",
                action:
                    nil,
                keyEquivalent:
                    ""
            )

        timingSummary.isEnabled =
            false

        menu.addItem(
            timingSummary
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

    private func formatSettingTime(
        _ seconds:
            Double
    ) -> String {
        if seconds
            >= 60 {
            let whole =
                Int(
                    round(
                        seconds
                    )
                )

            let minutes =
                whole
                / 60

            let remainder =
                whole
                % 60

            if remainder
                == 0 {
                return
                    "\(minutes)m"
            }

            return
                "\(minutes)m\(remainder)s"
        }

        if seconds.rounded()
            == seconds {
            return
                "\(Int(seconds))s"
        }

        return
            String(
                format:
                    "%.1fs",
                seconds
            )
    }

    private var settingsWindowVisible:
        Bool {
        settingsController?
            .window?
            .isVisible
        == true
    }

    @objc
    private func openSettings() {
        // Settings is never part of a resting session.
        // Restore first, then show the protected settings surface.
        breatheInImmediately()

        idleTimer?
            .invalidate()

        idleTimer =
            nil

        let controller:
            BreatheSettingsController

        if let existing =
            settingsController {
            controller =
                existing

            controller.update(
                idle:
                    idleSeconds,
                exhale:
                    fadeSeconds,
                inhale:
                    inhaleSeconds,
                resting:
                    restingOpacity
            )
        } else {
            let created =
                BreatheSettingsController(
                    idle:
                        idleSeconds,
                    exhale:
                        fadeSeconds,
                    inhale:
                        inhaleSeconds,
                    resting:
                        restingOpacity
                )

            created.onSave = {
                [weak self]
                values in

                guard
                    let self
                else {
                    return
                }

                // Commit the full draft atomically from the user's point of view.
                self.idleSeconds =
                    values.idle

                self.fadeSeconds =
                    values.exhale

                self.inhaleSeconds =
                    values.inhale

                self.restingOpacity =
                    values.resting
            }

            created.onClose = {
                [weak self,
                 weak created]
                in

                created?
                    .stop()

                guard
                    let self
                else {
                    return
                }

                if self
                    .settingsController
                    === created {
                    self.settingsController =
                        nil
                }

                self.scheduleIdleTimer()
            }

            settingsController =
                created

            controller =
                created
        }

        controller
            .showWindow(
                nil
            )

        _ =
            NSRunningApplication
                .current
                .activate(
                    options: []
                )

        controller
            .bringToFront()
    }

    private func handleActivity(
        _ kind:
            ActivityKind
    ) {
        guard
            mainStarted
        else {
            return
        }

        if session != nil {
            // Once resting, pointer/scroll/keyboard do not wake the whole desktop.
            // Hover, live typing, and click-restore are handled by session-specific logic.
            return
        }

        scheduleIdleTimer()
    }

    private func scheduleIdleTimer() {
        idleTimer?
            .invalidate()

        idleTimer =
            nil

        guard
            mainStarted,
            enabled,
            !settingsWindowVisible,
            session == nil,
            preparationTask == nil,
            screenPermission,
            accessibilityPermission
        else {
            return
        }

        let delay =
            max(
                0,
                idleSeconds
            )

        idleTimer =
            Timer
                .scheduledTimer(
                    withTimeInterval:
                        delay,
                    repeats:
                        false
                ) {
                    [weak self]
                    _ in

                    Task {
                        @MainActor in

                        self?
                            .beginScheduledBreathe()
                    }
                }
    }

    private func beginScheduledBreathe() {
        idleTimer =
            nil

        refreshPermissions()

        guard
            mainStarted,
            enabled,
            screenPermission,
            accessibilityPermission,
            !settingsWindowVisible,
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
    private func toggleEnabled() {
        enabled.toggle()
    }

    @objc
    private func breatheNow() {
        guard
            session == nil,
            preparationTask == nil,
            !settingsWindowVisible
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
            preparationTask == nil,
            !settingsWindowVisible
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

        let streamFPS:
            Int

        switch prepared.count {
        case 0...2:
            streamFPS =
                30

        case 3...4:
            streamFPS =
                24

        case 5...8:
            streamFPS =
                18

        default:
            streamFPS =
                12
        }

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

            // Foreground invariant: a real app activated by the user must
            // naturally be able to sit above Breathe.
            panel.level =
                .normal

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

            let overlay =
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

            do {
                let live =
                    try LiveWindowStream(
                        window:
                            item
                                .scWindow,
                        width:
                            max(
                                1,
                                Int(
                                    item
                                        .target
                                        .window
                                        .cgFrame
                                        .width
                                    * item
                                        .scale
                                )
                            ),
                        height:
                            max(
                                1,
                                Int(
                                    item
                                        .target
                                        .window
                                        .cgFrame
                                        .height
                                    * item
                                        .scale
                                )
                            ),
                        framesPerSecond:
                            streamFPS
                    ) {
                        [weak overlay]
                        image in

                        guard
                            let overlay
                        else {
                            return
                        }

                        overlay
                            .view
                            .setContentImage(
                                image
                            )
                    }

                overlay.liveStream =
                    live

                live.start()
            } catch {
                // Keep the initial captured frame if a live stream cannot start.
                // Never substitute another window or desktop composition here.
            }

            overlays.append(
                overlay
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
        // Real CGWindow order is front-to-back. Recompute continuously.
        // Any real window that is currently in front — including a newly opened
        // video/full-screen/media window — punches its area out of every resting
        // overlay behind it. Breathed-out apps can never bleed into media above.
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
                            .applyLayerOcclusion(
                                session:
                                    session
                            )

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
                1.0,
                max(
                    restingOpacity,
                    max(
                        0.30,
                        restingOpacity
                        + 0.20
                    )
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

            let previousFocus =
                overlay
                    .textStyleFocusRect

            let focusChanged =
                previousFocus
                == nil
                || abs(
                    previousFocus!.minX
                    - localRectPoints.minX
                ) > 1
                || abs(
                    previousFocus!.minY
                    - localRectPoints.minY
                ) > 1
                || abs(
                    previousFocus!.width
                    - localRectPoints.width
                ) > 1
                || abs(
                    previousFocus!.height
                    - localRectPoints.height
                ) > 1

            if focusChanged
                || overlay
                    .textStyleColor
                    == nil {
                overlay
                    .textStyleFocusRect =
                        localRectPoints

                overlay
                    .textStyleColor =
                        stableTextColor(
                            from:
                                image,
                            focusRect:
                                pixelRect
                        )
            }

            let textOnly =
                makeTextOnlyImage(
                    from:
                        image,
                    focusRect:
                        pixelRect,
                    textColor:
                        overlay
                            .textStyleColor
                        ?? CIColor(
                            red: 0.97,
                            green: 0.97,
                            blue: 0.97,
                            alpha: 1
                        )
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
                .textStyleFocusRect =
                    nil

            overlay
                .textStyleColor =
                    nil

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
                .orderBack(
                    nil
                )
        }

        // Remove the resting border immediately.
        // The real app owns foreground activation; the transition overlay stays
        // at ordinary window level so another user-selected app can still outrank it.
        for overlay
            in overlays {
            overlay
                .panel
                .level =
                    .normal

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

        for overlay
            in overlays {
            overlay
                .panel
                .orderFrontRegardless()
        }

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
                            .liveStream?
                            .stop()

                        overlay
                            .liveStream =
                                nil

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

                        self
                            .scheduleIdleTimer()
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
                .liveStream?
                .stop()

            overlay
                .liveStream =
                    nil

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
        scheduleIdleTimer()
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
