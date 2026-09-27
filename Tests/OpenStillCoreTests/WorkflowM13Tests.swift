import Foundation
import CoreImage
import CoreGraphics
import Testing
@testable import OpenStillCore

@Suite(.serialized) final class WorkflowM13Tests {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-m13-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func photo(_ name: String, in folder: String = "Photos", color: CIColor = CIColor(red: 0.3, green: 0.4, blue: 0.5), size: CGSize = CGSize(width: 64, height: 48)) throws -> URL {
        let folder = directory.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try ModernRenderer.export(CIImage(color: color).cropped(to: CGRect(origin: .zero, size: size)), to: url, source: nil, settings: ExportSettings())
        return url
    }
    func item(_ url: URL, store: PhotoRecordStore) throws -> ShootItem {
        ShootItem(url: url, record: try store.record(for: url), captured: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func editInRendersACopyAndStacksItOnTop() throws {
        let store = PhotoRecordStore(root: directory.appendingPathComponent("app"))
        let source = try photo("a.jpg")
        var original = try item(source, store: store)
        original.record = try store.update(original.id) { $0.rating = 4 }
        let copy = try EditIn.prepare(original, settings: EditInSettings(), store: store)
        #expect(copy.lastPathComponent == "a-Edit.tif" && FileManager.default.fileExists(atPath: copy.path))
        let second = try EditIn.prepare(original, settings: EditInSettings(), store: store)
        #expect(second.lastPathComponent == "a-Edit-2.tif")
        let copyRecord = try store.record(for: copy)
        #expect(copyRecord.rating == 4)
        let stack = store.catalog?.stacks().values.first { $0.contains(original.id) }
        #expect(stack?.count == 3 && stack?.last == original.id)
        #expect(EditInSettings().exportSettings.bitDepth == 16 && EditInSettings().exportSettings.format == .tiff)
    }

    @Test func afterExportRunsTheChosenScript() throws {
        let script = directory.appendingPathComponent("count.sh")
        try Data("#!/bin/sh\necho \"$# files: $(basename \"$1\")\"\n".utf8).write(to: script)
        let run = try ExportAfter.runScript(script.path, files: [directory.appendingPathComponent("one.jpg"), directory.appendingPathComponent("two.jpg")])
        #expect(run.status == 0 && run.output.contains("2 files: one.jpg"))
        #expect(ExportAfter.openIn(app: "/Applications/Affinity Photo 2.app").title == "Open in Affinity Photo 2")
        var settings = ExportSettings(); settings.after = .runScript(path: script.path)
        let decoded = try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.after == .runScript(path: script.path))
        // Settings saved before this option existed still load.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ExportSettings())) as! [String: Any]
        legacy.removeValue(forKey: "after")
        #expect(try JSONDecoder().decode(ExportSettings.self, from: JSONSerialization.data(withJSONObject: legacy)).after == nil)
    }

    @Test func smartPreviewStandsInWhileTheOriginalIsMissing() throws {
        let store = EditStorage.records
        let source = try photo("offline-\(UUID().uuidString.prefix(6)).jpg", size: CGSize(width: 3000, height: 2000))
        let record = try store.record(for: source)
        let preview = try SmartPreviews.build(source, record: record)
        #expect(FileManager.default.fileExists(atPath: preview.path) && SmartPreviews.exists(record))
        #expect(SmartPreviews.stand(in: source) == nil)
        // The drive goes away.
        let away = directory.appendingPathComponent("away.jpg"); try FileManager.default.moveItem(at: source, to: away)
        #expect(SmartPreviews.stand(in: source) == preview)
        let found = try store.record(for: source)
        #expect(found.id == record.id)
        let image = try ModernRenderer.source(source, mode: record.active.sourceMode)
        #expect(abs(max(image.extent.width, image.extent.height) - Double(SmartPreviews.longEdge)) <= 1)
        var recipe = record.active.recipe; recipe.edits.exposure = 1
        let rendered = try ModernRenderer.render(source: source, recipe: recipe, maximumDimension: 400)
        #expect(rendered.extent.width > 0)
        SmartPreviews.remove(record)
        #expect(!SmartPreviews.exists(record))
        try FileManager.default.moveItem(at: away, to: source)
    }

    @Test func catalogBackupsAreDatedAndPruned() throws {
        let store = PhotoRecordStore(root: directory.appendingPathComponent("app"))
        _ = try store.record(for: photo("a.jpg"))
        try Data("{}".utf8).write(to: store.root.appendingPathComponent("KeywordSets.json"))
        let folder = directory.appendingPathComponent("Backups")
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        for day in 0..<3 { try CatalogBackup.run(store: store, into: folder, keep: 2, now: t + Double(day) * 86_400) }
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("Backup ") }.sorted()
        #expect(backups.count == 2)
        let newest = folder.appendingPathComponent(backups.last!)
        for part in ["Catalog.sqlite", "PhotoRecords", "KeywordSets.json"] { #expect(FileManager.default.fileExists(atPath: newest.appendingPathComponent(part).path)) }
        let copy = try LibraryCatalog(url: newest.appendingPathComponent("Catalog.sqlite"))
        #expect(copy.photoCount == 1)
        var s = BackupSettings(); s.frequency = .daily
        #expect(CatalogBackup.isDue(s, now: t))
        s.last = t; #expect(!CatalogBackup.isDue(s, now: t + 3600) && CatalogBackup.isDue(s, now: t + 86_400))
        s.frequency = .never; #expect(!CatalogBackup.isDue(s, now: t + 1_000_000))
        s.frequency = .everyQuit; #expect(CatalogBackup.isDue(s, now: t + 1))
    }

    @Test func exportAsCatalogRoundTrips() throws {
        let store = PhotoRecordStore(root: directory.appendingPathComponent("app"))
        var items = [try item(photo("a.jpg"), store: store), try item(photo("b.jpg", color: CIColor(red: 0.6, green: 0.2, blue: 0.1)), store: store)]
        items[0].record = try store.update(items[0].id) { r in var d = r.active.document; var e = d.current; e.exposure = 0.7; d.commit(e, title: "Exposure"); r.updateDocument(d) }
        let out = directory.appendingPathComponent("Trip." + CatalogExport.fileExtension)
        let result = try CatalogExport.export(items, to: out, includeOriginals: true)
        #expect(result.exported == 2 && result.failed.isEmpty)
        let other = PhotoRecordStore(root: directory.appendingPathComponent("other"))
        let imported = CatalogExport.importCatalog(out, store: other)
        #expect(imported.imported.count == 2 && imported.failed.isEmpty)
        #expect(imported.imported.contains { $0.active.document.current.exposure == 0.7 })
    }

    @Test func bookPagesLayOutAndSaveAsPDF() throws {
        let ids = (0..<5).map { _ in UUID() }
        let pages = BookEngine.autoLayout(ids, template: .twoUp)
        #expect(pages.count == 3 && pages[2].photos == [ids[4], nil])
        var document = BookDocument(); document.pages = pages
        let page = CGRect(x: 0, y: 0, width: document.paper.width, height: document.paper.height)
        for template in BookTemplate.allCases {
            let cells = BookEngine.cells(template, document: document, caption: true)
            #expect(cells.count == template.slots && cells.allSatisfy { page.contains($0) })
            if template != .fullBleed { #expect(cells.allSatisfy { $0.minY >= document.margin + 28 - 0.001 }) }
        }
        #expect(BookEngine.cells(.fullBleed, document: document, caption: false) == [page])
        let fill = BookEngine.fill(CGSize(width: 300, height: 100), in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(fill.height == 100 && fill.width == 300)
        document.pages[0].caption = "Day one"
        let image = CIContext().createCGImage(CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 30)), from: CGRect(x: 0, y: 0, width: 40, height: 30))!
        let url = directory.appendingPathComponent("book.pdf")
        try BookEngine.pdf(document, images: Dictionary(uniqueKeysWithValues: ids.map { ($0, image) }), to: url)
        #expect(CGPDFDocument(url as CFURL)?.numberOfPages == 3)
        let root = directory.appendingPathComponent("books")
        try BookEngine.save(document, root: root)
        #expect(BookEngine.load(root: root) == document)
        #expect(BookPage(template: .fourUp, photos: [ids[0]]).photos.count == 4)
    }

    @Test func autoSyncCopiesOnlyWhatChanged() {
        let before = PhotoEdits()
        var after = before; after.exposure = 1; after.clarity = 0.3
        var target = PhotoEdits(); target.contrast = 1.2; target.exposure = -1; target.crop = EditRect(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        let synced = AutoSync.apply(from: before, to: after, onto: target)
        #expect(synced.exposure == 1 && abs(synced.clarity - 0.3) < 1e-9)
        #expect(synced.contrast == 1.2 && synced.crop == target.crop)
        #expect(AutoSync.changedGroups(from: before, to: before).isEmpty)
        var graded = before; graded.grain.amount = 0.4
        #expect(AutoSync.changedGroups(from: before, to: graded) == [.grain])
        #expect(AutoSync.apply(from: before, to: graded, onto: target).grain.amount == 0.4)
        #expect(AutoSync.apply(from: before, to: before, onto: target) == target.sanitized)
    }

    @Test func adaptivePresetsMaskTheirTools() {
        let pop = AdaptivePresets.all.first { $0.name == "Subject: Pop" }!
        let e = AdaptivePresets.apply(pop, to: PhotoEdits(), maskAsset: "subject.png")
        #expect(abs(e.clarity - 0.25) < 1e-9 && abs(e.texture - 0.2) < 1e-9)
        let clarityMask = e.advanced?.masks["Clarity"]
        #expect(clarityMask?.components?.first?.selection.asset == "subject.png" && clarityMask?.components?.first?.selection.inverted == false)
        let soften = AdaptivePresets.all.first { $0.target == .background }!
        let b = AdaptivePresets.apply(soften, to: PhotoEdits(), maskAsset: "subject.png")
        #expect(b.advanced?.masks["Texture"]?.components?.first?.selection.inverted == true)
        #expect(AdaptivePresets.all.contains { $0.needsSkyModel } && Set(AdaptivePresets.all.map(\.name)).count == AdaptivePresets.all.count)
    }

    @Test func bookIsAModuleAndCatalogLocationPersists() {
        #expect(LightroomModule.allCases.contains(.book) && !LightroomModule.book.isWorkspace)
        let previous = UserDefaults.standard.string(forKey: CatalogLocation.defaultsKey)
        CatalogLocation.choose(directory)
        #expect(CatalogLocation.chosen?.path == directory.path)
        CatalogLocation.choose(nil)
        #expect(CatalogLocation.chosen == nil)
        if let previous { UserDefaults.standard.set(previous, forKey: CatalogLocation.defaultsKey) }
    }
}
