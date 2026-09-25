import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for retina in [1, 2] {
        let pixels = size * retina
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let base = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 208, yRadius: 208)
        NSGradient(starting: NSColor(calibratedWhite: 0.20, alpha: 1), ending: NSColor(calibratedWhite: 0.075, alpha: 1))!.draw(in: base, angle: -90)
        let frame = NSBezierPath(roundedRect: NSRect(x: 216, y: 264, width: 592, height: 496), xRadius: 62, yRadius: 62)
        NSColor(calibratedRed: 0.80, green: 0.92, blue: 0.84, alpha: 1).setStroke()
        frame.lineWidth = 32
        frame.stroke()
        let mountain = NSBezierPath()
        mountain.move(to: NSPoint(x: 218, y: 353))
        mountain.line(to: NSPoint(x: 390, y: 536))
        mountain.line(to: NSPoint(x: 510, y: 413))
        mountain.line(to: NSPoint(x: 615, y: 515))
        mountain.line(to: NSPoint(x: 804, y: 325))
        mountain.lineJoinStyle = .round
        mountain.lineCapStyle = .round
        mountain.lineWidth = 32
        mountain.stroke()
        NSColor(calibratedRed: 0.80, green: 0.92, blue: 0.84, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 581, y: 582, width: 91, height: 91)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = retina == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
