import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

@Suite final class PhotoImportTests {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func write(_ image: CIImage, _ path: String) throws -> URL {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ModernRenderer.export(image.cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64)), to: url, source: nil, settings: ExportSettings())
        return url
    }
    func checker(_ brightness: Double = 1, size: Double = 8) -> CIImage {
        CIFilter(name: "CICheckerboardGenerator", parameters: ["inputColor0": CIColor(red: 0.9 * brightness, green: 0.8 * brightness, blue: 0.2 * brightness),
                                                                "inputColor1": CIColor(red: 0.1, green: 0.2, blue: 0.5), "inputWidth": size, "inputCenter": CIVector(x: 0, y: 0)])!.outputImage!
    }
    func stripes() -> CIImage {
        CIFilter(name: "CIStripesGenerator", parameters: ["inputColor0": CIColor(red: 0.1, green: 0.9, blue: 0.3), "inputColor1": CIColor(red: 0.8, green: 0.1, blue: 0.7), "inputWidth": 3.0])!.outputImage!
            .transformed(by: CGAffineTransform(rotationAngle: 0.6))
    }
    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9, _ min: Int = 5, _ s: Int = 7) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    @Test func templatesExpandAndRejectBadNames() throws {
        let c = ImportCandidate(url: URL(fileURLWithPath: "/Volumes/CARD/DCIM/100CANON/IMG_0042.CR3"), size: 1, captured: date(2026, 3, 7, 14, 2, 9), sidecar: nil)
        #expect(try PhotoImport.expand("{yyyy}/{yyyy}-{MM}-{dd}", candidate: c, index: 0, camera: "X", folders: true) == "2026/2026-03-07")
        #expect(try PhotoImport.expand("{date}_{time}_{index}", candidate: c, index: 4, camera: "X", folders: false) == "2026-03-07_140209_0005")
        #expect(try PhotoImport.expand("{camera}_{name}", candidate: c, index: 0, camera: "EOS R6/II", folders: false) == "EOS R6-II_IMG_0042")
        #expect(try PhotoImport.expand("", candidate: c, index: 0, camera: "X", folders: true) == "")
        #expect(throws: ImportError.self) { try PhotoImport.expand("{nope}", candidate: c, index: 0, camera: "X", folders: false) }
        #expect(throws: ImportError.self) { try PhotoImport.expand("../{name}", candidate: c, index: 0, camera: "X", folders: true) }
        #expect(throws: ImportError.self) { try PhotoImport.expand("a/{name}", candidate: c, index: 0, camera: "X", folders: false) }
        #expect(throws: ImportError.self) { try PhotoImport.expand("", candidate: c, index: 0, camera: "X", folders: false) }
    }

    @Test func importCopiesVerifiesAndNeverTouchesTheSource() throws {
        let card = directory.appendingPathComponent("CARD")
        let a = try write(checker(), "CARD/DCIM/100TEST/IMG_0001.JPG"), b = try write(stripes(), "CARD/DCIM/100TEST/IMG_0002.JPG")
        _ = try write(checker(0.8), "CARD/DCIM/101TEST/IMG_0001.JPG")   // same name in another folder
        var sidecarXMP = XMPMetadata(); sidecarXMP.rating = 4
        try XMPSidecar.xmpData(sidecarXMP).write(to: XMPSidecar.url(for: a))
        try Data("hidden".utf8).write(to: card.appendingPathComponent("DCIM/.hidden.jpg"))
        let sourceHashes = try [a, b].map { try PhotoRecordStore.contentHash($0) }

        let store = PhotoRecordStore(root: directory.appendingPathComponent("app")); store.writesSidecars = { false }
        let found = PhotoImport.scan(card, catalog: store.catalog)
        #expect(found.count == 3 && found.allSatisfy { $0.include && !$0.alreadyImported })
        #expect(found.first { $0.url == a.standardizedFileURL }?.sidecar != nil)

        var settings = ImportSettings(destination: directory.appendingPathComponent("Photos"))
        settings.folderTemplate = "Shoot"; settings.nameTemplate = "{name}"
        settings.backup = directory.appendingPathComponent("Backup")
        var meta = IPTCMetadata(); meta.creator = "Sample Studio"; meta.keywords = ["Imported"]; settings.metadata = meta
        var preset = PhotoEdits(); preset.exposure = 0.7; preset.crop = EditRect(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        settings.developPreset = preset; settings.developPresetName = "Bright"
        var steps: [Int] = []
        let report = PhotoImport.run(found, settings: settings, store: store, progress: { done, _ in steps.append(done) })
        #expect(report.imported.count == 3 && report.failed.isEmpty && report.backupFailed.isEmpty && steps.last == 3)
        let names = Set(report.imported.map(\.lastPathComponent))
        #expect(names == ["IMG_0001.JPG", "IMG_0001-1.JPG", "IMG_0002.JPG"])
        #expect(report.imported.allSatisfy { $0.deletingLastPathComponent().lastPathComponent == "Shoot" })
        // Copies are identical; the backup mirrors them; the sidecar came along.
        for url in report.imported {
            let backup = directory.appendingPathComponent("Backup/Shoot/" + url.lastPathComponent)
            #expect(try PhotoRecordStore.contentHash(url) == PhotoRecordStore.contentHash(backup))
        }
        let copiedA = try #require(report.imported.first { (try? PhotoRecordStore.contentHash($0)) == sourceHashes[0] })
        #expect(XMPSidecar.read(copiedA)?.rating == 4)
        #expect(FileManager.default.fileExists(atPath: XMPSidecar.url(for: directory.appendingPathComponent("Backup/Shoot/" + copiedA.lastPathComponent)).path))
        // The source is untouched.
        #expect(try [a, b].map { try PhotoRecordStore.contentHash($0) } == sourceHashes)
        #expect(FileManager.default.fileExists(atPath: XMPSidecar.url(for: a).path))
        // Records carry the metadata and preset; the preset's crop isn't applied.
        let record = try store.record(for: copiedA)
        #expect(record.rating == 4 && record.iptc.creator == "Sample Studio" && record.iptc.keywords == ["Imported"])
        #expect(abs(record.active.document.current.exposure - 0.7) < 1e-9 && record.active.document.current.crop == nil)
        #expect(record.active.document.steps.last?.title == "Bright")
        // No leftover partial files.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Photos/Shoot").path).filter { $0.hasSuffix(".importing") }
        #expect(leftovers.isEmpty)

        // Scanning again marks everything as already imported, and importing skips them.
        let again = PhotoImport.scan(card, catalog: store.catalog)
        #expect(again.allSatisfy { $0.alreadyImported && !$0.include })
        let second = PhotoImport.run(again, settings: settings, store: store)
        #expect(second.imported.isEmpty && second.skipped == 3 && second.summary.contains("already in your library"))
    }
    @Test func verifiedCopyNeverOverwrites() throws {
        let source = try write(checker(), "src/a.jpg"), existing = try write(stripes(), "dst/a.jpg")
        let before = try PhotoRecordStore.contentHash(existing)
        #expect(throws: (any Error).self) { try PhotoImport.verifiedCopy(source, to: existing) }
        #expect(try PhotoRecordStore.contentHash(existing) == before)
        let fresh = directory.appendingPathComponent("dst/b.jpg")
        #expect(try PhotoImport.verifiedCopy(source, to: fresh) == PhotoRecordStore.contentHash(source))
        #expect(PhotoImport.freeURL(directory.appendingPathComponent("dst"), stem: "a", ext: "jpg", taken: []).lastPathComponent == "a-1.jpg")
        #expect(PhotoImport.freeURL(directory.appendingPathComponent("dst"), stem: "c", ext: "jpg", taken: [directory.appendingPathComponent("dst/c.jpg").path.lowercased()]).lastPathComponent == "c-1.jpg")
    }
    @Test func cancelledImportKeepsFinishedCopies() throws {
        let files = try (0..<3).map { try write(checker(1 - Double($0) * 0.1), "card/IMG_\($0).jpg") }
        let store = PhotoRecordStore(root: directory.appendingPathComponent("app2")); store.writesSidecars = { false }
        var settings = ImportSettings(destination: directory.appendingPathComponent("out")); settings.folderTemplate = ""
        var calls = 0
        let report = PhotoImport.run(PhotoImport.scan(directory.appendingPathComponent("card"), catalog: store.catalog), settings: settings, store: store, cancelled: { calls += 1; return calls > 1 })
        #expect(report.cancelled && report.imported.count == 1 && report.summary.contains("Stopped"))
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func exactDuplicates() throws {
        let a = try write(checker(), "lib/a.jpg"), c = try write(stripes(), "lib/c.jpg")
        let b = directory.appendingPathComponent("lib/sub/b.jpg")
        try FileManager.default.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: a, to: b)
        let groups = DuplicateFinder.exact([a, b, c])
        #expect(groups.count == 1 && Set(groups[0].urls) == [a, b] && groups[0].kind == .exact)
        // The catalog finds the same pair once both are indexed.
        let store = PhotoRecordStore(root: directory.appendingPathComponent("app3"))
        for url in [a, b, c] { _ = try store.record(for: url) }
        let catalog = try #require(store.catalog)
        #expect(catalog.exactDuplicates().map { Set($0.map(\.path)) } == [[a.standardizedFileURL.path, b.standardizedFileURL.path]])
        let size = Int64(try a.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
        #expect(catalog.fingerprints(size: size) == [try PhotoRecordStore.contentHash(a)])
        // The higher-rated copy is the one to keep.
        var records: [URL: PhotoRecord] = [:]
        records[a] = try store.record(for: a); records[b] = try ShootWorkflow.mark(try store.record(for: b).id, rating: 3, store: store)
        #expect(DuplicateFinder.best(groups[0], records: records) == b)
    }
    @Test func similarPhotosGroupTogether() throws {
        let a = try write(checker(), "sim/a.jpg"), a2 = try write(checker(0.93), "sim/a2.jpg"), b = try write(stripes(), "sim/b.jpg")
        let pa = try #require(DuplicateFinder.featurePrint(a)), pa2 = try #require(DuplicateFinder.featurePrint(a2)), pb = try #require(DuplicateFinder.featurePrint(b))
        let near = try #require(DuplicateFinder.distance(pa, pa2)), far = try #require(DuplicateFinder.distance(pa, pb))
        #expect(near < far)
        let groups = DuplicateFinder.similar([a, a2, b], threshold: (near + far) / 2)
        #expect(groups.count == 1 && Set(groups[0].urls) == [a, a2] && groups[0].kind == .similar)
        #expect(DuplicateFinder.similar([a, b], threshold: near / 2).isEmpty)
    }
}
