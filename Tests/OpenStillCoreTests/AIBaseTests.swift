import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

/// The on-device AI tools must not bake in (or zoom to) the crop, and must keep every setting live.
@Suite final class AIBaseTests {
    let context = CIContext()
    var assets: [URL] = []
    deinit { for url in assets { try? FileManager.default.removeItem(at: url) } }

    /// An 80 × 60 photo with a different color in each quarter, so crops and rotations show.
    func photo() throws -> CGImage {
        func block(_ r: Double, _ g: Double, _ b: Double, _ x: Double, _ y: Double) -> CIImage {
            CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: CGRect(x: x, y: y, width: 40, height: 30))
        }
        let image = block(0.8, 0.2, 0.2, 0, 0).composited(over: block(0.2, 0.8, 0.2, 40, 0))
            .composited(over: block(0.2, 0.2, 0.8, 0, 30)).composited(over: block(0.8, 0.8, 0.2, 40, 30))
        return try #require(context.createCGImage(image, from: CGRect(x: 0, y: 0, width: 80, height: 60)))
    }
    func asset(_ image: CGImage) throws -> String {
        let url = try EditStorage.newAsset(); assets.append(url)
        try PhotoEditor.write(image, to: url)
        return url.lastPathComponent
    }
    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Double] {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return data.prefix(3).map { Double($0) / 255 }
    }

    @Test func eraseKeepsTheCropAndEverySetting() throws {
        let original = try photo()
        var edits = PhotoEdits()
        edits.crop = EditRect(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)); edits.rotation = 1; edits.exposure = 0.3; edits.straighten = 2
        // The tool gets the photo itself: full size, no crop, rotation or tone.
        let inputEdits = AIBase.inputEdits(edits, raw: false)
        #expect(inputEdits.crop == nil && inputEdits.rotation == 0 && inputEdits.exposure == 0 && inputEdits.straighten == 0)
        let input = try PhotoEditor.render(original, edits: inputEdits)
        #expect(input.width == 80 && input.height == 60)
        // Simulate the worker: the input with a small patch "erased" (painted white) inside the crop.
        let patch = CGRect(x: 36, y: 26, width: 8, height: 8)
        let erased = CIImage(color: .white).cropped(to: patch).composited(over: CIImage(cgImage: input))
        let output = try asset(try #require(context.createCGImage(erased, from: CGRect(x: 0, y: 0, width: 80, height: 60))))
        let maskImage = CIImage(color: .white).cropped(to: patch).composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 60)))
        let mask = try asset(try #require(context.createCGImage(maskImage, from: CGRect(x: 0, y: 0, width: 80, height: 60))))
        let result = AIBase.result(edits, output: output, background: try asset(input), mask: mask, key: "Erase", raw: false)
        // Every setting stays live.
        #expect(result.crop == edits.crop && result.rotation == 1 && result.exposure == 0.3 && result.straighten == 2 && result.baseAsset == output)
        // The bug: the result was rendered at the crop of the crop (zoomed in). Now it's the same frame as before.
        let before = try PhotoEditor.render(original, edits: edits), after = try PhotoEditor.render(original, edits: result)
        #expect(after.width == before.width && after.height == before.height)
        // Away from the erased patch the photo looks the same; on it, it changed.
        for (x, y) in [(1, 1), (before.width - 2, before.height - 2), (1, before.height - 2)] {
            #expect(zip(pixel(before, x, y), pixel(after, x, y)).allSatisfy { abs($0 - $1) < 0.03 }, "\(x),\(y)")
        }
        let centre = (before.width / 2, before.height / 2)
        #expect(zip(pixel(before, centre.0, centre.1), pixel(after, centre.0, centre.1)).contains { abs($0 - $1) > 0.1 })
        // A second AI tool starts from this result, limited the same way.
        let again = AIBase.inputEdits(result, raw: false)
        #expect(again.baseAsset == output && again.advanced?.aiFeatureKey == "Erase" && again.crop == nil)
    }
    /// The bug users saw: on screen the photo renders at preview size, but the image under an erase result was read at
    /// full size, so the frame showed a zoomed-in corner of it. Rendered with the real (modern) renderer at preview size.
    @Test func eraseResultRendersInPlaceAtPreviewSize() throws {
        let original = try photo()
        func floatAsset(_ image: CIImage) throws -> String {
            let url = try EditStorage.newAsset(extension: "osfloat"); assets.append(url)
            try FloatImageBridge.write(image, to: url); return url.lastPathComponent
        }
        let input = CIImage(cgImage: original), frame = CGRect(x: 0, y: 0, width: 80, height: 60)
        let patch = CGRect(x: 36, y: 26, width: 8, height: 8)
        let output = try floatAsset(CIImage(color: .white).cropped(to: patch).composited(over: input).cropped(to: frame))
        let background = try floatAsset(input)
        let maskImage = CIImage(color: .white).cropped(to: patch).composited(over: CIImage(color: .black).cropped(to: frame))
        let mask = try asset(try #require(context.createCGImage(maskImage, from: frame)))
        var edits = PhotoEdits(); edits.crop = EditRect(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)); edits.exposure = 0.3
        let result = AIBase.result(edits, output: output, background: background, mask: mask, key: "Erase", raw: false)
        var plain = edits; plain.baseAsset = output   // the same new base, without the selection blend
        for size in [40, 80] {
            let blended = try ModernRenderer.process(input, edits: result, maximumDimension: size)
            let reference = try ModernRenderer.process(input, edits: plain, maximumDimension: size)
            #expect(blended.extent.size == reference.extent.size, "\(size)")
            let a = try #require(context.createCGImage(blended, from: blended.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
            let b = try #require(context.createCGImage(reference, from: reference.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
            for (x, y) in [(1, 1), (a.width - 2, 1), (1, a.height - 2), (a.width - 2, a.height - 2), (a.width / 2, a.height / 2)] {
                #expect(zip(pixel(a, x, y), pixel(b, x, y)).allSatisfy { abs($0 - $1) < 0.04 }, "\(size): \(x),\(y) \(pixel(a, x, y)) vs \(pixel(b, x, y))")
            }
        }
    }
    @Test func rawResultsKeepWhiteBalanceAdjustable() {
        var edits = PhotoEdits(); edits.temperature = 5200; edits.tint = 8; edits.exposure = -0.4
        let input = AIBase.inputEdits(edits, raw: true)
        #expect(input.temperature == 5200 && input.exposure == 0)
        let result = AIBase.result(edits, output: "out.osfloat", background: "in.osfloat", mask: "mask.png", key: "Noise removal", raw: true)
        #expect(result.advanced?.rawDenoise == RawDenoiseBase(temperature: 5200, tint: 8) && result.exposure == -0.4)
        #expect(result.advanced?.aiBackgroundAsset == nil)   // the base already carries its white balance; no unbalanced blend
    }
}
