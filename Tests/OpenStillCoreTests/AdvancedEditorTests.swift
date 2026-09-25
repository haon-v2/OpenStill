import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

@Suite final class AdvancedEditorTests {
    let context = CIContext()
    func solid(_ r:Double = 0.4,_ g:Double = 0.4,_ b:Double = 0.4) throws -> CGImage {
        try #require(context.createCGImage(CIImage(color:CIColor(red:r,green:g,blue:b)).cropped(to:CGRect(x:0,y:0,width:200,height:120)),from:CGRect(x:0,y:0,width:200,height:120)))
    }
    func pixel(_ image:CGImage,_ x:Int = 100,_ y:Int = 60) throws -> [Int] {
        let ctx = try #require(CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        let data = try #require(ctx.data).assumingMemoryBound(to:UInt8.self), i = (y*image.width+x)*4
        return (0..<4).map { Int(data[i+$0]) }
    }
    func raster(_ image:CIImage) throws -> CGImage { try #require(context.createCGImage(image,from:image.extent)) }
    @Test func monochromeAndTonalControlsChangePixels() throws {
        let image = try solid(0.6,0.3,0.1)
        var e = PhotoEdits(); e.monochrome = 0.5
        let half = try pixel(PhotoEditor.render(image,edits:e)); e.monochrome = 1
        let full = try pixel(PhotoEditor.render(image,edits:e))
        #expect(half[0]-half[2] > 10); #expect(abs(full[0]-full[2]) <= 2)
        let gray = try solid(0.2,0.2,0.2); e = PhotoEdits();e.blacks = -1
        let black = try pixel(PhotoEditor.render(gray,edits:e)); e.blacks = 1
        #expect(try pixel(PhotoEditor.render(gray,edits:e))[0] > black[0]+15)
        let white = try solid(0.8,0.8,0.8); e = PhotoEdits(); e.whites = -1
        let dark = try pixel(PhotoEditor.render(white,edits:e)); e.whites = 1
        #expect(try pixel(PhotoEditor.render(white,edits:e))[0] > dark[0]+15)
    }
    @Test func signedVignetteLeavesCenterAndChangesCorners() throws {
        let image = try solid(), baseline = try pixel(image)
        var e = PhotoEdits();e.vignette = -0.8
        let black = try PhotoEditor.render(image,edits:e);e.vignette = 0.8
        let white = try PhotoEditor.render(image,edits:e)
        #expect(try pixel(black,2,2)[0] < baseline[0]-20)
        #expect(try pixel(white,2,2)[0] > baseline[0]+20)
        #expect(try abs(pixel(black)[0]-baseline[0]) <= 2)
        #expect(try abs(pixel(white)[0]-baseline[0]) <= 2)
    }
    @Test func colorBandsAreSelectiveAndKeepNeutrals() throws {
        var e = PhotoEdits();e.ensureAdvanced();e.advanced!.colors[0].saturation = -1
        let red = try pixel(PhotoEditor.render(solid(0.8,0.05,0.05),edits:e))
        #expect(abs(red[0]-red[1]) < 5)
        let blueImage = try solid(0.05,0.05,0.8), blue = try pixel(PhotoEditor.render(blueImage,edits:e))
        #expect(try abs(blue[2]-pixel(blueImage)[2]) < 3); #expect(blue[2]-blue[0] > 80)
        e.advanced!.colors[0].hue = 1
        let gray = try pixel(PhotoEditor.render(solid(),edits:e)); #expect(abs(gray[0]-gray[2]) <= 2)
        e.advanced!.colors[0].saturation = 0
        let shifted = try pixel(PhotoEditor.render(solid(0.8,0.05,0.05),edits:e)); #expect(shifted[1] > red[1]/2)
    }
    @Test func linearGradientUsesFullDragAndSharedPreviewEndpoints() throws {
        var mask = AdjustmentMask(kind:"linear")
        #expect(mask.feather == 1)
        mask.start = MaskPoint(CGPoint(x:0.1,y:0.5));mask.end = MaskPoint(CGPoint(x:0.9,y:0.5))
        let size = CGSize(width:200,height:120)
        let low = CGPoint(x:20,y:60),high = CGPoint(x:180,y:60)
        let endpoints = AdjustmentMask.linearEndpoints(start:low,end:high,feather:1)
        #expect(endpoints.0 == low && endpoints.1 == high)
        // Mask weights are linear light; an sRGB screenshot gamma-encodes gray values.
        func coverage(_ image:CIImage,_ x:Int) -> Float {
            var rgba = [Float](repeating:0,count:4)
            rgba.withUnsafeMutableBytes { data in
                context.render(image,toBitmap:data.baseAddress!,rowBytes:16,bounds:CGRect(x:x,y:60,width:1,height:1),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB))
            }
            return rgba[0]
        }
        let image = try mask.image(size:size)
        let samples = [10,60,100,140,190].map { coverage(image,$0) }
        #expect(samples[0] < 0.01 && samples[4] > 0.99)
        #expect(abs(samples[1]-0.25) < 0.015)
        #expect(abs(samples[2]-0.5) < 0.015)
        #expect(abs(samples[3]-0.75) < 0.015)
        mask.inverted = true
        let inverted = try mask.image(size:size)
        for x in [10,60,100,140,190] { #expect(abs(coverage(image,x)+coverage(inverted,x)-1) < 0.01) }
        let narrow = AdjustmentMask.linearEndpoints(start:low,end:high,feather:0.5)
        #expect(narrow.0 == CGPoint(x:60,y:60) && narrow.1 == CGPoint(x:140,y:60))
        let reverse = AdjustmentMask.linearEndpoints(start:high,end:low,feather:0.5)
        #expect(reverse.0 == narrow.1 && reverse.1 == narrow.0)
        // Existing saved gradients keep their stored feather value.
        mask.feather = 0.3
        #expect(try JSONDecoder().decode(AdjustmentMask.self,from:JSONEncoder().encode(mask)).feather == 0.3)
    }
    @Test func masksArePerFeatureAndPersistThroughGeometry() throws {
        let image = try solid(); var e = PhotoEdits(); e.exposure = 2
        var mask = AdjustmentMask(kind:"linear");mask.start = MaskPoint(CGPoint(x:0.4,y:0.5));mask.end = MaskPoint(CGPoint(x:0.6,y:0.5));mask.feather = 1
        e.setMask(mask,for:"Develop")
        let masked = try PhotoEditor.render(image,edits:e)
        #expect(try abs(pixel(masked,10,60)[0]-pixel(image,10,60)[0]) <= 2)
        #expect(try pixel(masked,190,60)[0] > pixel(image,190,60)[0]+50)
        e.setMask(AdjustmentMask(),for:"Color") // empty unrelated mask must not block Develop
        #expect(try pixel(PhotoEditor.render(image,edits:e),190,60)[0] > 150)
        e.rotation = 1; e.flip = true; e.crop = EditRect(CGRect(x:0.1,y:0.1,width:0.8,height:0.8));e.straighten = 6
        let geometry = EditGeometry(size:CGSize(width:200,height:120),edits:e)
        let point = geometry.sourcePoint(CGPoint(x:0.4,y:0.4))
        let back = CGPoint(x:point.x*200,y:point.y*120).applying(geometry.transform)
        #expect(abs(back.x/geometry.extent.width-0.4) < 0.00001)
        #expect(abs(back.y/geometry.extent.height-0.4) < 0.00001)
        let result = try PhotoEditor.render(image,edits:e)
        #expect(result.width == 96 && result.height == 160)
        #expect(try pixel(result,1,1)[3] == 255)
        #expect(try JSONDecoder().decode(PhotoEdits.self,from:JSONEncoder().encode(e)) == e)
    }
    @Test func brushRadialAndInversionHaveRealCoverage() throws {
        var brush = AdjustmentMask();brush.feather = 0
        brush.strokes = [MaskStroke(points:[MaskPoint(CGPoint(x:0.5,y:0.5))],radius:0.2),MaskStroke(points:[MaskPoint(CGPoint(x:0.5,y:0.5))],radius:0.05,subtract:true)]
        let size = CGSize(width:200,height:120), cg = try raster(brush.image(size:size))
        #expect(try pixel(cg)[0] < 5); #expect(try pixel(cg,115,60)[0] > 250); #expect(try pixel(cg,5,5)[0] < 5)
        var radial = AdjustmentMask(kind:"radial");radial.start = MaskPoint(CGPoint(x:0.5,y:0.5));radial.end = MaskPoint(CGPoint(x:0.8,y:0.8))
        let r = try raster(radial.image(size:size));#expect(try pixel(r)[0] > 250);#expect(try pixel(r,2,2)[0] < 5)
        radial.inverted = true; let inv = try raster(radial.image(size:size));#expect(try pixel(inv)[0] < 5);#expect(try pixel(inv,2,2)[0] > 250)
    }
    @Test func newToolDoesNotInheritGlowMaskAndClearingIsToolLocal() throws {
        let input = try solid(0.6,0.4,0.2)
        var edits = PhotoEdits();edits.glow.amount = 70
        let empty = AdjustmentMask()
        edits.setMask(empty,for:"Glow")
        let original = try pixel(input)
        let maskedGlow = try pixel(PhotoEditor.render(input,edits:edits))
        for c in 0..<3 { #expect(abs(original[c]-maskedGlow[c]) <= 1) }
        edits.exposure = 1 // A newly used tool starts with whole-photo coverage.
        let develop = try pixel(PhotoEditor.render(input,edits:edits))
        #expect(develop[0] > maskedGlow[0]+25)
        edits.setMask(empty,for:"Develop")
        #expect(try pixel(PhotoEditor.render(input,edits:edits)) == maskedGlow)
        edits.setMask(nil,for:"Develop")
        #expect(edits.advanced?.masks["Glow"] == empty)
        #expect(try pixel(PhotoEditor.render(input,edits:edits)) == develop)
    }
    @Test func cubeIdentityAndMalformedData() throws {
        var lines = ["TITLE \"Identity\"","LUT_3D_SIZE 2"]
        for b in 0...1 { for g in 0...1 { for r in 0...1 { lines.append("\(r) \(g) \(b)") } } }
        let lut = try CubeLUT(text:lines.joined(separator:"\n")), input = try solid(0.2,0.6,0.8)
        let output = try raster(lut.apply(CIImage(cgImage:input)))
        for c in 0..<3 { #expect(try abs(pixel(output)[c]-pixel(input)[c]) <= 2) }
        #expect(throws:LUTError.self) { try CubeLUT(text:"LUT_3D_SIZE 33\n0 0 0") }
        #expect(throws:LUTError.self) { try CubeLUT(text:"LUT_3D_SIZE 9000") }
    }
    @Test func oldVignettesAndMonochromeMigrate() throws {
        var old = PhotoEdits();old.vignette = 0.5;old.blackAndWhite = true
        var json = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(old)) as? [String:Any]);json.removeValue(forKey:"schemaVersion");json.removeValue(forKey:"advanced")
        let migrated = try JSONDecoder().decode(PhotoEdits.self,from:JSONSerialization.data(withJSONObject:json)).sanitized
        #expect(migrated.vignette == -0.5);#expect(migrated.monochrome == 1)
        #expect(migrated.sanitized.vignette == -0.5)
    }
    @Test func latestAIResultMaskRemainsEditable() throws {
        let input = try solid(0.2,0.2,0.2), output = try solid(0.8,0.8,0.8)
        let prior = try EditStorage.newAsset(), next = try EditStorage.newAsset()
        defer { try? FileManager.default.removeItem(at:prior);try? FileManager.default.removeItem(at:next) }
        try PhotoEditor.write(input,to:prior);try PhotoEditor.write(output,to:next)
        var e = PhotoEdits();e.baseAsset = next.lastPathComponent;e.ensureAdvanced();e.advanced!.aiBackgroundAsset = prior.lastPathComponent;e.advanced!.aiFeatureKey = "Noise removal"
        var mask = AdjustmentMask(kind:"linear");mask.feather = 1;e.setMask(mask,for:"Noise removal")
        let result = try PhotoEditor.render(input,edits:e)
        #expect(try pixel(result,5,60)[0] < 100);#expect(try pixel(result,195,60)[0] > 190)
        mask.inverted = true;e.setMask(mask,for:"Noise removal")
        let inverted = try PhotoEditor.render(input,edits:e);#expect(try pixel(inverted,5,60)[0] > 190)
    }
    @Test func objectMaskBrushRefinementAndSunraysRespectUnselectedPixels() throws {
        let asset = try EditStorage.newAsset();defer { try? FileManager.default.removeItem(at:asset) }
        try PhotoEditor.write(solid(1,1,1),to:asset)
        var mask = AdjustmentMask(kind:"object");mask.asset = asset.lastPathComponent;mask.feather = 0
        mask.strokes = [MaskStroke(points:[MaskPoint(CGPoint(x:0.5,y:0.5))],radius:0.1,subtract:true)]
        let refined = try raster(mask.image(size:CGSize(width:200,height:120)))
        #expect(try pixel(refined)[0] == 0);#expect(try pixel(refined,5,5)[0] == 255)
        let dark = try solid(0.1,0.1,0.1);var edits = PhotoEdits();edits.sunrays = 1
        let light = try PhotoEditor.render(dark,edits:edits)
        for c in 0..<3 { #expect(try abs(pixel(light)[c]-pixel(dark)[c]) <= 2) }
    }

    @Test func hslLightnessIsSelectiveAndModesPersistPerColor() throws {
        let old = try JSONDecoder().decode(ColorBand.self,from:Data("{\"hue\":0.25,\"saturation\":-0.2}".utf8))
        #expect(old.lightness == nil && old.displayMode == nil && old.hue == 0.25)
        var edits = PhotoEdits();edits.ensureAdvanced();edits.advanced!.colors[0].lightness = 0.7;edits.advanced!.colors[0].displayMode = "hsl"
        edits.advanced!.colors[5].displayMode = "saturation"
        let red = try solid(0.7,0.1,0.1), blue = try solid(0.1,0.1,0.7)
        #expect(try pixel(PhotoEditor.render(red,edits:edits))[1] > pixel(red)[1]+40)
        for c in 0..<3 { #expect(try abs(pixel(PhotoEditor.render(blue,edits:edits))[c]-pixel(blue)[c]) <= 3) }
        let before = try pixel(PhotoEditor.render(red,edits:edits));edits.advanced!.colors[0].displayMode = "saturation"
        #expect(try pixel(PhotoEditor.render(red,edits:edits)) == before)
        let decoded = try JSONDecoder().decode(PhotoEdits.self,from:JSONEncoder().encode(edits))
        #expect(decoded.advanced!.colors[0].lightness == 0.7 && decoded.advanced!.colors[5].displayMode == "saturation")
        edits.advanced!.colors[0].lightness = -0.7
        #expect(try pixel(PhotoEditor.render(red,edits:edits))[0] < pixel(red)[0]-40)
    }
    @Test func brushStrengthSoftnessAndGradientRefinement() throws {
        var mask = AdjustmentMask();mask.feather = 0
        var stroke = MaskStroke(points:[MaskPoint(CGPoint(x:0.5,y:0.5))],radius:0.2)
        stroke.strength = 0.4;stroke.softness = 0;mask.strokes = [stroke]
        let size = CGSize(width:200,height:120), weak = try raster(mask.image(size:size))
        #expect(try pixel(weak)[0] > 30 && pixel(weak)[0] < 230)
        stroke.strength = 1;mask.strokes = [stroke];let hard = try raster(mask.image(size:size))
        #expect(try pixel(hard)[0] > 250)
        stroke.softness = 1;mask.strokes = [stroke];let soft = try raster(mask.image(size:size))
        #expect(try pixel(soft,128,60)[0] > pixel(hard,128,60)[0]+5)
        mask = AdjustmentMask(kind:"radial");mask.start = MaskPoint(CGPoint(x:0.5,y:0.5));mask.end = MaskPoint(CGPoint(x:0.9,y:0.9));mask.feather = 0.2
        stroke.softness = 0;stroke.subtract = true;mask.strokes = [stroke]
        let refined = try raster(mask.image(size:size));#expect(try pixel(refined)[0] < 5);#expect(try pixel(refined,135,60)[0] > 200)
        let decoded = try JSONDecoder().decode(AdjustmentMask.self,from:JSONEncoder().encode(mask));#expect(decoded.strokes[0].strength == 1 && decoded.strokes[0].softness == 0)
    }

}
