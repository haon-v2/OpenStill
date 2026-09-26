import Foundation
import SQLite3

/// Reads a Lightroom Classic catalog (`.lrcat`) without changing it: folders, ratings, labels, picks, keywords,
/// collections and develop settings. The catalog is opened read-only, so Lightroom's own copy is never touched.
public final class LightroomCatalog {
    public struct Photo: Equatable {
        public var id: Int64
        public var path: String
        public var rating = 0
        public var flag: PhotoFlag = .none
        public var label: ColorLabel = .none
        public var keywords: [String] = []
        /// The XMP Lightroom keeps for the photo, with Camera Raw develop settings and IPTC fields.
        public var xmp: String?
    }
    public struct Collection: Equatable {
        public var name: String
        public var photoIDs: [Int64]
    }
    public let url: URL
    public private(set) var photos: [Photo] = []
    public private(set) var collections: [Collection] = []
    /// Parts of the catalog that couldn't be read (e.g. a table missing from an older Lightroom version).
    public private(set) var notes: [String] = []
    /// Smart collections and virtual copies aren't imported; how many were skipped.
    public private(set) var skippedSmartCollections = 0, skippedVirtualCopies = 0

    public init(url: URL) throws {
        self.url = url
        var handle: OpaquePointer?
        // immutable=1: never write, never take locks, so a catalog that Lightroom has open still reads.
        let uri = url.standardizedFileURL.absoluteString + "?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle); throw LightroomImportError.unreadable
        }
        defer { sqlite3_close(db) }
        guard Self.columns(db, "Adobe_images").contains("rootFile") else { throw LightroomImportError.notLightroom }
        try load(db)
    }

    private static func columns(_ db: OpaquePointer, _ table: String) -> Set<String> {
        Set(rows(db, "PRAGMA table_info(\(table))").compactMap { string($0["name"]) })
    }
    /// Every row as column → Int64, Double, String or nil.
    private static func rows(_ db: OpaquePointer, _ sql: String) -> [[String: Any?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let s = statement else { return [] }
        defer { sqlite3_finalize(s) }
        var out: [[String: Any?]] = []
        while sqlite3_step(s) == SQLITE_ROW {
            var row: [String: Any?] = [:]
            for i in 0..<sqlite3_column_count(s) {
                let name = String(cString: sqlite3_column_name(s, i))
                switch sqlite3_column_type(s, i) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(s, i)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(s, i)
                case SQLITE_TEXT: row[name] = sqlite3_column_text(s, i).map { String(cString: $0) }
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(s, i))
                    row[name] = sqlite3_column_blob(s, i).map { String(decoding: Data(bytes: $0, count: count), as: UTF8.self) }
                default: row[name] = nil as Any?
                }
            }
            out.append(row)
        }
        return out
    }
    private static func int(_ v: Any??) -> Int64? {
        switch v ?? nil { case let i as Int64: return i; case let d as Double: return Int64(d); case let s as String: return Int64(s); default: return nil }
    }
    private static func double(_ v: Any??) -> Double? {
        switch v ?? nil { case let i as Int64: return Double(i); case let d as Double: return d; case let s as String: return Double(s); default: return nil }
    }
    private static func string(_ v: Any??) -> String? { (v ?? nil) as? String }

    private func load(_ db: OpaquePointer) throws {
        let imageColumns = Self.columns(db, "Adobe_images")
        // Older catalogs may lack some columns; those read as NULL.
        let column = { (name: String) in imageColumns.contains(name) ? "i.\(name) AS \(name)" : "NULL AS \(name)" }
        let sql = """
        SELECT i.id_local AS id, \(column("rating")), \(column("colorLabels")), \(column("pick")), \(column("masterImage")),
               r.absolutePath AS root, f.pathFromRoot AS folder, l.baseName AS base, l.extension AS ext
        FROM Adobe_images i
        JOIN AgLibraryFile l ON l.id_local = i.rootFile
        JOIN AgLibraryFolder f ON f.id_local = l.folder
        JOIN AgLibraryRootFolder r ON r.id_local = f.rootFolder
        """
        var byID: [Int64: Int] = [:]
        for row in Self.rows(db, sql) {
            guard let id = Self.int(row["id"]) else { continue }
            if Self.int(row["masterImage"]) != nil { skippedVirtualCopies += 1; continue }
            let root = Self.string(row["root"]) ?? "", folder = Self.string(row["folder"]) ?? ""
            let base = Self.string(row["base"]) ?? "", ext = Self.string(row["ext"]) ?? ""
            guard !base.isEmpty else { continue }
            var photo = Photo(id: id, path: root + folder + base + (ext.isEmpty ? "" : "." + ext))
            photo.rating = Int(min(5, max(0, Self.double(row["rating"]) ?? 0)))
            let pick = Self.double(row["pick"]) ?? 0
            photo.flag = pick > 0 ? .pick : pick < 0 ? .reject : .none
            if let label = Self.string(row["colorLabels"])?.trimmingCharacters(in: .whitespaces), !label.isEmpty {
                photo.label = ColorLabel.allCases.first { $0 != .none && $0.rawValue.caseInsensitiveCompare(label) == .orderedSame } ?? ColorLabel.none
                if photo.label == .none { notes.append("Custom label “\(label)” isn’t one of OpenStill’s five colors") }
            }
            byID[id] = photos.count; photos.append(photo)
        }
        if photos.isEmpty && skippedVirtualCopies == 0 && !Self.rows(db, "SELECT 1 FROM Adobe_images LIMIT 1").isEmpty {
            notes.append("Photos were found, but their file locations couldn’t be read")
        }

        // Keywords: a tree of AgLibraryKeyword rows; the root has no name.
        if Self.columns(db, "AgLibraryKeyword").isSuperset(of: ["id_local", "name", "parent"]) {
            var tree: [Int64: (name: String?, parent: Int64?)] = [:]
            for row in Self.rows(db, "SELECT id_local, name, parent FROM AgLibraryKeyword") {
                if let id = Self.int(row["id_local"]) { tree[id] = (Self.string(row["name"]), Self.int(row["parent"])) }
            }
            func path(_ id: Int64) -> String? {
                var parts: [String] = [], current: Int64? = id, guardCount = 0
                while let c = current, let node = tree[c], guardCount < 64 {
                    if let name = node.name, !name.isEmpty { parts.insert(name, at: 0) }
                    current = node.parent; guardCount += 1
                }
                return parts.isEmpty ? nil : parts.joined(separator: " > ")
            }
            for row in Self.rows(db, "SELECT image, tag FROM AgLibraryKeywordImage") {
                guard let image = Self.int(row["image"]), let tag = Self.int(row["tag"]), let index = byID[image], let keyword = path(tag) else { continue }
                if !photos[index].keywords.contains(keyword) { photos[index].keywords.append(keyword) }
            }
        } else { notes.append("Keywords couldn’t be read") }

        // Develop settings and IPTC fields, as XMP.
        if Self.columns(db, "Adobe_AdditionalMetadata").isSuperset(of: ["image", "xmp"]) {
            for row in Self.rows(db, "SELECT image, xmp FROM Adobe_AdditionalMetadata") {
                guard let image = Self.int(row["image"]), let index = byID[image], let xmp = Self.string(row["xmp"]), !xmp.isEmpty else { continue }
                photos[index].xmp = xmp
            }
        } else { notes.append("Develop settings couldn’t be read") }

        // Collections. Smart collections are rules Lightroom evaluates, so they're skipped; groups (sets) hold no photos.
        if Self.columns(db, "AgLibraryCollection").isSuperset(of: ["id_local", "name", "creationId"]) {
            var members: [Int64: [Int64]] = [:]
            for row in Self.rows(db, "SELECT collection, image FROM AgLibraryCollectionImage") {
                if let c = Self.int(row["collection"]), let image = Self.int(row["image"]), byID[image] != nil { members[c, default: []].append(image) }
            }
            for row in Self.rows(db, "SELECT id_local, name, creationId FROM AgLibraryCollection ORDER BY name") {
                guard let id = Self.int(row["id_local"]), let name = Self.string(row["name"]), !name.isEmpty else { continue }
                switch Self.string(row["creationId"]) ?? "" {
                case "com.adobe.ag.library.smart_collection": skippedSmartCollections += 1
                case "com.adobe.ag.library.group", "com.adobe.ag.library.collection_set": continue
                default: if let ids = members[id], !ids.isEmpty { collections.append(Collection(name: name, photoIDs: ids)) }
                }
            }
        }
    }

    /// The top-level folders photos live in, so moved drives can be relinked.
    public var roots: [String] {
        var out: [String] = []
        for photo in photos {
            let parts = photo.path.split(separator: "/", omittingEmptySubsequences: true)
            // /Volumes/Drive/… → /Volumes/Drive/, /Users/name/… → /Users/name/
            let root = "/" + parts.prefix(2).joined(separator: "/") + "/"
            if !out.contains(root) { out.append(root) }
        }
        return out
    }
    /// Photos whose files can't be found (to be relinked).
    public var missing: [Photo] { photos.filter { !FileManager.default.fileExists(atPath: $0.path) } }
}

