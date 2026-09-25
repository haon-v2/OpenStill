import AppKit
import ImageIO
import UniformTypeIdentifiers

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for (index, name) in ["Coast-01.jpg", "Coast-02.jpg", "Coast-10.jpg"].enumerated() {
    let width = 3600, height = 2400
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let colors = [CGColor(red: 0.12, green: 0.24, blue: 0.30, alpha: 1), CGColor(red: 0.75, green: 0.77, blue: 0.66, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: width, y: height), options: [])
    ctx.setFillColor(CGColor(red: 0.89, green: 0.76, blue: 0.53, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 2400 - index * 600, y: 1550, width: 330, height: 330))
    for layer in 0..<4 {
        ctx.setFillColor(CGColor(red: 0.08 + Double(layer) * 0.04, green: 0.17 + Double(layer) * 0.06, blue: 0.19 + Double(layer) * 0.05, alpha: 1))
        ctx.beginPath()
        ctx.move(to: .zero)
        for x in stride(from: 0, through: width, by: 30) {
            let y = 250 + layer * 250 + Int(sin(Double(x) / 570 + Double(layer + index)) * 160)
            ctx.addLine(to: CGPoint(x: x, y: y))
        }
        ctx.addLine(to: CGPoint(x: width, y: 0)); ctx.closePath(); ctx.fillPath()
    }
    let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    let metadata: [CFString: Any] = [
        kCGImagePropertyTIFFDictionary: ["Make": "Canon", "Model": "Canon EOS R5"],
        kCGImagePropertyExifDictionary: ["LensMake": "Canon", "LensModel": "RF24-70mm F2.8 L IS USM", "ExposureTime": 0.004, "FNumber": 5.6, "ISOSpeedRatings": [100], "FocalLength": 35 + index * 15, "FocalLenIn35mmFilm": 35 + index * 15, "ExposureBiasValue": 0, "DateTimeOriginal": "2026:09:24 08:15:30"],
        kCGImagePropertyOrientation: index == 1 ? 6 : 1
    ]
    CGImageDestinationAddImage(destination, ctx.makeImage()!, metadata as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not save fixture") }
}
try Data("This is an intentionally corrupt QA fixture.".utf8).write(to: folder.appendingPathComponent("Corrupt.jpg"))
print(folder.path)
