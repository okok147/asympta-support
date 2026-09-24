#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/dist"
BUILD="$ROOT/.build"
APP="$OUT/Asympta Breathe.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$OUT" "$BUILD"
mkdir -p "$MACOS" "$RES" "$BUILD"

COMMON=(
  -swift-version 5
  -O
  -parse-as-library
  -sdk "$SDK"
  -framework AppKit
  -framework ScreenCaptureKit
  -framework CoreGraphics
  -framework QuartzCore
  -framework ApplicationServices
)

xcrun swiftc "${COMMON[@]}" -target arm64-apple-macos14.0   "$ROOT/main.swift" -o "$BUILD/AsymptaBreathe-arm64"

xcrun swiftc "${COMMON[@]}" -target x86_64-apple-macos14.0   "$ROOT/main.swift" -o "$BUILD/AsymptaBreathe-x86_64"

lipo -create   "$BUILD/AsymptaBreathe-arm64"   "$BUILD/AsymptaBreathe-x86_64"   -output "$MACOS/AsymptaBreathe"
chmod +x "$MACOS/AsymptaBreathe"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Asympta Breathe</string>
  <key>CFBundleExecutable</key><string>AsymptaBreathe</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.asympta.breathe</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Asympta Breathe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.4.1</string>
  <key>CFBundleVersion</key><string>41</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Asympta Breathe captures the frontmost app window so it can gently breathe out during inactivity.</string>
</dict>
</plist>
PLIST

cat > "$BUILD/IconMaker.swift" <<'SWIFT'
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let w = 1024
let h = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(
    data: nil,
    width: w,
    height: h,
    bitsPerComponent: 8,
    bytesPerRow: w * 4,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

let card = CGRect(x: 72, y: 72, width: 880, height: 880)
let cardPath = CGPath(
    roundedRect: card,
    cornerWidth: 205,
    cornerHeight: 205,
    transform: nil
)

ctx.saveGState()
ctx.addPath(cardPath)
ctx.clip()

let cream = [
    CGColor(red: 0.985, green: 0.976, blue: 0.952, alpha: 1),
    CGColor(red: 0.945, green: 0.932, blue: 0.900, alpha: 1)
] as CFArray
let creamGradient = CGGradient(colorsSpace: cs, colors: cream, locations: [0, 1])!
ctx.drawLinearGradient(
    creamGradient,
    start: CGPoint(x: 512, y: 952),
    end: CGPoint(x: 512, y: 72),
    options: []
)

let orbRect = CGRect(x: 220, y: 230, width: 584, height: 584)
let blues = [
    CGColor(red: 0.83, green: 0.91, blue: 0.95, alpha: 1),
    CGColor(red: 0.45, green: 0.68, blue: 0.80, alpha: 1),
    CGColor(red: 0.30, green: 0.55, blue: 0.70, alpha: 1)
] as CFArray
let orbGradient = CGGradient(colorsSpace: cs, colors: blues, locations: [0, 0.58, 1])!
ctx.saveGState()
ctx.addEllipse(in: orbRect)
ctx.clip()
ctx.drawRadialGradient(
    orbGradient,
    startCenter: CGPoint(x: 405, y: 690),
    startRadius: 24,
    endCenter: CGPoint(x: 525, y: 525),
    endRadius: 330,
    options: [.drawsAfterEndLocation]
)
ctx.restoreGState()

let smallRect = CGRect(x: 401, y: 257, width: 222, height: 222)
let small = [
    CGColor(red: 0.985, green: 0.99, blue: 0.985, alpha: 1),
    CGColor(red: 0.88, green: 0.92, blue: 0.94, alpha: 1)
] as CFArray
let smallGradient = CGGradient(colorsSpace: cs, colors: small, locations: [0, 1])!
ctx.saveGState()
ctx.addEllipse(in: smallRect)
ctx.clip()
ctx.drawRadialGradient(
    smallGradient,
    startCenter: CGPoint(x: 475, y: 405),
    startRadius: 10,
    endCenter: CGPoint(x: 520, y: 360),
    endRadius: 145,
    options: [.drawsAfterEndLocation]
)
ctx.restoreGState()

ctx.restoreGState()

ctx.addPath(cardPath)
ctx.setStrokeColor(CGColor(red: 0.58, green: 0.55, blue: 0.50, alpha: 0.10))
ctx.setLineWidth(2)
ctx.strokePath()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(
    output as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
)!
CGImageDestinationAddImage(dest, image, nil)
precondition(CGImageDestinationFinalize(dest))
SWIFT

xcrun swift "$BUILD/IconMaker.swift" "$BUILD/AppIcon1024.png"
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in   "16 icon_16x16.png"   "32 icon_16x16@2x.png"   "32 icon_32x32.png"   "64 icon_32x32@2x.png"   "128 icon_128x128.png"   "256 icon_128x128@2x.png"   "256 icon_256x256.png"   "512 icon_256x256@2x.png"   "512 icon_512x512.png"   "1024 icon_512x512@2x.png"; do
  size="${spec%% *}"
  name="${spec#* }"
  sips -z "$size" "$size" "$BUILD/AppIcon1024.png" --out "$ICONSET/$name" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
cp "$BUILD/AppIcon1024.png" "$RES/AppIcon.png"

codesign --force --deep --sign - "$APP"

file "$MACOS/AsymptaBreathe"
lipo -info "$MACOS/AsymptaBreathe"
codesign --verify --deep --strict --verbose=2 "$APP"
plutil -lint "$CONTENTS/Info.plist"

mkdir -p "$OUT/package"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/package/Asympta-Breathe-1.4.1.zip"

echo "Built $OUT/package/Asympta-Breathe-1.4.1.zip"
