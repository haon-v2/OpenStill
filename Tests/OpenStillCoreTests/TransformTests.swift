import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

@Suite struct TransformTests {
    func gradient(_ width: Int = 128, _ height: Int = 96) -> CIImage {
        CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: Double(width), y: 0), "inputColor0": CIColor.black, "inputColor1": CIColor.white])!
            .outputImage!.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }
    func pixels(_ image: CIImage) -> [Float] {
        let w = Int(image.extent.width), h = Int(image.extent.height); var data = [Float](repeating: 0, count: w*h*4)
        ModernRenderer.context.render(image, toBitmap: &data, rowBytes: w*16, bounds: image.extent, format: .RGBAf, colorSpace: ModernRenderer.workingSpace); return data
    }
    func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> [Float] { pixels(image.cropped(to: CGRect(x: x, y: y, width: 1, height: 1))) }
    func optics(_ configure: (inout TransformSettings) -> Void, turn: Int = 0, flip: Bool = false, lens: LensSettings = LensSettings()) -> OpticalCorrection {
        var t = TransformSettings(); configure(&t); return OpticalCorrection(lens: lens, transform: t, turn: turn, flip: flip)
    }
    /// Angle of a segment from the vertical, in degrees, after mapping through the perspective.
    func tilt(_ line: LineSegment, _ perspective: Perspective?, size: CGSize, vertical: Bool) -> Double {
        let a = perspective?.displayOutput(line.start) ?? line.start, b = perspective?.displayOutput(line.end) ?? line.end
        let dx = (b.x-a.x)*size.width, dy = (b.y-a.y)*size.height
        var angle = (vertical ? atan2(dx, dy) : atan2(dy, dx)) * 180 / .pi
        if angle > 90 { angle -= 180 } else if angle < -90 { angle += 180 }
        return angle
    }

    @Test func defaultsAreIdentityAndStoreNothing() throws {
        let image = gradient()
        #expect(!TransformSettings().hasEffect)
        #expect(!OpticalCorrection().hasEffect)
        #expect(try LensCorrections.apply(image, settings: OpticalCorrection(transform: TransformSettings(), turn: 1, flip: true)) === image)
        var e = PhotoEdits(); e.transformVertical = 0.3; e.transformVertical = 0
        #expect(e.advanced?.transform == nil)
        #expect(e.sanitized.advanced?.transform == nil)
        e.transformScale = 1.2
        #expect(e.advanced?.transform?.scale == 1.2 && e.optics.hasEffect)
        #expect(Perspective(TransformSettings(), sourceSize: CGSize(width: 10, height: 10), orientation: DisplayOrientation(turn: 0, flip: false)) == nil)
    }
    @Test func settingsAreSanitizedAndOldEditsDecode() throws {
        var t = TransformSettings(); t.vertical = .nan; t.horizontal = 4; t.rotate = -90; t.scale = .infinity; t.offsetX = -3
        t.upright = UprightSolution(mode: .full, rotate: 40, vertical: .nan, horizontal: 2)
        t.guides = [GuideLine(CGPoint(x: 0, y: 0), CGPoint(x: CGFloat.nan, y: 1))] + (0..<6).map { _ in GuideLine(CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.1, y: 0.9)) }
        let s = t.sanitized
        #expect(s.vertical == 0 && s.horizontal == 1 && s.rotate == -15 && s.scale == 1 && s.offsetX == -1)
        #expect(s.upright == UprightSolution(mode: .full, rotate: 15, vertical: 0, horizontal: 1))
        #expect(s.guides?.count == 4)
        var off = TransformSettings(); off.upright = UprightSolution(mode: .off, rotate: 3)
        #expect(off.sanitized.upright == nil)
        var e = PhotoEdits(); e.exposure = 1; e.ensureAdvanced()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as? [String: Any])
        var advanced = try #require(json["advanced"] as? [String: Any]); advanced.removeValue(forKey: "transform"); json["advanced"] = advanced
        let old = try JSONDecoder().decode(PhotoEdits.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.exposure == 1 && old.transform == TransformSettings())
        e.transformVertical = -0.4; e.transform.upright = UprightSolution(mode: .vertical, rotate: 1.5, vertical: -0.2)
        let saved = try JSONDecoder().decode(PhotoEdits.self, from: JSONEncoder().encode(e))
        #expect(saved.transform == e.transform)
    }
    @Test func homographyAndOrientationRoundTrip() throws {
        for turn in 0..<4 { for flip in [false, true] {
            let o = DisplayOrientation(turn: turn, flip: flip)
            for p in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.35), CGPoint(x: 0.5, y: 0.5)] {
                let back = o.source(o.display(p))
                #expect(abs(back.x-p.x) < 1e-12 && abs(back.y-p.y) < 1e-12)
            }
        } }
        var t = TransformSettings(); t.vertical = -0.5; t.horizontal = 0.3; t.rotate = 4; t.aspect = 0.4; t.scale = 1.1; t.offsetX = 0.2; t.offsetY = -0.1; t.constrain = false
        let p = try #require(Perspective(t, sourceSize: CGSize(width: 300, height: 200), orientation: DisplayOrientation(turn: 1, flip: true)))
        for q in [CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.7, y: 0.2), CGPoint(x: 0.55, y: 0.9)] {
            let input = try #require(p.input(q)), output = try #require(p.output(input))
            #expect(abs(output.x-q.x) < 1e-9 && abs(output.y-q.y) < 1e-9)
        }
    }
    @Test func constrainedCropNeverShowsEmptyEdges() throws {
        var t = TransformSettings(); t.vertical = -0.8; t.rotate = 6; t.horizontal = 0.4
        let size = CGSize(width: 160, height: 100)
        let p = try #require(Perspective(t, sourceSize: size, orientation: DisplayOrientation(turn: 0, flip: false)))
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)] {
            let input = try #require(p.input(corner))
            #expect(input.x >= -1e-6 && input.x <= 1+1e-6 && input.y >= -1e-6 && input.y <= 1+1e-6)
        }
        let image = CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: size))
        let constrained = pixels(try LensCorrections.apply(image, settings: OpticalCorrection(transform: t)))
        #expect(constrained.enumerated().filter { $0.offset % 4 == 3 }.allSatisfy { $0.element > 0.99 })
        t.constrain = false
        let loose = try LensCorrections.apply(image, settings: OpticalCorrection(transform: t))
        #expect(pixel(loose, 0, 99)[3] < 0.01 || pixel(loose, 159, 99)[3] < 0.01)
        #expect(pixel(loose, 80, 50)[3] > 0.99)
    }
    @Test func renderedPixelsMatchPointMapping() throws {
        let image = gradient()
        for (turn, flip) in [(0, false), (1, true), (2, false), (3, false)] {
            let settings = optics({ $0.vertical = -0.6; $0.rotate = 3; $0.constrain = false }, turn: turn, flip: flip)
            let output = try LensCorrections.apply(image, settings: settings, mask: true)
            #expect(output.extent == image.extent)
            for (x, y) in [(20, 80), (64, 48), (100, 10)] {
                let point = CGPoint(x: (Double(x)+0.5)/128, y: (Double(y)+0.5)/96)
                let mapped = LensCorrections.sourcePoint(point, size: image.extent.size, settings: settings)
                guard mapped.x > 0.02, mapped.x < 0.98, mapped.y > 0.02, mapped.y < 0.98 else { continue }
                #expect(abs(Double(pixel(output, x, y)[0]) - mapped.x) < 0.004)
            }
        }
    }
    @Test func correctedPointInvertsSourcePoint() {
        var lens = LensSettings(); lens.enabled = true; lens.manualDistortion = 0.5
        let size = CGSize(width: 400, height: 300)
        for settings in [optics({ $0.vertical = -0.7; $0.horizontal = 0.3; $0.rotate = -5 }, turn: 1, lens: lens), optics({ $0.scale = 1.4; $0.aspect = -0.5 }), OpticalCorrection(lens)] {
            for p in [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.6, y: 0.45), CGPoint(x: 0.5, y: 0.7)] {
                let source = LensCorrections.sourcePoint(p, size: size, settings: settings)
                let back = LensCorrections.correctedPoint(source, size: size, settings: settings)
                #expect(hypot(back.x-p.x, back.y-p.y) < 1e-4)
            }
        }
    }
    @Test func masksFollowThePerspective() throws {
        var edits = PhotoEdits(); edits.transformVertical = -0.6; edits.transformRotate = 2
        let size = CGSize(width: 120, height: 80), geometry = EditGeometry(size: size, edits: edits)
        var brush = AdjustmentMask(); brush.feather = 0
        brush.strokes = [MaskStroke(points: [MaskPoint(CGPoint(x: 0.3, y: 0.6)), MaskPoint(CGPoint(x: 0.35, y: 0.62))], radius: 0.06, subtract: false)]
        let red = CIImage(color: .red).cropped(to: CGRect(origin: .zero, size: size))
        let coverage = try brush.coverage(geometry: geometry, lens: edits.optics, input: red, modern: true)
        let expected = geometry.apply(try LensCorrections.apply(brush.image(size: size), settings: edits.optics, mask: true))
        #expect(pixels(coverage) == pixels(expected.cropped(to: coverage.extent)))
        // The painted spot lands where the corrected point says it does.
        let spot = LensCorrections.correctedPoint(CGPoint(x: 0.3, y: 0.6), size: size, settings: edits.optics)
        #expect(pixel(coverage, Int(spot.x*120), Int(spot.y*80))[0] > 0.5)
    }
    @Test func uprightVerticalMakesConvergingLinesParallel() throws {
        let size = CGSize(width: 1500, height: 1000)
        let lines = [LineSegment(CGPoint(x: 0.2, y: 0.1), CGPoint(x: 0.26, y: 0.9), weight: 800), LineSegment(CGPoint(x: 0.8, y: 0.1), CGPoint(x: 0.74, y: 0.9), weight: 800),
                     // The middle edge points at the same vanishing point (x = 0.5, y = 4.1) as the outer two.
                     LineSegment(CGPoint(x: 0.45, y: 0.15), CGPoint(x: 0.45 + 0.05*0.7/3.95, y: 0.85), weight: 600)]
        let solution = try #require(Upright.solve(.vertical, lines: lines, displaySize: size))
        #expect(solution.vertical < -0.1)
        var t = TransformSettings(); t.upright = solution; t.constrain = false
        let p = Perspective(t, sourceSize: size, orientation: DisplayOrientation(turn: 0, flip: false))
        for line in lines { #expect(abs(tilt(line, p, size: size, vertical: true)) < 0.3) }
        #expect(Upright.solve(.full, lines: [], displaySize: size) == nil)
        #expect(Upright.solve(.off, lines: lines, displaySize: size) == nil)
    }
    @Test func uprightLevelAndGuidedStraightenLines() throws {
        let size = CGSize(width: 1500, height: 1000), tilt3 = tan(3 * Double.pi/180)
        let horizon = LineSegment(CGPoint(x: 150/1500, y: 0.5), CGPoint(x: 1350/1500, y: (500 + 1200*tilt3)/1000), weight: 1200)
        let level = try #require(Upright.solve(.level, lines: [horizon], displaySize: size))
        #expect(abs(level.rotate + 3) < 0.1 && level.vertical == 0 && level.horizontal == 0)
        #expect(abs(try #require(Upright.straightenAngle(lines: [horizon], displaySize: size)) + 3) < 0.1)
        // Guided: the horizon plus an edge 600 px tall that leans 1° more than the camera roll.
        let lean = 4 * Double.pi/180
        let plumb = LineSegment(CGPoint(x: 0.3, y: 0.2), CGPoint(x: 0.3 - sin(lean)*600/1500, y: 0.2 + cos(lean)*600/1000))
        let guided = try #require(Upright.solve(.guided, lines: [horizon, plumb], displaySize: size))
        var t = TransformSettings(); t.upright = guided; t.constrain = false
        let p = Perspective(t, sourceSize: size, orientation: DisplayOrientation(turn: 0, flip: false))
        #expect(abs(tilt(horizon, p, size: size, vertical: false)) < 0.3)
        #expect(abs(tilt(plumb, p, size: size, vertical: true)) < 0.3)
    }
    @Test func detectsStraightEdgesInAPhoto() throws {
        let w = 400, h = 300, lean = 5 * Double.pi/180
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(gray: 0.2, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // A bright slab leaning 5° right, and a level band.
        ctx.setFillColor(gray: 0.9, alpha: 1)
        ctx.beginPath(); ctx.move(to: CGPoint(x: 100, y: 30)); ctx.addLine(to: CGPoint(x: 140, y: 30))
        ctx.addLine(to: CGPoint(x: 140 + 240*tan(lean), y: 270)); ctx.addLine(to: CGPoint(x: 100 + 240*tan(lean), y: 270)); ctx.closePath(); ctx.fillPath()
        ctx.fill(CGRect(x: 200, y: 200, width: 180, height: 30))
        let image = CIImage(cgImage: try #require(ctx.makeImage()))
        let lines = Upright.detectLines(image)
        let size = CGSize(width: w, height: h)
        let leaning = lines.filter { abs(tilt($0, nil, size: size, vertical: true) - 5) < 0.7 && hypot(($0.end.x-$0.start.x)*400, ($0.end.y-$0.start.y)*300) > 150 }
        #expect(!leaning.isEmpty)
        // Detected coordinates are normalized with y up: the slab's left edge starts near x = 100 at the bottom.
        #expect(leaning.contains { l in let bottom = l.start.y < l.end.y ? l.start : l.end; return abs(bottom.x*400 - (100 + (bottom.y*300-30)*tan(lean))) < 4 })
        #expect(lines.contains { abs(tilt($0, nil, size: size, vertical: false)) < 0.7 })
        #expect(Upright.detectLines(CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))).isEmpty)
    }
    @Test func batchCopiesManualTransformButNotGuides() throws {
        var e = PhotoEdits(); e.transformVertical = -0.3
        e.transform.guides = [GuideLine(CGPoint(x: 0.2, y: 0.1), CGPoint(x: 0.2, y: 0.9)), GuideLine(CGPoint(x: 0.7, y: 0.1), CGPoint(x: 0.72, y: 0.9))]
        e.transform.upright = UprightSolution(mode: .guided, rotate: 1, vertical: -0.2)
        var options = BatchOptions(); options.groups = [.transform]
        let copied = try BatchEdits.merging(e, into: PhotoEdits(), options: options, geometryCompatible: true)
        #expect(copied.transform.vertical == -0.3 && copied.transform.guides == nil && copied.transform.upright == nil)
        #expect(!AdjustmentGroup.defaults.contains(.transform))
        options.groups = [.develop]
        #expect(try BatchEdits.merging(e, into: PhotoEdits(), options: options, geometryCompatible: true).transform == TransformSettings())
        #expect(ClippingOverlay.geometryOnly(e).transform == e.transform)
    }
}
