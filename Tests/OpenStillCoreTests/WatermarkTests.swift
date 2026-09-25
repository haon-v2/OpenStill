import Foundation
import CoreImage
import ImageIO
import Testing
@testable import OpenStillCore

@Suite struct WatermarkTests {
    @Test func vectorDesignRetainsExactTextAndExports()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var design=LogoDesign(name:"Alex & Sam",tagline:"Light < moments >");design.color=LogoColor("#FFFFFF")
        let vector=try LogoRenderer.vector(design),svg=vector.svg(title:design.name+" · "+design.tagline)
        #expect(svg.contains("Alex &amp; Sam"));#expect(svg.contains("&lt; moments &gt;"));#expect(!svg.contains("<text"))
        let parsed=try StaticSVG.read(Data(svg.utf8));#expect(parsed.elements.count==vector.elements.count)
        for ext in ["svg","pdf","png"]{let url=root.appendingPathComponent("logo."+ext);try Watermarks.export(design,to:url);let image=try Watermarks.image(url,maximum:1000);#expect(image.extent.width>100);#expect(image.extent.height>50)}
        let cg=try vector.raster(maximum:1000);let data=try #require(cg.dataProvider?.data) as Data;#expect(data[3]==0)
    }
    @Test func staticSVGSupportsShapesTransformsArcsAndRejectsActiveContent()throws {
        let svg="<svg viewBox='0 0 100 80'><g transform='translate(5 10) scale(2)' fill='#fff' stroke='#123456' stroke-width='2'><path d='M0 0 L20 0 A10 10 0 0 1 20 20 Z'/><rect x='2' y='3' width='4' height='5'/></g></svg>"
        let vector=try StaticSVG.read(Data(svg.utf8));#expect(vector.elements.count==2)
        let point=CGPoint(x:1,y:1).applying(vector.elements[0].transform);#expect(point.x==7 && point.y==12)
        for content in ["<svg><script>alert(1)</script></svg>","<!DOCTYPE svg [<!ENTITY a SYSTEM 'file:///etc/passwd'>]><svg>&a;</svg>","<svg viewBox='0 0 10 10'><image href='https://example.com/a.png'/></svg>","<svg viewBox='0 0 10 10'><rect width='10' height='10' fill='url(#remote)'/></svg>","<svg viewBox='0 0 10 10'><path d='M1 2 R4 5'/></svg>"]{#expect(throws:LogoError.self){try StaticSVG.read(Data(content.utf8))}}
    }
    @Test func placementUsesNineAnchorsAndNeverChangesSource()throws {
        let source=CIImage(color:CIColor(red:0.2,green:0.3,blue:0.4)).cropped(to:CGRect(x:0,y:0,width:300,height:200))
        let logo=try Watermarks.saveDesign(LogoDesign(name:"Photographer"));var settings=WatermarkSettings(asset:logo.asset)
        defer{try? FileManager.default.removeItem(at:EditStorage.asset(logo.asset))}
        var positions=Set<String>()
        for anchor in WatermarkAnchor.allCases {settings.anchor=anchor;let rect=Watermarks.rect(image:source.extent.size,logo:CGSize(width:1000,height:300),settings:settings);#expect(source.extent.contains(rect));positions.insert("\(rect.origin)");let output=try Watermarks.apply(source,settings:settings);#expect(output.extent==source.extent)}
        #expect(positions.count==9)
        settings.opacity=0;#expect(try Watermarks.apply(source,settings:settings) === source)
        var export=ExportSettings();export.watermark=settings;#expect(try JSONDecoder().decode(ExportSettings.self,from:JSONEncoder().encode(export)).watermark==settings)
    }
    @Test func modelSchemaOutputCannotChangeExactText()throws {
        let candidates=[LogoSuggestion(),LogoSuggestion(),LogoSuggestion()]
        let json=try JSONEncoder().encode(["candidates":candidates])
        let result=try LogoInference.decode(json,name:"Exact Àrda",tagline:"Photography",color:LogoColor("#ffffff"),accent:LogoColor("#888888"))
        #expect(result.count==3);#expect(result.allSatisfy{$0.name=="Exact Àrda" && $0.tagline=="Photography"})
        #expect(throws:(any Error).self){try LogoInference.decode(Data("{\"candidates\":[{\"script\":\"run code\"}]}".utf8),name:"A",tagline:"",color:LogoColor("#fff"),accent:LogoColor("#fff"))}
    }
    @Test func realOfflineModel()throws {
        guard let model=ProcessInfo.processInfo.environment["OPENSTILL_LOGO_MODEL"],let helper=ProcessInfo.processInfo.environment["OPENSTILL_LOGO_HELPER"] else{return}
        let manifest=try LogoModelManifest.load();#expect(try PhotoRecordStore.contentHash(URL(fileURLWithPath:model))==manifest.model.sha256)
        let start=Date(),results=try LogoInference().generate(helper:URL(fileURLWithPath:helper),model:URL(fileURLWithPath:model),name:"Sample Studio",tagline:"Photography",style:"Minimal, refined automotive photography",symbol:"aperture or monogram",color:LogoColor("#FFFFFF"),accent:LogoColor("#D8C5A6"))
        #expect(results.count==3);#expect(results.allSatisfy{$0.name=="Sample Studio"});print("Local logo model: \(Date().timeIntervalSince(start)) seconds")
        if let folder=ProcessInfo.processInfo.environment["OPENSTILL_LOGO_QA"]{for (index,design) in results.enumerated(){try Watermarks.export(design,to:URL(fileURLWithPath:folder).appendingPathComponent("candidate-\(index+1).png"))}}
    }
}
