import Foundation
import CoreImage
import ImageIO
import Testing
@testable import OpenStillCore

@Suite struct HDRTests {
    func flat(_ v: Double, size: CGSize = CGSize(width: 64, height: 48)) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v, alpha: 1, colorSpace: ModernRenderer.workingSpace)!).cropped(to: CGRect(origin: .zero, size: size))
    }
    func value(_ image: CIImage) -> Float {
        var p = [Float](repeating: 0, count: 4)
        ModernRenderer.context.render(image, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: image.extent.midX, y: image.extent.midY, width: 1, height: 1), format: .RGBAf, colorSpace: ModernRenderer.workingSpace)
        return p[1]
    }

    @Test func expansionLiftsOnlyHighlights() throws {
        #expect(abs(value(try HDRTone.expand(flat(0.2), headroom: 2)) - 0.2) < 0.001)
        let white = value(try HDRTone.expand(flat(1), headroom: 2))
        #expect(white > 3 && white <= 4, "\(white)")
        // More headroom, brighter highlights; values already above white stay below the cap.
        #expect(value(try HDRTone.expand(flat(1), headroom: 1)) < white)
        #expect(value(try HDRTone.expand(flat(6), headroom: 2)) <= 4.001)
        // The SDR tone map is gentle below its shoulder and stays under white.
        #expect(abs(value(try HDRTone.toneMapSDR(flat(0.5))) - 0.5) < 0.001)
        #expect(value(try HDRTone.toneMapSDR(flat(4))) < 1)
    }

    @Test func settingsAndPipeline() throws {
        var edits = PhotoEdits()
        #expect(!edits.hdrEnabled && edits.advanced?.hdr == nil)
        edits.hdrEnabled = true; edits.hdrHeadroom = .nan
        #expect(edits.sanitized.hdr.headroom == 2)
        edits.hdrHeadroom = 9
        #expect(edits.sanitized.hdr.headroom == 4)
        edits.hdrHeadroom = 2
        let bright = flat(0.95, size: CGSize(width: 120, height: 80))
        #expect(value(try ModernRenderer.process(bright, edits: edits)) > 1.5)
        var off = edits; off.hdrEnabled = false
        #expect(value(try ModernRenderer.process(bright, edits: off)) < 1.001)
        // The SDR rendition of a recipe drops only the HDR expansion.
        let recipe = RenderRecipe(renderer: .linear2020, sourceMode: .original, edits: edits)
        #expect(recipe.sdr.edits.hdrEnabled == false && recipe.sdr.edits.hdrHeadroom == 2)
        // Legacy edits without the field still decode.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PhotoEdits())) as! [String: Any]
        legacy.removeValue(forKey: "advanced")
        let decoded = try JSONDecoder().decode(PhotoEdits.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(!decoded.hdrEnabled)
    }

    @Test func exportSettings() throws {
        var s = ExportSettings(); s.hdr = .pq
        #expect(s.sanitized.hdr == nil)            // PQ needs HEIF
        s.format = .jpeg; s.hdr = .gainMap
        #expect(s.sanitized.hdr == .gainMap)
        s.format = .heif; s.hdr = .hlg; s.bitDepth = 16
        #expect(s.sanitized.hdr == .hlg && s.sanitized.bitDepth == 8)
        s.format = .png; s.hdr = .gainMap
        #expect(s.sanitized.hdr == nil)
        // Presets saved before HDR export still load.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ExportSettings())) as! [String: Any]
        json.removeValue(forKey: "hdr")
        #expect(try JSONDecoder().decode(ExportSettings.self, from: JSONSerialization.data(withJSONObject: json)).hdr == nil)
        // HEIF exports are named .heic.
        var heif = ExportSettings(); heif.format = .heif; heif.filenameTemplate = "{name}"
        let url = URL(fileURLWithPath: "/fixtures/Sample.jpg")
        let record = PhotoRecord(source: url, fingerprint: "sha", version: EditVersion(name: "Main", renderer: .linear2020, sourceMode: .original, document: EditDocument(fingerprint: "stat")))
        let job = ExportJob(ShootItem(url: url, record: record, captured: Date(timeIntervalSince1970: 0)))
        #expect(try ExportWorkflow.filename(job, index: 0, settings: heif) == "Sample.heic")
    }

    /// HEIF encoding isn't available on every Mac (virtual machines may lack it); those runs check only the error.
    func export(_ image: CIImage, _ settings: ExportSettings, sdr: CIImage? = nil) throws -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + (settings.format == .jpeg ? ".jpg" : ".heic"))
        do { try ModernRenderer.export(image, to: url, source: nil, settings: settings, sdrImage: sdr) }
        catch let error as HDRExportError { #expect(error == .heifUnavailable || error == .needsMacOS15); return nil }
        return url
    }

    @Test(.timeLimit(.minutes(1))) func hdrFilesAreWritten() throws {
        let hdr = try HDRTone.expand(flat(0.9, size: CGSize(width: 256, height: 128)), headroom: 2)
        var pq = ExportSettings(); pq.format = .heif; pq.hdr = .pq
        if let url = try export(hdr, pq) {
            defer { try? FileManager.default.removeItem(at: url) }
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            #expect((CGImageSourceGetType(source) as String?)?.contains("hei") == true)
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
            #expect((props?[kCGImagePropertyDepth as String] as? Int ?? 0) >= 10, "\(props ?? [:])")
        }
        var sdrHEIF = ExportSettings(); sdrHEIF.format = .heif
        if let url = try export(flat(0.5, size: CGSize(width: 128, height: 64)), sdrHEIF) {
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(try ModernRenderer.readImage(url).extent.size == CGSize(width: 128, height: 64))
        }
        if #available(macOS 15, *) {
            var gain = ExportSettings(); gain.format = .jpeg; gain.hdr = .gainMap
            let url = try #require(try export(hdr, gain, sdr: flat(0.9, size: CGSize(width: 256, height: 128))))
            defer { try? FileManager.default.removeItem(at: url) }
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let iso = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap)
            let apple = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap)
            #expect(iso != nil || apple != nil)
        }
    }
}
