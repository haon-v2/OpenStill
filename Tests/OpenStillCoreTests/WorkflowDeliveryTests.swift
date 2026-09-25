import Foundation
import CoreImage
import ImageIO
import Testing
@testable import OpenStillCore

@Suite struct WorkflowDeliveryTests {
    @Test func metadataDefaultsAndBoundedPreviewAgreeWithExport() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("source.tiff"), output=root.appendingPathComponent("output.tiff")
        let image=CIImage(color:CIColor(red:1.1,green:0.4,blue:0.1,colorSpace:ExportProfile.displayP3.colorSpace)!).cropped(to:CGRect(x:0,y:0,width:16,height:16))
        let cg=try ModernRenderer.display(image)
        let writer=try #require(CGImageDestinationCreateWithURL(source as CFURL,"public.tiff" as CFString,1,nil))
        CGImageDestinationAddImage(writer,cg,[kCGImagePropertyTIFFDictionary:["Make":"Panasonic","Model":"DC-S9","Copyright":"Photographer"],kCGImagePropertyExifDictionary:["LensModel":"LUMIX S 20-60","ExposureTime":0.008],kCGImagePropertyGPSDictionary:["Latitude":40.0,"LatitudeRef":"N","Longitude":74.0,"LongitudeRef":"W"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(writer))
        var settings=ExportSettings();settings.format = .tiff;settings.bitDepth=16
        try ModernRenderer.export(image,to:output,source:source,settings:settings)
        let io=try #require(CGImageSourceCreateWithURL(output as CFURL,nil)),props=try #require(CGImageSourceCopyPropertiesAtIndex(io,0,nil) as? [String:Any])
        #expect(props[kCGImagePropertyGPSDictionary as String]==nil)
        let tiff=props[kCGImagePropertyTIFFDictionary as String] as? [String:Any],exif=props[kCGImagePropertyExifDictionary as String] as? [String:Any]
        #expect(tiff?["Model"] as? String == "DC-S9");#expect(tiff?["Copyright"] as? String == "Photographer");#expect(exif?["LensModel"] as? String == "LUMIX S 20-60")
        func sample(_ value:CIImage)->[Float] {var data=[Float](repeating:0,count:16*16*4);ModernRenderer.context.render(value,toBitmap:&data,rowBytes:16*16,bounds:value.extent,format:.RGBAf,colorSpace:ExportProfile.displayP3.colorSpace);return data}
        let preview=sample(try ModernRenderer.outputPreview(image,settings:settings)),exported=sample(try ModernRenderer.readImage(output))
        #expect(zip(preview,exported).allSatisfy{abs($0-$1)<0.002})
        settings.keepMetadata=false;try ModernRenderer.export(image,to:output,source:source,settings:settings)
        let stripped=PhotoMetadata.read(output);#expect(!stripped.camera.contains("DC-S9"))
    }
    @Test func importedLogoIsPrivateAndUnsupportedCharactersAreExplicit() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("logo.svg")
        try Data("<svg viewBox='0 0 100 100'><circle cx='50' cy='50' r='30' fill='#ffffff' fill-opacity='0.3'/></svg>".utf8).write(to:file)
        let logo=try Watermarks.importLogo(file);try FileManager.default.removeItem(at:file)
        #expect(try Watermarks.image(EditStorage.asset(logo.asset),maximum:200).extent.width==200)
        let original=try StaticSVG.read(Data(contentsOf:EditStorage.asset(logo.asset))),roundtrip=try StaticSVG.read(Data(original.svg().utf8))
        #expect(abs((roundtrip.elements[0].fill?.alpha ?? 0)-0.3)<0.001)
        #expect(throws:LogoError.self){try LogoRenderer.vector(LogoDesign(name:"Photographer 📷"))}
        #expect(try !LogoRenderer.vector(LogoDesign(name:"Àlex & Sam")).elements.isEmpty)
    }
    @Test func fullSizePerformanceAndRAWPreviewAgreement() throws {
        guard let rawPath=ProcessInfo.processInfo.environment["OPENSTILL_S9_RAW"],let jpegPath=ProcessInfo.processInfo.environment["OPENSTILL_PERFORMANCE_JPEG"] else{return}
        let rawURL=URL(fileURLWithPath:rawPath)
        var edits=PhotoEdits();edits.glow.amount=25;edits.glow.softness=50;edits.exposure=0.2
        let recipe=RenderRecipe(renderer:.linear2020,sourceMode:.raw,edits:edits)
        func realize(_ image:CIImage)throws{let cg=try ModernRenderer.display(image);let bytes=try #require(cg.dataProvider?.data);#expect(CFDataGetLength(bytes)>0)}
        var start=Date();let full=try ModernRenderer.render(source:rawURL,recipe:recipe)
        try realize(full);print("PERF S9 RAW 24MP full decode + glow: \(Date().timeIntervalSince(start))s")
        start=Date();let preview=try ModernRenderer.render(source:rawURL,recipe:recipe,maximumDimension:1600)
        try realize(preview);print("PERF S9 RAW interactive half-size decode + glow: \(Date().timeIntervalSince(start))s")
        func samples(_ image:CIImage)->[Float]{let scaled=image.transformed(by:CGAffineTransform(scaleX:32/image.extent.width,y:32/image.extent.height));var p=[Float](repeating:0,count:32*32*4);ModernRenderer.context.render(scaled,toBitmap:&p,rowBytes:32*16,bounds:CGRect(x:0,y:0,width:32,height:32),format:.RGBAf,colorSpace:ExportProfile.sRGB.colorSpace);return p}
        let a=samples(full),b=samples(preview);let error=zip(a,b).reduce(Float(0)){$0+abs($1.0-$1.1)}/Float(a.count)
        print("RAW interactive / full mean sample difference: \(error)");#expect(error<0.06)
        let source=try ModernRenderer.readImage(URL(fileURLWithPath:jpegPath))
        for scale:Double in [1,1.5] {let image=source.transformed(by:CGAffineTransform(scaleX:scale,y:scale));start=Date();try realize(ModernRenderer.process(image,edits:edits));print("PERF JPEG \(Int(image.extent.width*image.extent.height/1_000_000))MP glow: \(Date().timeIntervalSince(start))s")}
        start=Date();try realize(ModernRenderer.process(source,edits:edits,maximumDimension:1600));print("PERF JPEG interactive glow: \(Date().timeIntervalSince(start))s")
    }
}
