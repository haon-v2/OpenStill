import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import OpenStillCore

@Suite final class PhotoEditsTests {
    let directory: URL
    init() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func fixture() throws -> URL {
        let ctx = try #require(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)); ctx.fill(CGRect(x: 0,y: 0,width: 120,height: 80))
        let url = directory.appendingPathComponent("camera.jpg")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), [kCGImagePropertyTIFFDictionary:["Make":"Panasonic","Model":"DC-S9"], kCGImagePropertyExifDictionary:["LensModel":"LUMIX S 50/F1.8","ISOSpeedRatings":[400],"FNumber":2.8,"ExposureTime":0.004,"FocalLength":50]] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest)); return url
    }
    func rgb(_ image: CGImage) throws -> [UInt8] {
        let ctx = try #require(CGContext(data:nil,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image,in:CGRect(x:0,y:0,width:1,height:1));let data = try #require(ctx.data).assumingMemoryBound(to:UInt8.self);return [data[0],data[1],data[2]]
    }
    @Test func historyBranchesAndPersistsWithoutChangingOriginal() throws {
        let url = try fixture(), bytes = try Data(contentsOf: url)
        var doc = EditDocument(fingerprint: EditStorage.fingerprint(url)), edits = PhotoEdits()
        edits.exposure = 1;doc.commit(edits,title:"Exposure");edits.saturation = 0;doc.commit(edits,title:"B&W")
        doc.undo();#expect(doc.current.exposure == 1 && doc.current.saturation == 1)
        edits = doc.current;edits.contrast = 1.2;doc.commit(edits,title:"Contrast");doc.redo()
        #expect(doc.steps.map(\.title) == ["Original","Exposure","Contrast"])
        try EditStorage.save(doc,for:url);#expect(EditStorage.load(url).current == edits)
        #expect(try Data(contentsOf:url) == bytes)
        try Data("replaced source".utf8).write(to:url);#expect(EditStorage.load(url).current.isOriginal)
    }
    @Test func exposureCropRotationAndBlackWhiteRenderRealPixels() throws {
        let original = try PhotoDecoder.decode(fixture()), before = try rgb(original)
        var edit = PhotoEdits(); edit.exposure = 1
        let brighter = try rgb(PhotoEditor.render(original, edits:edit));#expect(brighter[0] > before[0]+10 && brighter[2] > before[2]+10)
        edit.blackAndWhite = true;let mono = try rgb(PhotoEditor.render(original,edits:edit));#expect(abs(Int(mono[0])-Int(mono[2])) <= 2)
        edit.rotation = 1;edit.crop = EditRect(CGRect(x:0.25,y:0.25,width:0.5,height:0.5))
        let crop = try PhotoEditor.render(original,edits:edit);#expect(crop.width == 40 && crop.height == 60)
        #expect(try PhotoEditor.render(original,edits:PhotoEdits()) === original)
    }
    @Test func exportedAndSharedEditsKeepMetadataAndProtectOriginal() throws {
        let url = try fixture(), bytes = try Data(contentsOf:url)
        var edits = PhotoEdits();edits.exposure = 1;edits.crop = EditRect(CGRect(x:0,y:0,width:0.5,height:1))
        edits.glow.mode = .softFocus; edits.glow.amount = 60
        let image = try PhotoEditor.render(source:url,edits:edits)
        #expect(throws:EditError.self) { try PhotoEditor.write(image,to:url,source:url,type:.jpeg) }
        let link = directory.appendingPathComponent("alias.jpg");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:url)
        #expect(throws:EditError.self) { try PhotoEditor.write(image,to:link,source:url,type:.jpeg) }
        let shared = try ShareExporter.prepare([url],format:.jpeg,in:directory.appendingPathComponent("share"),edits:[url:edits])[0]
        let metadata = PhotoMetadata.read(shared)
        #expect(metadata.camera.contains("DC-S9"));#expect(metadata.lens.contains("50/F1.8"));#expect(metadata.iso == "400")
        #expect(metadata.allFields.contains { $0.contains("LensModel") })
        #expect(try PhotoDecoder.decode(shared).width == 60)
        #expect(try rgb(PhotoDecoder.decode(shared))[0] > rgb(PhotoDecoder.decode(url))[0]+10)
        let originalCopy = try ShareExporter.prepare(url,format:.original,in:directory,edits:edits)
        #expect(try Data(contentsOf:originalCopy) == bytes);#expect(try Data(contentsOf:url) == bytes)
    }
    @Test func allAdjustmentFiltersRenderAndInvalidCropFails() throws {
        let source = try PhotoDecoder.decode(fixture());var e = PhotoEdits()
        e.autoEnhance = true;e.contrast = 1.1;e.highlights = 0.5;e.shadows = 0.3;e.temperature = 7200;e.tint = 5;e.vibrance = 0.2;e.structure = 0.2;e.sharpness = 0.3;e.denoise = 0.2;e.vignette = 0.2;e.sunrays = 0.2;e.opacity = 0.8
        let rendered = try PhotoEditor.render(source,edits:e);#expect(rendered.width == 120);#expect(try rgb(rendered).max()! > 10)
        e.crop = EditRect(CGRect(x:2,y:2,width:0.5,height:0.5));#expect(throws:EditError.self) { try PhotoEditor.render(source,edits:e) }
    }
}
