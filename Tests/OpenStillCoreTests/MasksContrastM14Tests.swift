import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

@Suite struct MasksContrastM14Tests {
    let sRGB = CGColorSpace(name: CGColorSpace.extendedSRGB)!
    func solid(_ r: Double, _ g: Double, _ b: Double, size: CGFloat = 64) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }
    func pixel(_ image: CIImage, _ x: CGFloat = 0, _ y: CGFloat = 0) -> [Float] {
        var p = [Float](repeating: 0, count: 4)
        ModernRenderer.context.render(image, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: image.extent.minX + x, y: image.extent.minY + y, width: 1, height: 1), format: .RGBAf, colorSpace: sRGB)
        return p
    }
    /// A left-to-right gray ramp from black to white.
    func ramp(width: CGFloat = 256) -> CIImage {
        CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: width - 1, y: 0),
                                                        "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 1, blue: 1)])!
            .outputImage!.cropped(to: CGRect(x: 0, y: 0, width: width, height: 4))
    }

    // MARK: Mask layers
    @Test func maskLayersAreAddedDuplicatedAndRemovedWithTheirMasks() throws {
        var e = PhotoEdits()
        #expect(e.localAdjustments.isEmpty)
        let sky = e.addLocalAdjustment(named: "Sky"), ground = e.addLocalAdjustment()
        #expect(e.localAdjustments.map(\.name) == ["Sky", "Mask 2"] && sky.maskKey != ground.maskKey && sky.maskKey.hasPrefix(LocalAdjustment.keyPrefix))
        e.setMask(AdjustmentMask(kind: "linear"), for: sky.maskKey)
        e.updateLocalAdjustment(sky.id) { $0.settings.exposure = 9; $0.settings.contrast = .nan; $0.name = "   " }
        let saved = e.localAdjustments[0]
        #expect(saved.settings.exposure == 4 && saved.settings.contrast == 0 && saved.name == "Mask")
        let duplicated = e.duplicateLocalAdjustment(sky.id); let copy = try #require(duplicated)
        #expect(e.localAdjustments.count == 3 && e.advanced?.masks[copy.maskKey] != nil && copy.settings.exposure == 4)
        e.removeLocalAdjustment(sky.id)
        #expect(e.localAdjustments.count == 2 && e.advanced?.masks[sky.maskKey] == nil && e.advanced?.masks[copy.maskKey] != nil)
        // Edits saved before mask layers existed decode with none.
        let legacy = try JSONDecoder().decode(PhotoEdits.self, from: JSONEncoder().encode(PhotoEdits()))
        #expect(legacy.localAdjustments.isEmpty && !legacy.usesSmartContrast)
        let round = try JSONDecoder().decode(PhotoEdits.self, from: JSONEncoder().encode(e))
        #expect(round.localAdjustments == e.localAdjustments)
    }
    @Test func eachMaskLayerChangesOnlyItsOwnArea() throws {
        let photo = solid(0.4, 0.4, 0.4)
        let size = CGSize(width: 64, height: 64)
        var e = PhotoEdits()
        // Brighten the right side; darken the left side with a second, separate mask.
        let bright = e.addLocalAdjustment(named: "Right"), dark = e.addLocalAdjustment(named: "Left")
        var right = AdjustmentMask(kind: "linear"); right.start = MaskPoint(CGPoint(x: 0.55, y: 0.5)); right.end = MaskPoint(CGPoint(x: 0.7, y: 0.5)); right.feather = 1
        var left = AdjustmentMask(kind: "linear"); left.start = MaskPoint(CGPoint(x: 0.45, y: 0.5)); left.end = MaskPoint(CGPoint(x: 0.3, y: 0.5)); left.feather = 1
        e.setMask(right, for: bright.maskKey); e.setMask(left, for: dark.maskKey)
        e.updateLocalAdjustment(bright.id) { $0.settings.exposure = 1 }
        e.updateLocalAdjustment(dark.id) { $0.settings.exposure = -1 }
        let out = try PhotoEditor.process(photo, sourceSize: size, edits: e, modern: true)
        let l = pixel(out, 4, 32)[0], m = pixel(out, 32, 32)[0], r = pixel(out, 60, 32)[0], base = pixel(photo, 32, 32)[0]
        #expect(r > base + 0.1 && l < base - 0.1 && abs(m - base) < 0.03)
        // Hidden, neutral or unmasked layers do nothing.
        e.updateLocalAdjustment(bright.id) { $0.hidden = true }
        let hidden = try PhotoEditor.process(photo, sourceSize: size, edits: e, modern: true)
        #expect(abs(pixel(hidden, 60, 32)[0] - base) < 0.02)
        var unmasked = PhotoEdits(); let u = unmasked.addLocalAdjustment(); unmasked.updateLocalAdjustment(u.id) { $0.settings.exposure = 2 }
        #expect(abs(pixel(try PhotoEditor.process(photo, sourceSize: size, edits: unmasked, modern: true), 32, 32)[0] - base) < 0.02)
    }
    @Test func layerSlidersRender() throws {
        let photo = solid(0.3, 0.5, 0.2)
        #expect(LocalSettings().isNeutral)
        var s = LocalSettings(); s.exposure = 1
        let brighter = pixel(try LocalAdjustments.apply(photo, settings: s, sourceSize: CGSize(width: 64, height: 64)), 10, 10)
        #expect(brighter[1] > 0.6)
        s = LocalSettings(); s.saturation = -1
        let gray = pixel(try LocalAdjustments.apply(photo, settings: s, sourceSize: CGSize(width: 64, height: 64)), 10, 10)
        #expect(abs(gray[0] - gray[1]) < 0.02)
        s = LocalSettings(); s.temperature = 1
        let warm = pixel(try LocalAdjustments.apply(photo, settings: s, sourceSize: CGSize(width: 64, height: 64)), 10, 10)
        #expect(warm[2] < 0.2 && warm[0] > 0.3)
        s = LocalSettings(); s.tint = 1
        let magenta = pixel(try LocalAdjustments.apply(photo, settings: s, sourceSize: CGSize(width: 64, height: 64)), 10, 10)
        #expect(magenta[1] < 0.5, "tint +1 should be more magenta: \(magenta)")
    }
    @Test func batchCopiesMaskLayersOnlyWithMasks() throws {
        var source = PhotoEdits(); let layer = source.addLocalAdjustment(named: "Sky")
        source.setMask(AdjustmentMask(kind: "radial"), for: layer.maskKey); source.updateLocalAdjustment(layer.id) { $0.settings.dehaze = 0.4 }
        var options = BatchOptions()
        #expect(try BatchEdits.merging(source, into: PhotoEdits(), options: options, geometryCompatible: true).localAdjustments.isEmpty)
        options.masks = true
        let copied = try BatchEdits.merging(source, into: PhotoEdits(), options: options, geometryCompatible: true)
        #expect(copied.localAdjustments.map(\.name) == ["Sky"] && copied.advanced?.masks[layer.maskKey] != nil)
    }

    // MARK: Smart Contrast
    @Test func smartContrastIsNeutralAtOneAndNeverClips() throws {
        let r = ramp()
        #expect(try SmartContrast.apply(r, contrast: 1) == r)
        for contrast in [1.5, 0.5] {
            let out = try SmartContrast.apply(r, contrast: contrast, pivot: 0.5, localContrast: false)
            var last: Float = -1
            for x in stride(from: 0, to: 256, by: 8) {
                let v = pixel(out, CGFloat(x), 1)[0]
                #expect(v >= last - 0.002 && v >= -0.001 && v <= 1.001, "contrast \(contrast) at \(x)")
                last = v
            }
            // The ends stay where they were: no clipping, no milky blacks.
            #expect(abs(pixel(out, 0, 1)[0] - pixel(r, 0, 1)[0]) < 0.03 && abs(pixel(out, 255, 1)[0] - pixel(r, 255, 1)[0]) < 0.03, "contrast \(contrast) ends")
        }
        // More contrast darkens shadows and brightens highlights around the pivot; less does the opposite.
        let high = try SmartContrast.apply(r, contrast: 1.5, pivot: 0.5, localContrast: false), low = try SmartContrast.apply(r, contrast: 0.5, pivot: 0.5)
        #expect(pixel(high, 16, 1)[0] < pixel(r, 16, 1)[0] && pixel(high, 200, 1)[0] > pixel(r, 200, 1)[0])
        #expect(pixel(low, 16, 1)[0] > pixel(r, 16, 1)[0] && pixel(low, 200, 1)[0] < pixel(r, 200, 1)[0])
    }
    @Test func smartContrastKeepsColorsAndFollowsThePhoto() throws {
        let color = solid(0.8, 0.4, 0.2)
        let out = pixel(try SmartContrast.apply(color, contrast: 1.5, pivot: 0.3), 10, 10), before = pixel(color, 10, 10)
        // Hue stays: the channels keep their order and roughly their proportions.
        #expect(out[0] > out[1] && out[1] > out[2])
        #expect(abs(Double(out[1] / out[0]) - Double(before[1] / before[0])) < 0.08)
        let dark = SmartContrast.pivot(solid(0.1, 0.1, 0.1)), bright = SmartContrast.pivot(solid(0.9, 0.9, 0.9)), mid = SmartContrast.pivot(solid(0.5, 0.5, 0.5))
        #expect(dark == 0.3 && bright == 0.7 && abs(mid - 0.5) < 0.05)
    }
    @Test func olderEditsKeepTheOriginalContrastUntilItChanges() throws {
        var e = PhotoEdits(); e.contrast = 1.3
        #expect(!e.usesSmartContrast)
        let old = e; e.exposure = 0.5; e.adoptSmartContrast(changedFrom: old)
        #expect(!e.usesSmartContrast)
        let before = e; e.contrast = 1.2; e.adoptSmartContrast(changedFrom: before)
        #expect(e.usesSmartContrast)
        // The two models render differently, so an old edit really does keep its look.
        let photo = solid(0.3, 0.3, 0.3)
        var legacy = PhotoEdits(); legacy.contrast = 1.4
        var smart = legacy; smart.usesSmartContrast = true
        let a = pixel(try PhotoEditor.process(photo, sourceSize: CGSize(width: 64, height: 64), edits: legacy, modern: true), 5, 5)[0]
        let b = pixel(try PhotoEditor.process(photo, sourceSize: CGSize(width: 64, height: 64), edits: smart, modern: true), 5, 5)[0]
        #expect(abs(a - b) > 0.005)
        #expect(QuickDevelop.apply(.contrast(0.2), to: PhotoEdits()).usesSmartContrast)
        #expect(!QuickDevelop.apply(.exposure(1), to: PhotoEdits()).usesSmartContrast)
    }

    // MARK: Temperature and Tint on rendered photos
    @Test func temperatureWarmsAndTintAddsMagentaOnceCorrected() throws {
        let gray = solid(0.4, 0.4, 0.4), size = CGSize(width: 64, height: 64)
        func render(_ e: PhotoEdits) throws -> [Float] { pixel(try PhotoEditor.process(gray, sourceSize: size, edits: e, modern: true), 5, 5) }
        var old = PhotoEdits(); old.temperature = 7500
        #expect(!old.usesCorrectedWhiteBalance)
        let legacy = try render(old)
        // An older edit keeps its look: this is the reversed rendering it was saved with.
        #expect(legacy[2] > legacy[0])
        var warm = old; warm.temperature = 7600; warm.adoptSmartContrast(changedFrom: old)
        #expect(warm.usesCorrectedWhiteBalance)
        let w = try render(warm)
        #expect(w[0] > w[2] + 0.02)
        var cool = PhotoEdits(); cool.usesCorrectedWhiteBalance = true; cool.temperature = 4000
        let c = try render(cool)
        #expect(c[2] > c[0] + 0.02)
        var magenta = PhotoEdits(); magenta.usesCorrectedWhiteBalance = true; magenta.tint = 50
        let m = try render(magenta)
        #expect(m[1] < m[0] && m[1] < m[2])
        // Unrelated changes leave an older edit alone; Quick Develop and saved JSON carry the fix.
        var other = old; other.exposure = 0.3; other.adoptSmartContrast(changedFrom: old)
        #expect(!other.usesCorrectedWhiteBalance)
        #expect(QuickDevelop.apply(.whiteBalance(.shade), to: PhotoEdits()).usesCorrectedWhiteBalance)
        #expect(try JSONDecoder().decode(PhotoEdits.self, from: JSONEncoder().encode(warm)).usesCorrectedWhiteBalance)
        // Releasing a slider hands over the panel's copy, which was made before the switch and repeats the last value:
        // the edit must stay switched, or the photo flips back to the reversed rendering on release.
        var released = PhotoEdits(); released.temperature = 7600
        #expect(!released.usesCorrectedWhiteBalance)
        released.adoptSmartContrast(changedFrom: warm)
        #expect(released.usesCorrectedWhiteBalance)
        let r = try render(released); #expect(r[0] > r[2] + 0.02)
        var contrast = PhotoEdits(); contrast.contrast = 1.3
        var smart = contrast; smart.usesSmartContrast = true
        contrast.adoptSmartContrast(changedFrom: smart)
        #expect(contrast.usesSmartContrast)
    }
}
