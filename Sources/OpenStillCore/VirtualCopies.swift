import Foundation
import SQLite3

// MARK: - Virtual copies

/// Lightroom's virtual copies: another entry for the same file, with its own edits, rating, flag, label and metadata.
/// A copy is its own photo record (marked with the original's ID). In photo lists it's the file's URL with
/// "#copy-<id>" after it, so it sits beside the original as its own thumbnail while every file operation reads the same file.
public enum VirtualCopy {
    static let prefix = "copy-"
    /// The URL a copy is listed under.
    public static func url(path: String, copy id: UUID) -> URL {
        var parts = URLComponents(url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)!
        parts.fragment = prefix + id.uuidString
        return parts.url!
    }
    /// The copy a listed URL stands for, if it's a virtual copy.
    public static func id(in url: URL) -> UUID? {
        guard let fragment = url.fragment, fragment.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(fragment.dropFirst(prefix.count)))
    }
    public static func isCopy(_ url: URL) -> Bool { id(in: url) != nil }
    /// The original file's URL for a listed photo (the URL itself for an original).
    public static func file(_ url: URL) -> URL { isCopy(url) ? URL(fileURLWithPath: url.path) : url }

    /// Makes a virtual copy of a photo: its current edit becomes the copy's starting point; rating, flag and label start
    /// empty (as in Lightroom); metadata is copied. Returns the copy's record.
    @discardableResult public static func create(of original: PhotoRecord, store: PhotoRecordStore = EditStorage.records) throws -> PhotoRecord {
        let master = original.masterID.flatMap { try? store.read($0) } ?? original
        var version = original.active
        version.id = UUID(); version.name = "Original"; version.created = Date(); version.revision = UUID()
        var copy = PhotoRecord(source: URL(fileURLWithPath: master.sourcePath), fingerprint: master.contentFingerprint, version: version)
        copy.bookmark = master.bookmark
        copy.metadata = original.metadata; copy.location = original.location
        copy.masterID = master.id
        let siblings = store.catalog?.virtualCopies(of: master.id).count ?? 0
        copy.copyName = "Copy \(siblings + 1)"
        try store.save(copy)
        if let catalog = store.catalog {
            var facts = catalog.photo(master.id) ?? CatalogPhoto(id: copy.id, path: master.sourcePath)
            facts.id = copy.id; facts.keywords = []
            try catalog.upsert(copy, facts: facts)
            try catalog.markCopy(copy.id, of: master.id)
            // Copies stack under their original, as in Lightroom.
            let existing = catalog.stacks().values.first { $0.contains(master.id) } ?? [master.id]
            try catalog.createStack(existing + [copy.id])
        }
        return copy
    }
    /// Removes a virtual copy from the library. The file and the original are untouched.
    public static func remove(_ id: UUID, store: PhotoRecordStore = EditStorage.records) throws {
        guard let record = try? store.read(id), record.masterID != nil else { return }
        try store.catalog?.remove(id)
        try store.deleteRecord(id)
    }
    /// The URLs of every virtual copy of these photos, each placed right after its original.
    public static func expand(_ urls: [URL], catalog: LibraryCatalog? = EditStorage.records.catalog) -> [URL] {
        guard let catalog else { return urls }
        let copies = catalog.virtualCopies(forPaths: urls.filter { !isCopy($0) }.map(\.path))
        guard !copies.isEmpty else { return urls }
        var out: [URL] = []
        for url in urls {
            out.append(url)
            if !isCopy(url) { out += (copies[url.path] ?? []).map { self.url(path: url.path, copy: $0) } }
        }
        return out
    }
}

extension PhotoRecord {
    public var isVirtualCopy: Bool { masterID != nil }
    /// The URL this photo is listed under: the file, or the file with "#copy-<id>" for a virtual copy.
    public var listURL: URL { masterID == nil ? URL(fileURLWithPath: sourcePath) : VirtualCopy.url(path: sourcePath, copy: id) }
}

extension CatalogPhoto {
    /// The URL this row is listed under (virtual copies carry their ID).
    public var listURL: URL { masterID == nil ? URL(fileURLWithPath: path) : VirtualCopy.url(path: path, copy: id) }
}

extension LibraryCatalog {
    func prepareCopiesAndSets() throws {
        var photoColumns = Set<String>(), collectionColumns = Set<String>()
        _ = try? run("PRAGMA table_info(photos)") { photoColumns.insert(Self.text($0, 1)) }
        _ = try? run("PRAGMA table_info(collections)") { collectionColumns.insert(Self.text($0, 1)) }
        if !photoColumns.contains("master_id") { try execute("ALTER TABLE photos ADD COLUMN master_id TEXT") }
        if !collectionColumns.contains("parent") { try execute("ALTER TABLE collections ADD COLUMN parent TEXT") }
        if !collectionColumns.contains("is_set") { try execute("ALTER TABLE collections ADD COLUMN is_set INTEGER DEFAULT 0") }
        try execute("CREATE INDEX IF NOT EXISTS photos_master ON photos(master_id)")
    }
    func markCopy(_ id: UUID, of master: UUID) throws {
        try run("UPDATE photos SET master_id = ? WHERE id = ?", [.text(master.uuidString), .text(id.uuidString)])
    }
    /// A photo's virtual copies, oldest first.
    public func virtualCopies(of master: UUID) -> [UUID] {
        var out: [UUID] = []
        _ = try? run("SELECT id FROM photos WHERE master_id = ? ORDER BY rowid", [.text(master.uuidString)]) { if let id = UUID(uuidString: Self.text($0, 0)) { out.append(id) } }
        return out
    }
    /// Virtual copies of the files at these paths, by path.
    public func virtualCopies(forPaths paths: [String]) -> [String: [UUID]] {
        var out: [String: [UUID]] = [:]
        let wanted = Set(paths)
        _ = try? run("SELECT path, id FROM photos WHERE master_id IS NOT NULL ORDER BY rowid") { s in
            let path = Self.text(s, 0)
            if wanted.contains(path), let id = UUID(uuidString: Self.text(s, 1)) { out[path, default: []].append(id) }
        }
        return out
    }
    /// After an original moves or is relinked, its copies follow.
    public func moveCopies(of master: UUID, to path: String) throws {
        try run("UPDATE photos SET path = ? WHERE master_id = ?", [.text(path), .text(master.uuidString)])
    }

