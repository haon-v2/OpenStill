import Foundation
import CoreImage
import ImageIO
import Testing
@testable import OpenStillCore

@Suite final class WorkflowFoundationTests {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
    }
    deinit { try? FileManager.default.removeItem(at:directory) }
    func source(_ name:String = "photo.jpg") throws -> URL {
        let url = directory.appendingPathComponent(name)
        let image = CIImage(color:CIColor(red:0.25,green:0.4,blue:0.6)).cropped(to:CGRect(x:0,y:0,width:40,height:30))
        try ModernRenderer.export(image, to:url, source:nil, settings:ExportSettings())
        return url
    }
    @Test func identityMovesReplacementAndDuplicateNames() throws {
        let store = PhotoRecordStore(root:directory.appendingPathComponent("app")), file = try source()
        var record = try store.record(for:file)
        var doc = record.active.document, edits = PhotoEdits(); edits.exposure = 1
        doc.commit(edits,title:"Exposure"); record.updateDocument(doc); try store.save(record)
        let moved = directory.appendingPathComponent("moved.jpg"); try FileManager.default.moveItem(at:file,to:moved)
        let relinked = try store.record(for:moved)
        #expect(relinked.id == record.id); #expect(relinked.active.document.current.exposure == 1)
        let duplicate = directory.appendingPathComponent("duplicate.jpg"); try FileManager.default.copyItem(at:moved,to:duplicate)
        #expect(try store.record(for:duplicate).id != record.id)
        try Data("replacement".utf8).write(to:moved)
        let replaced = try store.record(for:moved)
        #expect(replaced.id != record.id); #expect(replaced.active.document.current.isOriginal)
        #expect(try store.read(record.id).active.document.current.exposure == 1)
    }
    @Test func snapshotsRecoverAndKeepNamedVersions() throws {
        let store = PhotoRecordStore(root:directory), file = try source()
        var record = try store.record(for:file)
        for i in 0..<14 { record.duplicateVersion(named:"Version \(i)"); try store.save(record) }
        let snapshots = try FileManager.default.contentsOfDirectory(at:directory.appendingPathComponent("Recovery/\(record.id.uuidString)"), includingPropertiesForKeys:nil)
        #expect(snapshots.count == 10); #expect(try store.read(record.id).versions.count == 15)
        try Data("interrupted write".utf8).write(to:directory.appendingPathComponent("PhotoRecords/\(record.id.uuidString).json"))
        let recovered = try store.read(record.id)
        #expect(recovered.versions.count == 14)
        #expect(recovered.active.name == "Version 12")
    }
    @Test func legacyUpgradePreservesHistoryAndSourceSwitchResetsGeometry() throws {
        let file = try source(), store = PhotoRecordStore(root:directory)
        var doc = EditDocument(fingerprint:EditStorage.fingerprint(file)), edits = PhotoEdits()
        edits.exposure = 1; edits.crop = EditRect(CGRect(x:0.1,y:0,width:0.8,height:1)); edits.setMask(AdjustmentMask(kind:"linear"),for:"Glow")
        doc.commit(edits,title:"Edit")
        var record = try store.record(for:file,legacy:doc)
        #expect(record.active.renderer == .legacy)
        let legacy = record.active.id; record.upgrade()
        #expect(record.versions.count == 2); #expect(record.active.document.steps == doc.steps)
        #expect(record.versions.first { $0.id == legacy }?.renderer == .legacy)
        record.switchSource(to:.raw)
        #expect(record.versions.count == 3); #expect(record.active.document.current.isOriginal)
        #expect(record.active.sourceMode == .raw)
        let request = RenderRequest(photo:record)
        record.updateDocument(record.active.document)
        #expect(request != RenderRequest(photo:record))
    }
    @Test func exportsAreActually16BitAndProfileTagged() throws {
        var pixels:[Float] = []
        for y in 0..<2 { for x in 0..<2048 { let f = Float(x)/2047; pixels += [f,f,Float(y)*0.1+f*0.8,1] } }
        let data = pixels.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData:data,bytesPerRow:2048*16,size:CGSize(width:2048,height:2),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedSRGB)!)
        for profile in ExportProfile.allCases {
            for format in [ExportFormat.png,.tiff] {
                var settings = ExportSettings(); settings.format = format; settings.bitDepth = 16; settings.profile = profile
                let output = directory.appendingPathComponent("\(profile.rawValue).\(format.rawValue)")
                try ModernRenderer.export(image,to:output,source:nil,settings:settings)
                let io = try #require(CGImageSourceCreateWithURL(output as CFURL,nil))
                let cg = try #require(CGImageSourceCreateImageAtIndex(io,0,nil))
                #expect(cg.bitsPerComponent == 16); #expect(cg.width == 2048)
                let profileData = try #require(cg.colorSpace?.copyICCData())
                #expect(CFDataGetLength(profileData) > 100)
                let props = CGImageSourceCopyPropertiesAtIndex(io,0,nil) as? [String:Any]
                let profileName = props?[kCGImagePropertyProfileName as String] as? String ?? ""
                let expected = [ExportProfile.sRGB:"sRGB", .displayP3:"Display P3", .adobeRGB:"Adobe RGB", .proPhotoRGB:"ROMM RGB"]
                #expect(profileName.contains(expected[profile]!))
                print("Export profile \(profile.rawValue)/\(format.rawValue): \(profileName)")
                let values = try #require(cg.dataProvider?.data) as Data
                #expect(Set(values.withUnsafeBytes { Array($0.bindMemory(to:UInt16.self)) }).count > 256)
            }
        }
    }
    @Test func floatBridgeRetainsFractionalAndOutOfRangeSamples() throws {
        let values:[Float] = [0.12345,0.45678,1.23,1,-0.05,0.23456,0.98,1,0.2,0.4,0.6,0.5,0.7,0.8,0.9,1]
        let data = values.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData:data,bytesPerRow:32,size:CGSize(width:2,height:2),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedSRGB)!)
        let file = directory.appendingPathComponent("float.osfloat")
        try FloatImageBridge.write(image,to:file)
        let read = try FloatImageBridge.read(file)
        var result = [Float](repeating:0,count:16)
        ModernRenderer.context.render(read,toBitmap:&result,rowBytes:32,bounds:read.extent,format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedSRGB)!)
        for i in values.indices { #expect(abs(values[i]-result[i]) < 0.001) }
        var invalid = try Data(contentsOf:file); invalid[4] = 0
        try invalid.write(to:file); #expect(throws:PhotoReadError.self) { try FloatImageBridge.read(file) }
    }
    @Test func rawFailureIsExplicitAndControlsAreSanitized() throws {
        let file = try source()
        #expect(throws:RawDecodeError.self) { try RawDecoder.decode(file) }
        var raw = RawSettings(); raw.whiteBalance = [.nan,1,1,1]; raw.highlightRecovery = 99
        #expect(raw.sanitized.whiteBalance == nil); #expect(raw.sanitized.highlightRecovery == 9)
        #expect(RawDecoder.version == "0.22.2-Release")
        #expect(RawDecoder.defaultMode(for:file) == .original)
    }
    @Test func realS9Pair() throws {
        guard let path = ProcessInfo.processInfo.environment["OPENSTILL_S9_RAW"] else { return }
        let file = URL(fileURLWithPath:path), jpeg = file.deletingPathExtension().appendingPathExtension("jpg")
        #expect(RawDecoder.defaultMode(for:file) == .cameraLook)
        let start = Date(), raw = try RawDecoder.decode(file)
        #expect(raw.image.extent.width >= 5900); #expect(raw.image.extent.height >= 3900)
        #expect(raw.cameraWhiteBalance.count == 4)
        #expect(raw.sensorClippedFraction != nil)
        var edit = PhotoEdits(); edit.glow.amount = 25
        let render = try ModernRenderer.process(raw.image,edits:edit,maximumDimension:1200)
        var settings = ExportSettings(); settings.format = .png; settings.bitDepth = 16
        try ModernRenderer.export(render,to:directory.appendingPathComponent("RAW.png"),source:file,settings:settings)
        let camera = try RawDecoder.cameraPreview(file)
        func samples(_ image:CIImage)->[Float] {
            let small=image.transformed(by:CGAffineTransform(scaleX:16/image.extent.width,y:16/image.extent.height))
            var pixels=[Float](repeating:0,count:16*16*4)
            ModernRenderer.context.render(small,toBitmap:&pixels,rowBytes:16*16,bounds:CGRect(x:0,y:0,width:16,height:16),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
            var luma:[Float]=[]
            for i in 0..<256 {let k=i*4;let sum:Float=pixels[k]+pixels[k+1]+pixels[k+2];luma.append(sum/3)}
            let average=luma.reduce(0,+)/256
            return luma.map{$0/max(0.001,average)}
        }
        let a=samples(raw.image),b=samples(camera)
        let aligned=(0..<256).reduce(Float(0)){$0+abs(a[$1]-b[$1])}
        var flipped:Float=0
        for i in 0..<256 {let j=(15-i/16)*16+i%16;flipped += abs(a[i]-b[j])}
        #expect(aligned < flipped, "RAW row orientation must agree with the camera JPEG")
        #expect(camera.extent.width > 1000)
        #expect(PhotoMetadata.read(jpeg).camera.contains("DC-S9"))
        if let review = ProcessInfo.processInfo.environment["OPENSTILL_QA_OUTPUT"] {
            try ModernRenderer.export(render,to:URL(fileURLWithPath:review).appendingPathComponent("S9-RAW.png"),source:file,settings:settings)
            try ModernRenderer.export(ModernRenderer.process(camera,edits:edit,maximumDimension:1200),to:URL(fileURLWithPath:review).appendingPathComponent("S9-CameraLook.png"),source:file,settings:settings)
        }
        print("S9 RAW decode + 1200px glow/export: \(Date().timeIntervalSince(start))s; \(raw.image.extent)")
    }
}
