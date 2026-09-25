import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

@Suite final class DevelopToolsTests {
    let context = CIContext()
    /// 200×120 sRGB image drawn by `paint`, with values given as sRGB-encoded 0…1 components.
    func image(_ paint: (CGContext) -> Void) throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        paint(ctx); return try #require(ctx.makeImage())
    }
    func fill(_ ctx: CGContext, _ rect: CGRect, _ r: Double, _ g: Double, _ b: Double) { ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1)); ctx.fill(rect) }
    func solid(_ r: Double, _ g: Double, _ b: Double) throws -> CGImage { try image { self.fill($0, CGRect(x: 0, y: 0, width: 200, height: 120), r, g, b) } }
    /// RGBA at (x, y) with y measured from the top, like CGContext bitmaps are stored.
    func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [Int] {
        let ctx = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(ctx.data).assumingMemoryBound(to: UInt8.self), i = (y*image.width+x)*4
        return (0..<4).map { Int(data[i+$0]) }
    }
    func render(_ source: CGImage, _ edits: PhotoEdits) throws -> CGImage { try PhotoEditor.render(source, edits: edits) }

    @Test func zeroSettingsAreExactIdentityAndStoreNothing() throws {
        let input = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        #expect(try DevelopTools.clarity(input, amount: 0) === input)
        #expect(try DevelopTools.texture(input, amount: 0) === input)
        #expect(try DevelopTools.dehaze(input, amount: 0) === input)
        #expect(try DevelopTools.colorGrade(input, settings: ColorGrading()) === input)
        #expect(try DevelopTools.grain(input, settings: GrainSettings()) === input)
        #expect(try DevelopTools.defringe(input, settings: DefringeSettings()) === input)
        var e = PhotoEdits(); e.clarity = 0.4; e.clarity = 0; e.grainAmount = 0.5; e.grainAmount = 0
        #expect(e.advanced?.clarity == nil); #expect(e.advanced?.grain == nil)
        e.grainSize = 0.8
        #expect(e.advanced?.grain?.size == 0.8)
    }
    @Test func settingsAreSanitized() {
        var e = PhotoEdits(); e.clarity = .nan; e.texture = 5; e.dehaze = -.infinity
        var grading = ColorGrading(); grading.shadows = GradeWheel(hue: 400, saturation: 2, luminance: -3); grading.blending = .nan
        e.colorGrading = grading; e.grainAmount = 7
        var fringe = DefringeSettings(); fringe.purpleLow = 340; fringe.purpleHigh = 300; e.defringe = fringe
        let s = e.sanitized
        #expect(s.clarity == 0); #expect(s.texture == 1); #expect(s.dehaze == 0)
        #expect(s.colorGrading.shadows == GradeWheel(hue: 40, saturation: 1, luminance: -1)); #expect(s.colorGrading.blending == 0.5)
        #expect(s.grain.amount == 1); #expect(s.defringe.purpleHigh >= s.defringe.purpleLow)
    }
    @Test func clarityChangesContrastAcrossEdges() throws {
        let stripes = try image { ctx in
            self.fill(ctx, CGRect(x: 0, y: 0, width: 200, height: 120), 0.35, 0.35, 0.35)
            for x in stride(from: 0, to: 200, by: 40) { self.fill(ctx, CGRect(x: x, y: 0, width: 20, height: 120), 0.6, 0.6, 0.6) }
        }
        func edgeContrast(_ image: CGImage) throws -> Int { try pixel(image, 18, 60)[0] - pixel(image, 22, 60)[0] }
        var e = PhotoEdits(); let base = try edgeContrast(render(stripes, e))
        e.clarity = 1; let more = try edgeContrast(render(stripes, e))
        e.clarity = -1; let less = try edgeContrast(render(stripes, e))
        #expect(more > base + 4); #expect(less < base - 4)
        // An empty mask keeps the photo unchanged.
        e.clarity = 1; e.setMask(AdjustmentMask(), for: "Clarity")
        #expect(try edgeContrast(render(stripes, e)) == base)
    }
    @Test func textureChangesMediumDetail() throws {
        let checker = try image { ctx in
            self.fill(ctx, CGRect(x: 0, y: 0, width: 200, height: 120), 0.4, 0.4, 0.4)
            for x in stride(from: 0, to: 200, by: 4) { for y in stride(from: 0, to: 120, by: 4) where (x/4 + y/4) % 2 == 0 { self.fill(ctx, CGRect(x: x, y: y, width: 4, height: 4), 0.5, 0.5, 0.5) } }
        }
        func amplitude(_ image: CGImage) throws -> Int { abs(try pixel(image, 101, 61)[0] - pixel(image, 105, 61)[0]) }
        var e = PhotoEdits(); let base = try amplitude(render(checker, e))
        e.texture = 1; #expect(try amplitude(render(checker, e)) > base + 2)
        e.texture = -1; #expect(try amplitude(render(checker, e)) < base - 2)
    }
    @Test func dehazeRestoresContrastAndNegativeAddsHaze() throws {
        let hazy = try image { ctx in
            self.fill(ctx, CGRect(x: 0, y: 0, width: 200, height: 120), 0.72, 0.74, 0.78)
            self.fill(ctx, CGRect(x: 70, y: 30, width: 60, height: 60), 0.55, 0.57, 0.62)
        }
        func contrast(_ image: CGImage) throws -> Int { try pixel(image, 10, 10)[1] - pixel(image, 100, 60)[1] }
        var e = PhotoEdits(); let base = try contrast(render(hazy, e))
        e.dehaze = 0.8; #expect(try contrast(render(hazy, e)) > base + 10)
        e.dehaze = -0.8; #expect(try contrast(render(hazy, e)) < base - 5)
        // Modern pipeline too.
        let source = CIImage(cgImage: hazy)
        e.dehaze = 0.8
        let modern = try context.createCGImage(ModernRenderer.process(source, edits: e), from: source.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        #expect(try contrast(#require(modern)) > base + 10)
    }
    @Test func colorGradingTintsEachTonalRange() throws {
        var grading = ColorGrading()
        grading.shadows = GradeWheel(hue: 240, saturation: 1); grading.highlights = GradeWheel(hue: 30, saturation: 1)
        var e = PhotoEdits(); e.colorGrading = grading
        let dark = try pixel(render(solid(0.15, 0.15, 0.15), e), 100, 60)
        let bright = try pixel(render(solid(0.9, 0.9, 0.9), e), 100, 60)
        let mid = try pixel(render(solid(0.5, 0.5, 0.5), e), 100, 60)
        #expect(dark[2] > dark[0] + 10); #expect(bright[0] > bright[2] + 10)
        #expect(abs(mid[0] - mid[2]) <= 3)
        grading = ColorGrading(); grading.global.luminance = 1; e.colorGrading = grading
        #expect(try pixel(render(solid(0.5, 0.5, 0.5), e), 100, 60)[0] > mid[0] + 20)
    }
    @Test func grainIsDeterministicAndVisible() throws {
        let gray = try solid(0.5, 0.5, 0.5)
        var e = PhotoEdits(); e.grainAmount = 1
        let first = try render(gray, e), second = try render(gray, e)
        let row = try (0..<60).map { try pixel(first, 70 + $0, 60)[1] }
        #expect(Set(row).count > 5)
        #expect(try (0..<60).allSatisfy { try pixel(second, 70 + $0, 60)[1] == row[$0] })
        let mean = Double(row.reduce(0, +)) / Double(row.count), original = try pixel(gray, 100, 60)[1]
        #expect(abs(mean - Double(original)) < 12)
    }
    @Test func defringeRemovesEdgeFringesButKeepsPurpleAreas() throws {
        let photo = try image { ctx in
            self.fill(ctx, CGRect(x: 0, y: 0, width: 200, height: 120), 0.05, 0.05, 0.05)
            self.fill(ctx, CGRect(x: 60, y: 0, width: 50, height: 120), 1, 1, 1)
            self.fill(ctx, CGRect(x: 57, y: 0, width: 3, height: 120), 0.6, 0.2, 0.75)
            self.fill(ctx, CGRect(x: 140, y: 30, width: 55, height: 60), 0.6, 0.2, 0.75)
        }
        var e = PhotoEdits(); e.defringePurple = 1
        let fixed = try render(photo, e), fringe = try pixel(fixed, 58, 60), area = try pixel(fixed, 167, 60)
        let before = try pixel(photo, 58, 60)
        #expect(abs(fringe[0] - fringe[1]) < abs(before[0] - before[1]) / 2)
        #expect(area[2] - area[1] > 80)
    }
    @Test func autoToneBrightensDarkAndTamesBrightPhotos() {
        func histogram(at value: Double, spread: Int = 6) -> PhotoHistogram {
            var h = PhotoHistogram(); let center = Int(value*255)
            for i in max(0, center-spread)...min(255, center+spread) { h.luminance[i] = 100 }
            return h
        }
        let dark = AutoTone.apply(histogram(at: 0.12), to: PhotoEdits())
        #expect(dark.exposure > 0.5); #expect(dark.contrast > 1)
        let bright = AutoTone.apply(histogram(at: 0.85), to: PhotoEdits())
        #expect(bright.exposure < 0)
        let wide = AutoTone.apply(histogram(at: 0.5, spread: 127), to: PhotoEdits())
        #expect(abs(wide.exposure) < 0.3)
        #expect(AutoTone.apply(PhotoHistogram(), to: PhotoEdits()) == PhotoEdits())
        var kept = PhotoEdits(); kept.temperature = 7000; kept.clarity = 0.3
        let result = AutoTone.apply(histogram(at: 0.3), to: kept)
        #expect(result.temperature == 7000 && result.clarity == 0.3)
    }
    @Test func clippingOverlayMatchesClippedPixels() throws {
        let photo = try image { ctx in
            self.fill(ctx, CGRect(x: 0, y: 0, width: 200, height: 120), 0.5, 0.5, 0.5)
            self.fill(ctx, CGRect(x: 0, y: 0, width: 40, height: 120), 1, 1, 1)
            self.fill(ctx, CGRect(x: 160, y: 0, width: 40, height: 120), 0, 0, 0)
        }
        let overlay = try #require(ClippingOverlay.render(photo))
        let white = try pixel(overlay, 20, 60), black = try pixel(overlay, 180, 60), mid = try pixel(overlay, 100, 60)
        #expect(white[3] > 150 && white[0] > white[2]); #expect(black[3] > 150 && black[2] > black[0]); #expect(mid[3] == 0)
    }
    @Test func beforeFrameKeepsOnlyGeometry() {
        var e = PhotoEdits(); e.exposure = 1; e.clarity = 0.5; e.rotation = 1; e.crop = EditRect(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)); e.straighten = 3
        let before = ClippingOverlay.geometryOnly(e)
        #expect(before.exposure == 0 && before.clarity == 0)
        #expect(before.rotation == 1 && before.crop == e.crop && before.straighten == 3)
    }
    @Test func persistenceHistoryAndBatchCopy() throws {
        var e = PhotoEdits(); e.clarity = 0.4; e.texture = -0.2; e.dehaze = 0.3; e.grainAmount = 0.5
        var grading = ColorGrading(); grading.midtones = GradeWheel(hue: 120, saturation: 0.4, luminance: 0.1); e.colorGrading = grading
        e.defringePurple = 0.6
        let decoded = try JSONDecoder().decode(PhotoEdits.self, from: JSONEncoder().encode(e))
        #expect(decoded == e)
        // Edits saved before these tools existed still decode.
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode({ var x = PhotoEdits(); x.exposure = 1; x.ensureAdvanced(); return x }())) as? [String: Any])
        var advanced = try #require(old["advanced"] as? [String: Any])
        for key in ["clarity", "texture", "dehaze", "colorGrading", "grain", "defringe"] { advanced.removeValue(forKey: key) }
        old["advanced"] = advanced
        let legacy = try JSONDecoder().decode(PhotoEdits.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(legacy.exposure == 1 && legacy.clarity == 0 && legacy.colorGrading.isIdentity)
        var doc = EditDocument(fingerprint: "fixture"); doc.commit(e, title: "Clarity"); doc.undo()
        #expect(doc.current.clarity == 0); doc.redo(); #expect(doc.current.clarity == 0.4)
        var options = BatchOptions(); options.groups = [.presence, .grading, .grain, .lens]
        let copied = try BatchEdits.merging(e, into: PhotoEdits(), options: options, geometryCompatible: true)
        #expect(copied.clarity == 0.4 && copied.texture == -0.2 && copied.dehaze == 0.3)
        #expect(copied.colorGrading == e.colorGrading && copied.grain == e.grain && copied.defringe == e.defringe)
        options.groups = [.develop]
        let untouched = try BatchEdits.merging(e, into: PhotoEdits(), options: options, geometryCompatible: true)
        #expect(untouched.clarity == 0 && untouched.grain.amount == 0)
    }
}
