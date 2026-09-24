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
  <key>CFBundleShortVersionString</key><string>1.1.0</string>
  <key>CFBundleVersion</key><string>10</string>
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
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: colorSpace, bitmapInfo: bitmapInfo)!
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

let card = CGRect(x: 72, y: 72, width: 880, height: 880)
let cardPath = CGPath(roundedRect: card, cornerWidth: 205, cornerHeight: 205, transform: nil)
ctx.saveGState()
ctx.addPath(cardPath)
ctx.clip()

let paperColors = [
    CGColor(red: 0.965, green: 0.945, blue: 0.900, alpha: 1),
    CGColor(red: 0.915, green: 0.895, blue: 0.845, alpha: 1)
] as CFArray
let paperGradient = CGGradient(colorsSpace: colorSpace, colors: paperColors, locations: [0, 1])!
ctx.drawLinearGradient(paperGradient, start: CGPoint(x: 0, y: 952), end: CGPoint(x: 1024, y: 72), options: [])

var seed: UInt64 = 0xA59F_7D21_3C44_8B17
func rnd() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat((seed >> 33) & 0x7fffffff) / CGFloat(0x7fffffff)
}
for _ in 0..<11000 {
    let x = card.minX + rnd() * card.width
    let y = card.minY + rnd() * card.height
    let len = 0.6 + rnd() * 3.0
    let alpha = 0.018 + rnd() * 0.022
    if rnd() > 0.5 {
        ctx.setStrokeColor(CGColor(red: 0.42, green: 0.35, blue: 0.27, alpha: alpha))
    } else {
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 0.98, alpha: alpha * 1.7))
    }
    ctx.setLineWidth(0.55 + rnd() * 0.65)
    ctx.move(to: CGPoint(x: x, y: y))
    ctx.addLine(to: CGPoint(x: x + len, y: y + (rnd() - 0.5) * 1.4))
    ctx.strokePath()
}

let center = CGPoint(x: 512, y: 540)
let sphereColors = [
    CGColor(red: 0.86, green: 0.91, blue: 0.92, alpha: 1),
    CGColor(red: 0.46, green: 0.65, blue: 0.72, alpha: 1),
    CGColor(red: 0.30, green: 0.50, blue: 0.60, alpha: 1)
] as CFArray
let sphereGradient = CGGradient(colorsSpace: colorSpace, colors: sphereColors, locations: [0, 0.55, 1])!
ctx.drawRadialGradient(
    sphereGradient,
    startCenter: CGPoint(x: 440, y: 650), startRadius: 20,
    endCenter: center, endRadius: 260,
    options: [.drawsAfterEndLocation]
)

ctx.setFillColor(CGColor(red: 0.965, green: 0.955, blue: 0.925, alpha: 1))
ctx.fillEllipse(in: CGRect(x: 350, y: 235, width: 324, height: 324))
ctx.setFillColor(CGColor(red: 0.42, green: 0.60, blue: 0.67, alpha: 1))
ctx.fillEllipse(in: CGRect(x: 325, y: 338, width: 374, height: 345))

ctx.setFillColor(CGColor(red: 1, green: 0.995, blue: 0.97, alpha: 1))
ctx.fillEllipse(in: CGRect(x: 705, y: 710, width: 86, height: 86))

ctx.restoreGState()
ctx.addPath(cardPath)
ctx.setStrokeColor(CGColor(red: 0.62, green: 0.58, blue: 0.50, alpha: 0.12))
ctx.setLineWidth(2)
ctx.strokePath()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
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
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/package/Asympta-Breathe-1.1.0.zip"

echo "Built $OUT/package/Asympta-Breathe-1.1.0.zip"
