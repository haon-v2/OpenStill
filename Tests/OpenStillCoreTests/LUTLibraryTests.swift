import Foundation
import CoreImage
import CryptoKit
import Testing
@testable import OpenStillCore

@Suite final class LUTLibraryTests {
    let bundle = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/LUTs")
    let context = CIContext()
    static let legacyIDs = ["freshluts-1660","freshluts-169","freshluts-1015","freshluts-2426","freshluts-148","freshluts-357",
                            "freshluts-218","freshluts-285","freshluts-1053","freshluts-276","freshluts-166","freshluts-217"]
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
    func rgb(_ lut:CubeLUT) -> [Float] { lut.data.withUnsafeBytes { Array($0.bindMemory(to:Float.self)) } }

    @Test func packHoldsEveryLookWithLicenseCreditAndValidTable() throws {
        let empty = try temporary();defer { try? FileManager.default.removeItem(at:empty) }
        let started = Date()
        let library = try LUTLibrary(bundled:bundle,imported:empty)
        #expect(Date().timeIntervalSince(started) < 0.5)
        let ids = library.items.map(\.entry.id)
        #expect(ids.filter { $0.hasPrefix("freshluts-") }.count == 50)
        #expect(ids.filter { $0.hasPrefix("film-") }.count == 293)
        #expect(ids.filter { $0.hasPrefix("openstill-") }.count >= 70)
        #expect(library.filtered("Imported").isEmpty)
        for item in library.items {
            let e = item.entry
            #expect(item.isPacked && LUTLibrary.bundledCategories.contains(e.category))
            #expect(!e.creator.isEmpty && e.source.hasPrefix("https://") && !e.description.isEmpty)
            #expect(e.license == (e.id.hasPrefix("film-") ? "CC-BY-SA-4.0" : "CC0-1.0"))
            let lut = try item.load()
            #expect(lut.dimension == e.dimension)
            #expect(rgb(lut).allSatisfy { (0...1).contains($0) })
        }
        #expect(library.categories.first == "All" && !library.categories.contains("Imported"))
        #expect(Set(library.categories.dropFirst()) == Set(library.items.map(\.entry.category)))
    }
    @Test func savedEditsFromEarlierVersionsStillFindTheirLooks() throws {
        let empty = try temporary();defer { try? FileManager.default.removeItem(at:empty) }
        let library = try LUTLibrary(bundled:bundle,imported:empty), original = try image()
        var signatures:Set<Data> = []
        for id in Self.legacyIDs {
            let item = try #require(library.items.first { $0.entry.id == id })
            var saved = PhotoEdits();saved.ensureAdvanced();saved.advanced!.lutAsset = "saved.cube";saved.advanced!.lutID = id
            #expect(library.selected(for:saved) == item)
            var edits = PhotoEdits();edits.lutAmount = 0.7
            signatures.insert(pixels(try PhotoEditor.render(original,edits:edits,lutOverride:item.load(),previewMaxDimension:80)))
        }
        #expect(signatures.count == 12)
    }
    @Test func originalsAreExactWhereTheyPromiseToBe() throws {
        let library = try LUTLibrary(bundled:bundle,imported:try temporary())
        let neutral = try #require(library.items.first { $0.entry.id == "openstill-neutral" }).load(), n = neutral.dimension
        let values = rgb(neutral)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let i = ((b*n+g)*n+r)*4
            #expect(abs(values[i]-Float(r)/Float(n-1)) <= 1/255 && abs(values[i+1]-Float(g)/Float(n-1)) <= 1/255 && abs(values[i+2]-Float(b)/Float(n-1)) <= 1/255)
        } } }
        let mono = library.items.filter { $0.entry.id.hasPrefix("openstill-b-w-") }
        #expect(mono.count >= 8)
        for item in mono {
            let v = rgb(try item.load())
            #expect(stride(from:0,to:v.count,by:4).allSatisfy { v[$0] == v[$0+1] && v[$0+1] == v[$0+2] })
        }
    }
    @Test func tamperedPackIsRefused() throws {
        let folder = try temporary();defer { try? FileManager.default.removeItem(at:folder) }
        let copy = folder.appendingPathComponent("LUTs");try FileManager.default.copyItem(at:bundle,to:copy)
        let library = try LUTLibrary(bundled:copy,imported:folder), item = library.items[3]
        let handle = try FileHandle(forUpdating:copy.appendingPathComponent("Library.lutpack"))
        try handle.seek(toOffset:UInt64(item.entry.offset!+item.entry.length!/2));try handle.write(contentsOf:Data([0x55,0xAA,0x55]));try handle.close()
        #expect(throws:LUTError.self) { try item.load() }
    }
    @Test func versionOneCatalogsAndImportsStillLoad() throws {
        let folder = try temporary();defer { try? FileManager.default.removeItem(at:folder) }
        let pack = try LUTLibrary(bundled:bundle,imported:folder)
        let source = try #require(pack.items.first { $0.entry.id == "freshluts-218" })
        let text = try LUTPack.cubeText(pack:source.url,entry:source.entry), bytes = Data(text.utf8)
        let old = folder.appendingPathComponent("Old");try FileManager.default.createDirectory(at:old,withIntermediateDirectories:true)
        try bytes.write(to:old.appendingPathComponent("cool_cinema.cube"))
        let digest = SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
        try Data("{\"version\":1,\"revision\":\"x\",\"entries\":[{\"id\":\"freshluts-218\",\"name\":\"Cool Cinema\",\"category\":\"Automotive\",\"filename\":\"cool_cinema.cube\",\"creator\":\"Andy\",\"source\":\"https://freshluts.com/luts/218\",\"license\":\"CC0-1.0\",\"checksum\":\"\(digest)\",\"description\":\"d\"}]}".utf8).write(to:old.appendingPathComponent("catalog.json"))
        let imports = folder.appendingPathComponent("Imports");try FileManager.default.createDirectory(at:imports,withIntermediateDirectories:true)
        try bytes.write(to:imports.appendingPathComponent("Test Look — Creator.cube"))
        try Data("[{\"name\":\"Test Look\",\"creator\":\"Creator\",\"source\":\"https://example.com/look\"}]".utf8).write(to:imports.appendingPathComponent("sources.json"))
        let library = try LUTLibrary(bundled:old,imported:imports)
        #expect(library.items.count == 2 && library.categories == ["All","Automotive","Imported"])
        #expect(try library.items[0].load().data == source.load().data)
        let item = try #require(library.filtered("Imported").first)
        #expect(item.entry.creator == "Creator" && item.entry.name == "Test Look — Creator")
        var legacy = PhotoEdits();legacy.ensureAdvanced();legacy.advanced!.lutAsset = "saved.cube";legacy.advanced!.lutName = item.entry.name
        #expect(library.selected(for:legacy) == item)
        try Data("LUT_3D_SIZE 2\n".utf8).write(to:old.appendingPathComponent("cool_cinema.cube"))
        #expect(throws:LUTError.self) { try LUTLibrary(bundled:old,imported:imports).items[0].load() }
    }
    @Test func searchVariantsAndFamilies() throws {
        let library = try LUTLibrary(bundled:bundle,imported:try temporary())
        #expect(library.search("teal orange").contains { $0.entry.id == "openstill-teal-orange-subtle" })
        #expect(library.search("PORTRAIT 400").contains { $0.entry.id == "film-portrait-400-plus2" })
        #expect(library.search("cafe").isEmpty == library.search("café").isEmpty)
        #expect(library.search("zzzz-nothing").isEmpty && library.search("  ").count == library.items.count)
        let portrait = try #require(library.items.first { $0.entry.id == "film-portrait-400" })
        let variants = library.variants(of:portrait)
        #expect(variants.map { $0.entry.variant ?? "" } == ["−1","Normal","+1","+2"])
        let collapsed = library.collapsed(library.items)
        #expect(collapsed.contains(portrait) && !collapsed.contains(variants[0]))
        #expect(Set(collapsed.compactMap(\.entry.family)).count == collapsed.filter { $0.entry.family != nil }.count)
        #expect(variants[2].entry.displayName == "Portrait 400 +1" && portrait.entry.displayName == "Portrait 400")
    }
    @Test func previewReplacesPriorLUTAndPreservesMasksWithoutWrites() throws {
        let folder = try temporary();defer { try? FileManager.default.removeItem(at:folder) }
        let library = try LUTLibrary(bundled:bundle,imported:folder), original = try image()
        var edits = PhotoEdits();edits.exposure = 0.3;edits.rotation = 1
        edits.glow.mode = .softFocus;edits.glow.amount = 65
        edits.setMask(AdjustmentMask(kind:"radial"),for:"Glow")
        var mask = AdjustmentMask(kind:"linear");mask.feather = 1;edits.setMask(mask,for:"LUT")
        let first = try library.items[0].applying(to:edits)
        let second = try library.items[60].applying(to:first)
        defer { for e in [first,second] { if let name = e.advanced?.lutAsset { try? FileManager.default.removeItem(at:EditStorage.asset(name)) } } }
        #expect(second.exposure == edits.exposure && second.advanced?.masks == edits.advanced?.masks)
        #expect(second.glow == edits.glow)
        #expect(second.lutAmount == 0.7 && library.selected(for:second) == library.items[60])
        let before = Set(try FileManager.default.contentsOfDirectory(atPath:EditStorage.assets.path))
        let serialized = try JSONEncoder().encode(first)
        let preview = try PhotoEditor.render(original,edits:first,lutOverride:library.items[60].load())
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
