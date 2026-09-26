import Foundation
import CoreImage
import ImageIO
import Testing
@testable import OpenStillCore

@Suite final class LibraryCatalogTests {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func photo(_ name: String, in folder: URL? = nil, color: CIColor = CIColor(red: 0.3, green: 0.4, blue: 0.5)) throws -> URL {
        let folder = folder ?? directory.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try ModernRenderer.export(CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24)), to: url, source: nil, settings: ExportSettings())
        return url
    }
    func facts(_ id: UUID = UUID(), _ configure: (inout CatalogPhoto) -> Void = { _ in }) -> CatalogPhoto {
        var p = CatalogPhoto(id: id, path: "/Photos/IMG_\(id.uuidString.prefix(4)).jpg"); configure(&p); return p
    }

    @Test func storeIndexesRecordsAndFindsThemByFileFacts() throws {
        let store = PhotoRecordStore(root: directory.appendingPathComponent("app")), file = try photo("a.jpg")
        let catalog = try #require(store.catalog)
        let record = try store.record(for: file)
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        #expect(catalog.recordID(path: file.standardizedFileURL.path, size: Int64(values.fileSize!), modified: values.contentModificationDate!.timeIntervalSince1970) == record.id)
        #expect(catalog.recordIDs(fingerprint: record.contentFingerprint) == [record.id])
        #expect(catalog.photo(record.id)?.width == 32 && catalog.photoCount == 1)
        // The second lookup takes the fast path and returns the same record.
        #expect(try store.record(for: file).id == record.id)
        // A moved file is found again by content, and the catalog follows it.
        let moved = directory.appendingPathComponent("Photos/moved.jpg"); try FileManager.default.moveItem(at: file, to: moved)
        #expect(try store.record(for: moved).id == record.id)
        #expect(catalog.photo(record.id)?.path == moved.standardizedFileURL.path)
        // Changed contents at the same path are a different photo.
        try Data("not the same photo".utf8).write(to: moved)
        #expect(try store.record(for: moved).id != record.id)
    }
    @Test func existingRecordsAreIndexedOnce() throws {
        let root = directory.appendingPathComponent("legacy"), file = try photo("b.jpg")
        let record = try PhotoRecordStore(root: root).record(for: file)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Catalog.sqlite"))
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(at: root.appendingPathComponent("Catalog.sqlite" + suffix)) }
        let fresh = PhotoRecordStore(root: root)
        #expect(fresh.catalog?.photoCount == 0)
        let moved = directory.appendingPathComponent("Photos/b-moved.jpg"); try FileManager.default.moveItem(at: file, to: moved)
        #expect(try fresh.record(for: moved).id == record.id)
        #expect(fresh.catalog?.value("indexedRecords") == "1")
    }
    @Test func ratingsLabelsAndMetadataAreMirrored() throws {
        let store = PhotoRecordStore(root: directory.appendingPathComponent("mirror")), file = try photo("c.jpg")
        let record = try store.record(for: file)
        try ShootWorkflow.mark(record.id, rating: 4, flag: .pick, label: .green, store: store)
        var meta = IPTCMetadata(); meta.title = "Harbor"; meta.keywords = ["Places > France > Marseille", "boats"]
        try ShootWorkflow.applyMetadata(record.id, meta, store: store)
        let row = try #require(store.catalog?.photo(record.id))
        #expect(row.rating == 4 && row.flag == .pick && row.label == .green && row.title == "Harbor")
        #expect(Set(row.keywords) == ["Places", "Places > France", "Places > France > Marseille", "boats"])
        // Batch apply adds keywords and keeps fields left empty; removal takes one off.
        var more = IPTCMetadata(); more.keywords = ["sunset"]; more.creator = "Sample Studio"
        let updated = try ShootWorkflow.applyMetadata(record.id, more, removingKeywords: ["boats"], store: store)
        #expect(updated.iptc.title == "Harbor" && updated.iptc.creator == "Sample Studio")
        #expect(updated.iptc.keywords == ["Places > France > Marseille", "sunset"])
        #expect(store.catalog?.keywordCounts().contains { $0.0 == "sunset" && $0.1 == 1 } == true)
        try ShootWorkflow.mark(record.id, label: ColorLabel.none, store: store)
        #expect(try store.read(record.id).label == nil)
    }
    @Test func metadataIsSanitizedAndOldRecordsDecode() throws {
        var m = IPTCMetadata(); m.title = "  Title\nsecond line \u{7}"; m.caption = "Line one\nLine two"
        m.keywords = [" Places >  France>Paris ", "places > france > paris", "", "cats"]
        let s = m.sanitized
        #expect(s.title == "Title second line" && s.caption == "Line one\nLine two")
        #expect(s.keywords == ["Places > France > Paris", "cats"])
        #expect(s.keywordPaths == ["Places", "Places > France", "Places > France > Paris", "cats"])
        #expect(s.flatKeywords == ["Paris", "cats"])
        #expect(IPTCMetadata.parseKeywords("a, b;c\nd > e") == ["a", "b", "c", "d > e"])
        #expect(ColorLabel.forKey(6) == .red && ColorLabel.forKey(9) == .blue && ColorLabel.forKey(5) == nil)
        let file = try photo("old.jpg"), store = PhotoRecordStore(root: directory.appendingPathComponent("old"))
        let record = try store.record(for: file)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json.removeValue(forKey: "label"); json.removeValue(forKey: "metadata")
        let decoded = try JSONDecoder().decode(PhotoRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.colorLabel == .none && decoded.iptc.isEmpty && decoded.isValid)
    }
    @Test func searchAndSmartRules() throws {
        let camera = facts { $0.camera = "Panasonic DC-S9"; $0.lens = "LUMIX S 50/F1.8"; $0.keywords = ["Places", "Places > Paris"]; $0.rating = 5; $0.iso = 3200; $0.label = .red; $0.edited = true
            $0.captured = ISO8601DateFormatter().date(from: "2026-06-15T10:00:00Z") }
        let other = facts { $0.camera = "Canon EOS R6"; $0.rating = 2; $0.iso = 100; $0.flag = .reject; $0.captured = ISO8601DateFormatter().date(from: "2025-01-01T10:00:00Z") }
        #expect(camera.matches(text: "paris s9") && !camera.matches(text: "paris canon") && camera.matches(text: ""))
        /// (rule, matches camera, matches other)
        let cases: [(SmartRule.Field, SmartRule.Operation, String, Bool, Bool)] = [
            (.rating, .atLeast, "4", true, false), (.iso, .atMost, "400", false, true), (.keyword, .equals, "paris", true, false),
            (.keyword, .notContains, "paris", false, true), (.label, .equals, "red", true, false), (.flag, .equals, "reject", false, true),
            (.captured, .atLeast, "2026-06-15", true, false), (.captured, .atMost, "2026-06-15", true, true), (.edited, .isTrue, "", true, false),
            (.edited, .isFalse, "", false, true), (.camera, .contains, "canon", false, true), (.lens, .contains, "50/F1.8", true, false)]
        for (field, operation, value, first, second) in cases {
            let rule = try #require(SmartRule.make(field, operation, value: value))
            #expect(rule.matches(camera) == first && rule.matches(other) == second, "\(field) \(operation) \(value)")
        }
        func rule(_ f: SmartRule.Field, _ o: SmartRule.Operation, _ v: String) throws -> SmartRule { try #require(SmartRule.make(f, o, value: v)) }
        #expect(SmartRule.make(.rating, .atLeast, value: "five") == nil && SmartRule.make(.captured, .atLeast, value: "June") == nil && SmartRule.make(.label, .equals, value: "pink") == nil)
        let all = SmartRules(matchAll: true, rules: [try rule(.rating, .atLeast, "2"), try rule(.camera, .contains, "canon")])
        let any = SmartRules(matchAll: false, rules: all.rules)
        #expect(!all.matches(camera) && all.matches(other) && any.matches(camera) && any.matches(other))
        #expect(!SmartRule.operations(for: .keyword).isEmpty && SmartRule.choices(for: .label).contains("purple"))
    }
    @Test func collectionsAndSmartCollections() throws {
        let catalog = try LibraryCatalog(url: directory.appendingPathComponent("c.sqlite"))
        var a = PhotoRecord(source: try photo("one.jpg"), fingerprint: "1", version: EditVersion(name: "O", renderer: .linear2020, sourceMode: .original, document: EditDocument(fingerprint: "x")))
        a.rating = 5
        let b = PhotoRecord(source: try photo("two.jpg"), fingerprint: "2", version: EditVersion(name: "O", renderer: .linear2020, sourceMode: .original, document: EditDocument(fingerprint: "y")))
        try catalog.upsert(a, facts: facts(a.id)); try catalog.upsert(b, facts: facts(b.id))
        let trip = try catalog.createCollection(name: "  Trip  ")
        #expect(trip.name == "Trip" && !trip.isSmart)
        try catalog.add([a.id, b.id, a.id], to: trip.id)
        #expect(Set(catalog.members(of: trip).map(\.id)) == [a.id, b.id])
        try catalog.remove([b.id], from: trip.id)
        #expect(catalog.members(of: trip).map(\.id) == [a.id])
        let best = try catalog.createCollection(name: "Best", smart: SmartRules(rules: [SmartRule(.rating, .atLeast, low: 5)]))
        #expect(catalog.collections().map(\.name) == ["Best", "Trip"])
        #expect(catalog.members(of: try #require(catalog.collections().first { $0.isSmart })).map(\.id) == [a.id])
        try catalog.renameCollection(trip.id, to: "Holiday")
        #expect(catalog.collections().contains { $0.name == "Holiday" })
        try catalog.remove(a.id)
        #expect(catalog.members(of: trip).isEmpty && catalog.members(of: best).isEmpty)
        try catalog.deleteCollection(trip.id)
        #expect(catalog.collections().map(\.name) == ["Best"])
    }
    @Test func subfoldersAndCollectionFiles() throws {
        let root = directory.appendingPathComponent("Shoot")
        let top = try photo("top.jpg", in: root), nested = try photo("nested.jpg", in: root.appendingPathComponent("Day 2"))
        _ = try photo("secret.jpg", in: root.appendingPathComponent(".hidden"))
        try Data("x".utf8).write(to: root.appendingPathComponent("notes.txt"))
        #expect(try PhotoCatalog.open([root]).urls.map(\.lastPathComponent) == [top.lastPathComponent])
        let deep = try PhotoCatalog.open([root], includeSubfolders: true)
        #expect(Set(deep.urls.map(\.lastPathComponent)) == ["top.jpg", "nested.jpg"] && deep.folder?.lastPathComponent == "Shoot")
        let files = PhotoCatalog.files([nested, top, root.appendingPathComponent("missing.jpg")])
        #expect(files.urls == [nested.standardizedFileURL, top.standardizedFileURL] && files.folder == nil)
    }
    @Test func exportsCarryIPTC() throws {
        var meta = IPTCMetadata(); meta.title = "Harbor at dawn"; meta.caption = "Boats"; meta.creator = "Sample Studio"; meta.copyright = "© 2026 Sample Studio"
        meta.keywords = ["Places > France > Marseille", "boats"]; meta.city = "Marseille"; meta.country = "France"
        let out = directory.appendingPathComponent("export.jpg")
        try ModernRenderer.export(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16)), to: out, source: nil, settings: ExportSettings(), metadata: meta)
        let props = try #require(CGImageSourceCreateWithURL(out as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [String: Any])
        let iptc = try #require(props[kCGImagePropertyIPTCDictionary as String] as? [String: Any])
        #expect(iptc[kCGImagePropertyIPTCObjectName as String] as? String == "Harbor at dawn")
        #expect(iptc[kCGImagePropertyIPTCKeywords as String] as? [String] == ["Marseille", "boats"])
        #expect((iptc[kCGImagePropertyIPTCByline as String] as? [String])?.first == "Sample Studio")
        #expect(iptc[kCGImagePropertyIPTCCity as String] as? String == "Marseille")
        #expect((props[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFCopyright as String] as? String == "© 2026 Sample Studio")
        let plain = directory.appendingPathComponent("plain.jpg")
        try ModernRenderer.export(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16)), to: plain, source: nil, settings: ExportSettings())
        let plainProps = CGImageSourceCreateWithURL(plain as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [String: Any]
        #expect((plainProps?[kCGImagePropertyIPTCDictionary as String] as? [String: Any])?[kCGImagePropertyIPTCKeywords as String] == nil)
    }
    @Test func previewCacheKeepsOnlyTheLatestRevision() throws {
        let root = directory.appendingPathComponent("previews"), file = try photo("p.jpg")
        let store = PhotoRecordStore(root: root)
        var record = try store.record(for: file)
        let image = try PhotoDecoder.decode(file)
        let first = RenderRequest(photo: record, profile: .displayP3, maximumDimension: 420)
        #expect(PreviewCache.read(first, root: root) == nil)
        PreviewCache.write(image, for: first, root: root)
        #expect(PreviewCache.read(first, root: root)?.width == 32)
        var doc = record.active.document, edits = PhotoEdits(); edits.exposure = 1; doc.commit(edits, title: "Exposure"); record.updateDocument(doc)
        let second = RenderRequest(photo: record, profile: .displayP3, maximumDimension: 420)
        #expect(PreviewCache.read(second, root: root) == nil)
        PreviewCache.write(image, for: second, root: root)
        #expect(PreviewCache.read(first, root: root) == nil && PreviewCache.read(second, root: root) != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: PreviewCache.directory(root: root).path).count == 1)
    }
    @Test func libraryFilterUsesLabelsAndMetadata() throws {
        func item(_ name: String, label: ColorLabel, keywords: [String] = []) throws -> ShootItem {
            var record = PhotoRecord(source: URL(fileURLWithPath: "/tmp/\(name)"), fingerprint: name, version: EditVersion(name: "O", renderer: .linear2020, sourceMode: .original, document: EditDocument(fingerprint: name)))
            record.colorLabel = label; var m = IPTCMetadata(); m.keywords = keywords; record.iptc = m
            return ShootItem(url: URL(fileURLWithPath: "/tmp/\(name)"), record: record, captured: Date())
        }
        let items = [try item("A.jpg", label: .red, keywords: ["Beach"]), try item("B.jpg", label: .none), try item("C.jpg", label: .blue, keywords: ["beach > sunset"])]
        #expect(ShootWorkflow.filter(items, minimumRating: 0, flag: .all, sort: .filename, label: .red).map(\.url.lastPathComponent) == ["A.jpg"])
        #expect(ShootWorkflow.filter(items, minimumRating: 0, flag: .all, sort: .filename, label: ColorLabel.none).map(\.url.lastPathComponent) == ["B.jpg"])
        #expect(ShootWorkflow.filter(items, minimumRating: 0, flag: .all, sort: .filename, text: "beach").map(\.url.lastPathComponent) == ["A.jpg", "C.jpg"])
        #expect(ShootWorkflow.filter(items, minimumRating: 0, flag: .all, sort: .filename).count == 3)
    }
}
