#!/bin/bash
# scripts/make-icon.sh: draws the placeholder app icon and writes Resources/AppIcon.icns (committed binary).
# Usage: scripts/make-icon.sh
# All intermediate files live in a fresh ${TMPDIR}/macx-icon-XXXXXX directory, which is removed on exit.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
out="$repo/Resources/AppIcon.icns"
work="$(mktemp -d "${TMPDIR:-/tmp}/macx-icon-XXXXXX")"
case "$work" in
    "${TMPDIR:-/tmp}"/macx-icon-*) ;;
    *) echo "make-icon.sh: unexpected temp dir $work" >&2; exit 1 ;;
esac
trap 'rm -rf "$work"' EXIT

cat > "$work/draw.swift" <<'SWIFT'
import AppKit

let iconset = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)

func draw(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let s = CGFloat(pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Rounded-square tile with a blue gradient.
    let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.55, blue: 0.98, alpha: 1),
               ending: NSColor(srgbRed: 0.05, green: 0.30, blue: 0.75, alpha: 1))!.draw(in: tilePath, angle: -90)
    // A folder shape.
    NSColor(srgbRed: 1.0, green: 0.82, blue: 0.35, alpha: 1).setFill()
    let tab = NSBezierPath(roundedRect: NSRect(x: s * 0.24, y: s * 0.58, width: s * 0.22, height: s * 0.10),
                           xRadius: s * 0.03, yRadius: s * 0.03)
    tab.fill()
    let body = NSBezierPath(roundedRect: NSRect(x: s * 0.24, y: s * 0.28, width: s * 0.52, height: s * 0.36),
                            xRadius: s * 0.04, yRadius: s * 0.04)
    body.fill()
    // Three "list rows" on the folder.
    NSColor(srgbRed: 0.05, green: 0.30, blue: 0.75, alpha: 0.85).setFill()
    for row in 0..<3 {
        NSBezierPath(roundedRect: NSRect(x: s * 0.31, y: s * (0.34 + 0.08 * CGFloat(row)), width: s * 0.38, height: s * 0.035),
                     xRadius: s * 0.015, yRadius: s * 0.015).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try draw(pixels: points * scale).write(to: iconset.appending(path: name))
    }
}
SWIFT

mkdir "$work/AppIcon.iconset"
xcrun swift "$work/draw.swift" "$work/AppIcon.iconset"
mkdir -p "$repo/Resources"
iconutil --convert icns --output "$work/AppIcon.icns" "$work/AppIcon.iconset"
mv "$work/AppIcon.icns" "$out"
echo "wrote $out"
