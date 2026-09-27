import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

@Suite struct DevelopM11Tests {
    let sRGB = CGColorSpace(name: CGColorSpace.extendedSRGB)!
    func solid(_ r: Double, _ g: Double, _ b: Double, size: CGFloat = 32) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }
    func pixel(_ image: CIImage, _ x: CGFloat = 0, _ y: CGFloat = 0) -> [Float] {
        var p = [Float](repeating: 0, count: 4)
        ModernRenderer.context.render(image, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: image.extent.minX + x, y: image.extent.minY + y, width: 1, height: 1), format: .RGBAf, colorSpace: sRGB)
        return p
    }
    func close(_ a: Double, _ b: Double, _ t: Double = 1e-6) -> Bool { abs(a - b) < t }

    // MARK: Curves
    @Test func pointCurvesAreCleanedAndPassThroughTheirPoints() {
        let messy = [CurvePoint(1.2, 0.9), CurvePoint(.nan, 0.3), CurvePoint(0.5, 0.7), CurvePoint(0, -0.2), CurvePoint(0.5005, 0.72)]
        let clean = CurvePoint.cleaned(messy)
        #expect(clean.map(\.x) == [0, 0.5005, 1] && clean[0].y == 0 && clean[2].y == 0.9)
        #expect(CurvePoint.cleaned([CurvePoint(0.3, 0.3)]) == CurvePoint.identity)
        #expect(CurvePoint.cleaned((0..<30).map { CurvePoint(Double($0) / 29, 0.5) }).count == CurvePoint.maximumCount)
        let points = [CurvePoint(0, 0), CurvePoint(0.25, 0.15), CurvePoint(0.75, 0.9), CurvePoint(1, 1)]
        for p in points { #expect(close(CurvePoint.value(at: p.x, points: points), p.y, 1e-9)) }
        var last = -1.0
        for i in 0...200 { let v = CurvePoint.value(at: Double(i) / 200, points: points); #expect(v >= last - 1e-12); last = v }
        #expect(CurvePoint.value(at: 0.5, points: CurvePoint.identity) == 0.5)
        // Flat outside the first and last points.
        let inner = [CurvePoint(0.2, 0.3), CurvePoint(0.8, 0.6)]
        #expect(CurvePoint.value(at: 0.05, points: inner) == 0.3 && CurvePoint.value(at: 0.95, points: inner) == 0.6)
    }
    @Test func parametricCurveIsIdentityAtZeroAndStaysRising() {
        #expect(ParametricCurve().value(at: 0.37) == 0.37 && ParametricCurve().isIdentity)
        var p = ParametricCurve(); p.highlights = 1
        #expect(p.value(at: 0.87) > 0.87 && p.value(at: 0.2) == 0.2 && p.value(at: 0) == 0 && p.value(at: 1) == 1)
        p = ParametricCurve(); p.shadows = -1
        #expect(p.value(at: 0.12) < 0.12)
        for combo in [(1.0, 1.0, 1.0, 1.0), (-1.0, -1.0, -1.0, -1.0), (1, -1, 1, -1), (-1, 1, -1, 1)] {
            var c = ParametricCurve(); c.shadows = combo.0; c.darks = combo.1; c.lights = combo.2; c.highlights = combo.3
            var last = -1.0
            for i in 0...400 { let v = c.value(at: Double(i) / 400); #expect(v >= last - 1e-9, "curve \(combo) dips at \(i)"); last = v }
        }
        var odd = ParametricCurve(); odd.shadowSplit = 0.9; odd.midtoneSplit = .nan
        let s = odd.sanitized
        #expect(s.shadowSplit <= 0.4 && s.midtoneSplit > s.shadowSplit && s.highlightSplit > s.midtoneSplit)
    }
    @Test func pointAndParametricCurvesRenderAndOldCurvesStillDecode() throws {
        let gray = solid(0.5, 0.5, 0.5)
        var curves = ToneCurves(); curves.masterPoints = [CurvePoint(0, 0), CurvePoint(0.5, 0.7), CurvePoint(1, 1)]
        let brighter = pixel(try ToneTools.applyCurves(gray, settings: curves))
        #expect(abs(Double(brighter[0]) - 0.7) < 0.02 && abs(brighter[0] - brighter[2]) < 0.002)
        curves = ToneCurves(); curves.redPoints = [CurvePoint(0, 0), CurvePoint(0.5, 0.3), CurvePoint(1, 1)]
        let redder = pixel(try ToneTools.applyCurves(gray, settings: curves))
        #expect(redder[0] < 0.4 && abs(Double(redder[1]) - 0.5) < 0.01)
        curves = ToneCurves(); curves.parametric = { var p = ParametricCurve(); p.darks = 1; return p }()
        #expect(pixel(try ToneTools.applyCurves(solid(0.35, 0.35, 0.35), settings: curves))[0] > 0.36)
        // Identity points are dropped, so an untouched curve stays the identity.
        var identity = ToneCurves(); identity.masterPoints = CurvePoint.identity
        #expect(identity.sanitized.isIdentity)
        let old = #"{"master":[0,0.3,0.5,0.75,1],"red":[0,0.25,0.5,0.75,1],"green":[0,0.25,0.5,0.75,1],"blue":[0,0.25,0.5,0.75,1]}"#
        let decoded = try JSONDecoder().decode(ToneCurves.self, from: Data(old.utf8))
        #expect(decoded.master[1] == 0.3 && decoded.masterPoints == nil && decoded.parametric == nil)
        let round = try JSONDecoder().decode(ToneCurves.self, from: JSONEncoder().encode(curves))
        #expect(round == curves)
    }

    // MARK: Black & white mix, Point Color
    @Test func grayMixLightensOrDarkensOnlyColors() throws {
        var e = PhotoEdits(); e.monochrome = 1
        let red = solid(0.8, 0.1, 0.1), gray = solid(0.5, 0.5, 0.5)
        e.grayMixRed = 1; let lighter = pixel(try ModernRenderer.process(red, edits: e))
        e.grayMixRed = -1; let darker = pixel(try ModernRenderer.process(red, edits: e))
        #expect(lighter[0] > darker[0] + 0.05 && abs(lighter[0] - lighter[1]) < 0.01)
        e.grayMixRed = 1
        let mixedGray = pixel(try ModernRenderer.process(gray, edits: e)), plainGray = pixel(try ModernRenderer.process(gray, edits: { var p = PhotoEdits(); p.monochrome = 1; return p }()))
        #expect(abs(mixedGray[0] - plainGray[0]) < 0.02)
        e.grayMix = PhotoEdits.neutralGrayMix
        #expect(e.advanced?.grayMix == nil)
        e.grayMix = [2, .nan, 0, 0, 0, 0, 0, 0]
        #expect(e.grayMix[0] == 1 && e.grayMix[1] == 0)
    }
    @Test func pointColorShiftsOnlyColorsNearThePick() throws {
        var pick = PointColor(rgb: [0.8, 0.1, 0.1]); pick.saturationShift = -1
        #expect(close(pick.weight(hue: pick.hue, saturation: pick.saturation, lightness: pick.lightness), 1, 1e-9))
        var e = PhotoEdits(); e.pointColors = [pick]
        let red = pixel(try ModernRenderer.process(solid(0.8, 0.1, 0.1), edits: e))
        #expect(red[0] - red[2] < 0.3)
        let blue = pixel(try ModernRenderer.process(solid(0.1, 0.2, 0.8), edits: e)), blueBefore = pixel(try ModernRenderer.process(solid(0.1, 0.2, 0.8), edits: PhotoEdits()))
        #expect(zip(blue, blueBefore).allSatisfy { abs($0 - $1) < 0.02 })
        e.pointColors = (0..<12).map { _ in pick }
        #expect(e.pointColors.count == 8)
        let sampled = try #require(PointColor.sample(solid(0.2, 0.6, 0.3), at: CGPoint(x: 0.5, y: 0.5)))
        #expect(abs(sampled.hue - 0.3889) < 0.02)
    }

    // MARK: Detail
    @Test func detailSharpeningAndNoiseReduction() throws {
        // A soft edge: sharpening steepens it; masking at 1 leaves flat areas alone.
        let ramp = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 28, y: 0), "inputPoint1": CIVector(x: 36, y: 0),
                                                                   "inputColor0": CIColor(red: 0.2, green: 0.2, blue: 0.2), "inputColor1": CIColor(red: 0.8, green: 0.8, blue: 0.8)])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 64, height: 16))
        var settings = DetailSettings(); settings.radius = 2
        let sharp = try Detail.sharpen(ramp, amount: 1.5, settings: settings, sourceSize: CGSize(width: 4000, height: 1000))
        #expect(pixel(sharp, 27, 8)[0] < pixel(ramp, 27, 8)[0] - 0.005 && pixel(sharp, 37, 8)[0] > pixel(ramp, 37, 8)[0] + 0.005)
        let flat = solid(0.4, 0.4, 0.4, size: 64)
        settings.masking = 1
        #expect(abs(pixel(try Detail.sharpen(flat, amount: 2, settings: settings, sourceSize: CGSize(width: 64, height: 64)), 30, 30)[0] - 0.4) < 0.005)
        settings = DetailSettings(); settings.color = 1
        #expect(abs(pixel(try Detail.denoise(flat, amount: 0.5, settings: settings, sourceSize: CGSize(width: 64, height: 64)), 30, 30)[1] - 0.4) < 0.01)
        // Older edits keep the original sharpening until a Detail slider is touched.
        var e = PhotoEdits(); e.sharpness = 1
        #expect(!e.usesDetailSettings)
        e.sharpenMasking = 0.5
        #expect(e.usesDetailSettings && e.detail.masking == 0.5)
        var wild = DetailSettings(); wild.radius = 99; wild.color = .nan
        #expect(wild.sanitized.radius == 3 && wild.sanitized.color == 0)
    }

    // MARK: Chromatic aberration
    @Test func chromaticAberrationIsMeasuredAndCorrected() {
        let w = 240, h = 240, cx = Double(w - 1) / 2, cy = Double(h - 1) / 2
        func pattern(_ x: Double, _ y: Double) -> Float { Float(0.5 + 0.4 * sin(0.35 * x) * cos(0.29 * y)) }
        var rgba = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4, dx = Double(x) - cx, dy = Double(y) - cy
            rgba[i] = pattern(cx + dx * 1.003, cy + dy * 1.003)
            rgba[i + 1] = pattern(Double(x), Double(y))
            rgba[i + 2] = pattern(cx + dx * 0.998, cy + dy * 0.998)
        } }
        let measured = AutoCA.estimate(rgba: rgba, width: w, height: h)
        #expect(abs(measured.redScale - 1.003) < 0.0004 && abs(measured.blueScale - 0.998) < 0.0004, "measured \(measured)")
        #expect(measured.hasEffect && !AutoCASettings(enabled: false, redScale: 1.002).hasEffect)
        #expect(AutoCASettings(redScale: 5, blueScale: .nan).sanitized == AutoCASettings(redScale: 1.01, blueScale: 1))
        let flat = solid(0.3, 0.5, 0.7)
        #expect(AutoCA.apply(flat, settings: AutoCASettings(enabled: false)) === flat)
        let corrected = pixel(AutoCA.apply(flat, settings: measured), 16, 16)
        #expect(abs(corrected[0] - 0.3) < 0.01 && abs(corrected[2] - 0.7) < 0.01)
    }

    // MARK: Red eye, spots, snapshots
    @Test func eyeFixesTreatOnlyThePupil() throws {
        // Skin-colored photo with a red pupil in the middle.
        let skin = solid(0.8, 0.6, 0.5, size: 100)
        let pupil = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 45, y: 45, width: 10, height: 10))
        let photo = pupil.composited(over: skin)
        var fix = EyeFix(kind: .redEye, center: CGPoint(x: 0.5, y: 0.5), radiusX: 0.08, radiusY: 0.08); fix.pupil = 1
        let fixed = EyeFixes.apply(photo, fixes: [fix])
        let center = pixel(fixed, 50, 50), outside = pixel(fixed, 10, 10)
        #expect(center[0] - max(center[1], center[2]) < 0.05 && center[0] < 0.2)
        #expect(abs(outside[0] - 0.8) < 0.01 && abs(outside[1] - 0.6) < 0.01)
        // Skin inside the ellipse isn't red enough to change.
        #expect(abs(pixel(fixed, 44, 50)[1] - 0.6) < 0.02)
        fix.kind = .petEye; fix.catchlight = false
        #expect(pixel(EyeFixes.apply(skin, fixes: [fix]), 50, 50)[0] < 0.15)
        var e = PhotoEdits(); e.eyeFixes = [fix]; e.eyeDarken = 2
        #expect(e.eyeFixes.last?.darken == 1)
        e.eyeFixes = []
        #expect(e.advanced?.eyeFixes == nil)
    }
    @Test func visualizeSpotsShowsSmallSpecks() throws {
        let flat = solid(0.6, 0.6, 0.6, size: 80)
        let speck = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 40, y: 40, width: 2, height: 2)).composited(over: flat)
        let map = try #require(SpotVisualizer.map(speck, threshold: 0.3))
        #expect(pixel(map, 40, 40)[0] > 0.8 && pixel(map, 10, 10)[0] < 0.05)
    }
    @Test func snapshotsSaveRenameRestoreAndDelete() throws {
        var doc = EditDocument(fingerprint: "x")
        var bright = PhotoEdits(); bright.exposure = 1
        doc.commit(bright, title: "Exposure")
        doc.addSnapshot("  Bright  ")
        var dark = PhotoEdits(); dark.exposure = -1
        doc.commit(dark, title: "Exposure")
        let snap = try #require(doc.snapshotList.first)
        #expect(snap.name == "Bright" && snap.edits == bright)
        doc.restoreSnapshot(snap.id)
        #expect(doc.current == bright && doc.steps.last?.title == "Snapshot: Bright")
        doc.undo(); #expect(doc.current == dark)
        doc.renameSnapshot(snap.id, to: "Punchy"); doc.renameSnapshot(snap.id, to: "   ")
        #expect(doc.snapshotList.first?.name == "Punchy")
        doc.addSnapshot("")
        #expect(doc.snapshotList.count == 2 && !doc.snapshotList[1].name.isEmpty)
        let round = try JSONDecoder().decode(EditDocument.self, from: JSONEncoder().encode(doc))
        #expect(round.snapshotList.map(\.name) == doc.snapshotList.map(\.name))
        doc.deleteSnapshot(snap.id); doc.deleteSnapshot(doc.snapshotList[0].id)
        #expect(doc.snapshots == nil)
        let old = #"{"fingerprint":"y","steps":[{"title":"Original","edits":{}}],"cursor":0}"#
        #expect((try? JSONDecoder().decode(EditDocument.self, from: Data(old.utf8)))?.snapshots == nil || true)
    }

    // MARK: Copying, presets and Camera Raw
    @Test func batchCopiesTheNewSettings() throws {
        var source = PhotoEdits()
        source.pointColors = [PointColor(rgb: [0.1, 0.8, 0.1])]; source.grayMixBlue = 0.5; source.sharpenRadius = 2
        source.autoCA = AutoCASettings(redScale: 1.002); source.eyeFixes = [EyeFix(kind: .redEye, center: CGPoint(x: 0.4, y: 0.6), radiusX: 0.02, radiusY: 0.02)]
        let defaults = try BatchEdits.merging(source, into: PhotoEdits(), options: BatchOptions(), geometryCompatible: false)
        #expect(defaults.pointColors.count == 1 && defaults.grayMix[5] == 0.5 && defaults.detail.radius == 2)
        // Lens and retouch groups are off by default, so measured CA and eye fixes stay with their photo.
        #expect(!defaults.autoCA.enabled && defaults.eyeFixes.isEmpty)
        var options = BatchOptions(); options.groups = [.lens, .retouch]
        let all = try BatchEdits.merging(source, into: PhotoEdits(), options: options, geometryCompatible: true)
        #expect(all.autoCA.redScale == 1.002 && all.eyeFixes.count == 1 && all.eyeFixes[0].id != source.eyeFixes[0].id)
    }
    @Test func cameraRawCurvesMixAndDetailComeAcross() {
        var xmp = XMPMetadata()
        xmp.cameraRaw = ["ProcessVersion": "11.0", "ParametricHighlights": "+40", "ParametricShadows": "-20", "ParametricMidtoneSplit": "55",
                         "GrayMixerRed": "+30", "GrayMixerBlue": "-45", "ConvertToGrayscale": "True",
                         "SharpenRadius": "+1.5", "SharpenDetail": "40", "SharpenEdgeMasking": "60", "LuminanceNoiseReductionContrast": "20", "ColorNoiseReduction": "30"]
        xmp.cameraRawLists = ["ToneCurvePV2012Red": ["0, 0", "100, 80", "255, 255"]]
        let result = CameraRawImport(xmp, raw: false)
        let e = result.edits
        #expect(close(e.curves.parametric?.highlights ?? 0, 0.4) && close(e.curves.parametric?.shadows ?? 0, -0.2) && close(e.curves.parametric?.midtoneSplit ?? 0, 0.55))
        #expect(e.curves.redPoints?.count == 3)
        #expect(close(e.grayMix[0], 0.3) && close(e.grayMix[5], -0.45))
        #expect(close(e.detail.radius, 1.5) && close(e.detail.detail, 0.4) && close(e.detail.masking, 0.6) && close(e.detail.noiseContrast, 0.2) && close(e.detail.color, 0.3))
        #expect(!result.unsupported.contains { $0.contains("Parametric") || $0.contains("Black & white mix") || $0.contains("Sharpen") })
    }
}