public enum LightroomImportError: LocalizedError {
    case unreadable, notLightroom
    public var errorDescription: String? {
        switch self {
        case .unreadable: return "The catalog couldn’t be opened. Quit Lightroom if it is using the catalog, then try again."
        case .notLightroom: return "This file isn’t a Lightroom Classic catalog."
        }
    }
}

/// Brings a Lightroom catalog into OpenStill's library. Originals and the Lightroom catalog are never changed.
public struct LightroomImport {
    public var ratings = true, keywordsAndMetadata = true, collections = true, developSettings = true
    /// Replaces the start of photo paths, e.g. "/Volumes/Old Drive/" → "/Volumes/New Drive/", for moved photos.
    public var relink: [(from: String, to: String)] = []
    public init() {}

    public struct Report {
        public var imported = 0, missing = 0, developed = 0, collections = 0, failed = 0
        public var unsupported: [String: Int] = [:]
        public var notes: [String] = []
        public var missingPaths: [String] = []
        public var summary: String {
            var lines = ["\(imported) photo\(imported == 1 ? "" : "s") imported."]
            if developed > 0 { lines.append("\(developed) with Lightroom develop settings, as a version named “Lightroom”.") }
            if collections > 0 { lines.append("\(collections) collection\(collections == 1 ? "" : "s") created.") }
            if missing > 0 { lines.append("\(missing) photo\(missing == 1 ? "" : "s") not found at the catalog’s location. Use Relink to point to where they are now.") }
            if failed > 0 { lines.append("\(failed) photo\(failed == 1 ? "" : "s") couldn’t be read.") }
            if !unsupported.isEmpty {
                lines.append("Develop settings not carried over (number of photos):\n" + unsupported.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(25).map { "• \($0.key): \($0.value)" }.joined(separator: "\n"))
            }
            if !notes.isEmpty { lines.append(notes.map { "• " + $0 }.joined(separator: "\n")) }
            return lines.joined(separator: "\n\n")
        }
    }

