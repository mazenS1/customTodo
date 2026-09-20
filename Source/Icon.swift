import AppKit
import Foundation

// Draw a small, resolution-independent identity with native paths. Each icon size is
// rasterized independently for crisp Finder, Dock, and Spotlight presentation.
let target = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
        NSColor(white: 0.94, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 220, yRadius: 220).fill()
        let ink = NSColor(white: 0.23, alpha: 1)
        ink.setStroke()
        let tray = NSBezierPath(); tray.lineWidth = 47; tray.lineJoinStyle = .round; tray.lineCapStyle = .round
        tray.move(to: NSPoint(x: 255, y: 465)); tray.line(to: NSPoint(x: 205, y: 310)); tray.line(to: NSPoint(x: 205, y: 240)); tray.line(to: NSPoint(x: 819, y: 240)); tray.line(to: NSPoint(x: 819, y: 310)); tray.line(to: NSPoint(x: 769, y: 465)); tray.stroke()
        let lip = NSBezierPath(); lip.lineWidth = 42; lip.lineJoinStyle = .round; lip.lineCapStyle = .round
        lip.move(to: NSPoint(x: 215, y: 370)); lip.line(to: NSPoint(x: 405, y: 370)); lip.line(to: NSPoint(x: 440, y: 310)); lip.line(to: NSPoint(x: 585, y: 310)); lip.line(to: NSPoint(x: 620, y: 370)); lip.line(to: NSPoint(x: 809, y: 370)); lip.stroke()
        ink.setFill()
        for (y, width) in [(CGFloat(715), CGFloat(400)), (CGFloat(610), CGFloat(310)), (CGFloat(505), CGFloat(220))] {
            NSBezierPath(roundedRect: NSRect(x: 315, y: y, width: width, height: 45), xRadius: 22, yRadius: 22).fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: target.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
