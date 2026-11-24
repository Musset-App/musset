// Draws the picture behind the disk image's window: paper, the name, an arrow from the app to Applications.
//   swift scripts/dmg/make-background.swift scripts/dmg     → background.png, background@2x.png, background.tiff
// The window is 640 × 400 points; the app's icon sits at (170, 205) and Applications at (470, 205), from the top left.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let size = NSSize(width: 640, height: 400)

func draw(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Paper, a shade warmer than white, as the app's own panels.
    NSColor(srgbRed: 0.957, green: 0.953, blue: 0.937, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    let ink = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1)
    func text(_ s: String, _ font: NSFont, _ color: NSColor, y: CGFloat, tracking: CGFloat = 0) {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: tracking])
        a.draw(at: NSPoint(x: (size.width - a.size().width) / 2, y: y))
    }
    let serif = NSFont(descriptor: NSFont.systemFont(ofSize: 34).fontDescriptor.withDesign(.serif)!, size: 34)!
    text("Musset", serif, ink, y: 318)
    text("Drag Musset onto Applications", NSFont.systemFont(ofSize: 13), ink.withAlphaComponent(0.55), y: 60)
    // The arrow, between the two icons (their centres are 205 points from the top).
    let y = size.height - 205
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 262, y: y)); path.line(to: NSPoint(x: 378, y: y))
    path.move(to: NSPoint(x: 366, y: y + 10)); path.line(to: NSPoint(x: 378, y: y)); path.line(to: NSPoint(x: 366, y: y - 10))
    path.lineWidth = 2; path.lineCapStyle = .round; path.lineJoinStyle = .round
    ink.withAlphaComponent(0.35).setStroke()
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try draw(scale: 1).write(to: out.appendingPathComponent("background.png"))
try draw(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
