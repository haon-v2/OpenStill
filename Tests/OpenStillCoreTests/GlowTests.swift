import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

@Suite final class GlowTests {
    private let context = CIContext()
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    private func fixture(_ width: Int = 320, _ height: Int = 240, uniform: Bool = false) throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: uniform ? 0.7 : 0.06, green: uniform ? 0.6 : 0.06, blue: uniform ? 0.5 : 0.06, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if !uniform {
            ctx.setFillColor(CGColor(red: 0.96, green: 0.8, blue: 0.6, alpha: 1))
            ctx.fill(CGRect(x: Double(width)*0.4, y: Double(height)*0.2, width: Double(width)*0.2, height: Double(height)*0.6))
        }
        return try #require(ctx.makeImage())
    }
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let ctx = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width*4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try #require(ctx.data).assumingMemoryBound(to: UInt8.self), count: image.width*image.height*4))
    }
    private func edits(_ mode: GlowMode = .glow, amount: Double = 80) -> PhotoEdits {
        var e = PhotoEdits(); e.glow.mode = mode; e.glow.amount = amount; return e
    }

    @Test func zeroAmountIsExactIdentityAndSettingsAreSanitized() throws {
        let input = try fixture()
        for mode in GlowMode.allCases {
            var e = edits(mode, amount: 0); e.glow.warmth = 100; e.glow.brightness = 100
            #expect(try PhotoEditor.render(input, edits: e) === input)
        }
        var e = edits(); e.glow.amount = .infinity; e.glow.softness = .nan
        e.glow.brightness = -300; e.glow.contrast = 400; e.glow.warmth = .nan
        let s = e.sanitized.glow
        #expect(s.amount == 0 && s.softness == 50 && s.brightness == -100 && s.contrast == 100 && s.warmth == 0)
    }

    @Test func glowBloomsAtLightsWithoutWashingDarkAreasAndModesDiffer() throws {
        let input = try fixture(), original = try pixels(input)
        var results: [[UInt8]] = []
        for mode in GlowMode.allCases {
            let output = try PhotoEditor.render(input, edits: edits(mode))
            #expect(output.width == input.width && output.height == input.height)
            let data = try pixels(output); results.append(data)
            #expect(data != original)
            #expect(stride(from: 3, to: data.count, by: 4).allSatisfy { data[$0] == 255 })
        }
        for a in results.indices { for b in results.indices where a < b { #expect(results[a] != results[b]) } }
        let nearLight = (120*320+126)*4, farShadow = (120*320+20)*4
        #expect(Int(results[0][nearLight]) > Int(original[nearLight])+15)
        #expect(abs(Int(results[0][farShadow])-Int(original[farShadow])) <= 1)
        #expect(Int(results[1][(120*320+130)*4]) < Int(original[(120*320+130)*4])) // edge diffusion
    }

    @Test func slidersChangeEffectAndUniformEdgesStayClean() throws {
        let input = try fixture(), baseline = try pixels(PhotoEditor.render(input, edits: edits()))
        for path in [\GlowSettings.softness, \.brightness, \.contrast, \.warmth] {
            var e = edits(); e.glow[keyPath: path] = path == \GlowSettings.softness ? 100 : -90
            #expect(try pixels(PhotoEditor.render(input, edits: e)) != baseline)
        }
        let uniform = try fixture(uniform: true)
        for mode in GlowMode.allCases {
            let data = try pixels(PhotoEditor.render(uniform, edits: edits(mode)))
            for c in 0..<3 { #expect(abs(Int(data[c])-Int(data[(120*320+160)*4+c])) <= 1) }
        }
    }

    @Test func allMaskKindsProtectPixelsAndSurviveGeometry() throws {
        let input = try fixture(uniform: true)
        let asset = try EditStorage.newAsset()
        defer { try? FileManager.default.removeItem(at: asset) }
        var linear = AdjustmentMask(kind: "linear"); linear.start = MaskPoint(CGPoint(x: 0.25, y: 0.5)); linear.end = MaskPoint(CGPoint(x: 0.75, y: 0.5))
        let raster = try #require(context.createCGImage(try linear.image(size: CGSize(width: 320, height: 240)), from: CGRect(x: 0, y: 0, width: 320, height: 240)))
        try PhotoEditor.write(raster, to: asset)
        var object = AdjustmentMask(kind: "object"); object.asset = asset.lastPathComponent
        var radial = AdjustmentMask(kind: "radial"); radial.start = MaskPoint(CGPoint(x: 0.7, y: 0.5)); radial.end = MaskPoint(CGPoint(x: 0.98, y: 0.95))
        var brush = AdjustmentMask(); brush.feather = 0.2
        brush.strokes = [MaskStroke(points: [MaskPoint(CGPoint(x: 0.7, y: 0.5))], radius: 0.22)]
        for mask in [linear, radial, brush, object] {
            var e = edits(); e.setMask(mask, for: "Glow")
            e.setMask(AdjustmentMask(), for: "Color")
            let data = try pixels(PhotoEditor.render(input, edits: e)), original = try pixels(input)
            for c in 0..<3 { #expect(abs(Int(data[(120*320+5)*4+c])-Int(original[(120*320+5)*4+c])) <= 1) }
            #expect(data[(120*320+224)*4] > original[(120*320+224)*4])
            e.rotation = 1; e.flip = true; e.straighten = 5
            e.crop = EditRect(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
            let output = try PhotoEditor.render(input, edits: e)
            #expect(output.width == 192 && output.height == 256)
            // Inverting the same mask gives complementary coverage even after geometry.
            let masked = try pixels(output)
            var inverse = mask; inverse.inverted = true; e.setMask(inverse, for: "Glow")
            let inverted = try pixels(PhotoEditor.render(input, edits: e))
            e.setMask(nil, for: "Glow"); let full = try pixels(PhotoEditor.render(input, edits: e))
            e.glow.amount = 0; let plain = try pixels(PhotoEditor.render(input, edits: e))
            // Compare after decoding sRGB to linear light, where masks are blended.
            func linearize(_ v: UInt8) -> Double { let x = Double(v)/255; return x <= 0.04045 ? x/12.92 : pow((x+0.055)/1.055, 2.4) }
            for i in stride(from: 0, to: masked.count, by: 28) {
                #expect(abs(linearize(masked[i])+linearize(inverted[i])-linearize(full[i])-linearize(plain[i])) < 0.02)
            }
        }
    }

    @Test func previewMatchesDownsampledExport() throws {
        let input = try fixture(1280, 960)
        for mode in GlowMode.allCases {
            let e = edits(mode), full = try PhotoEditor.render(input, edits: e)
            let preview = try PhotoEditor.render(input, edits: e, previewMaxDimension: 320)
            let reference = try PhotoEditor.render(full, edits: PhotoEdits(), previewMaxDimension: 320)
            let a = try pixels(preview), b = try pixels(reference)
            let mean = zip(a,b).reduce(0.0) { $0 + abs(Double($1.0)-Double($1.1)) } / Double(a.count)
            #expect(mean < 2.5)
        }
    }

    @Test func settingsHistoryPresetsAndLegacyDecoding() throws {
        var legacy = PhotoEdits(); legacy.exposure = 0.3; legacy.lutAmount = 0.7
        let oldJSON = try JSONEncoder().encode(legacy)
        #expect(!String(decoding: oldJSON, as: UTF8.self).contains("glow"))
        #expect(try JSONDecoder().decode(PhotoEdits.self, from: oldJSON).glow == GlowSettings())
        var e = legacy; e.glow = edits(.softFocus).glow
        e.setMask(AdjustmentMask(kind: "linear"), for: "Glow")
        e.advanced!.lutAsset = "existing.cube"; e.advanced!.lutID = "existing"
        var document = EditDocument(fingerprint: "fixture")
        document.commit(legacy, title: "Existing edits"); document.commit(e, title: "Glow")
        document.undo(); #expect(document.current == legacy)
        document.redo(); #expect(document.current == e)
        let saved = try JSONDecoder().decode(EditDocument.self, from: JSONEncoder().encode(document))
        #expect(saved.current == e)
        let preset = try JSONDecoder().decode(PhotoEdits.self, from: JSONEncoder().encode(e))
        #expect(preset.glow == e.glow)
        let mask = e.advanced!.masks["Glow"]
        e.glow = GlowSettings()
        #expect(e.glow.amount == 0 && e.advanced!.masks["Glow"] == mask)
        #expect(e.exposure == legacy.exposure && e.advanced!.lutAsset == "existing.cube" && e.lutAmount == 0.7)
    }
}
