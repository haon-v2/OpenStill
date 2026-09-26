import Foundation
import CryptoKit

public enum SourceMode: String, Codable, CaseIterable { case original, cameraLook, raw }
public enum RendererVersion: String, Codable { case legacy, linear2020 }
public enum ExportProfile: String, Codable, CaseIterable { case sRGB, displayP3, adobeRGB, proPhotoRGB }
public enum ExportFormat: String, Codable, CaseIterable { case jpeg, png, tiff, heif }

public struct RawSettings: Codable, Equatable, Hashable {
    public var whiteBalance: [Float]?
    public var highlightRecovery = 2
    public var temperature: Double?
    public var tint: Double?
    /// Demosaic and LibRaw noise choices; nil keeps LibRaw's defaults.
    public var options: RawOptions?
    public init() {}
    public var cacheKey:String {
        let s = sanitized
        var key = "\(s.whiteBalance ?? [])|\(s.highlightRecovery)|\(s.temperature ?? 6500)|\(s.tint ?? 0)"
        if let o = s.options { key += "|\(o.demosaic.rawValue)|\(o.noise)|\(o.colorNoise)|\(o.impulseNoise)" }
        return key
    }
    public var sanitized: RawSettings {
        var s = self
        s.highlightRecovery = min(9, max(0, highlightRecovery))
        s.temperature = (temperature ?? 6500).isFinite ? min(10000,max(2500,temperature ?? 6500)) : 6500
        s.tint = (tint ?? 0).isFinite ? min(100,max(-100,tint ?? 0)) : 0
        if let options { let clean = options.sanitized; s.options = clean.isDefault ? nil : clean }
        if let wb = whiteBalance, wb.count != 4 || wb.contains(where: { !$0.isFinite || $0 <= 0 || $0 > 32 }) { s.whiteBalance = nil }
        return s
    }
}
public struct ExportSettings: Codable, Equatable {
    public var format: ExportFormat = .jpeg
    public var profile: ExportProfile = .sRGB
    public var bitDepth = 8
    public var quality = 0.9
    public var longestEdge: Int?
    public var allowUpscaling = false
    public var sharpening = 0.0
    public var keepMetadata = true
    public var keepGPS = false
    public var filenameTemplate = "{name}-edited"
    public var watermark:WatermarkSettings?
    /// HDR output; nil = SDR. PQ and HLG need HEIF; a gain map works with JPEG or HEIF.
    public var hdr: HDRExport?
    public init() {}
    public var isHDR: Bool { hdr != nil }
    public var sanitized: ExportSettings {
        var s = self
        s.bitDepth = format == .jpeg || format == .heif ? 8 : (bitDepth == 16 ? 16 : 8)
        if let mode = hdr, !(format == .heif || (format == .jpeg && mode == .gainMap)) { s.hdr = nil }
        s.quality = quality.isFinite ? min(1, max(0, quality)) : 0.9
        s.sharpening = sharpening.isFinite ? min(2, max(0, sharpening)) : 0
        if let edge = longestEdge { s.longestEdge = max(1, min(65535, edge)) }
        return s
    }
}
public struct RenderRecipe: Codable {
    public var renderer: RendererVersion
    public var sourceMode: SourceMode
    public var raw: RawSettings
    public var edits: PhotoEdits
    public init(renderer: RendererVersion, sourceMode: SourceMode, raw: RawSettings = RawSettings(), edits: PhotoEdits) {
        self.renderer = renderer; self.sourceMode = sourceMode; self.raw = raw; self.edits = edits
        if sourceMode == .raw {
            self.raw.temperature = edits.temperature; self.raw.tint = edits.tint
            self.raw.highlightRecovery = edits.advanced?.rawRecovery ?? raw.highlightRecovery
            if let wb = edits.advanced?.rawWhiteBalance { self.raw.whiteBalance = wb }
            self.raw.options = edits.advanced?.rawOptions
        }
    }
}
public struct RenderRequest: Hashable {
    public let photoID: UUID
    public let sourceFingerprint: String
    public let sourceMode: SourceMode
    public let versionID: UUID
    public let revision: UUID
    public let profile: ExportProfile
    public let maximumDimension: Int?
    public init(photo: PhotoRecord, profile: ExportProfile = .sRGB, maximumDimension: Int? = nil) {
        photoID = photo.id; sourceFingerprint = photo.contentFingerprint; sourceMode = photo.active.sourceMode
        versionID = photo.active.id; revision = photo.active.revision; self.profile = profile; self.maximumDimension = maximumDimension
    }
}
public struct EditVersion: Codable, Identifiable {
    public var id = UUID()
    public var name: String
    public var created = Date()
    public var renderer: RendererVersion
    public var sourceMode: SourceMode
    public var raw = RawSettings()
    public var document: EditDocument
    public var revision = UUID()
    public var recipe: RenderRecipe { RenderRecipe(renderer: renderer, sourceMode: sourceMode, raw: raw, edits: document.current) }
    public init(name: String, renderer: RendererVersion, sourceMode: SourceMode, document: EditDocument) {
        self.name = name; self.renderer = renderer; self.sourceMode = sourceMode; self.document = document
    }
}
public struct PhotoRecord: Codable, Identifiable {
    public var schemaVersion = 1
    public var id = UUID()
    public var sourcePath: String
    public var bookmark: Data?
    public var contentFingerprint: String
    public var versions: [EditVersion]
    public var activeVersionID: UUID
    public var rating = 0
    public var flag: PhotoFlag = .none
    public var label: ColorLabel?
    public var metadata: IPTCMetadata?
    public var active: EditVersion { versions.first(where: { $0.id == activeVersionID }) ?? versions[0] }
    public init(source: URL, fingerprint: String, version: EditVersion) {
        sourcePath = source.standardizedFileURL.path; contentFingerprint = fingerprint
        bookmark = try? source.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        versions = [version]; activeVersionID = version.id
    }
    public mutating func updateDocument(_ document: EditDocument) {
        guard let i = versions.firstIndex(where: { $0.id == activeVersionID }) else { return }
        versions[i].document = document; versions[i].revision = UUID()
    }
    @discardableResult public mutating func duplicateVersion(named name: String) -> UUID {
        var next = active; next.id = UUID(); next.name = name; next.created = Date(); next.revision = UUID()
        versions.append(next); activeVersionID = next.id; return next.id
    }
    public mutating func upgrade() {
        guard active.renderer == .legacy else { return }
        duplicateVersion(named: "Modern · " + active.name)
        versions[versions.count-1].renderer = .linear2020
    }
    public mutating func switchSource(to mode: SourceMode) {
        guard active.sourceMode != mode else { return }
        var version = EditVersion(name: mode == .raw ? "RAW" : "Camera Look", renderer: .linear2020, sourceMode: mode,
                                  document: EditDocument(fingerprint: active.document.fingerprint))
        if mode == .raw {
            var lens = LensLibrary.shared.suggested(for:URL(fileURLWithPath:sourcePath))
            if lens.profileID != nil { lens.enabled = true; var edits = PhotoEdits(); edits.lens = lens; version.document.commit(edits,title:"Matched RAW lens corrections") }
        }
        versions.append(version); activeVersionID = version.id
    }
    public var isValid: Bool {
        schemaVersion == 1 && (0...5).contains(rating) && !versions.isEmpty && versions.contains(where: { $0.id == activeVersionID }) &&
        Set(versions.map(\.id)).count == versions.count && versions.allSatisfy { !$0.document.steps.isEmpty && $0.document.steps.indices.contains($0.document.cursor) }
    }
}
public enum PhotoFlag: String, Codable, CaseIterable { case none, pick, reject }
public enum WorkflowError: LocalizedError {
    case invalidDocument, changedSource, unavailableVersion, invalidPackage
    public var errorDescription: String? {
        switch self {
        case .invalidDocument: return "The saved edit document is damaged or from a newer OpenStill version. Your originals are unchanged."
        case .changedSource: return "The photo file has changed. Open it again before saving edits."
        case .unavailableVersion: return "That edit version is unavailable."
        case .invalidPackage: return "This edit package is incomplete or its checksums do not match."
        }
    }
}

