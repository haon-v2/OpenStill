import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

@Suite struct MaskComponentTests {
    let size=CGSize(width:100,height:80)
    var input:CIImage {CIImage(color:CIColor(red:0.4,green:0.4,blue:0.4)).cropped(to:CGRect(origin:.zero,size:size))}
    func pixels(_ image:CIImage)->[Float] {
        let w=Int(image.extent.width),h=Int(image.extent.height);var p=[Float](repeating:0,count:w*h*4)
        ModernRenderer.context.render(image,toBitmap:&p,rowBytes:w*16,bounds:image.extent,format:.RGBAf,colorSpace:ModernRenderer.workingSpace);return p
    }
    func coverage(_ mask:AdjustmentMask,edits:PhotoEdits = PhotoEdits())throws->CIImage {
        let geometry=EditGeometry(size:size,edits:edits)
        return try mask.coverage(geometry:geometry,lens:edits.lens,input:geometry.apply(input),modern:true)
    }
    @Test func legacyMigrationPreservesCoverageAndCopyIsIndependent()throws{
        var old=AdjustmentMask(kind:"linear");old.inverted=true;old.feather=0.7
        let before=pixels(try coverage(old))
        var migrated=old;migrated.replaceComponents(old.namedComponents)
        let migratedPixels=pixels(try coverage(migrated)); let migrationError=zip(migratedPixels,before).map{abs($0-$1)}.max() ?? 0
        #expect(migrationError < 0.00001)
        var copy=migrated.independentCopy();copy.components![0].selection.inverted.toggle()
        #expect(copy.components![0].id != migrated.components![0].id)
        #expect(migrated.components![0].selection.inverted)
        var edits=PhotoEdits();edits.setMask(migrated,for:"Glow");edits.setMask(copy,for:"Curves")
        let saved=try JSONDecoder().decode(PhotoEdits.self,from:JSONEncoder().encode(edits))
        #expect(saved.advanced?.masks["Glow"]==migrated);#expect(saved.advanced?.masks["Curves"]==copy)
    }
    @Test func componentOpacityVisibilityAndOperations()throws{
        var full=AdjustmentMask();full.inverted=true
        var a=MaskComponent(name:"Base",selection:full);a.opacity=0.8
        var b=MaskComponent(name:"Subtract",selection:full);b.opacity=0.25;b.operation = .subtract
        var root=AdjustmentMask(kind:"stack");root.components=[a,b]
        #expect(abs(pixels(try coverage(root))[0]-0.6)<0.001)
        root.components![1].operation = .intersect
        #expect(abs(pixels(try coverage(root))[0]-0.2)<0.001)
        root.components![1].visible=false
        #expect(abs(pixels(try coverage(root))[0]-0.8)<0.001)
        root.components![1].visible=true;root.components![1].operation = .add
        #expect(abs(pixels(try coverage(root))[0]-0.8)<0.001)
        root.inverted=true
        #expect(abs(pixels(try coverage(root))[0]-0.2)<0.001)
    }
    @Test func rangeMaskSamplesToolInputWithoutFeedback()throws{
        let gray=CIImage(color:CIColor(red:0.4,green:0.4,blue:0.4)).cropped(to:CGRect(origin:.zero,size:size))
        var range=AdjustmentMask(kind:"luminanceRange");range.feather=0;range.range=RangeSelection();range.range!.low=0.3;range.range!.high=0.5;range.range!.softness=0.02
        var edits=PhotoEdits();edits.exposure=2;edits.setMask(range,for:"Develop")
        let output=pixels(try ModernRenderer.process(gray,edits:edits)),plain=pixels(try ModernRenderer.process(gray,edits:PhotoEdits()))
        #expect(output[0]>plain[0]*3.8)
        edits.exposure=3
        let more=pixels(try ModernRenderer.process(gray,edits:edits));#expect(more[0]>output[0]*1.9)
        let incoming=try ModernRenderer.process(gray,edits:edits,stopBeforeTool:"Develop")
        #expect(pixels(incoming)==plain)
    }
    @Test func colorRangeAndGeometryStayAligned()throws{
        let red=CIImage(color:CIColor(red:1,green:0,blue:0)).cropped(to:CGRect(origin:.zero,size:size))
        var range=AdjustmentMask(kind:"colorRange");range.range=RangeSelection();range.feather=0
        let geometry=EditGeometry(size:size,edits:PhotoEdits())
        let match=try range.coverage(geometry:geometry,lens:LensSettings(),input:red,modern:true)
        #expect(pixels(match)[0]>0.99)
        range.range!.red=0;range.range!.blue=1
        #expect(pixels(try range.coverage(geometry:geometry,lens:LensSettings(),input:red,modern:true))[0]<0.01)
        var edits=PhotoEdits();edits.rotation=1;edits.straighten=7;edits.crop=EditRect(CGRect(x:0.1,y:0.2,width:0.7,height:0.7));edits.lens.enabled=true;edits.lens.manualDistortion=0.4
        let shape=AdjustmentMask(kind:"linear"),geom=EditGeometry(size:size,edits:edits)
        var stack=AdjustmentMask(kind:"stack");stack.components=[MaskComponent(name:"Gradient",selection:shape)]
        let a=try stack.coverage(geometry:geom,lens:edits.lens,input:geom.apply(red),modern:true)
        let b=geom.apply(try LensCorrections.apply(shape.image(size:size),settings:edits.lens,mask:true))
        #expect(a.extent==geom.extent);let alignmentError=zip(pixels(a),pixels(b)).map{abs($0-$1)}.max() ?? 0;#expect(alignmentError < 0.00001)
    }
}