    // MARK: Collection sets

    /// Collection sets hold collections (and other sets), like folders. Collections at the top level have no parent.
    @discardableResult public func createCollectionSet(name: String, parent: UUID? = nil) throws -> PhotoCollection {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let set = PhotoCollection(id: UUID(), name: clean.isEmpty ? "Untitled set" : String(clean.prefix(200)), smart: nil)
        try run("INSERT INTO collections(id, name, rules, created, parent, is_set) VALUES(?, ?, NULL, ?, ?, 1)",
                [.text(set.id.uuidString), .text(set.name), .real(Date().timeIntervalSince1970), parent.map { .text($0.uuidString) } ?? .null])
        return set
    }
    /// The collection sets, by name.
    public func collectionSets() -> [PhotoCollection] {
        var out: [PhotoCollection] = []
        _ = try? run("SELECT id, name FROM collections WHERE is_set = 1 ORDER BY name COLLATE NOCASE") { s in
            if let id = UUID(uuidString: Self.text(s, 0)) { out.append(PhotoCollection(id: id, name: Self.text(s, 1), smart: nil)) }
        }
        return out
    }
    /// Each collection's set (nil at the top level).
    public func collectionParents() -> [UUID: UUID] {
        var out: [UUID: UUID] = [:]
        _ = try? run("SELECT id, parent FROM collections WHERE parent IS NOT NULL") { s in
            if let id = UUID(uuidString: Self.text(s, 0)), let parent = UUID(uuidString: Self.text(s, 1)) { out[id] = parent }
        }
        return out
    }
    /// Moves a collection or set into a set (nil: to the top level). A set can't go inside itself or its own sets.
    public func move(collection id: UUID, into parent: UUID?) throws {
        if let parent {
            guard collectionSets().contains(where: { $0.id == parent }) else { return }
            let parents = collectionParents()
            var cursor: UUID? = parent
            while let c = cursor { if c == id { return }; cursor = parents[c] }
        }
        try run("UPDATE collections SET parent = ? WHERE id = ?", [parent.map { .text($0.uuidString) } ?? .null, .text(id.uuidString)])
    }
    /// Deleting a set moves what's inside it up a level.
    public func deleteCollectionSet(_ id: UUID) throws {
        let parent = collectionParents()[id]
        try transaction {
            try run("UPDATE collections SET parent = ? WHERE parent = ?", [parent.map { .text($0.uuidString) } ?? .null, .text(id.uuidString)])
            try run("DELETE FROM collections WHERE id = ? AND is_set = 1", [.text(id.uuidString)])
        }
    }

    // MARK: Synchronize Folder

    /// Photos the catalog has in this folder (and below) whose files are gone, while the folder itself is there:
    /// deleted or moved outside OpenStill. Virtual copies of them are included.
    public func photosMissing(under folder: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [CatalogPhoto] {
        guard exists(folder) else { return [] }
        let paths = Set(photoPaths(under: folder).filter { !exists($0) })
        guard !paths.isEmpty else { return [] }
        var ids = Set<UUID>()
        _ = try? run("SELECT id, path FROM photos") { s in if paths.contains(Self.text(s, 1)), let id = UUID(uuidString: Self.text(s, 0)) { ids.insert(id) } }
        return photos(ids: ids)
    }
}

/// Photos taken out of the library by Synchronize Folder. Their records stay on disk and are listed here,
/// so edits can come back if the file does.
public enum RemovedPhotos {
    public struct Entry: Codable, Equatable { public var id: UUID; public var path: String; public var removed: Date }
    static func file(_ root: URL) -> URL { root.appendingPathComponent("RemovedPhotos.json") }
    public static func load(root: URL = EditStorage.root) -> [Entry] { (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: file(root)))) ?? [] }
    static func forget(_ id: UUID, root: URL) {
        let log = load(root: root).filter { $0.id != id }
        try? JSONEncoder().encode(log).write(to: file(root), options: .atomic)
    }
    /// Removes these photos from the catalog (not their records or files) and notes them.
    public static func remove(_ photos: [CatalogPhoto], store: PhotoRecordStore = EditStorage.records) throws {
        let root = store.root
        guard let catalog = store.catalog, !photos.isEmpty else { return }
        var log = load(root: root)
        for p in photos {
            try catalog.remove(p.id)
            log.append(Entry(id: p.id, path: p.path, removed: Date()))
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(log.suffix(5000))).write(to: file(root), options: .atomic)
    }
}

extension PhotoRecordStore {
    /// Deletes a record and its recovery copies (virtual copies only; originals' records are kept).
    func deleteRecord(_ id: UUID) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("PhotoRecords/\(id.uuidString).json"))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("Recovery/\(id.uuidString)"))
    }
}
