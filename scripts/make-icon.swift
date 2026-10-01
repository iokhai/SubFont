import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = destination.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let n = CGFloat(pixels)
        let rect = NSRect(x: n * 0.06, y: n * 0.06, width: n * 0.88, height: n * 0.88)
        let path = NSBezierPath(roundedRect: rect, xRadius: n * 0.21, yRadius: n * 0.21)
        NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.50, blue: 0.78, alpha: 1),
                   ending: NSColor(calibratedRed: 0.04, green: 0.21, blue: 0.43, alpha: 1))!.draw(in: path, angle: 270)
        let text = "Aa" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: n * 0.48, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let measured = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (n - measured.width) / 2, y: (n - measured.height) / 2 + n * 0.035), withAttributes: attrs)
        let line = NSBezierPath(roundedRect: NSRect(x: n * 0.29, y: n * 0.22, width: n * 0.42, height: n * 0.025),
                                xRadius: n * 0.013, yRadius: n * 0.013)
        NSColor(calibratedWhite: 1, alpha: 0.65).setFill(); line.fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(
            to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", destination.appendingPathComponent("AppIcon.icns").path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
try FileManager.default.removeItem(at: iconset)
