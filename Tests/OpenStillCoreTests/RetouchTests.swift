import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

@Suite struct RetouchTests {
    func fixture()->CIImage {
        var pixels=[Float](repeating:1,count:128*128*4)
        for y in 0..<128{for x in 0..<128{let value:Float=x<64 ? (x%2==0 ? 0.1:0.3):0.7;for c in 0..<3{pixels[(y*128+x)*4+c]=value}}}
        return CIImage(bitmapData:pixels.withUnsafeBufferPointer{Data(buffer:$0)},bytesPerRow:128*16,size:CGSize(width:128,height:128),format:.RGBAf,colorSpace:ModernRenderer.workingSpace)
    }
    func sample(_ image:CIImage,x:Int,y:Int=64)->Float {
        var pixel=[Float](repeating:0,count:4)
        ModernRenderer.context.render(image,toBitmap:&pixel,rowBytes:16,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBAf,colorSpace:ModernRenderer.workingSpace);return pixel[0]
    }
    func stroke(_ mode:RetouchMode)->RetouchStroke {RetouchStroke(mode:mode,source:CGPoint(x:0.25,y:0.5),destination:CGPoint(x:0.75,y:0.5),points:[CGPoint(x:0.75,y:0.5)],radius:0.1,feather:0,opacity:1)}
    @Test func cloningCopiesSourceAndProtectsOutsideBrush()throws{
        let input=fixture(),output=try Retouch.apply(input,strokes:[stroke(.clone)])
        #expect(abs(sample(output,x:96)-sample(input,x:32))<0.0001)
        #expect(abs(sample(output,x:97)-sample(input,x:33))<0.0001)
        #expect(abs(sample(output,x:120)-sample(input,x:120))<0.0001)
        var half=stroke(.clone);half.opacity=0.5
        #expect(abs(sample(try Retouch.apply(input,strokes:[half]),x:96)-0.4)<0.005)
    }
    @Test func healingTransfersTextureAndKeepsTargetTone()throws{
        let input=fixture(),output=try Retouch.apply(input,strokes:[stroke(.heal)])
        let a=sample(output,x:96),b=sample(output,x:97)
        #expect(abs((a+b)/2-0.7)<0.03);#expect(abs(a-b)>0.1)
        #expect(output.extent==input.extent)
    }
    @Test func alignedSourcePersistsAcrossStrokesAndUnalignedResets(){
        var session=RetouchSession();session.mode = .clone;session.setSource(CGPoint(x:0.2,y:0.2))
        let first=session.stroke(points:[CGPoint(x:0.6,y:0.6)],radius:0.1)!
        let next=session.stroke(points:[CGPoint(x:0.7,y:0.7)],radius:0.1)!
        #expect(abs(first.source.x-0.2)<0.0001);#expect(abs(next.source.x-0.3)<0.0001)
        session.aligned=false
        #expect(session.stroke(points:[CGPoint(x:0.8,y:0.8)],radius:0.1)!.source.x==0.2)
    }
    @Test func strokesSurviveHistoryAndTransformWithSource()throws{
        var edits=PhotoEdits();edits.retouch=[stroke(.clone)]
        var document=EditDocument(fingerprint:"fixture");document.commit(edits,title:"Clone stroke");document.undo();#expect(document.current.retouch.isEmpty);document.redo();#expect(document.current.retouch.count==1)
        let saved=try JSONDecoder().decode(EditDocument.self,from:JSONEncoder().encode(document));#expect(saved.current.retouch==edits.retouch)
        edits.rotation=1;edits.straighten=5;edits.crop=EditRect(CGRect(x:0.1,y:0.1,width:0.8,height:0.8));edits.lens.enabled=true;edits.lens.manualDistortion=0.3
        let geometry=EditGeometry(size:fixture().extent.size,edits:edits)
        let rendered=try ModernRenderer.process(fixture(),edits:edits)
        #expect(rendered.extent==geometry.extent)
        edits.setMask(AdjustmentMask(),for:"Retouch")
        let protected=try ModernRenderer.process(fixture(),edits:edits)
        edits.retouch=[];let plain=try ModernRenderer.process(fixture(),edits:edits)
        #expect(abs(sample(protected,x:50)-sample(plain,x:50))<0.0001)
    }
}
