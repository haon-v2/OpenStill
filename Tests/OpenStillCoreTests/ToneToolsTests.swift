import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

@Suite struct ToneToolsTests {
    func sample(_ image:CIImage) -> [Float] {
        var pixels = [Float](repeating:0,count:4)
        ModernRenderer.context.render(image,toBitmap:&pixels,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:ModernRenderer.workingSpace)
        return pixels
    }
    @Test func neutralPickerBalancesWithoutSamplingOverlays() throws {
        let input = CIImage(color:CIColor(red:0.2,green:0.4,blue:0.6,colorSpace:ModernRenderer.workingSpace)!).cropped(to:CGRect(x:0,y:0,width:32,height:32))
        let neutral = try ToneTools.neutralSample(input,point:CGPoint(x:0.5,y:0.5))
        let balanced = sample(ToneTools.balance(input,settings:neutral))
        #expect(abs(balanced[0]-balanced[1]) < 0.001); #expect(abs(balanced[1]-balanced[2]) < 0.001)
        #expect(throws:EditError.self) { try ToneTools.neutralSample(CIImage(color:.black).cropped(to:input.extent),point:.zero) }
    }
    @Test func curvesAreIdentityByDefaultAndChannelsRemainIndependent() throws {
        let input = CIImage(color:CIColor(red:0.2,green:0.4,blue:0.6,colorSpace:ModernRenderer.workingSpace)!).cropped(to:CGRect(x:0,y:0,width:32,height:32))
        #expect(try ToneTools.applyCurves(input,settings:ToneCurves()) === input)
        var curves = ToneCurves(); curves.master[2] = 0.65
        let brighter = sample(try ToneTools.applyCurves(input,settings:curves)), before = sample(input)
        #expect(brighter[0] > before[0]); #expect(brighter[1] > before[1])
        curves = ToneCurves(); curves.red[2] = 0.7
        let output = try ToneTools.applyCurves(input,settings:curves)
        var srgbBefore = [Float](repeating:0,count:4), srgbAfter = srgbBefore
        let space = CGColorSpace(name:CGColorSpace.extendedSRGB)!
        ModernRenderer.context.render(input,toBitmap:&srgbBefore,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:space)
        ModernRenderer.context.render(output,toBitmap:&srgbAfter,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:space)
        #expect(srgbAfter[0] > srgbBefore[0]); #expect(abs(srgbAfter[1]-srgbBefore[1]) < 0.002); #expect(abs(srgbAfter[2]-srgbBefore[2]) < 0.002)
    }
    @Test func curveMaskAndHistoryRemainIndependent() throws {
        let source = CIImage(color:CIColor(red:0.4,green:0.4,blue:0.4)).cropped(to:CGRect(x:0,y:0,width:32,height:32))
        var e = PhotoEdits(); e.curves.master[2] = 0.7
        let plain = sample(try ModernRenderer.process(source,edits:PhotoEdits()))
        e.setMask(AdjustmentMask(),for:"Curves")
        let masked = sample(try ModernRenderer.process(source,edits:e))
        #expect(zip(plain,masked).allSatisfy { abs($0-$1) < 0.002 })
        e.setMask(nil,for:"Curves")
        var doc = EditDocument(fingerprint:"fixture"); doc.commit(e,title:"Curves"); doc.undo()
        #expect(doc.current.curves.isIdentity); doc.redo(); #expect(doc.current.curves == e.curves)
        let saved = try JSONDecoder().decode(PhotoEdits.self,from:JSONEncoder().encode(e)); #expect(saved.curves == e.curves)
    }
    @Test func histogramReportsOutputNotSensorClipping() {
        let red = CIImage(color:CIColor(red:1,green:0,blue:0)).cropped(to:CGRect(x:0,y:0,width:8,height:8))
        let histogram = PhotoHistogram.measure(red)
        #expect(histogram.red.reduce(0,+) == 64)
        #expect(histogram.red[255] == 64); #expect(histogram.highlightClipped == 1); #expect(histogram.shadowClipped == 1)
    }
    @Test func rawWhiteBalanceChangesDecoderAndSurvivesUndo() throws {
        guard let path = ProcessInfo.processInfo.environment["OPENSTILL_S9_RAW"] else { return }
        let url = URL(fileURLWithPath:path)
        let first = try RawDecoder.decode(url)
        var settings = RawSettings(); settings.temperature = 8000
        let warm = try RawDecoder.decode(url,settings:settings)
        let a = PhotoHistogram.measure(first.image), b = PhotoHistogram.measure(warm.image)
        #expect(a.red != b.red); #expect(a.blue != b.blue)
        #expect(first.sensorClippedFraction == warm.sensorClippedFraction)
        var e = PhotoEdits(); e.temperature = 8000
        let recipe = RenderRecipe(renderer:.linear2020,sourceMode:.raw,edits:e)
        #expect(recipe.raw.temperature == 8000)
        var doc = EditDocument(fingerprint:"fixture"); doc.commit(e,title:"WB"); doc.undo(); #expect(doc.current.temperature == 6500)
    }
}
