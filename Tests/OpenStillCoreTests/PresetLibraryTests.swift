import Foundation
import Testing
@testable import OpenStillCore

@Suite final class PresetLibraryTests {
    let resources = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
    var bundled: URL { resources.appendingPathComponent("Presets/presets.json") }
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url
    }
    /// A photo with photo-specific work a preset must never touch.
    func photo() -> PhotoEdits {
        var e = PhotoEdits();e.exposure = 0.7;e.temperature = 5000;e.clarity = 0.4;e.rotation = 1;e.flip = true
        e.crop = EditRect(CGRect(x:0.1,y:0.1,width:0.8,height:0.7));e.straighten = 3
        e.setMask(AdjustmentMask(kind:"radial"),for:"Glow");e.advanced!.lutAsset = "look.cube";e.advanced!.lutID = "x";e.lutAmount = 0.4
        e.eyeFixes = [EyeFix(kind:.redEye,center:CGPoint(x:0.3,y:0.4),radiusX:0.02,radiusY:0.02)]
        return e
    }
    func expectKeepsPhotoSpecifics(_ result:PhotoEdits, _ current:PhotoEdits) {
        #expect(result.crop == current.crop && result.rotation == current.rotation && result.flip == current.flip && result.straighten == current.straighten)
        #expect(result.advanced?.masks == current.advanced?.masks && result.eyeFixes == current.eyeFixes)
        #expect(result.advanced?.lutAsset == current.advanced?.lutAsset && result.lutAmount == current.lutAmount)
    }

    @Test func bundledPresetsAreValidAndTheirLooksExist() throws {
        let library = try PresetLibrary(bundled:bundled,user:try temporary())
        let looks = try LUTLibrary(bundled:resources.appendingPathComponent("LUTs"),imported:try temporary())
        #expect(library.presets.count >= 60)
        #expect(Set(library.presets.map(\.category)).count >= 12)
        for preset in library.presets {
            #expect(preset.problems.isEmpty && !preset.description.isEmpty)
            if let lut = preset.lut { #expect(looks.items.contains { $0.entry.id == lut.id }, "\(preset.name) uses \(lut.id)") }
        }
        #expect(library.categories.first == "All" && library.categories.last == PresetLibrary.myPresets)
        #expect(library.search("teal").contains { $0.name == "Teal & Orange" })
    }
    @Test func theSixOriginalPresetsGiveTheSameEditsAsBefore() throws {
        let library = try PresetLibrary(bundled:bundled,user:try temporary()), current = photo()
        func before(_ name:String) -> PhotoEdits {  // OpenStill's presets up to 0.0.18
            var e = current
            e.highlightsAmount = 0; e.shadowsAmount = 0; e.exposure = 0; e.contrast = 1; e.saturation = 1; e.vibrance = 0; e.temperature = 6500; e.tint = 0; e.monochrome = 0; e.blacks = 0; e.whites = 0; e.advanced!.colors = [ColorBand](repeating:ColorBand(),count:8); e.autoEnhance = false
            e.clarity = 0; e.texture = 0; e.dehaze = 0; e.colorGrading = ColorGrading()
            e.grayMix = PhotoEdits.neutralGrayMix; e.pointColors = []
            switch name {
            case "Warm light": e.temperature = 7800; e.vibrance = 0.15; e.contrast = 1.05
            case "Cool shadows": e.temperature = 5200; e.shadowsAmount = 0.2; e.contrast = 1.05
            case "Vivid": e.vibrance = 0.35; e.saturation = 1.12; e.contrast = 1.12; e.clarity = 0.15
            case "Soft portrait": e.contrast = 0.9; e.shadowsAmount = 0.2; e.saturation = 0.95; e.temperature = 6900
            case "Monochrome": e.monochrome = 1; e.contrast = 1.2
            default: break
            }
            return e.sanitized
        }
        for name in ["Natural","Warm light","Cool shadows","Vivid","Soft portrait","Monochrome"] {
            let preset = try #require(library.presets.first { $0.name == name })
            #expect(preset.edits(from:current) == before(name), "\(name)")
        }
    }
    @Test func amountScalesFromUnchangedThroughExaggerated() throws {
        let library = try PresetLibrary(bundled:bundled,user:try temporary()), current = photo()
        let preset = try #require(library.presets.first { $0.name == "Dark & Moody" })
        #expect(preset.edits(from:current,amount:0) == current)
        let full = preset.edits(from:current,amount:1), half = preset.edits(from:current,amount:0.5), double = preset.edits(from:current,amount:2)
        #expect(full == preset.target(from:current))
        #expect(abs(half.exposure - (current.exposure+full.exposure)/2) < 1e-9)
        #expect(abs(half.clarity - current.clarity/2) < 1e-9)
        #expect(abs(double.exposure - 2*full.exposure) < 1e-9 && abs(double.saturation - 0.6) < 1e-9)
        #expect(abs(double.colorGrading.shadows.saturation - 2*full.colorGrading.shadows.saturation) < 1e-9)
        #expect(preset.edits(from:current,amount:.nan) == full)
        for p in library.presets {
            for amount in [0.0,0.3,1,1.7,2] { let e = p.edits(from:current,amount:amount); expectKeepsPhotoSpecifics(e,current) }
        }
    }
    @Test func presetLooksAreAppliedAsIndependentCopies() throws {
        let library = try PresetLibrary(bundled:bundled,user:try temporary())
        let looks = try LUTLibrary(bundled:resources.appendingPathComponent("LUTs"),imported:try temporary())
        let preset = try #require(library.presets.first { $0.name == "Teal & Orange" })
        let result = try preset.apply(to:PhotoEdits(),amount:1,library:looks)
        defer { if let name = result.advanced?.lutAsset { try? FileManager.default.removeItem(at:EditStorage.asset(name)) } }
        #expect(result.advanced?.lutID == preset.lut?.id && result.lutAmount == preset.lut?.amount)
        #expect(try CubeLUT.load(EditStorage.asset(result.advanced!.lutAsset!)).data == looks.items.first { $0.entry.id == preset.lut!.id }!.load().data)
        let current = photo();#expect(try preset.apply(to:current,amount:0,library:looks) == current)
    }
    @Test func myPresetsSaveListRenameDeleteAndImportOldFiles() throws {
        let folder = try temporary();defer { try? FileManager.default.removeItem(at:folder) }
        var edits = photo();edits.contrast = 1.3;edits.grainAmount = 0.4
        try PresetLibrary.save(edits,name:"Punchy",in:folder)
        #expect(throws:PresetLibrary.PresetError.self) { try PresetLibrary.save(edits,name:"Punchy",in:folder) }
        #expect(throws:PresetLibrary.PresetError.self) { try PresetLibrary.save(edits,name:"../escape",in:folder) }
        var library = try PresetLibrary(bundled:nil,user:folder)
        let mine = try #require(library.filtered(PresetLibrary.myPresets).first)
        #expect(mine.name == "Punchy" && mine.snapshot?.crop == nil && mine.snapshot?.advanced?.masks.isEmpty == true && mine.snapshot?.advanced?.lutAsset == nil)
        let other = PhotoEdits()
        let applied = mine.edits(from:other)
        #expect(applied.contrast == 1.3 && applied.grainAmount == 0.4 && applied.exposure == 0.7 && applied.crop == nil)
        let current = photo();expectKeepsPhotoSpecifics(mine.edits(from:current),current)
        try PresetLibrary.rename("Punchy",to:"Punchy Film",in:folder)
        library = try PresetLibrary(bundled:nil,user:folder);#expect(library.presets.map(\.name) == ["Punchy Film"])
        // A file saved by earlier versions: the whole PhotoEdits, including photo-specific parts.
        let old = folder.appendingPathComponent("Elsewhere.json");var legacy = photo();legacy.vibrance = 0.5
        try JSONEncoder().encode(legacy).write(to:old)
        let imported = try PresetLibrary.importPreset(old,into:folder)
        #expect(imported.lastPathComponent == "Elsewhere.openstillpreset")
        library = try PresetLibrary(bundled:nil,user:folder)
        let loaded = try #require(library.presets.first { $0.name == "Elsewhere" })
        #expect(loaded.edits(from:PhotoEdits()).vibrance == 0.5 && loaded.edits(from:PhotoEdits()).crop == nil)
        try PresetLibrary.delete("Punchy Film",in:folder);try PresetLibrary.delete("Elsewhere",in:folder)
        #expect(try PresetLibrary(bundled:nil,user:folder).presets.isEmpty)
    }
}
