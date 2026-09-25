import Foundation
import CoreImage
import ImageIO
import Testing
@testable import OpenStillCore

@Suite struct LensCorrectionsTests {
    func gradient(_ size:Int = 128)->CIImage {
        CIFilter(name:"CILinearGradient",parameters:["inputPoint0":CIVector(x:0,y:0),"inputPoint1":CIVector(x:Double(size),y:0),"inputColor0":CIColor.black,"inputColor1":CIColor.white])!.outputImage!.cropped(to:CGRect(x:0,y:0,width:size,height:size))
    }
    func pixels(_ image:CIImage)->[Float] {
        let w=Int(image.extent.width),h=Int(image.extent.height);var data=[Float](repeating:0,count:w*h*4)
        ModernRenderer.context.render(image,toBitmap:&data,rowBytes:w*16,bounds:image.extent,format:.RGBAf,colorSpace:ModernRenderer.workingSpace);return data
    }
    @Test func profilesAreBundledUniqueAndHaveCalibrations() throws {
        let profiles=LensLibrary.shared.profiles
        #expect(profiles.count > 1000)
        #expect(Set(profiles.map(\.id)).count == profiles.count)
        #expect(profiles.contains{$0.name.contains("20-60") && $0.capabilities & 8 != 0})
        #expect(profiles.allSatisfy{!$0.name.isEmpty && $0.crop > 0})
    }
    @Test func disabledIdentityAndManualCoordinatesAreSharedWithMasks() throws {
        let image=gradient()
        #expect(try LensCorrections.apply(image,settings:LensSettings()) === image)
        var settings=LensSettings();settings.enabled=true;settings.manualDistortion=0.8
        let output=try LensCorrections.apply(image,settings:settings,mask:true),data=pixels(output)
        #expect(output.extent == image.extent);#expect(data.allSatisfy{$0.isFinite})
        let point=CGPoint(x:0.25,y:0.25),mapped=LensCorrections.sourcePoint(point,size:image.extent.size,settings:settings)
        #expect(mapped.x < point.x && mapped.y < point.y)
        let sample=pixels(output.cropped(to:CGRect(x:32,y:32,width:1,height:1)))[0]
        let samplePoint=LensCorrections.sourcePoint(CGPoint(x:32.5/128,y:32.5/128),size:image.extent.size,settings:settings)
        #expect(abs(Double(sample)-samplePoint.x)<0.002)
    }
    @Test func verticalMapMatchesBrushCoordinates() throws {
        let image=CIFilter(name:"CILinearGradient",parameters:["inputPoint0":CIVector(x:0,y:0),"inputPoint1":CIVector(x:0,y:128),"inputColor0":CIColor.black,"inputColor1":CIColor.white])!.outputImage!.cropped(to:CGRect(x:0,y:0,width:128,height:128))
        var settings=LensSettings();settings.enabled=true;settings.manualDistortion=0.8
        let output=try LensCorrections.apply(image,settings:settings,mask:true)
        for y in [20,40,90,110] {
            let point=CGPoint(x:32.5/128,y:(Double(y)+0.5)/128)
            let mapped=LensCorrections.sourcePoint(point,size:image.extent.size,settings:settings)
            let sample=pixels(output.cropped(to:CGRect(x:32,y:y,width:1,height:1)))[0]
            #expect(abs(Double(sample)-mapped.y)<0.002)
        }
    }
    @Test func profileRenderingIsFiniteAndPreservesMaskLevels() throws {
        let profile=try #require(LensLibrary.shared.profiles.first{$0.name.contains("20-60") && $0.capabilities & 8 != 0})
        var settings=LensSettings();settings.enabled=true;settings.profileID=profile.id;settings.focal=20;settings.crop=1;settings.aperture=5.6
        let image=gradient(96)
        let output=try LensCorrections.apply(image,settings:settings)
        #expect(output.extent == image.extent);#expect(pixels(output).allSatisfy{$0.isFinite})
        let white=CIImage(color:.white).cropped(to:image.extent)
        let mask=pixels(try LensCorrections.apply(white,settings:settings,mask:true))
        #expect(mask.allSatisfy{abs($0-1)<0.002})
        #expect(pixels(output) != pixels(image))
        settings.profileID="missing-profile"
        #expect(throws:LensError.self){try LensCorrections.apply(image,settings:settings)}
    }
    @Test func jpegDefaultsOffAndSettingsRoundTrip() throws {
        var e=PhotoEdits();e.lens.enabled=true;e.lens.manualDistortion = -0.4
        let saved=try JSONDecoder().decode(PhotoEdits.self,from:JSONEncoder().encode(e));#expect(saved.lens == e.lens)
        #expect(!PhotoEdits().lens.enabled)
        #expect(!LensLibrary.shared.suggested(for:URL(fileURLWithPath:"/missing.jpg")).enabled)
        var settings=LensSettings();settings.focal = .nan;settings.crop = -1;settings.manualVignette = .infinity
        #expect(settings.sanitized.focal == 50);#expect(settings.sanitized.crop == 0.1);#expect(settings.sanitized.manualVignette == 0)
    }
    @Test func curveDrawingMatchesIdentityAndControlPoints(){
        for i in 0...100 {let x=Double(i)/100;#expect(abs(ToneCurves.value(at:x,points:ToneCurves.identity)-x)<0.000001)}
        let points=[0.0,0.1,0.8,0.9,1]
        for i in 0..<5 {#expect(abs(ToneCurves.value(at:Double(i)/4,points:points)-points[i])<0.000001)}
        #expect((0...1000).allSatisfy{let y=ToneCurves.value(at:Double($0)/1000,points:points);return y>=0 && y<=1})
    }
}
