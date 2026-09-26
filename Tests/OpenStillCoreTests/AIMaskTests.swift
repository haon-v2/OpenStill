import Foundation
import CoreImage
import Testing
import UniformTypeIdentifiers
@testable import OpenStillCore

@Suite struct AIMaskTests {
    func pixels(_ image: CIImage) -> [Float] {
        let w = Int(image.extent.width), h = Int(image.extent.height); var p = [Float](repeating: 0, count: w * h * 4)
        ModernRenderer.context.render(image, toBitmap: &p, rowBytes: w * 16, bounds: image.extent, format: .RGBAf, colorSpace: ModernRenderer.workingSpace); return p
    }
    /// Top row first: p[(row * w + x) * 4].
    func value(_ p: [Float], _ w: Int, _ x: Int, _ row: Int) -> Float { p[(row * w + x) * 4] }
    /// A grayscale asset that is white at the top (near) and black at the bottom (far).
    func verticalDepth(_ size: CGSize) throws -> String {
        let gradient = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0, y: size.height),
                                                                      "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 1, blue: 1)])!.outputImage!
        let asset = try EditStorage.newAsset(); try PhotoEditor.write(try AIMasks.grayscale(gradient.cropped(to: CGRect(origin: .zero, size: size)), size: size), to: asset)
        return asset.lastPathComponent
    }
    /// Near (white) on the left half, far (black) on the right.
    func splitDepth(_ size: CGSize) throws -> String {
        let bounds = CGRect(origin: .zero, size: size)
        let left = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
        let image = left.composited(over: CIImage(color: .black).cropped(to: bounds))
        let asset = try EditStorage.newAsset(); try PhotoEditor.write(try AIMasks.grayscale(image, size: size), to: asset)
        return asset.lastPathComponent
    }

    @Test func depthRangeSelectsANearFarBand() throws {
        let size = CGSize(width: 100, height: 80)
        var mask = AdjustmentMask(kind: "depthRange"); mask.asset = try verticalDepth(size); mask.feather = 0
        var range = RangeSelection(); range.low = 0.5; range.high = 1; range.softness = 0.05; mask.range = range
        let geometry = EditGeometry(size: size, edits: PhotoEdits())
        let input = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: CGRect(origin: .zero, size: size))
        let p = pixels(try mask.coverage(geometry: geometry, lens: OpticalCorrection(), input: input, modern: true))
        #expect(value(p, 100, 50, 2) > 0.95 && value(p, 100, 50, 77) < 0.05)
        // Inverting selects the far part; a mask stack combines it like any other component.
        mask.inverted = true
        let q = pixels(try mask.coverage(geometry: geometry, lens: OpticalCorrection(), input: input, modern: true))
        #expect(value(q, 100, 50, 2) < 0.05 && value(q, 100, 50, 77) > 0.95)
        // It follows a 90° rotation like the photo.
        mask.inverted = false
        var turned = PhotoEdits(); turned.rotation = 1
        let rotated = EditGeometry(size: size, edits: turned)
        let r = pixels(try mask.coverage(geometry: rotated, lens: OpticalCorrection(), input: rotated.apply(input), modern: true))
        let w = Int(rotated.extent.width)
        #expect(abs(value(r, w, 2, 50) - value(r, w, w - 3, 50)) > 0.9)
    }

    @Test func lensBlurKeepsTheFocusBandSharp() throws {
        let size = CGSize(width: 400, height: 300)
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputColor0": CIColor.white, "inputColor1": CIColor.black, "inputWidth": 4.0, "inputCenter": CIVector(x: 0, y: 0)])!
            .outputImage!.cropped(to: CGRect(origin: .zero, size: size))
        var settings = LensBlurSettings(); settings.amount = 1; settings.focus = 1; settings.range = 0.2; settings.depthAsset = try splitDepth(size)
        let geometry = EditGeometry(size: size, edits: PhotoEdits())
        let out = pixels(try LensBlur.apply(checker, settings: settings, geometry: geometry, lens: OpticalCorrection(), modern: true))
        func variance(_ xs: Range<Int>) -> Float {
            var values: [Float] = []
            for row in 100..<200 { for x in xs { values.append(value(out, 400, x, row)) } }
            let mean = values.reduce(0, +) / Float(values.count)
            return values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)
        }
        let sharp = variance(40..<160), soft = variance(260..<380)
        #expect(sharp > 0.15 && soft < 0.03)
        // No depth map or no amount: unchanged.
        var off = settings; off.amount = 0
        #expect(pixels(try LensBlur.apply(checker, settings: off, geometry: geometry, lens: OpticalCorrection(), modern: true)) == pixels(checker))
        #expect(!LensBlurSettings().hasEffect)
    }

    @Test func lensBlurRunsInThePipelineAndSurvivesSaving() throws {
        let size = CGSize(width: 200, height: 150)
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputColor0": CIColor(red: 0.8, green: 0.8, blue: 0.8), "inputColor1": CIColor(red: 0.1, green: 0.1, blue: 0.1), "inputWidth": 3.0, "inputCenter": CIVector(x: 0, y: 0)])!
            .outputImage!.cropped(to: CGRect(origin: .zero, size: size))
        var edits = PhotoEdits()
        var blur = LensBlurSettings(); blur.amount = 1; blur.focus = 1; blur.range = 0.1; blur.depthAsset = try splitDepth(size); blur.depthSource = "subject"
        edits.lensBlur = blur
        let saved = try JSONDecoder().decode(PhotoEdits.self, from: JSONEncoder().encode(edits))
        #expect(saved.lensBlur == blur && saved.lensBlurAmount == 1)
        let processed = pixels(try PhotoEditor.process(checker, sourceSize: size, edits: saved, modern: true))
        let untouched = pixels(try PhotoEditor.process(checker, sourceSize: size, edits: saved, modern: true, stopBeforeTool: "Lens blur"))
        #expect(processed != untouched)
        // The near half matches the input; only the far half changed.
        #expect(abs(value(processed, 200, 20, 75) - value(untouched, 200, 20, 75)) < 0.01)
        // Sanitizing
        var bad = LensBlurSettings(); bad.amount = .nan; bad.focus = 3; bad.range = -1
        let clean = bad.sanitized
        #expect(clean.amount == 0 && clean.focus == 1 && clean.range == 0)
        // Presets from the app don't carry a photo's depth map; the setter stores nil at the default.
        var cleared = saved; cleared.lensBlur = LensBlurSettings()
        #expect(cleared.advanced?.lensBlur == nil)
    }

    @Test func helpers() throws {
        let hull = AIMasks.convexHull([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10), CGPoint(x: 5, y: 5), CGPoint(x: 3, y: 7)])
        #expect(hull.count == 4 && !hull.contains(CGPoint(x: 5, y: 5)))
        // Depth maps are stretched to use the full range.
        let size = CGSize(width: 40, height: 40)
        let flat = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 40, y: 0),
                                                                  "inputColor0": CIColor(red: 0.2, green: 0.2, blue: 0.2), "inputColor1": CIColor(red: 0.6, green: 0.6, blue: 0.6)])!.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
        let stretched = pixels(CIImage(cgImage: try AIMasks.normalized(flat, size: size)))
        #expect(value(stretched, 40, 0, 20) < 0.05 && value(stretched, 40, 39, 20) > 0.95)
        // Skin tones of light and dark complexions pass; blue, green and gray don't.
        func skin(_ r: Double, _ g: Double, _ b: Double) -> Float {
            let patch = CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
            return pixels(AIMasks.skinKernel!.apply(extent: patch.extent, arguments: [patch])!)[0]
        }
        #expect(skin(0.85, 0.65, 0.52) > 0.9 && skin(0.45, 0.30, 0.22) > 0.9)
        #expect(skin(0.2, 0.3, 0.8) < 0.05 && skin(0.3, 0.7, 0.3) < 0.05 && skin(0.5, 0.5, 0.5) < 0.05)
        #expect(AIMaskKind.allCases.allSatisfy { !$0.title.isEmpty })
    }

    @Test func emptyPhotosReportNothingFound() throws {
        let context = CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        let plain = context.makeImage()!
        #expect(throws: (any Error).self) { try AIMasks.face(plain, part: .eyes) }
        #expect(throws: (any Error).self) { try AIMasks.people(plain) }
        // A JPEG has no depth data.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nodepth-\(UUID().uuidString).jpg")
        try PhotoEditor.write(plain, to: url, type: .jpeg); defer { try? FileManager.default.removeItem(at: url) }
        #expect(AIMasks.embeddedDepth(url, size: CGSize(width: 160, height: 120)) == nil)
    }

    @Test func rawDenoiseKeepsEditsLive() throws {
        var edits = PhotoEdits(); edits.exposure = 1; edits.temperature = 5200; edits.ensureAdvanced(); edits.advanced!.rawRecovery = 4
        edits.setMask(AdjustmentMask(kind: "radial"), for: "Develop")
        let decode = RawDenoiseBase.decodeOnly(edits)
        #expect(decode.exposure == 0 && decode.temperature == 5200 && decode.advanced?.rawRecovery == 4 && decode.advanced?.masks.isEmpty == true)
        // A denoised base keeps its baked white balance until the temperature changes.
        let base = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        let asset = try EditStorage.newAsset(extension: "osfloat"); try FloatImageBridge.write(base, to: asset)
        var denoised = PhotoEdits(); denoised.baseAsset = asset.lastPathComponent; denoised.temperature = 5200; denoised.ensureAdvanced()
        denoised.advanced!.rawDenoise = RawDenoiseBase(temperature: 5200, tint: 0)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("unused.dng")
        func render(_ e: PhotoEdits) throws -> [Float] { pixels(try ModernRenderer.render(source: source, recipe: RenderRecipe(renderer: .linear2020, sourceMode: .raw, edits: e))) }
        let same = try render(denoised)
        #expect(abs(same[0] - same[2]) < 0.01)   // still neutral: not balanced twice
        var warmer = denoised; warmer.temperature = 7500
        let warm = try render(warmer)
        #expect(warm[0] > warm[2] + 0.02)
        let saved = try JSONDecoder().decode(PhotoEdits.self, from: JSONEncoder().encode(denoised))
        #expect(saved.advanced?.rawDenoise == RawDenoiseBase(temperature: 5200, tint: 0))
    }
}
