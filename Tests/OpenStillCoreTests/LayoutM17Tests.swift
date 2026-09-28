import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

@Suite struct FolderTreeTests {
    @Test func drivesThenFoldersWithCounts() {
        let paths = ["/Users/a/Pictures/2024/Rome/1.raf", "/Users/a/Pictures/2024/Rome/2.raf", "/Users/a/Pictures/2024/Paris/day 1/3.arw",
                     "/Volumes/Photos/Travel/Oslo/4.raf", "/Volumes/Photos/Family/5.jpg", "/Volumes/Photos/Family/6.jpg"]
        let volumes = FolderTree.volumes(paths, startupName: "Macintosh HD", exists: { $0 == "/" })
        #expect(volumes.map(\.name) == ["Macintosh HD", "Photos"])  // startup disk first
        #expect(volumes.map(\.count) == [3, 3] && volumes.map(\.online) == [true, false])
        // The chain /Users/a/Pictures is skipped: the startup disk starts at 2024, where the photos are.
        let disk = volumes[0]
        #expect(disk.folders.map(\.name) == ["2024"] && disk.folders[0].path == "/Users/a/Pictures/2024" && disk.folders[0].count == 3)
        #expect(disk.folders[0].children.map(\.name) == ["Paris", "Rome"] && disk.folders[0].children.map(\.count) == [1, 2])
        #expect(disk.folders[0].children[0].children.map(\.path) == ["/Users/a/Pictures/2024/Paris/day 1"])
        // Where folders branch at the top, each branch is its own top-level folder.
        let drive = volumes[1]
        #expect(drive.path == "/Volumes/Photos" && drive.folders.map(\.name) == ["Family", "Travel"] && drive.folders.map(\.count) == [2, 1])
        #expect(FolderTree.volumes([]).isEmpty)
    }

    @Test func aFolderWithPhotosIsKeptEvenWithOneSubfolder() {
        let paths = ["/Users/a/Shoot/1.jpg", "/Users/a/Shoot/Selects/2.jpg", "/Users/a/Shoot/Selects/3.jpg"]
        let folders = FolderTree.volumes(paths, startupName: "Disk", exists: { _ in true })[0].folders
        #expect(folders.map(\.name) == ["Shoot"] && folders[0].count == 3 && folders[0].children.map(\.name) == ["Selects"])
        // Names sort like Finder: 2 before 10.
        let numbered = FolderTree.volumes(["/p/Roll 10/a.jpg", "/p/Roll 2/b.jpg"], startupName: "Disk", exists: { _ in true })[0].folders
        #expect(numbered.map(\.name) == ["Roll 2", "Roll 10"])
    }
}

@Suite final class ImportModeTests {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("import-mode-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func photo(_ path: String, _ brightness: Double) throws -> URL {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let image = CIImage(color: CIColor(red: brightness, green: 0.4, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        try ModernRenderer.export(image, to: url, source: nil, settings: ExportSettings())
        return url
    }
    func store() -> PhotoRecordStore { let s = PhotoRecordStore(root: directory.appendingPathComponent("app")); s.writesSidecars = { false }; return s }

    @Test func addLeavesPhotosWhereTheyAre() throws {
        let a = try photo("Shoot/a.jpg", 0.9), b = try photo("Shoot/b.jpg", 0.5)
        let before = try [a, b].map { try PhotoRecordStore.contentHash($0) }
        let store = store()
        var settings = ImportSettings(destination: directory.appendingPathComponent("Unused")); settings.importMode = .add
        var meta = IPTCMetadata(); meta.keywords = ["Added"]; settings.metadata = meta
        let report = PhotoImport.run(PhotoImport.scan(directory.appendingPathComponent("Shoot"), catalog: store.catalog), settings: settings, store: store)
        #expect(report.mode == .add && report.failed.isEmpty)
        #expect(Set(report.imported.map { $0.standardizedFileURL.path }) == Set([a, b].map { $0.standardizedFileURL.path }))
        #expect(try [a, b].map { try PhotoRecordStore.contentHash($0) } == before)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Unused").path))
        #expect(try store.record(for: a).iptc.keywords.contains("Added"))
        #expect(report.summary.contains("left where they are") && report.summary.contains("Nothing was deleted"))
    }

    @Test func moveTakesThePhotosAndTheirSidecars() throws {
        let a = try photo("In/a.jpg", 0.9)
        var xmp = XMPMetadata(); xmp.rating = 3
        try XMPSidecar.xmpData(xmp).write(to: XMPSidecar.url(for: a))
        let hash = try PhotoRecordStore.contentHash(a)
        let store = store()
        var settings = ImportSettings(destination: directory.appendingPathComponent("Library")); settings.importMode = .move; settings.folderTemplate = "Moved"
        let report = PhotoImport.run(PhotoImport.scan(directory.appendingPathComponent("In"), catalog: store.catalog), settings: settings, store: store)
        #expect(report.mode == .move && report.failed.isEmpty && report.originalsKept.isEmpty && report.imported.count == 1)
        let moved = try #require(report.imported.first)
        #expect(moved.deletingLastPathComponent().lastPathComponent == "Moved" && (try PhotoRecordStore.contentHash(moved)) == hash)
        #expect(!FileManager.default.fileExists(atPath: a.path) && !FileManager.default.fileExists(atPath: XMPSidecar.url(for: a).path))
        #expect(XMPSidecar.read(moved)?.rating == 3)
        #expect(PhotoImport.sameVolume(directory, directory.appendingPathComponent("not/made/yet")))
    }

    @Test func copyIsStillTheDefault() throws {
        // Settings saved before modes existed have no "mode" key.
        var saved = ImportSettings(destination: directory); saved.importMode = .move
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        #expect(json["mode"] as? String == "move")
        json["mode"] = nil
        let decoded = try JSONDecoder().decode(ImportSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.importMode == .copy && decoded.mode == nil)
        #expect(ImportMode.allCases.map(\.title) == ["Copy", "Move", "Add"])
    }
}