    public func resolvedPath(_ path: String) -> String {
        for (from, to) in relink where !from.isEmpty && path.hasPrefix(from) { return to + path.dropFirst(from.count) }
        return path
    }

    public func run(_ catalog: LightroomCatalog, store: PhotoRecordStore = EditStorage.records, progress: ((Int, Int) -> Bool)? = nil) -> Report {
        var report = Report()
        report.notes = Array(Set(catalog.notes)).sorted()
        if catalog.skippedSmartCollections > 0 { report.notes.append("\(catalog.skippedSmartCollections) smart collection\(catalog.skippedSmartCollections == 1 ? " was" : "s were") skipped; make them again with New smart collection.") }
        if catalog.skippedVirtualCopies > 0 { report.notes.append("\(catalog.skippedVirtualCopies) virtual cop\(catalog.skippedVirtualCopies == 1 ? "y was" : "ies were") skipped.") }
        var recordIDs: [Int64: UUID] = [:]
        for (n, photo) in catalog.photos.enumerated() {
            if let progress, !progress(n, catalog.photos.count) { report.notes.append("Stopped after \(n) photos."); break }
            let path = resolvedPath(photo.path)
            guard FileManager.default.fileExists(atPath: path) else { report.missing += 1; if report.missingPaths.count < 200 { report.missingPaths.append(path) }; continue }
            do {
                let url = URL(fileURLWithPath: path)
                let base = try store.record(for: url)
                let xmp = photo.xmp.flatMap { XMPSidecar.parse(Data($0.utf8)) }
                var developed: CameraRawImport?
                let record = try store.update(base.id) { record in
                    if ratings { record.rating = photo.rating; record.flag = photo.flag; record.colorLabel = photo.label }
                    if keywordsAndMetadata {
                        var metadata = xmp?.iptc ?? IPTCMetadata()
                        metadata.keywords = photo.keywords + metadata.keywords
                        record.iptc = record.iptc.applying(metadata.sanitized)
                    }
                    if developSettings, let xmp, xmp.hasDevelopSettings, !record.versions.contains(where: { $0.name == "Lightroom" }) {
                        developed = record.importCameraRaw(xmp, name: "Lightroom")
                    }
                }
                recordIDs[photo.id] = record.id
                report.imported += 1
                if let developed {
                    report.developed += 1
                    for item in developed.unsupported {
                        let key = item.components(separatedBy: " (").first ?? item
                        report.unsupported[key, default: 0] += 1
                    }
                }
            } catch { report.failed += 1 }
        }
        if collections, let catalogStore = store.catalog {
            let existing = catalogStore.collections()
            for collection in catalog.collections {
                let ids = collection.photoIDs.compactMap { recordIDs[$0] }
                guard !ids.isEmpty else { continue }
                do {
                    let target = try existing.first(where: { $0.name == collection.name && $0.smart == nil }) ?? catalogStore.createCollection(name: collection.name)
                    try catalogStore.add(ids, to: target.id)
                    report.collections += 1
                } catch { report.notes.append("Collection “\(collection.name)” couldn’t be created.") }
            }
        }
        return report
    }
}
