// Draws the background for the Keelson DMG window.
// Usage: swift scripts/dmg-background.swift <out.png> <scale>
// Window content is 660x400 points (428 with the title bar); icons sit at (170, 190) and (490, 190).
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let scale = Double(args[2]) else {
    FileHandle.standardError.write("usage: dmg-background.swift <out.png> <scale>\n".data(using: .utf8)!)
    exit(1)
}
let size = NSSize(width: 660, height: 400)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Light background with a soft teal glow, matching the app icon colours.
NSGradient(colors: [NSColor(srgbRed: 0.97, green: 0.98, blue: 0.99, alpha: 1),
                    NSColor(srgbRed: 0.90, green: 0.94, blue: 0.97, alpha: 1)])!
    .draw(in: NSRect(origin: .zero, size: size), angle: -90)
NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.70, blue: 0.70, alpha: 0.10), .clear])!
    .draw(fromCenter: NSPoint(x: 330, y: 210), radius: 0, toCenter: NSPoint(x: 330, y: 210), radius: 300, options: [])

let navy = NSColor(srgbRed: 0.08, green: 0.16, blue: 0.29, alpha: 1)
let teal = NSColor(srgbRed: 0.13, green: 0.62, blue: 0.64, alpha: 1)

func drawCentered(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let s = NSAttributedString(string: text, attributes: attrs)
    let w = s.size().width
    s.draw(at: NSPoint(x: (size.width - w) / 2, y: y))
}

// Title (AppKit's y axis points up; Finder's icon positions point down).
drawCentered("Keelson", y: 330, font: .systemFont(ofSize: 26, weight: .bold), color: navy)
drawCentered("Drag Keelson to Applications to install", y: 306, font: .systemFont(ofSize: 13, weight: .regular),
             color: navy.withAlphaComponent(0.65))

// Arrow between the two icons (icon centres at y = 400 - 190 = 210).
let arrow = NSBezierPath()
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 262, y: 210))
arrow.line(to: NSPoint(x: 392, y: 210))
arrow.move(to: NSPoint(x: 374, y: 226))
arrow.line(to: NSPoint(x: 394, y: 210))
arrow.line(to: NSPoint(x: 374, y: 194))
teal.setStroke()
arrow.stroke()

drawCentered("Windows 11 guests also need:  brew install qemu swtpm", y: 72,
             font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: navy.withAlphaComponent(0.55))
drawCentered("First launch: right-click Keelson ▸ Open", y: 52,
             font: .systemFont(ofSize: 11, weight: .regular), color: navy.withAlphaComponent(0.55))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
