import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

@Suite final class SunraysTests {
    let context = CIContext(options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!])
    let extent = CGRect(x:0,y:0,width:320,height:240)
    func input() -> CIImage {CIImage(color:CIColor(red:0.15,green:0.18,blue:0.12)).cropped(to:extent)}
    func pixels(_ image:CIImage) -> [Float] {
        var values = [Float](repeating:0,count:Int(extent.width*extent.height)*4)
        context.render(image,toBitmap:&values,rowBytes:320*16,bounds:extent,format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
        return values
    }
    func render(_ s:SunraysSettings) throws -> CIImage {
        try PhotographicSunrays.apply(input(),settings:s,geometry:EditGeometry(size:extent.size,edits:PhotoEdits()))
    }
    @Test func identityLimitsAndRoundTrip() throws {
        var s = SunraysSettings()
        #expect(try pixels(render(s)) == pixels(input()))
        s.amount = .infinity; s.rayCount = -8; s.centerX = -0.3; s.centerY = 1.4
        #expect(s.sanitized.amount == 0 && s.sanitized.rayCount == 1)
        #expect(s.sanitized.centerX == -0.3 && s.sanitized.centerY == 1.4)
        s.amount = 60
        var e = PhotoEdits(); e.sunSettings = s
        #expect(try JSONDecoder().decode(PhotoEdits.self,from:JSONEncoder().encode(e)) == e)
        let old = PhotoEdits()
        #expect(try JSONDecoder().decode(PhotoEdits.self,from:JSONEncoder().encode(old)).advanced?.sunSettings == nil)
    }
    @Test func everyControlChangesLightAndSeedIsRepeatable() throws {
        var s = SunraysSettings(); s.amount = 80; s.centerX = 0.5; s.centerY = 0.5
        let baseline = try pixels(render(s))
        #expect(baseline.allSatisfy { $0.isFinite })
        for path in [\SunraysSettings.amount, \.overallLook, \.length, \.penetration, \.sunRadius, \.glowRadius, \.glowAmount, \.rayCount, \.randomize, \.sunWarmth, \.raysWarmth] {
            var changed = s; changed[keyPath:path] = 90
            #expect(try pixels(render(changed)) != baseline, "Control: \(path)")
        }
        #expect(try pixels(render(s)) == baseline)
    }
    @Test func offPhotoSourceLightsFrameWithoutDiskAndGeometryRoundTrips() throws {
        var s = SunraysSettings(); s.amount = 100; s.centerX = -0.1; s.centerY = 0.8; s.length = 100
        let rendered = try render(s), data = pixels(rendered), original = pixels(input())
        #expect(rendered.extent == extent)
        #expect(zip(data,original).contains{$0 > $1+0.01})
        #expect(stride(from:3,to:data.count,by:4).allSatisfy{abs(data[$0]-1)<0.0001})
        var noDisk = s; noDisk.sunRadius = 0
        #expect(try pixels(render(noDisk)) == data)
        var e = PhotoEdits(); e.rotation = 1; e.flip = true; e.straighten = 9; e.crop = EditRect(CGRect(x:0.2,y:0.1,width:0.7,height:0.8))
        let geometry = EditGeometry(size:extent.size,edits:e), p = CGPoint(x:-0.35,y:1.2)
        s.place(at:p,geometry:geometry)
        let result = s.displayedCenter(geometry:geometry)
        #expect(abs(result.x-p.x)<0.000001 && abs(result.y-p.y)<0.000001)
    }
    @Test func maskedPipelineAndBatchPreserveSettings() throws {
        var e = PhotoEdits(); e.sunSettings.amount = 80
        let original = try #require(context.createCGImage(input(),from:extent))
        var mask = AdjustmentMask(kind:"linear"); mask.start = MaskPoint(CGPoint(x:0.3,y:0.5)); mask.end = MaskPoint(CGPoint(x:0.7,y:0.5))
        e.setMask(mask,for:"Sunrays")
        let output = try PhotoEditor.render(original,edits:e)
        let data = pixels(CIImage(cgImage:output)), plain = pixels(CIImage(cgImage:original))
        for c in 0..<3 {#expect(abs(data[(120*320+5)*4+c]-plain[(120*320+5)*4+c])<0.005)}
        var options = BatchOptions(); options.groups = [.sunrays]
        let copied = try BatchEdits.merging(e,into:PhotoEdits(),options:options,geometryCompatible:false)
        #expect(copied.sunSettings == e.sunSettings && copied.advanced?.masks["Sunrays"] == nil)
    }
    @Test func previewAgreesWithFullResolution() throws {
        var e = PhotoEdits(); e.sunSettings.amount = 70; e.sunSettings.centerX = -0.1
        let size = CGSize(width:1280,height:960)
        let fullInput = input().transformed(by:CGAffineTransform(scaleX:4,y:4))
        let full = try PhotographicSunrays.apply(fullInput,settings:e.sunSettings,geometry:EditGeometry(size:size,edits:e)).transformed(by:CGAffineTransform(scaleX:0.25,y:0.25))
        let preview = try render(e.sunSettings), a = pixels(full), b = pixels(preview)
        let average = zip(a,b).reduce(0.0){$0+Double(abs($1.0-$1.1))}/Double(a.count)
        #expect(average < 0.01)
    }
}
