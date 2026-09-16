import AppKit
import Foundation

// Deterministic, native drawing; no asset downloads or third-party tools.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift make-icon.swift OUTPUT_DIRECTORY\n", stderr)
    exit(2)
}

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = destination.appendingPathComponent("FreeSound.iconset", isDirectory: true)
let manager = FileManager.default
try manager.createDirectory(at: iconset, withIntermediateDirectories: true)

func renderIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "FreeSound.Icon", code: 1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    let tile = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 210, yRadius: 210)
    NSGradient(colors: [
        NSColor(srgbRed: 0.035, green: 0.09, blue: 0.105, alpha: 1),
        NSColor(srgbRed: 0.07, green: 0.20, blue: 0.22, alpha: 1)
    ])!.draw(in: tile, angle: 75)

    NSColor(srgbRed: 0.31, green: 0.63, blue: 0.60, alpha: 0.30).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    let heights: [CGFloat] = [130, 270, 445, 610, 360, 210, 105]
    let barWidth: CGFloat = 52
    let barGap: CGFloat = 26
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * barGap
    let startX = (1024 - totalWidth) / 2

    for (index, height) in heights.enumerated() {
        let x = startX + CGFloat(index) * (barWidth + barGap)
        let bar = NSBezierPath(roundedRect: NSRect(x: x, y: (1024 - height) / 2, width: barWidth, height: height), xRadius: barWidth / 2, yRadius: barWidth / 2)
        NSGradient(colors: [
            NSColor(srgbRed: 0.16, green: 0.74, blue: 0.59, alpha: 1),
            NSColor(srgbRed: 0.58, green: 0.98, blue: 0.77, alpha: 1)
        ])!.draw(in: bar, angle: 90)
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "FreeSound.Icon", code: 2)
    }
    return data
}

for size in [16, 32, 128, 256, 512] {
    try renderIcon(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try renderIcon(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", destination.appendingPathComponent("FreeSound.icns").path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    exit(iconutil.terminationStatus)
}
