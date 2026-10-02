import Foundation
import CoreImage
import ImageIO
import Testing
@testable import OpenStillCore

/// Virtual copies, collection sets and Synchronize Folder removing deleted photos.
@Suite final class VirtualCopyTests {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("copies-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func photo(_ name: String, color: CIColor = CIColor(red: 0.3, green: 0.4, blue: 0.5)) throws -> URL {
        let folder = directory.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try ModernRenderer.export(CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24)), to: url, source: nil, settings: ExportSettings())
        return url
    }

    @Test func aCopyHasItsOwnEditsRatingAndListing() throws {
        let store = PhotoRecordStore(root: directory.appendingPathComponent("app")), file = try photo("a.jpg")
        let catalog = try #require(store.catalog)
        var original = try store.record(for: file)
        var e = PhotoEdits(); e.exposure = 0.5
        var document = original.active.document; document.commit(e, title: "Exposure"); original.updateDocument(document)
        original.rating = 4; try store.save(original)
        let copy = try VirtualCopy.create(of: original, store: store)
        #expect(copy.masterID == original.id && copy.copyName == "Copy 1" && copy.rating == 0 && copy.active.document.current.exposure == 0.5)
        // The file finds the original; the copy's URL finds the copy.
        #expect(try store.record(for: file).id == original.id)
        #expect(VirtualCopy.id(in: copy.listURL) == copy.id && copy.listURL.path == file.standardizedFileURL.path)
        #expect(try store.record(for: copy.listURL).id == copy.id)
        // Its own edits and rating.
        var changed = try store.record(for: copy.listURL); changed.rating = 2; try store.save(changed)
        let originalRating = try store.read(original.id).rating, copyRating = try store.read(copy.id).rating
        #expect(originalRating == 4 && copyRating == 2)
        // Listed right after the original, and stacked with it.
        #expect(VirtualCopy.expand([file.standardizedFileURL]) .count == 1)   // the default store isn't this one
        #expect(VirtualCopy.expand([file.standardizedFileURL], catalog: catalog) == [file.standardizedFileURL, copy.listURL])
        #expect(catalog.stacks().values.contains { Set($0) == [original.id, copy.id] })
        #expect(catalog.photo(copy.id)?.masterID == original.id && catalog.photo(copy.id)?.listURL == copy.listURL)
        // The folder count and duplicate finder ignore copies.
        #expect(catalog.photoPaths().count == 1 && catalog.exactDuplicates().isEmpty)
        // A second copy is "Copy 2"; removing a copy leaves the file and the original.
        let second = try VirtualCopy.create(of: original, store: store)
        #expect(second.copyName == "Copy 2" && catalog.virtualCopies(of: original.id) == [copy.id, second.id])
        try VirtualCopy.remove(copy.id, store: store)
        #expect(catalog.virtualCopies(of: original.id) == [second.id] && FileManager.default.fileExists(atPath: file.path) && (try? store.read(copy.id)) == nil)
        // Removing an original by this call does nothing.
        try VirtualCopy.remove(original.id, store: store)
        #expect(catalog.photo(original.id) != nil)
    }
    @Test func filesOpenThroughACopysURL() throws {
        let file = try photo("b.jpg")
        let url = VirtualCopy.url(path: file.standardizedFileURL.path, copy: UUID())
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }?.width == 32)
        let image = try ModernRenderer.render(source: url, recipe: RenderRecipe(renderer: .linear2020, sourceMode: .original, edits: PhotoEdits()), maximumDimension: 64, keepSource: false)
        #expect(image.extent.width == 32)
        #expect(VirtualCopy.file(url) == URL(fileURLWithPath: file.standardizedFileURL.path) && !VirtualCopy.isCopy(file))
    }
    @Test func collectionSetsNestAndUnnest() throws {
        let catalog = try LibraryCatalog(url: directory.appendingPathComponent("sets.sqlite"))
        let trips = try catalog.createCollectionSet(name: "Trips"), europe = try catalog.createCollectionSet(name: "Europe", parent: trips.id)
        let paris = try catalog.createCollection(name: "Paris")
        try catalog.move(collection: paris.id, into: europe.id)
        #expect(catalog.collectionParents()[paris.id] == europe.id && catalog.collectionParents()[europe.id] == trips.id)
        // Sets aren't collections of photos.
        #expect(catalog.collections().map(\.name) == ["Paris"] && catalog.collectionSets().map(\.name) == ["Europe", "Trips"])
        // A set can't go inside itself or its own sets.
        try catalog.move(collection: trips.id, into: europe.id)
        #expect(catalog.collectionParents()[trips.id] == nil)
        // A collection can't go "into" a regular collection.
        let other = try catalog.createCollection(name: "Other")
        try catalog.move(collection: paris.id, into: other.id)
        #expect(catalog.collectionParents()[paris.id] == europe.id)
        // Deleting a set moves what's inside up a level.
        try catalog.deleteCollectionSet(europe.id)
        #expect(catalog.collectionParents()[paris.id] == trips.id && catalog.collections().count == 2)
    }
    @Test func synchronizeFolderFindsDeletedPhotosAndTheyComeBack() throws {
        let store = PhotoRecordStore(root: directory.appendingPathComponent("sync"))
        let catalog = try #require(store.catalog)
        let a = try photo("keep.jpg"), b = try photo("gone.jpg", color: CIColor(red: 0.9, green: 0.2, blue: 0.1))
        _ = try store.record(for: a)
        var removed = try store.record(for: b); removed.rating = 5; try store.save(removed)
        let copy = try VirtualCopy.create(of: removed, store: store)
        let backup = directory.appendingPathComponent("gone-backup.jpg")
        try FileManager.default.moveItem(at: b, to: backup)
        let folder = directory.appendingPathComponent("Photos").path
        let missing = catalog.photosMissing(under: folder)
        #expect(Set(missing.map(\.id)) == [removed.id, copy.id])
        // A folder that isn't there (an unplugged drive) reports nothing.
        #expect(catalog.photosMissing(under: directory.appendingPathComponent("Nope").path).isEmpty)
        try RemovedPhotos.remove(missing, store: store)
        #expect(catalog.photo(removed.id) == nil && catalog.photoCount == 1)
        // The file comes back: same record, rating and edits.
        try FileManager.default.moveItem(at: backup, to: b)
        let back = try store.record(for: b)
        #expect(back.id == removed.id && back.rating == 5 && catalog.photo(removed.id) != nil)
    }
}
