import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

@Suite final class LibraryM12Tests {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("library-m12-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func photo(_ name: String, in folder: String = "Photos", color: CIColor = CIColor(red: 0.3, green: 0.4, blue: 0.5)) throws -> URL {
        let folder = directory.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try ModernRenderer.export(CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24)), to: url, source: nil, settings: ExportSettings())
        return url
    }
    func item(_ url: URL, store: PhotoRecordStore, captured: Date = Date(timeIntervalSince1970: 1_700_000_000), camera: String = "") throws -> ShootItem {
        let record = try store.record(for: url)
        var facts = CatalogPhoto(id: record.id, path: url.path); facts.camera = camera
        return ShootItem(url: url, record: record, captured: captured, facts: facts)
    }

    // MARK: Stacks
    @Test func stacksGroupReorderAndBreakUp() throws {
        let catalog = try #require(PhotoRecordStore(root: directory.appendingPathComponent("app")).catalog)
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let single = try catalog.createStack([a]); #expect(single == nil)
        let stack = try #require(try catalog.createStack([a, b, c, a]))
        #expect(catalog.stacks()[stack] == [a, b, c])
        try catalog.setStackTop(c)
        #expect(catalog.stacks()[stack] == [c, a, b])
        // A photo joining a new stack leaves its old one.
        let other = try #require(try catalog.createStack([b, d]))
        #expect(catalog.stacks()[stack] == [c, a] && catalog.stacks()[other] == [b, d])
        // A stack left with one photo goes away.
        try catalog.removeFromStacks([a])
        #expect(catalog.stacks()[stack] == nil)
        try catalog.unstack(other)
        #expect(catalog.stacks().isEmpty)
    }
    @Test func closedStacksShowTheirTopAndOpenOnesShowAll() {
        let ids = (0..<5).map { _ in UUID() }
        let stack = UUID(), stacks = [stack: [ids[3], ids[1], ids[2]]]
        let closed = Stacking.arrange(ids, id: { $0 }, stacks: stacks, expanded: [])
        #expect(closed.map(\.item) == [ids[0], ids[3], ids[4]])
        #expect(closed[1].count == 3 && closed[1].isTop && closed[0].stack == nil)
        let open = Stacking.arrange(ids, id: { $0 }, stacks: stacks, expanded: [stack])
        #expect(open.map(\.item) == [ids[0], ids[3], ids[1], ids[2], ids[4]])
        #expect(open.map(\.position) == [0, 0, 1, 2, 0])
        // Filtered down to one member, a stack is just a photo.
        let one = Stacking.arrange([ids[0], ids[2]], id: { $0 }, stacks: stacks, expanded: [])
        #expect(one.map(\.item) == [ids[0], ids[2]] && one.allSatisfy { $0.stack == nil })
    }
    @Test func autoStackGroupsBursts() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let p = (0..<6).map { _ in UUID() }
        let photos = [(p[0], t), (p[1], t + 2), (p[2], t + 4), (p[3], t + 300), (p[4], t + 302), (p[5], t + 900)].map { (id: $0.0, captured: $0.1) }
        #expect(AutoStack.groups(photos.shuffled(), gap: 10) == [[p[0], p[1], p[2]], [p[3], p[4]]])
        #expect(AutoStack.groups(photos, gap: 1).isEmpty)
        #expect(AutoStack.groups([(id: p[0], captured: .distantPast), (id: p[1], captured: .distantPast)], gap: 10).isEmpty)
    }

    // MARK: Filter bar
    @Test func metadataColumnsCountAndNarrowEachOther() throws {
        let store = PhotoRecordStore(root: directory.appendingPathComponent("app"))
        let year = { (y: Int) in Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(secondsFromGMT: 0), year: y, month: 6, day: 1))! }
        var items = [
            try item(photo("a.jpg"), store: store, captured: year(2024), camera: "Lumix S9"),
            try item(photo("b.jpg"), store: store, captured: year(2024), camera: "X100"),
            try item(photo("c.jpg"), store: store, captured: year(2025), camera: "Lumix S9"),
        ]
        items[0].record.colorLabel = .red
        var filter = LibraryFilter()
        #expect(filter.facets(items, column: .date) == [FacetValue(value: "2025", count: 1), FacetValue(value: "2024", count: 2)])
        #expect(filter.facets(items, column: .camera) == [FacetValue(value: "Lumix S9", count: 2), FacetValue(value: "X100", count: 1)])
        filter.choose("2024", in: .date, items: items)
        #expect(filter.facets(items, column: .camera) == [FacetValue(value: "Lumix S9", count: 1), FacetValue(value: "X100", count: 1)])
        filter.choose("X100", in: .camera, items: items)
        #expect(filter.apply(items).map(\.url.lastPathComponent) == ["b.jpg"])
        // Choosing a year without that camera clears the camera choice.
        filter.choose("2025", in: .date, items: items)
        #expect(filter.metadata[.camera] == nil && filter.apply(items).map(\.url.lastPathComponent) == ["c.jpg"])
        filter = LibraryFilter(); filter.choose("Red", in: .label, items: items)
        #expect(filter.apply(items).count == 1)
        filter = LibraryFilter(); filter.minimumRating = 3
        #expect(filter.apply(items).isEmpty && filter.facets(items, column: .date).isEmpty)
    }

    // MARK: Quick Develop
    @Test func quickDevelopNudgesClampsAndUndoes() throws {
        var e = PhotoEdits()
        e = QuickDevelop.apply(.exposure(1.0 / 3), to: e); #expect(abs(e.exposure - 1.0 / 3) < 1e-9)
        e = QuickDevelop.apply(.exposure(10), to: e); #expect(e.exposure == 4)
        e = QuickDevelop.apply(.contrast(-1), to: e); #expect(e.contrast == 0.5)
        e = QuickDevelop.apply(.whiteBalance(.tungsten), to: e); #expect(e.temperature == 2850)
        e = QuickDevelop.apply(.clarity(0.2), to: e); #expect(abs(e.clarity - 0.2) < 1e-9)
        e.crop = EditRect(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        let reset = QuickDevelop.apply(.resetAll, to: e)
        #expect(reset.exposure == 0 && reset.contrast == 1 && reset.crop == e.crop)
        #expect(QuickDevelop.apply(.autoTone, to: PhotoEdits(), histogram: nil) == PhotoEdits().sanitized)
        #expect(QuickDevelopStep.exposure(-1).title == "Exposure -1.00 EV")

        // As a batch on two photos: one undoable step.
        let store = PhotoRecordStore(root: directory.appendingPathComponent("app"))
        let items = [try item(photo("a.jpg"), store: store), try item(photo("b.jpg"), store: store)]
        let batch = try BatchEdits.apply(QuickDevelop.prepare(items, step: .exposure(1)), store: store)
        #expect(batch.entries.allSatisfy { $0.failure == nil })
        for i in items { let e = try store.read(i.id).active.document.current.exposure; #expect(e == 1) }
        _ = try BatchEdits.undo(batch, store: store)
        for i in items { let e = try store.read(i.id).active.document.current.exposure; #expect(e == 0) }
        let auto = QuickDevelop.prepare(items, step: .autoTone)
        #expect(auto.entries.allSatisfy { $0.failure != nil })
    }

    // MARK: Keywords
    @Test func keywordTreeListsEveryLevel() {
        let tree = KeywordTree.build([("Places", 3), ("Places > France", 2), ("Places > France > Paris", 1), ("Animals", 1), ("places > Spain", 1)])
        #expect(tree.map(\.name) == ["Animals", "Places"])
        let places = tree[1]
        #expect(places.count == 3 && places.children.map(\.name) == ["France", "Spain"] && places.children[0].children[0].path == "Places > France > Paris")
        #expect(KeywordTree.rows(tree, filter: "par").map(\.node.name) == ["Places", "France", "Paris"])
        #expect(KeywordTree.rows(tree).map(\.depth) == [0, 0, 1, 2, 1])
    }
    @Test func keywordSuggestionsAndRecentKeywords() throws {
        let store = PhotoRecordStore(root: directory.appendingPathComponent("app"))
        let a = try store.record(for: photo("a.jpg")), b = try store.record(for: photo("b.jpg")), c = try store.record(for: photo("c.jpg"))
        var m = IPTCMetadata()
        m.keywords = ["Beach", "Sunset", "Places > Spain"]; _ = try ShootWorkflow.applyMetadata(a.id, m, store: store)
        m.keywords = ["Beach", "Sunset"]; _ = try ShootWorkflow.applyMetadata(b.id, m, store: store)
        m.keywords = ["Forest"]; _ = try ShootWorkflow.applyMetadata(c.id, m, store: store)
        let catalog = try #require(store.catalog)
        let suggested = catalog.keywordSuggestions(for: ["Beach"])
        #expect(suggested.first == "Sunset" && suggested.contains("Places > Spain") && !suggested.contains("Places") && !suggested.contains("Forest") && !suggested.contains("Beach"))
        #expect(catalog.keywordSuggestions(for: []).isEmpty)
        let root = directory.appendingPathComponent("sets")
        KeywordSets.noteRecent(["Beach", "Sunset"], root: root); KeywordSets.noteRecent(["beach"], root: root)
        #expect(KeywordSets.recent(root: root) == ["beach", "Sunset"])
        #expect(KeywordSets.all(root: root).first?.keywords == ["beach", "Sunset"] && KeywordSets.builtIn.allSatisfy { $0.keywords.count == 9 })
        try KeywordSets.saveCustom([KeywordSet(name: "Mine", keywords: (1...12).map { "k\($0)" })], root: root)
        #expect(KeywordSets.custom(root: root).first?.keywords.count == 9)
    }

    // MARK: Rename
    @Test func renameMovesFilesAndSidecarsAndUndoes() throws {
        let store = PhotoRecordStore(root: directory.appendingPathComponent("app"))
        let a = try photo("a.jpg"), b = try photo("b.jpg")
        try Data("<x:xmpmeta/>".utf8).write(to: XMPSidecar.url(for: a))
        let items = [try item(a, store: store), try item(b, store: store)]
        #expect(throws: RenameError.self) { _ = try BatchRename.plan(items, template: "{nope}") }
        #expect(throws: RenameError.self) { _ = try BatchRename.plan(items, template: "same") }
        let unchanged = try BatchRename.plan(items, template: "{name}"); #expect(unchanged.isEmpty)
        // An unrelated file already has the name.
        _ = try photo("trip-001.jpg")
        #expect(throws: RenameError.self) { _ = try BatchRename.plan(items, template: "trip-{index}") }
        let plan = try BatchRename.plan(items, template: "trip-{index}", start: 5)
        #expect(plan.map(\.to.lastPathComponent) == ["trip-005.jpg", "trip-006.jpg"])
        let journal = try BatchRename.perform(plan, store: store)
        let renamed = directory.appendingPathComponent("Photos/trip-005.jpg")
        #expect(journal.entries.allSatisfy { $0.done })
        #expect(FileManager.default.fileExists(atPath: renamed.path) && !FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: XMPSidecar.url(for: renamed).path))
        let movedPath = try store.read(items[0].id).sourcePath; #expect(movedPath == renamed.standardizedFileURL.path)
        #expect(store.catalog?.photo(items[0].id)?.path == renamed.standardizedFileURL.path)
        let found = try store.record(for: renamed).id; #expect(found == items[0].id)
        #expect(BatchRename.latest(store: store)?.id == journal.id)
        let undone = try BatchRename.undo(journal, store: store)
        #expect(undone.undone && undone.entries.allSatisfy { !$0.done })
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: XMPSidecar.url(for: a).path))
        let backPath = try store.read(items[0].id).sourcePath; #expect(backPath == a.standardizedFileURL.path)
        #expect(BatchRename.latest(store: store) == nil)
    }

    // MARK: Auto Import
    @Test func autoImportMovesSettledPhotos() throws {
        let store = PhotoRecordStore(root: directory.appendingPathComponent("app"))
        var settings = AutoImportSettings()
        settings.watched = directory.appendingPathComponent("Watch"); settings.destination = directory.appendingPathComponent("Library")
        settings.folderTemplate = ""
        #expect(!settings.isReady)
        settings.enabled = true
        #expect(settings.isReady)
        let shot = try photo("shot.jpg", in: "Watch")
        _ = try photo("inside.jpg", in: "Watch/Sub")
        // Just written: left for the next pass.
        #expect(AutoImport.run(settings, store: store, now: Date()).imported.isEmpty)
        let report = AutoImport.run(settings, store: store, now: Date().addingTimeInterval(60))
        #expect(report.imported.map(\.lastPathComponent) == ["shot.jpg"] && report.failed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: shot.path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Library/shot.jpg").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Watch/Sub/inside.jpg").path))
        // A destination inside the watched folder would import forever.
        settings.destination = directory.appendingPathComponent("Watch/Out")
        #expect(!settings.isReady && AutoImport.run(settings, store: store).imported.isEmpty)
        let root = directory.appendingPathComponent("settings")
        try AutoImport.save(settings, root: root)
        #expect(AutoImport.load(root: root) == settings)
    }
}
