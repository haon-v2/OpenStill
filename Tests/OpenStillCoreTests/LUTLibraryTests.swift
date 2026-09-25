import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

@Suite final class LUTLibraryTests {
    let bundle = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/LUTs")
    let context = CIContext()
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url
    }
    func image() throws -> CGImage {
        let image = CIFilter(name:"CILinearGradient",parameters:["inputPoint0":CIVector(x:0,y:0),"inputPoint1":CIVector(x:160,y:100),"inputColor0":CIColor(red:0.15,green:0.3,blue:0.6),"inputColor1":CIColor(red:0.85,green:0.55,blue:0.3)])!.outputImage!
        return try #require(context.createCGImage(image,from:CGRect(x:0,y:0,width:160,height:100)))
    }
    func pixels(_ image:CGImage) -> Data {
        var data = Data(count:image.width*image.height*4)
        data.withUnsafeMutableBytes { bytes in
            let ctx = CGContext(data:bytes.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        };return data
    }
    @Test func cleanOfflineCatalogHasTwelveValidDistinctLooks() throws {
        let empty = try temporary();defer { try? FileManager.default.removeItem(at:empty) }
        let library = try LUTLibrary(bundled:bundle,imported:empty)
        #expect(library.items.count == 12);#expect(library.filtered("Imported").isEmpty)
        for category in LUTLibrary.categories[1...4] { #expect(library.filtered(category).count == 3) }
        let original = try image();var signatures:Set<Data> = []
        for item in library.items {
            #expect(item.entry.license == "CC0-1.0");#expect(item.entry.source.hasPrefix("https://freshluts.com/luts/"))
            let lut = try item.load();#expect((2...65).contains(lut.dimension))
            var edits = PhotoEdits();edits.lutAmount = 0.7
            let output = try PhotoEditor.render(original,edits:edits,lutOverride:lut,previewMaxDimension:80)
            #expect(output.width <= 80 && output.height <= 80);signatures.insert(pixels(output))
        }
        #expect(signatures.count == 12)
    }
    @Test func importsKeepNamesAndProvenanceAndDetectTampering() throws {
        let folder = try temporary();defer { try? FileManager.default.removeItem(at:folder) }
        let original = bundle.appendingPathComponent("cool_cinema.cube")
        let imported = folder.appendingPathComponent("Test Look — Creator.cube")
        try FileManager.default.copyItem(at:original,to:imported)
        try Data("[{\"name\":\"Test Look\",\"creator\":\"Creator\",\"source\":\"https://example.com/look\"}]".utf8).write(to:folder.appendingPathComponent("sources.json"))
        let library = try LUTLibrary(bundled:bundle,imported:folder)
        let item = try #require(library.filtered("Imported").first)
        #expect(item.entry.creator == "Creator");#expect(item.entry.name == "Test Look — Creator")
        var legacy = PhotoEdits();legacy.ensureAdvanced();legacy.advanced!.lutAsset = "saved.cube";legacy.advanced!.lutName = item.entry.name
        #expect(library.selected(for:legacy) == item)
        let badBundle = folder.appendingPathComponent("Bad")
        try FileManager.default.copyItem(at:bundle,to:badBundle)
        let tampered = try #require(library.items.first)
        try Data("LUT_3D_SIZE 2\n".utf8).write(to:badBundle.appendingPathComponent(tampered.entry.filename))
        let bad = try LUTLibrary(bundled:badBundle,imported:folder)
        #expect(throws:LUTError.self) { try bad.items[0].load() }
    }
    @Test func previewReplacesPriorLUTAndPreservesMasksWithoutWrites() throws {
        let folder = try temporary();defer { try? FileManager.default.removeItem(at:folder) }
        let library = try LUTLibrary(bundled:bundle,imported:folder), original = try image()
        var edits = PhotoEdits();edits.exposure = 0.3;edits.rotation = 1
        edits.glow.mode = .softFocus;edits.glow.amount = 65
        edits.setMask(AdjustmentMask(kind:"radial"),for:"Glow")
        var mask = AdjustmentMask(kind:"linear");mask.feather = 1;edits.setMask(mask,for:"LUT")
        let first = try library.items[0].applying(to:edits)
        let second = try library.items[6].applying(to:first)
        defer { for e in [first,second] { if let name = e.advanced?.lutAsset { try? FileManager.default.removeItem(at:EditStorage.asset(name)) } } }
        #expect(second.exposure == edits.exposure && second.advanced?.masks == edits.advanced?.masks)
        #expect(second.glow == edits.glow)
        #expect(second.lutAmount == 0.7 && library.selected(for:second) == library.items[6])
        let before = Set(try FileManager.default.contentsOfDirectory(atPath:EditStorage.assets.path))
        let serialized = try JSONEncoder().encode(first)
        let preview = try PhotoEditor.render(original,edits:first,lutOverride:library.items[6].load())
        let applied = try PhotoEditor.render(original,edits:second)
        #expect(pixels(preview) == pixels(applied))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath:EditStorage.assets.path)) == before)
        #expect(try JSONDecoder().decode(PhotoEdits.self,from:serialized) == first)
        var history = EditDocument(fingerprint:"test");history.commit(first,title:"First");history.commit(second,title:"Second")
        history.undo();#expect(history.current == first);history.redo();#expect(history.current == second)
        var zero = second;zero.lutAmount = 0
        var removed = zero;removed.advanced!.lutAsset = nil;removed.advanced!.lutID = nil;removed.advanced!.lutName = nil
        #expect(try pixels(PhotoEditor.render(original,edits:zero)) == pixels(PhotoEditor.render(original,edits:removed)))
        let output = folder.appendingPathComponent("export.png");try PhotoEditor.write(applied,to:output)
        #expect(try pixels(PhotoDecoder.decode(output)) == pixels(applied))
    }
    @Test func stalePreviewGenerationsCannotDeliver() {
        let gate = LUTPreviewGeneration(), photoOne = gate.begin()
        #expect(gate.isCurrent(photoOne))
        let newEdits = gate.begin();#expect(!gate.isCurrent(photoOne));#expect(gate.isCurrent(newEdits))
        let photoTwo = gate.begin();#expect(!gate.isCurrent(newEdits));#expect(gate.isCurrent(photoTwo))
    }
}
