import Foundation
import CoreImage
import SQLite3
import Testing
@testable import OpenStillCore

@Suite final class XMPImportTests {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("xmp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func photo(_ name: String, in folder: String = "Photos") throws -> URL {
        let dir = directory.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try ModernRenderer.export(CIImage(color: CIColor(red: 0.4, green: 0.3, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 24, height: 16)), to: url, source: nil, settings: ExportSettings())
        return url
    }
    static func packet(_ attributes: String, _ body: String = "") -> Data {
        Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" \(attributes)>\(body)</rdf:Description>
        </rdf:RDF></x:xmpmeta>
        """.utf8)
    }
    func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

    @Test func libraryFieldsRoundTrip() throws {
        var xmp = XMPMetadata()
        xmp.rating = 4; xmp.flag = .pick; xmp.label = .blue
        xmp.iptc.title = "Harbor at dawn"; xmp.iptc.caption = "Boats leaving.\nSecond line"; xmp.iptc.creator = "Sample Studio"; xmp.iptc.copyright = "© 2026 Sample Studio"
        xmp.iptc.keywords = ["Places > France > Marseille", "boats"]; xmp.iptc.city = "Marseille"; xmp.iptc.state = "Provence"; xmp.iptc.country = "France"; xmp.iptc.location = "Vieux-Port"
        let data = try XMPSidecar.xmpData(xmp)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("Places|France|Marseille") && text.contains("x-default"))
        let back = try #require(XMPSidecar.parse(data))
        #expect(back.rating == 4 && back.flag == .pick && back.label == .blue)
        #expect(back.iptc == xmp.iptc.sanitized)
        #expect(back.cameraRaw.isEmpty && !back.hasDevelopSettings)
    }
    @Test func writingKeepsOtherTagsAndCameraRawSettings() throws {
        let existing = Self.packet(#"xmp:Rating="2" xmp:CreatorTool="Sample Tool" crs:Exposure2012="+1.00" crs:ProcessVersion="11.0""#,
                                   "<crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>64, 40</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012>")
        var xmp = XMPMetadata(); xmp.rating = 5; xmp.label = .red
        let merged = try XMPSidecar.xmpData(xmp, merging: existing)
        let back = try #require(XMPSidecar.parse(merged))
        #expect(back.rating == 5 && back.label == .red)
        #expect(back.cameraRaw["Exposure2012"] == "+1.00" && back.cameraRawLists["ToneCurvePV2012"]?.count == 3)
        #expect(String(decoding: merged, as: UTF8.self).contains("Sample Tool"))
        // Clearing a field removes it.
        let cleared = try #require(XMPSidecar.parse(try XMPSidecar.xmpData(XMPMetadata(), merging: merged)))
        #expect(cleared.rating == nil && cleared.label == nil && cleared.cameraRaw["Exposure2012"] == "+1.00")
    }
    @Test func bridgeRejectAndUnknownLabels() throws {
        let rejected = try #require(XMPSidecar.parse(Self.packet(#"xmp:Rating="-1" xmp:Label="To Do""#)))
        #expect(rejected.flag == .reject && rejected.rating == 0 && rejected.label == nil)
        var record = PhotoRecord(source: directory, fingerprint: "x", version: EditVersion(name: "Original", renderer: .linear2020, sourceMode: .original, document: EditDocument(fingerprint: "x")))
        record.rating = 3
        rejected.apply(to: &record)
        #expect(record.flag == .reject && record.rating == 0)
    }
    @Test func storeReadsSidecarsForNewPhotosAndWritesThemWhenAsked() throws {
        let file = try photo("IMG_0001.jpg")
        var incoming = XMPMetadata(); incoming.rating = 3; incoming.label = .green; incoming.iptc.keywords = ["Travel > Italy"]
        try XMPSidecar.xmpData(incoming).write(to: XMPSidecar.url(for: file))
        #expect(XMPSidecar.url(for: file).lastPathComponent == "IMG_0001.xmp")
        let store = PhotoRecordStore(root: directory.appendingPathComponent("app"))
        store.writesSidecars = { false }
        let record = try store.record(for: file)
        #expect(record.rating == 3 && record.colorLabel == .green && record.iptc.keywords == ["Travel > Italy"])
        // With the preference off, nothing is written.
        try FileManager.default.removeItem(at: XMPSidecar.url(for: file))
        try ShootWorkflow.mark(record.id, rating: 5, store: store)
        #expect(!FileManager.default.fileExists(atPath: XMPSidecar.url(for: file).path))
        // With it on, a change writes the sidecar.
        store.writesSidecars = { true }
        try ShootWorkflow.mark(record.id, flag: .pick, label: .purple, store: store)
        let written = try #require(XMPSidecar.read(file))
        #expect(written.rating == 5 && written.flag == .pick && written.label == .purple && written.iptc.keywords == ["Travel > Italy"])
        // Saving edits that don't touch library fields leaves the sidecar alone.
        let before = try Data(contentsOf: XMPSidecar.url(for: file))
        try store.update(record.id) { $0.duplicateVersion(named: "Copy") }
        #expect(try Data(contentsOf: XMPSidecar.url(for: file)) == before)
    }
    @Test func cameraRawSettingsMapToSliders() throws {
        var xmp = XMPMetadata()
        xmp.cameraRaw = ["ProcessVersion": "11.0", "Exposure2012": "+0.50", "Contrast2012": "+20", "Highlights2012": "-40", "Shadows2012": "+30", "Whites2012": "+10",
                         "Blacks2012": "-15", "Vibrance": "+25", "Saturation": "-10", "Clarity2012": "+35", "Texture": "+10", "Dehaze": "+20",
                         "HueAdjustmentBlue": "-20", "SaturationAdjustmentOrange": "+15", "LuminanceAdjustmentAqua": "-5", "HueAdjustmentRed": "0",
                         "ColorGradeShadowHue": "220", "ColorGradeShadowSat": "30", "ColorGradeBlending": "60", "GrainAmount": "25", "GrainSize": "30",
                         "PostCropVignetteAmount": "-20", "IncrementalTemperature": "10", "HasCrop": "True", "CropLeft": "0.1", "CropTop": "0.2",
                         "CropRight": "0.9", "CropBottom": "0.8", "CropAngle": "0", "VignetteAmount": "+12", "FutureSlider": "7", "SharpenRadius": "+1.0", "ConvertToGrayscale": "False"]
        xmp.cameraRawLists = ["ToneCurvePV2012": ["0, 0", "128, 150", "255, 255"]]
        #expect(xmp.hasDevelopSettings)
        let result = CameraRawImport(xmp, raw: false)
        let e = result.edits
        #expect(close(e.exposure, 0.5) && close(e.contrast, 1.1) && close(e.highlights, 0.6) && close(e.shadows, 0.3))
        #expect(close(e.whites, 0.1) && close(e.blacks, -0.15) && close(e.vibrance, 0.25) && close(e.saturation, 0.9))
        #expect(close(e.clarity, 0.35) && close(e.texture, 0.1) && close(e.dehaze, 0.2))
        let colors = try #require(e.advanced?.colors)
        #expect(close(colors[5].hue, -0.2) && close(colors[1].saturation, 0.15) && close(colors[4].lightness ?? 0, -0.05) && colors[0] == ColorBand())
        #expect(close(e.colorGrading.shadows.hue, 220) && close(e.colorGrading.shadows.saturation, 0.3) && close(e.colorGrading.blending, 0.6))
        #expect(close(e.grain.amount, 0.25) && close(e.grain.size, 0.3) && close(e.grain.roughness, 0.5))
        #expect(close(e.vignette, -0.2) && close(e.temperature, 6850) && e.monochrome == 0)
        let crop = try #require(e.crop)
        #expect(close(crop.x, 0.1) && close(crop.y, 0.2) && close(crop.width, 0.8) && close(crop.height, 0.6))
        #expect(e.curves.master[2] > 0.55 && close(e.curves.master[0], 0) && close(e.curves.master[4], 1))
        #expect(result.unsupported.contains("Lens vignetting 12") && result.unsupported.contains("Future Slider (7)"))
        #expect(!result.unsupported.contains { $0.contains("Sharpen Radius") || $0.contains("Process") || $0.contains("Grayscale") })
        #expect(result.approximated.contains { $0.hasPrefix("White balance") })
        #expect(result.applied >= 20 && result.report.contains("Not imported"))
    }
    @Test func rawWhiteBalanceAndVersions() throws {
        var xmp = XMPMetadata(); xmp.cameraRaw = ["WhiteBalance": "Custom", "Temperature": "5200", "Tint": "+8", "Exposure2012": "-0.30"]
        let raw = CameraRawImport(xmp, raw: true)
        #expect(close(raw.edits.temperature, 5200) && close(raw.edits.tint, 8) && close(raw.edits.exposure, -0.3))
        xmp.cameraRaw["WhiteBalance"] = "As Shot"
        #expect(close(CameraRawImport(xmp, raw: true).edits.temperature, 6500))
        // Only bookkeeping: nothing to import, so no version is added.
        var record = PhotoRecord(source: directory.appendingPathComponent("a.jpg"), fingerprint: "x", version: EditVersion(name: "Original", renderer: .linear2020, sourceMode: .original, document: EditDocument(fingerprint: "x")))
        var empty = XMPMetadata(); empty.cameraRaw = ["ProcessVersion": "11.0", "HasSettings": "True"]
        #expect(!empty.hasDevelopSettings && record.importCameraRaw(empty) == nil && record.versions.count == 1)
        #expect(record.importCameraRaw(xmp) != nil && record.versions.count == 2 && record.active.name == "Camera Raw" && close(record.active.document.current.exposure, -0.3))
        #expect(record.isValid)
    }

    // MARK: Lightroom catalog

    func makeCatalog(root: String) throws -> URL {
        let url = directory.appendingPathComponent("Sample.lrcat")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let develop = String(decoding: Self.packet(#"xmp:Rating="5" crs:Exposure2012="+1.00" crs:Clarity2012="+20" crs:ProcessVersion="11.0" crs:LensProfileEnable="1""#,
                                                   #"<dc:title xmlns:dc="http://purl.org/dc/elements/1.1/"><rdf:Alt><rdf:li xml:lang="x-default">Harbor</rdf:li></rdf:Alt></dc:title>"#), as: UTF8.self)
            .replacingOccurrences(of: "'", with: "''")
        let sql = """
        CREATE TABLE Adobe_images (id_local INTEGER PRIMARY KEY, rootFile INTEGER, rating REAL, colorLabels TEXT, pick REAL, masterImage INTEGER, captureTime TEXT);
        CREATE TABLE AgLibraryFile (id_local INTEGER PRIMARY KEY, baseName TEXT, extension TEXT, folder INTEGER);
        CREATE TABLE AgLibraryFolder (id_local INTEGER PRIMARY KEY, pathFromRoot TEXT, rootFolder INTEGER);
        CREATE TABLE AgLibraryRootFolder (id_local INTEGER PRIMARY KEY, absolutePath TEXT, name TEXT);
        CREATE TABLE AgLibraryKeyword (id_local INTEGER PRIMARY KEY, name TEXT, parent INTEGER);
        CREATE TABLE AgLibraryKeywordImage (id_local INTEGER PRIMARY KEY, image INTEGER, tag INTEGER);
        CREATE TABLE AgLibraryCollection (id_local INTEGER PRIMARY KEY, name TEXT, creationId TEXT, parent INTEGER);
        CREATE TABLE AgLibraryCollectionImage (id_local INTEGER PRIMARY KEY, collection INTEGER, image INTEGER);
        CREATE TABLE Adobe_AdditionalMetadata (id_local INTEGER PRIMARY KEY, image INTEGER, xmp TEXT);
        INSERT INTO AgLibraryRootFolder VALUES (1, '\(root)', 'Photos');
        INSERT INTO AgLibraryFolder VALUES (1, 'Shoot/', 1);
        INSERT INTO AgLibraryFile VALUES (1, 'a', 'jpg', 1), (2, 'b', 'jpg', 1), (3, 'gone', 'jpg', 1);
        INSERT INTO Adobe_images VALUES (10, 1, 5, 'Red', 1, NULL, NULL), (11, 2, NULL, '', -1, NULL, NULL), (12, 3, 2, NULL, 0, NULL, NULL), (13, 1, 1, NULL, 0, 10, NULL);
        INSERT INTO AgLibraryKeyword VALUES (1, NULL, NULL), (2, 'Places', 1), (3, 'France', 2), (4, 'boats', 1);
        INSERT INTO AgLibraryKeywordImage VALUES (1, 10, 3), (2, 10, 4), (3, 11, 4);
        INSERT INTO AgLibraryCollection VALUES (1, 'Trip', 'com.adobe.ag.library.collection', NULL), (2, 'Five stars', 'com.adobe.ag.library.smart_collection', NULL), (3, 'Set', 'com.adobe.ag.library.group', NULL);
        INSERT INTO AgLibraryCollectionImage VALUES (1, 1, 10), (2, 1, 11), (3, 1, 12);
        INSERT INTO Adobe_AdditionalMetadata VALUES (1, 10, '\(develop)');
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return url
    }
    @Test func lightroomCatalogImportsLibraryAndDevelopSettings() throws {
        let a = try photo("a.jpg", in: "Moved/Shoot"), b = try photo("b.jpg", in: "Moved/Shoot")
        let catalogURL = try makeCatalog(root: "/Volumes/Old Drive/")
        let modified = try FileManager.default.attributesOfItem(atPath: catalogURL.path)[.modificationDate] as? Date
        let catalog = try LightroomCatalog(url: catalogURL)
        #expect(catalog.photos.count == 3 && catalog.skippedVirtualCopies == 1 && catalog.skippedSmartCollections == 1)
        #expect(catalog.collections.map(\.name) == ["Trip"])
        #expect(catalog.roots == ["/Volumes/Old Drive/"] && catalog.missing.count == 3)
        var options = LightroomImport()
        options.relink = [(from: "/Volumes/Old Drive/", to: directory.appendingPathComponent("Moved").path + "/")]
        #expect(options.resolvedPath("/Volumes/Old Drive/Shoot/a.jpg") == a.path)
        let store = PhotoRecordStore(root: directory.appendingPathComponent("app"))
        store.writesSidecars = { false }
        let report = options.run(catalog, store: store)
        #expect(report.imported == 2 && report.missing == 1 && report.developed == 1 && report.collections == 1 && report.failed == 0)
        #expect(report.unsupported["Lens profile corrections"] == 1)
        #expect(report.summary.contains("2 photos imported"))

        let first = try store.record(for: a), second = try store.record(for: b)
        #expect(first.rating == 5 && first.flag == .pick && first.colorLabel == .red)
        #expect(Set(first.iptc.keywords) == ["Places > France", "boats"] && first.iptc.title == "Harbor")
        #expect(first.active.name == "Lightroom" && close(first.active.document.current.exposure, 1) && close(first.active.document.current.clarity, 0.2))
        #expect(second.flag == .reject && second.rating == 0 && second.iptc.keywords == ["boats"] && second.versions.count == 1)
        let trip = try #require(store.catalog?.collections().first { $0.name == "Trip" })
        #expect(Set(store.catalog!.members(of: trip).map(\.id)) == [first.id, second.id])

        // Importing again doesn't add a second Lightroom version or collection.
        let again = options.run(try LightroomCatalog(url: catalogURL), store: store)
        #expect(again.developed == 0)
        #expect(try store.record(for: a).versions.count == 2)
        #expect(store.catalog?.collections().filter { $0.name == "Trip" }.count == 1)
        // The Lightroom catalog itself is untouched.
        #expect(try FileManager.default.attributesOfItem(atPath: catalogURL.path)[.modificationDate] as? Date == modified)
    }
    @Test func notALightroomCatalog() throws {
        let url = directory.appendingPathComponent("other.sqlite")
        var db: OpaquePointer?; sqlite3_open(url.path, &db); sqlite3_exec(db, "CREATE TABLE t (x INTEGER)", nil, nil, nil); sqlite3_close(db)
        #expect(throws: LightroomImportError.self) { try LightroomCatalog(url: url) }
        #expect(throws: (any Error).self) { try LightroomCatalog(url: directory.appendingPathComponent("missing.lrcat")) }
    }
}