/// Local records use content identity, never just a filename. Every write is atomic;
/// the previous ten valid documents remain available independently of named versions.
public final class PhotoRecordStore {
    public let root: URL
    private let lock = NSRecursiveLock()
    /// The SQLite index next to the records. Nil only if the file can't be opened; lookups then fall back to scanning.
    public let catalog: LibraryCatalog?
    /// Whether saving a changed rating, flag, label or metadata also writes the photo's `.xmp` sidecar.
    public var writesSidecars: () -> Bool = { XMPSidecar.autoWrite }
    public init(root: URL) { self.root = root; catalog = try? LibraryCatalog(url: root.appendingPathComponent("Catalog.sqlite")) }
    /// Indexes records saved before the catalog existed, once.
    private func migrateIfNeeded(_ catalog: LibraryCatalog) {
        guard catalog.value("indexedRecords") == nil else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: records, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), let record = try? read(id) else { continue }
            let source = URL(fileURLWithPath: record.sourcePath)
            let facts = FileManager.default.fileExists(atPath: source.path) ? CatalogPhoto.read(source, id: id) : CatalogPhoto(id: id, path: record.sourcePath)
            try? catalog.upsert(record, facts: facts)
        }
        try? catalog.setValue("1", for: "indexedRecords")
    }
    private var records: URL { root.appendingPathComponent("PhotoRecords", isDirectory: true) }
    private func url(_ id: UUID) -> URL { records.appendingPathComponent(id.uuidString + ".json") }
    public static func contentHash(_ source: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: source); defer { try? file.close() }
        var hash = SHA256()
        while let block = try file.read(upToCount: 1024*1024), !block.isEmpty { hash.update(data: block) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func decode(_ file: URL) throws -> PhotoRecord {
        let record = try JSONDecoder().decode(PhotoRecord.self, from: Data(contentsOf: file))
        guard record.isValid else { throw WorkflowError.invalidDocument }
        return record
    }
    public func read(_ id: UUID) throws -> PhotoRecord {
        lock.lock(); defer { lock.unlock() }
        if let record = try? decode(url(id)) { return record }
        for i in 0..<10 {
            if let record = try? decode(snapshot(id, i)), record.id == id { return record }
        }
        throw WorkflowError.invalidDocument
    }
    private func snapshot(_ id: UUID, _ index: Int) -> URL {
        root.appendingPathComponent("Recovery/\(id.uuidString)/\(index).json")
    }
    /// Read-modify-write under one lock so culling cannot overwrite newer edits.
    @discardableResult public func update(_ id:UUID,_ mutation:(inout PhotoRecord)throws->Void)throws->PhotoRecord {
        lock.lock();defer{lock.unlock()}
        var record=try read(id);try mutation(&record);try save(record);return record
    }
    public func save(_ record: PhotoRecord) throws {
        lock.lock(); defer { lock.unlock() }
        guard record.isValid else { throw WorkflowError.invalidDocument }
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let destination = url(record.id)
        let previous = try? decode(destination)
        if let previous {
            let directory = snapshot(record.id, 0).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for i in stride(from: 8, through: 0, by: -1) {
                if let bytes = try? Data(contentsOf: snapshot(record.id, i)) { try bytes.write(to: snapshot(record.id, i+1), options: .atomic) }
            }
            try JSONEncoder().encode(previous).write(to: snapshot(record.id, 0), options: .atomic)
        }
        try JSONEncoder().encode(record).write(to: destination, options: .atomic)
        try? catalog?.updateRecord(record)
        let fields = XMPMetadata(record: record)
        if writesSidecars(), previous.map({ XMPMetadata(record: $0) != fields }) ?? fields.isSet {
            try? XMPSidecar.write(record, for: URL(fileURLWithPath: record.sourcePath))
        }
    }
    public func record(for source: URL, legacy: EditDocument? = nil) throws -> PhotoRecord {
        lock.lock(); defer { lock.unlock() }
        let path = source.standardizedFileURL.path
        // Fast path: the catalog knows this exact file (same path, size and modification time), so no hashing.
        // A fresh URL: Foundation caches resource values per URL object, which would hide a replaced file.
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if let catalog, let size = values?.fileSize, let modified = values?.contentModificationDate?.timeIntervalSince1970,
           let id = catalog.recordID(path: path, size: Int64(size), modified: modified), let record = try? read(id), record.sourcePath == path { return record }
        let fingerprint = try Self.contentHash(source)
        // Candidates share the content hash. The catalog answers directly; without one, every record is read.
        let candidates: [UUID]
        if let catalog { migrateIfNeeded(catalog); candidates = catalog.recordIDs(fingerprint: fingerprint) }
        else {
            candidates = ((try? FileManager.default.contentsOfDirectory(at: records, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
        }
        func indexed(_ record: PhotoRecord) -> PhotoRecord { try? catalog?.upsert(record, facts: CatalogPhoto.read(source, id: record.id)); return record }
        var matches: [PhotoRecord] = []
        for id in candidates {
            guard var record = try? read(id), record.contentFingerprint == fingerprint else { continue }
            if record.sourcePath == path { return indexed(record) }
            var stale = false
            let resolved = record.bookmark.flatMap { try? URL(resolvingBookmarkData: $0, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) }
            if resolved?.standardizedFileURL.path == path || !FileManager.default.fileExists(atPath: record.sourcePath) {
                record.sourcePath = path
                record.bookmark = try? source.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                matches.append(record)
            }
        }
        // Ambiguous identical copies are not silently merged.
        if matches.count == 1 { try save(matches[0]); return indexed(matches[0]) }
        let mode = RawDecoder.defaultMode(for: source)
        var initial = EditVersion(name: legacy == nil ? "Original" : "Legacy", renderer: legacy == nil ? .linear2020 : .legacy,
                                  sourceMode: legacy == nil ? mode : (source.pathExtension.lowercased() == "rw2" ? .cameraLook : .original),
                                  document: legacy ?? EditDocument(fingerprint: EditStorage.fingerprint(source)))
        if legacy == nil && mode == .raw {
            var lens = LensLibrary.shared.suggested(for:source)
            if lens.profileID != nil { lens.enabled = true; var edits = PhotoEdits(); edits.lens = lens; initial.document.commit(edits,title:"Matched RAW lens corrections") }
        }
        var record = PhotoRecord(source: source, fingerprint: fingerprint, version: initial)
        // Ratings, labels and metadata from Lightroom, Bridge or the camera (sidecar first, then embedded XMP).
        if let xmp = XMPSidecar.read(source), xmp.hasLibraryMetadata { xmp.apply(to: &record) }
        try save(record); return indexed(record)
    }
}
