import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

@Suite final class SkyReplacementTests {
    let resources = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
    let context = CIContext()
    var assets: [URL] = []
    deinit { for url in assets { try? FileManager.default.removeItem(at: url) } }

    func solid(_ r: Double, _ g: Double, _ b: Double, _ w: Int = 64, _ h: Int = 64) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }
    /// A 64×64 photo: blue sky on top, gray land below.
    func photo() throws -> CGImage {
        let land = solid(0.5, 0.5, 0.5, 64, 32), sky = solid(0.35, 0.55, 0.9, 64, 32).transformed(by: CGAffineTransform(translationX: 0, y: 32))
        return try #require(context.createCGImage(sky.composited(over: land), from: CGRect(x: 0, y: 0, width: 64, height: 64)))
    }
    func asset(_ image: CIImage) throws -> String {
        let url = try EditStorage.newAsset(); assets.append(url)
        try PhotoEditor.write(try #require(context.createCGImage(image, from: image.extent)), to: url)
        return url.lastPathComponent
    }
    /// Edits with a sky mask over the top half and a sky of this average color.
    func edits(sky color: [Double], relight: Double) throws -> PhotoEdits {
        let maskImage = solid(1, 1, 1, 64, 32).transformed(by: CGAffineTransform(translationX: 0, y: 32)).composited(over: solid(0, 0, 0, 64, 64))
        var mask = AdjustmentMask(kind: "object"); mask.asset = try asset(maskImage); mask.feather = 0
        var e = PhotoEdits(); e.setMask(mask, for: PhotoEdits.skyMaskKey)
        let linear = color.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        var sky = SkyReplacement(id: "test", name: "Test", asset: try asset(solid(color[0], color[1], color[2], 96, 54)), mean: linear, horizonColor: linear, relight: relight)
        sky.atmosphere = 0; e.sky = sky
        return e
    }
    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Double] {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return data.prefix(3).map { Double($0) / 255 }
    }

    @Test func darkSkyReplacesTheSkyAndDarkensTheLand() throws {
        let original = try photo()
        let before = try PhotoEditor.render(original, edits: PhotoEdits())
        let dark = try PhotoEditor.render(original, edits: edits(sky: [0.05, 0.05, 0.08], relight: 1))
        let skyPixel = pixel(dark, 32, 8), landPixel = pixel(dark, 32, 56), landBefore = pixel(before, 32, 56)
        #expect(skyPixel.allSatisfy { $0 < 0.15 })                     // the sky is the new, dark one
        #expect(landPixel.reduce(0, +) < landBefore.reduce(0, +) * 0.5) // and the land is much darker
        let untouched = try PhotoEditor.render(original, edits: edits(sky: [0.05, 0.05, 0.08], relight: 0))
        #expect(zip(pixel(untouched, 32, 56), landBefore).allSatisfy { abs($0 - $1) < 0.02 })   // relight 0 leaves the land
        #expect(pixel(untouched, 32, 8).allSatisfy { $0 < 0.15 })
    }
    @Test func sunsetWarmsTheLand() throws {
        let original = try photo()
        let warm = pixel(try PhotoEditor.render(original, edits: edits(sky: [0.95, 0.55, 0.3], relight: 0.8)), 32, 56)
        #expect(warm[0] > warm[2] + 0.05)
    }
    @Test func noSelectionMeansNoSky() throws {
        let original = try photo()
        var e = try edits(sky: [0.05, 0.05, 0.08], relight: 1); e.advanced!.masks[PhotoEdits.skyMaskKey] = nil
        #expect(pixel(try PhotoEditor.render(original, edits: e), 32, 8) == pixel(try PhotoEditor.render(original, edits: PhotoEdits()), 32, 8))
    }
    @Test func gainsFollowTheSky() {
        func sky(_ mean: [Double], _ relight: Double) -> SkyReplacement { SkyReplacement(id: nil, name: "", asset: "x", mean: mean, horizonColor: mean, relight: relight) }
        #expect(sky([0.004, 0.004, 0.007], 1).sceneGains.allSatisfy { $0 < 0.5 })
        #expect(sky([0.004, 0.004, 0.007], 0).sceneGains.allSatisfy { abs($0 - 1) < 1e-9 })
        let sunset = sky([0.8, 0.3, 0.08], 0.8).sceneGains
        #expect(sunset[0] > sunset[2])
        let daylight = sky(SkyReplacement.reference, 1).sceneGains
        #expect(daylight.allSatisfy { abs($0 - 1) < 1e-6 })
        #expect(sky([0.004, 0.004, 0.007], 1).sceneSaturation < 0.7)
    }
    @Test func settingsAreSanitizedSavedAndKeptByPresets() throws {
        var e = PhotoEdits()
        var s = SkyReplacement(id: "a", name: "A", asset: "a.jpg", mean: [0.1, 0.2], horizonColor: [.nan, 0, 0], relight: 7)
        s.horizon = -9; s.defocus = .infinity
        e.sky = s
        #expect(e.sky!.relight == 1 && e.sky!.horizon == -1 && e.sky!.defocus == 0 && e.sky!.mean.count == 3 && e.sky!.horizonColor[0] == 0.5)
        e.skyRelight = 0.3; #expect(e.sky!.relight == 0.3)
        #expect(try JSONDecoder().decode(PhotoEdits.self, from: JSONEncoder().encode(e)) == e)
        var none = PhotoEdits(); none.skyRelight = 0.9; #expect(none.sky == nil)   // sliders do nothing without a sky
        let preset = PresetRecipe(id: "p", name: "P", category: "Moody", description: "", adjustments: ["exposure": -0.5])
        #expect(preset.edits(from: e).sky == e.sky)
        let saved = PresetRecipe(id: "u", name: "U", category: PresetLibrary.myPresets, description: "", snapshot: PresetRecipe.snapshot(of: PhotoEdits()))
        #expect(saved.edits(from: e).sky == e.sky)
    }
    @Test func bundledSkiesAreFreeAndApplyAsCopies() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try SkyLibrary(bundled: resources.appendingPathComponent("Skies"), user: folder)
        #expect(library.items.count >= 20)
        #expect(Set(library.items.map(\.entry.category)).count >= 5)
        for item in library.items {
            #expect(item.entry.license == "CC0-1.0" && item.entry.source.hasPrefix("https://polyhaven.com/") && !item.entry.creator.isEmpty)
            #expect(FileManager.default.fileExists(atPath: item.url.path))
            #expect(item.entry.mean.allSatisfy { (0...1).contains($0) })
        }
        let night = try #require(library.filtered("Night").first ?? library.filtered("Dramatic").first)
        var current = PhotoEdits(); current.sky = SkyReplacement(id: nil, name: "Old", asset: "old.jpg", mean: [0.3, 0.4, 0.6], horizonColor: [0.3, 0.4, 0.6]); current.skyHorizon = 0.4
        let applied = try night.applying(to: current)
        defer { if let a = applied.sky?.asset { try? FileManager.default.removeItem(at: EditStorage.asset(a)) } }
        #expect(applied.sky?.id == night.entry.id && applied.sky?.horizon == 0.4 && applied.sky!.relight >= 0.75)
        #expect(FileManager.default.contentsEqual(atPath: EditStorage.asset(applied.sky!.asset).path, andPath: night.url.path))
        #expect(library.selected(for: applied) == night)
        // Your own sky: copied and measured.
        let own = folder.appendingPathComponent("Evening.png"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try PhotoEditor.write(try #require(context.createCGImage(solid(0.9, 0.5, 0.2, 40, 20), from: CGRect(x: 0, y: 0, width: 40, height: 20))), to: own)
        let imported = try SkyLibrary.importSky(own, into: folder.appendingPathComponent("Skies"))
        #expect(imported.entry.category == "Your Skies" && imported.entry.mean[0] > imported.entry.mean[2])
        #expect(try SkyLibrary(bundled: nil, user: folder.appendingPathComponent("Skies")).items.map(\.entry.name) == ["Evening"])
        try? FileManager.default.removeItem(at: folder)
    }
}
