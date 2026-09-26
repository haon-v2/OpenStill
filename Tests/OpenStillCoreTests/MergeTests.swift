import Foundation
import CoreImage
import Testing
import simd
@testable import OpenStillCore

@Suite struct MergeTests {
    /// RGBA at a Core Image pixel (origin bottom left), in the linear working space.
    func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> [Float] {
        var p = [Float](repeating: 0, count: 4)
        Merges.context.render(image, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: ModernRenderer.workingSpace)
        return p
    }
    /// Blurred noise stretched to 0…1: texture Vision can register, with no repeating pattern.
    func texture(_ size: CGSize, radius: Double = 1.5, offset: CGPoint = .zero) -> CIImage {
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.transformed(by: CGAffineTransform(translationX: -offset.x, y: -offset.y)).applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        let v = CIVector(x: 2.5, y: 2.5, z: 2.5, w: 0)
        return noise.applyingFilter("CIColorMatrix", parameters: ["inputRVector": v, "inputGVector": v, "inputBVector": v, "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: -3.25, y: -3.25, z: -3.25, w: 1)])
            .applyingFilter("CIColorClamp").cropped(to: CGRect(origin: .zero, size: size))
    }
    /// Whole image, top row first: p[(row * w + x) * 4].
    func pixels(_ image: CIImage) -> [Float] {
        let w = Int(image.extent.width), h = Int(image.extent.height); var p = [Float](repeating: 0, count: w * h * 4)
        Merges.context.render(image, toBitmap: &p, rowBytes: w * 16, bounds: image.extent, format: .RGBAf, colorSpace: ModernRenderer.workingSpace); return p
    }
    /// Scales every channel by `gain` and adds `bias` (no clamping: values above 1 survive in float).
    func scaled(_ image: CIImage, _ gain: Double, _ bias: Double = 0) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0), "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)])
    }
    /// A flat color in the linear working space (plain CIColor values would be read as sRGB).
    func flat(_ r: Double, _ g: Double, _ b: Double) -> CIImage { CIImage(color: CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: ModernRenderer.workingSpace)!) }
    func clipped(_ image: CIImage) -> CIImage { image.applyingFilter("CIColorClamp") }
    /// A scene from 0.02 (left) to 2.5 (right, brighter than white), with a little texture.
    func brightScene(_ size: CGSize) -> CIImage {
        let ramp = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: size.width, y: 0), "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 1, blue: 1)])!.outputImage!
        let base = scaled(ramp, 2.48, 0.02).cropped(to: CGRect(origin: .zero, size: size))
        return base.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: scaled(texture(size), 0.2, 0.9)]).cropped(to: CGRect(origin: .zero, size: size))
    }

    @Test(.timeLimit(.minutes(1))) func hdrMergeRecoversHighlightsAndShadows() throws {
        let size = CGSize(width: 400, height: 200), scene = brightScene(size)
        let brackets = [clipped(scaled(scene, 0.25)), clipped(scene), clipped(scaled(scene, 4))]
        var options = MergeOptions(); options.align = false
        let merged = try Merges.hdr(brackets, options: options)
        #expect(merged.extent == CGRect(origin: .zero, size: size))
        for x in [4, 60, 200, 330, 395] {
            let expected = pixel(scene, x, 100)[1], got = pixel(merged, x, 100)[1]
            #expect(abs(got - expected) / expected < 0.08, "x \(x): expected \(expected), got \(got)")
        }
        // The middle exposure clips on the right; the merge keeps the real (brighter than white) value.
        #expect(pixel(merged, 380, 100)[1] > 1.5)
    }

    @Test(.timeLimit(.minutes(1))) func deghostingTakesMovingThingsFromTheReference() throws {
        let size = CGSize(width: 200, height: 120), bounds = CGRect(origin: .zero, size: size)
        let scene = flat(0.4, 0.4, 0.4).cropped(to: bounds)
        // Something dark moved into the middle exposure only.
        let object = flat(0.1, 0.1, 0.1).cropped(to: CGRect(x: 60, y: 30, width: 60, height: 60))
        let brackets = [clipped(scaled(scene, 0.25)), object.composited(over: scene), clipped(scaled(scene, 4))]
        var options = MergeOptions(); options.align = false
        options.deghost = 1
        let clean = pixel(try Merges.hdr(brackets, options: options), 90, 60)[0]
        options.deghost = 0
        let ghosted = pixel(try Merges.hdr(brackets, options: options), 90, 60)[0]
        #expect(clean < 0.13, "deghosted \(clean)")
        #expect(ghosted > 0.18, "blended \(ghosted)")
        // Away from the object nothing changes.
        #expect(abs(pixel(try Merges.hdr(brackets, options: options), 10, 10)[0] - 0.4) < 0.02)
    }

    @Test(.timeLimit(.minutes(1))) func alignmentFindsAShift() throws {
        let scene = scaled(texture(CGSize(width: 800, height: 700), radius: 2), 0.6, 0.1)
        func frame(_ x: CGFloat, _ y: CGFloat) -> CIImage { scene.cropped(to: CGRect(x: x, y: y, width: 640, height: 480)).transformed(by: CGAffineTransform(translationX: -x, y: -y)) }
        // The floating frame was taken 17 px further left and 11 px higher.
        let reference = frame(100, 100), floating = frame(83, 111)
        let h = try #require(Merges.align(Merges.Proxy(floating), to: Merges.Proxy(reference), strict: true))
        // A point of the floating frame lands 17 px left and 11 px up in the reference.
        let p = h * SIMD3<Double>(320, 240, 1)
        #expect(abs(p.x / p.z - 303) < 2 && abs(p.y / p.z - 251) < 2, "\(p.x / p.z), \(p.y / p.z)")
    }

    @Test(.timeLimit(.minutes(2))) func panoramaJoinsOverlappingFrames() throws {
        let scene = scaled(texture(CGSize(width: 1200, height: 420), radius: 2), 0.6, 0.1)
        let frames = [0.0, 350, 700].map { x in
            scene.cropped(to: CGRect(x: x, y: 0, width: 500, height: 420)).transformed(by: CGAffineTransform(translationX: -x, y: 0))
        }
        var options = MergeOptions(); options.projection = .perspective
        let pano = try Merges.panorama(frames, options: options)
        #expect(abs(pano.extent.width - 1200) < 40 && abs(pano.extent.height - 420) < 30, "\(pano.extent)")
        // Seams blend the same content, so the result matches the scene closely.
        let a = pixel(pano, 600, 200)[0]
        #expect(a > 0.05 && a < 0.8)
        // Frames that don't overlap are reported rather than stacked.
        let unrelated = scaled(texture(CGSize(width: 500, height: 420), radius: 2, offset: CGPoint(x: 5000, y: 3000)), 0.6, 0.1)
        #expect(throws: MergeError.self) { try Merges.panorama([frames[0], unrelated], options: options) }
    }

    @Test(.timeLimit(.minutes(1))) func focusStackKeepsTheSharpestParts() throws {
        let size = CGSize(width: 300, height: 200), bounds = CGRect(origin: .zero, size: size)
        let sharp = scaled(texture(size), 0.6, 0.1)
        let soft = sharp.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 4]).cropped(to: bounds)
        let left = CGRect(x: 0, y: 0, width: 150, height: 200), right = CGRect(x: 150, y: 0, width: 150, height: 200)
        let nearFocus = sharp.cropped(to: left).composited(over: soft), farFocus = sharp.cropped(to: right).composited(over: soft)
        var options = MergeOptions(); options.align = false
        let stacked = try Merges.focusStack([nearFocus, farFocus], options: options)
        func detail(_ image: CIImage, _ xs: Range<Int>) -> Float {
            let p = pixels(image), w = Int(image.extent.width)
            var values: [Float] = []
            for row in 60..<140 { for x in xs { values.append(p[(row * w + x) * 4]) } }
            let mean = values.reduce(0, +) / Float(values.count)
            return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
        }
        for xs in [30..<120, 180..<270] {
            #expect(detail(stacked, xs) > detail(sharp, xs) * 0.7, "\(xs)")
            #expect(detail(stacked, xs) > detail(soft, xs) * 2, "\(xs)")
        }
    }

    @Test func helpers() throws {
        // Largest all-covered rectangle.
        let grid: [Bool] = [
            false, true, true, true, false,
            true, true, true, true, true,
            true, true, true, true, false,
            false, true, true, false, false,
        ]
        let r = try #require(Merges.maximalRectangle(grid, width: 5, height: 4))
        #expect(r.width * r.height == 9 && r.x == 1 && r.y == 0 && r.height == 3)
        // A cylinder narrows a wide frame and leaves the middle row in place.
        let frame = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 400))
        let wrapped = try Merges.cylindrical(frame, focal: 800)
        #expect(abs(wrapped.extent.width - (2 * 800 * atan(500.0 / 800)).rounded(.down)) < 1 && wrapped.extent.height == 400)
        #expect(pixel(wrapped, Int(wrapped.extent.width / 2), 200)[3] > 0.99)
        #expect(pixel(wrapped, 2, 2)[3] < 0.01)
        // New files never replace existing ones.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("IMG_0001.CR3")
        #expect(Merges.outputURL(for: first, kind: .hdr).lastPathComponent == "IMG_0001-HDR.tif")
        try Data().write(to: folder.appendingPathComponent("IMG_0001-Pano.tif"))
        #expect(Merges.outputURL(for: first, kind: .panorama).lastPathComponent == "IMG_0001-Pano-2.tif")
        #expect(throws: MergeError.tooFew) { try Merges.merge([first], kind: .hdr) }
    }

    @Test func floatTIFFKeepsValuesAboveWhite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tif")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = scaled(flat(1, 0.2, 0.02).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 16)), 2.5)
        try Merges.writeFloatTIFF(image, to: url)
        let back = try ModernRenderer.readImage(url)
        #expect(back.extent.size == CGSize(width: 32, height: 16))
        let p = pixel(back, 10, 8)
        #expect(abs(p[0] - 2.5) < 0.1 && abs(p[1] - 0.5) < 0.03 && abs(p[2] - 0.05) < 0.01, "\(p)")
    }
}
