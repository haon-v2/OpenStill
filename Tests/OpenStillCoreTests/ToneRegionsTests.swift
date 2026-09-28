import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

@Suite struct ToneRegionsTests {
    let sRGB = CGColorSpace(name: CGColorSpace.extendedSRGB)!
    func pixel(_ image: CIImage, _ x: CGFloat, _ y: CGFloat = 1) -> [Float] {
        var p = [Float](repeating: 0, count: 4)
        ModernRenderer.context.render(image, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: image.extent.minX + x, y: image.extent.minY + y, width: 1, height: 1), format: .RGBAf, colorSpace: sRGB)
        return p
    }
    /// A left-to-right gray ramp from black to white.
    func ramp() -> CIImage {
        CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 255, y: 0),
                                                        "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 1, blue: 1)])!
            .outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 256, height: 4))
    }
    func profile(_ image: CIImage) -> [Float] { stride(from: 0, to: 256, by: 4).map { pixel(image, CGFloat($0))[0] } }

    @Test func highlightsRecoverWithoutWhiteningAndBrightenTheOtherWay() throws {
        let r = ramp(), base = profile(r)
        let recover = profile(try ToneRegions.apply(r, highlights: -1, shadows: 0))
        let brighten = profile(try ToneRegions.apply(r, highlights: 1, shadows: 0))
        for i in base.indices {
            // Recovering never brightens anything, and brightening never darkens: the reverse of the bug.
            #expect(recover[i] <= base[i] + 0.002, "recover at \(i * 4)")
            #expect(brighten[i] >= base[i] - 0.002, "brighten at \(i * 4)")
            if i > 0 { #expect(recover[i] >= recover[i - 1] - 0.002 && brighten[i] >= brighten[i - 1] - 0.002, "order at \(i * 4)") }
        }
        // Bright tones move clearly; the darker half is left alone; white stays white.
        let upper = 48  // x ≈ 192
        #expect(recover[upper] < base[upper] - 0.04 && brighten[upper] > base[upper] + 0.03)
        #expect(abs(recover[8] - base[8]) < 0.003 && abs(brighten[8] - base[8]) < 0.003)  // x ≈ 32
        #expect(pixel(try ToneRegions.apply(r, highlights: -1, shadows: 0), 255)[0] > 0.99)
    }

    @Test func shadowsMirrorHighlights() throws {
        let r = ramp(), base = profile(r)
        let lift = profile(try ToneRegions.apply(r, highlights: 0, shadows: 1))
        let deepen = profile(try ToneRegions.apply(r, highlights: 0, shadows: -1))
        let dark = 12  // x ≈ 48
        #expect(lift[dark] > base[dark] + 0.03 && deepen[dark] < base[dark] - 0.03)
        #expect(abs(lift[56] - base[56]) < 0.003 && abs(deepen[56] - base[56]) < 0.003)
        for i in 1..<base.count { #expect(lift[i] >= lift[i - 1] - 0.002 && deepen[i] >= deepen[i - 1] - 0.002) }
        #expect(try ToneRegions.apply(r, highlights: 0, shadows: 0) == r)
    }

    @Test func colorsKeepTheirHue() throws {
        let color = CIImage(color: CIColor(red: 0.8, green: 0.5, blue: 0.3, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let before = pixel(color, 2), after = pixel(try ToneRegions.apply(color, highlights: -1, shadows: 0.5), 2)
        #expect(after[0] < before[0] && after[0] > after[1] && after[1] > after[2])
        #expect(abs(Double(after[2] / after[0]) - Double(before[2] / before[0])) < 0.06)
    }

    @Test func slidersAreCentredAndOlderEditsKeepTheirLook() throws {
        var fresh = PhotoEdits()
        #expect(fresh.highlightsAmount == 0 && fresh.shadowsAmount == 0 && !fresh.usesToneRegions)
        fresh.highlightsAmount = 0
        #expect(fresh == PhotoEdits())  // Setting the current value changes nothing.
        // An older edit shows its values on the new scale and still renders the original way.
        var old = PhotoEdits(); old.highlights = 0.6; old.shadows = 0.3
        #expect(abs(old.highlightsAmount + 0.4) < 1e-9 && abs(old.shadowsAmount - 0.3) < 1e-9 && !old.usesToneRegions)
        let photo = ramp(), size = CGSize(width: 256, height: 4)
        var legacy = PhotoEdits(); legacy.highlights = 0.6
        let legacyOut = try PhotoEditor.process(photo, sourceSize: size, edits: legacy, modern: true)
        let expected = photo.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 0.6, "inputShadowAmount": 0])
        #expect(abs(pixel(legacyOut, 200)[0] - pixel(expected, 200)[0]) < 0.01)
        // Moving a slider switches the edit over, keeping the other slider's value.
        old.highlightsAmount = -0.5
        #expect(old.usesToneRegions && old.highlights == 1 && old.shadows == 0 && abs(old.shadowsAmount - 0.3) < 1e-9 && old.highlightsAmount == -0.5)
        let round = try JSONDecoder().decode(PhotoEdits.self, from: JSONEncoder().encode(old))
        #expect(round.usesToneRegions && round.highlightsAmount == -0.5)
        var wild = PhotoEdits(); wild.highlightsAmount = 7; wild.shadowsAmount = .nan
        #expect(wild.sanitized.highlightsAmount == 1 && wild.sanitized.shadowsAmount == 0)
        // Quick Develop and Camera Raw use the same scale, both directions.
        #expect(QuickDevelop.apply(.highlights(-0.2), to: PhotoEdits()).highlightsAmount == -0.2)
        #expect(QuickDevelop.apply(.highlights(0.2), to: PhotoEdits()).highlightsAmount == 0.2)
        var xmp = XMPMetadata(); xmp.cameraRaw = ["ProcessVersion": "11.0", "Highlights2012": "+30", "Shadows2012": "-20"]
        let imported = CameraRawImport(xmp, raw: false).edits
        #expect(abs(imported.highlightsAmount - 0.3) < 1e-9 && abs(imported.shadowsAmount + 0.2) < 1e-9)
    }
}

@Suite struct ImportFoldersTests {
    @Test func foldersAreListedAndGroupedWhenThereAreMany() {
        let few = ["/Users/a/Pictures/2024/Rome/1.raf", "/Users/a/Pictures/2024/Rome/2.raf", "/Users/a/Pictures/2024/Paris/3.arw"]
        let rows = LightroomCatalog.folders(of: few)
        #expect(rows.map(\.folder) == ["/Users/a/Pictures/2024/Paris", "/Users/a/Pictures/2024/Rome"] && rows.map(\.count) == [1, 2])
        // Many folders collapse to their shared parents, never more than the limit.
        let many = (1...40).map { "/Volumes/Photos/\($0 % 3 == 0 ? "Travel" : "Family")/Shoot \($0)/img.raf" }
        let grouped = LightroomCatalog.folders(of: many, limit: 5)
        #expect(grouped.count <= 5 && grouped.map(\.folder) == ["/Volumes/Photos/Family", "/Volumes/Photos/Travel"] && grouped.map(\.count).reduce(0, +) == 40)
        #expect(LightroomCatalog.folders(of: []).isEmpty)
    }
}
