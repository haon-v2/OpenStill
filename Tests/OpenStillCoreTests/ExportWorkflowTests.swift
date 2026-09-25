import Foundation
import CoreImage
import ImageIO
import Testing
@testable import OpenStillCore

@Suite struct ExportWorkflowTests {
    @Test func queueKeepsCompletedFilesRetriesFailuresAndAvoidsCollisions()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let store=PhotoRecordStore(root:root)
        let image=CIImage(color:CIColor(red:0.3,green:0.6,blue:0.1)).cropped(to:CGRect(x:0,y:0,width:100,height:60))
        var items:[ShootItem]=[]
        for name in ["a","b"]{let url=root.appendingPathComponent(name+".jpg");try ModernRenderer.export(image,to:url,source:nil,settings:ExportSettings());items.append(ShootItem(url:url,record:try store.record(for:url),captured:Date()))}
        let bytes=try Data(contentsOf:items[1].url);try FileManager.default.removeItem(at:items[1].url)
        var settings=ExportSettings();settings.filenameTemplate="{name}";settings.longestEdge=50
        let batch=ExportBatch(items:items,settings:settings,directory:root)
        let first=ExportWorkflow.run(batch)
        #expect(first.jobs[0].state == .complete);#expect(first.jobs[0].output?.lastPathComponent=="a-1.jpg");#expect(first.jobs[1].state == .failed)
        let output=try #require(first.jobs[0].output),hash=try PhotoRecordStore.contentHash(output)
        let io=try #require(CGImageSourceCreateWithURL(output as CFURL,nil)),cg=try #require(CGImageSourceCreateImageAtIndex(io,0,nil));#expect(cg.width==50);#expect(cg.height==30)
        try bytes.write(to:items[1].url)
        let second=ExportWorkflow.run(first);#expect(second.jobs.allSatisfy{$0.state == .complete});#expect(try PhotoRecordStore.contentHash(output)==hash)
        #expect(try PhotoRecordStore.contentHash(items[0].url)==items[0].record.contentFingerprint)
        #expect(ExportWorkflow.run(batch,cancelled:{true}).jobs.allSatisfy{$0.state == .cancelled})
    }
    @Test func templatesPresetsAndDefaults()throws {
        let url=URL(fileURLWithPath:"/fixtures/photo.jpg"),record=PhotoRecord(source:url,fingerprint:"sha",version:EditVersion(name:"Print / warm",renderer:.linear2020,sourceMode:.original,document:EditDocument(fingerprint:"stat")))
        let job=ExportJob(ShootItem(url:url,record:record,captured:Date(timeIntervalSince1970:0)))
        var settings=ExportSettings();#expect(!settings.keepGPS);#expect(settings.quality==0.9);#expect(settings.profile == .sRGB)
        settings.filenameTemplate="{name}-{index}-{date}-{version}"
        #expect(try ExportWorkflow.filename(job,index:2,settings:settings)=="photo-003-1970-01-01-Print - warm.jpg")
        settings.filenameTemplate="../{name}";#expect(throws:ExportWorkflowError.self){try ExportWorkflow.filename(job,index:0,settings:settings)}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        settings=ExportSettings();settings.profile = .proPhotoRGB;settings.bitDepth=16;settings.format = .tiff
        try ExportPresets.save([ExportPreset(name:"Print",settings:settings)],root:root);#expect(ExportPresets.load(root:root).first?.settings==settings)
    }
    @Test func proofingKnownRGBProfileIsPreviewOnly()throws {
        let image=CIFilter(name:"CILinearGradient",parameters:["inputPoint0":CIVector(x:0,y:0),"inputPoint1":CIVector(x:64,y:0),"inputColor0":CIColor(red:0,green:0,blue:0),"inputColor1":CIColor(red:1,green:1,blue:1)])!.outputImage!.cropped(to:CGRect(x:0,y:0,width:64,height:8))
        let profile=ExportProfile.sRGB.colorSpace.copyICCData()! as Data
        #expect(SoftProof.validate(profile));#expect(!SoftProof.validate(Data("not icc".utf8)))
        func pixels(_ image:CIImage)->[Float]{var p=[Float](repeating:0,count:64*8*4);ModernRenderer.context.render(image,toBitmap:&p,rowBytes:64*16,bounds:image.extent,format:.RGBAf,colorSpace:ExportProfile.displayP3.colorSpace);return p}
        let original=pixels(image)
        let proof=try SoftProof.render(image,profile:profile,intent:.relative,paper:false,gamut:false),processed=pixels(proof)
        #expect(processed.allSatisfy{$0.isFinite});#expect(processed.count==original.count)
        #expect(zip(original,processed).allSatisfy{abs($0-$1)<0.015})
        #expect(pixels(image)==original)
        #expect(try SoftProof.apply(image,settings:ProofSettings()) === image)
        for intent in RenderingIntent.allCases{#expect(pixels(try SoftProof.render(image,profile:profile,intent:intent,paper:true,gamut:true)).allSatisfy{$0.isFinite})}
    }
    @Test func cmykChartMatchesOfficialLittleCMSTransicc()throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let profile=try Data(contentsOf:root.appendingPathComponent(".build/native-sources/little-cms2/testbed/test1.icc"))
        let samples:[Float]=[1,0,0,1,0,1,0,1,0,0,1,1,1,1,1,1,128/255,128/255,128/255,1]
        let space=ExportProfile.displayP3.colorSpace
        let image=CIImage(bitmapData:samples.withUnsafeBytes{Data($0)},bytesPerRow:80,size:CGSize(width:5,height:1),format:.RGBAf,colorSpace:space)
        func values(_ image:CIImage)->[Float]{var output=[Float](repeating:0,count:20);ModernRenderer.context.render(image,toBitmap:&output,rowBytes:80,bounds:image.extent,format:.RGBAf,colorSpace:space);return output}
        let actual=values(try SoftProof.render(image,profile:profile,intent:.relative,paper:false,gamut:false))
        // Official transicc 2.19.1, Display P3 -> SWOP test1.icc -> Display P3,
        // -t1 -m1 -b, 0..255 floating RGB, same five patches.
        let reference:[Float]=[218.8065,69.6785,64.9434,255,93.4958,177.8910,95.7490,255,76.0182,92.2506,162.4984,255,255.0012,254.9972,254.9994,255,133.9360,132.8924,132.6208,255]
        for i in actual.indices{#expect(abs(actual[i]-reference[i]/255)<0.004)}
        let warning=values(try SoftProof.render(image,profile:profile,intent:.relative,paper:false,gamut:true))
        #expect(warning[0]>0.99 && warning[1]<0.01 && warning[2]>0.99)
        let paper=values(try SoftProof.render(image,profile:profile,intent:.relative,paper:true,gamut:false))
        #expect(paper[12]<actual[12])
    }

}
