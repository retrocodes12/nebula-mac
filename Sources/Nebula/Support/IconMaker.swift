import AppKit

/// `Nebula --icon <file.png>` draws the app icon at 1024: the Mac's rounded square in Nebula's
/// near-black, the red disc and the play triangle. The build turns it into the .icns.
enum IconMaker {
    static func run(_ path: String) -> Never {
        let px = 1024
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        // Apple's grid: an 824-point square on the 1024 canvas, corners at 22.37 % of its side
        let box = NSRect(x: 100, y: 100, width: 824, height: 824)
        let plate = NSBezierPath(roundedRect: box, xRadius: 184, yRadius: 184)
        NSGradient(colors: [NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1), NSColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 1)])?.draw(in: plate, angle: -90)
        NSColor(white: 1, alpha: 0.08).setStroke()
        plate.lineWidth = 3
        plate.stroke()
        NSColor(srgbRed: 0.898, green: 0.035, blue: 0.078, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 512 - 290, y: 512 - 290, width: 580, height: 580)).fill()
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: 512 - 105, y: 512 + 150))
        tri.line(to: NSPoint(x: 512 + 165, y: 512))
        tri.line(to: NSPoint(x: 512 - 105, y: 512 - 150))
        tri.close()
        tri.lineJoinStyle = .round
        NSColor.white.setFill()
        tri.fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { exit(1) }
        exit(0)
    }
}
