import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

/// The library cache and relinking: recent photos stay visible while their drive is away, and come back by themselves.
@Suite final class LibraryLocationsTests {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("locations-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func photo(_ name: String, in folder: URL, color: CIColor = CIColor(red: 0.3, green: 0.4, blue: 0.5)) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try ModernRenderer.export(CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24)), to: url, source: nil, settings: ExportSettings())
        return url
    }
    func location(_ path: String, uuid: String? = "CARD-1", name: String = "EOS_DIGITAL", size: Int64 = 100) -> PhotoLocation {
        let relative = path.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true).last.map(String.init)
        return PhotoLocation(id: UUID(), path: path, size: size, volumeUUID: uuid, volumeName: name, relative: relative)
    }

    @Test func theSameDriveRelinksWhereverItMounts() {
        // The card was "/Volumes/EOS_DIGITAL"; it now mounts as "/Volumes/EOS_DIGITAL 1".
        let photos = (1...3).map { location("/Volumes/EOS_DIGITAL/DCIM/100CANON/IMG_000\($0).CR3") }
        let card = MountedVolume(uuid: "CARD-1", name: "EOS_DIGITAL", root: "/Volumes/EOS_DIGITAL 1")
        let present = Set(photos.map { card.absolute($0.relative!) })
        let plan = LibraryRelocator.plan(for: card, locations: photos, exists: { present.contains($0) }, size: { _ in 100 })
        #expect(plan.automatic.count == 3 && plan.suggested.isEmpty)
        #expect(plan.automatic[0].to == "/Volumes/EOS_DIGITAL 1/DCIM/100CANON/IMG_0001.CR3")
        // Photos whose recorded path still exists aren't touched.
        let stillThere = LibraryRelocator.plan(for: card, locations: photos, exists: { _ in true }, size: { _ in 100 })
        #expect(stillThere.isEmpty)
    }
    @Test func aReformattedCardWithTheSameNameRelinksOnlyWhenTheFilesMatch() {
        let photos = (1...3).map { location("/Volumes/EOS_DIGITAL/DCIM/100CANON/IMG_000\($0).CR3", uuid: "OLD") }
        let card = MountedVolume(uuid: "NEW", name: "EOS_DIGITAL", root: "/Volumes/EOS_DIGITAL")
        let elsewhere = MountedVolume(uuid: "NEW", name: "EOS_DIGITAL", root: "/Volumes/EOS_DIGITAL 1")
        let present = Set(photos.map { elsewhere.absolute($0.relative!) })
        let matching = LibraryRelocator.plan(for: elsewhere, locations: photos, exists: { present.contains($0) }, size: { _ in 100 })
        #expect(matching.automatic.count == 3)
        // Same names, different sizes: different photos (a reused card), nothing relinks.
        let different = LibraryRelocator.plan(for: elsewhere, locations: photos, exists: { present.contains($0) }, size: { _ in 999 })
        #expect(different.isEmpty)
        _ = card
    }
    @Test func photosCopiedToAnotherDriveAreSuggestedNotMoved() {
        let photos = (1...4).map { location("/Volumes/EOS_DIGITAL/DCIM/100CANON/IMG_000\($0).CR3") }
        let backup = MountedVolume(uuid: "SSD", name: "Photos SSD", root: "/Volumes/Photos SSD")
        let present = Set(photos.map { backup.absolute($0.relative!) })
        let plan = LibraryRelocator.plan(for: backup, locations: photos, exists: { present.contains($0) }, size: { _ in 100 })
        #expect(plan.automatic.isEmpty && plan.suggested.count == 4 && plan.suggestedFrom == "EOS_DIGITAL")
        // One or two stray files with the same names aren't enough to ask.
        let few = LibraryRelocator.plan(for: backup, locations: Array(photos.prefix(2)), exists: { present.contains($0) }, size: { _ in 100 })
        #expect(few.isEmpty)
    }
    @Test func findMissingFolderMatchesNamesAndSizesUnderTheNewFolder() {
        let photos = [location("/Volumes/Old/Shoots/2024/a.jpg"), location("/Volumes/Old/Shoots/2024/day2/b.jpg"), location("/Volumes/Old/Other/c.jpg")]
        let present: Set<String> = ["/Users/me/Shoots 2024/a.jpg", "/Users/me/Shoots 2024/day2/b.jpg", "/Users/me/Shoots 2024/c.jpg"]
        let moves = LibraryRelocator.plan(from: "/Volumes/Old/Shoots/2024", to: "/Users/me/Shoots 2024", locations: photos, exists: { present.contains($0) }, size: { _ in 100 })
        #expect(moves.map(\.to).sorted() == ["/Users/me/Shoots 2024/a.jpg", "/Users/me/Shoots 2024/day2/b.jpg"])
    }
    @Test func relinkingUpdatesRecordsAndCatalog() throws {
        let store = PhotoRecordStore(root: directory.appendingPathComponent("app"))
        let catalog = try #require(store.catalog)
        let file = try photo("IMG_0001.jpg", in: directory.appendingPathComponent("Card/DCIM"))
        let record = try store.record(for: file)
        // The location is recorded on indexing.
        let recorded = try #require(catalog.locations(ids: [record.id]).first)
        #expect(recorded.relative?.hasSuffix("Card/DCIM/IMG_0001.jpg") == true && recorded.volumeName != nil)
        // The card is copied somewhere else and the original disappears.
        let copy = directory.appendingPathComponent("Card 1/DCIM/IMG_0001.jpg")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: copy)
        let moves = LibraryRelocator.plan(from: directory.appendingPathComponent("Card").path, to: directory.appendingPathComponent("Card 1").path, locations: catalog.locations())
        #expect(moves.count == 1)
        #expect(LibraryRelocator.apply(moves, store: store) == 1)
        #expect(try store.read(record.id).sourcePath == copy.standardizedFileURL.path)
        #expect(catalog.photo(record.id)?.path == copy.standardizedFileURL.path)
        // Edits stay with the photo: the same record opens at the new place.
        #expect(try store.record(for: copy).id == record.id)
    }
    @Test func missingPhotosStayListedAndFoldersOpenFromTheCatalog() throws {
        let store = PhotoRecordStore(root: directory.appendingPathComponent("offline"))
        let catalog = try #require(store.catalog)
        let folder = directory.appendingPathComponent("Card_2024/100%")
        let file = try photo("x.jpg", in: folder)
        let record = try store.record(for: file)
        _ = try photo("other.jpg", in: directory.appendingPathComponent("Card-2024"))
        try FileManager.default.removeItem(at: file)
        // "_" and "%" in folder names are matched literally.
        #expect(catalog.photoPaths(under: directory.appendingPathComponent("Card_2024").path) == [file.standardizedFileURL.path])
        #expect(catalog.recordID(path: file.standardizedFileURL.path) == record.id)
        // The record still opens while the file is gone (for its cached look).
        #expect(try store.record(for: file).id == record.id)
    }
    @Test func recentIsNewestFirst() throws {
        let store = PhotoRecordStore(root: directory.appendingPathComponent("recent"))
        let catalog = try #require(store.catalog)
        let a = try store.record(for: try photo("a.jpg", in: directory.appendingPathComponent("R"))), b = try store.record(for: try photo("b.jpg", in: directory.appendingPathComponent("R"), color: CIColor(red: 0.9, green: 0.1, blue: 0.1)))
        catalog.touchRecent(a.id, at: Date(timeIntervalSince1970: 100))
        catalog.touchRecent(b.id, at: Date(timeIntervalSince1970: 200))
        #expect(catalog.recent() == [b.id, a.id])
        catalog.touchRecent(a.id, at: Date(timeIntervalSince1970: 300))
        #expect(catalog.recent() == [a.id, b.id] && catalog.recent(limit: 1) == [a.id])
        catalog.touchRecent(UUID())   // unknown photos are ignored
        #expect(catalog.recent().count == 2)
    }
    @Test func libraryCacheKeepsRecentLooks() throws {
        let root = directory.appendingPathComponent("cache")
        let image = try #require(CIContext().createCGImage(CIImage(color: CIColor(red: 0.8, green: 0.3, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 4000, height: 3000)), from: CGRect(x: 0, y: 0, width: 4000, height: 3000)))
        let a = UUID(), b = UUID()
        LibraryCache.store(image, for: a, revision: "r1", root: root)
        LibraryCache.store(image, for: b, revision: "r1", root: root)
        let cached = try #require(LibraryCache.image(for: a, root: root))
        #expect(max(cached.width, cached.height) == LibraryCache.longEdge)
        #expect(LibraryCache.revision(of: a, root: root) == "r1" && LibraryCache.date(of: a, root: root) != nil)
        #expect((LibraryCache.image(for: a, maximum: 300, root: root)?.width ?? 0) <= 300)
        LibraryCache.prune(keeping: [b, a], keep: 1, root: root)
        #expect(LibraryCache.image(for: a, root: root) == nil && LibraryCache.image(for: b, root: root) != nil && LibraryCache.revision(of: a, root: root) == nil)
    }
    @Test func aiResultsThatMoveTheFrameDontLineUp() throws {
        let context = CIContext()
        func image(_ make: () -> CIImage, _ w: Int = 160, _ h: Int = 120) throws -> CGImage { try #require(context.createCGImage(make(), from: CGRect(x: 0, y: 0, width: w, height: h))) }
        let scene = { () -> CIImage in
            CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 60))
                .composited(over: CIImage(color: CIColor(red: 0.2, green: 0.8, blue: 0.2)).cropped(to: CGRect(x: 80, y: 0, width: 80, height: 60)))
                .composited(over: CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.8)).cropped(to: CGRect(x: 0, y: 60, width: 160, height: 60)))
        }
        let before = try image(scene)
        // An erased patch: the rest is the same.
        let erased = try image { CIImage(color: .white).cropped(to: CGRect(x: 70, y: 50, width: 20, height: 20)).composited(over: scene()) }
        #expect(AIBase.linesUp(before: before, after: erased))
        // The bug this guards against: a zoomed-in corner, washed out.
        let zoomed = try image { scene().transformed(by: CGAffineTransform(scaleX: 4, y: 4)).applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.5]) }
        #expect(!AIBase.linesUp(before: before, after: zoomed))
        // A different frame size never lines up.
        #expect(!AIBase.linesUp(before: before, after: try image(scene, 120, 120)))
    }
}
