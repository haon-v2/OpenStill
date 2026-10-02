import Foundation
import CoreGraphics
import ImageIO
import SQLite3

// MARK: - Where each photo lives

/// A mounted drive: its identity (stable across mount points and renames) and where it's mounted now.
public struct MountedVolume: Equatable, Sendable {
    /// The file system's UUID, when it has one. Reformatting a card gives it a new one.
    public var uuid: String?
    public var name: String
    /// The mount point: "/" for the startup disk, "/Volumes/Name" for others.
    public var root: String
    public init(uuid: String?, name: String, root: String) { self.uuid = uuid; self.name = name; self.root = root }

    /// The drive a file or folder is on, from the nearest part of the path that exists. Nil when none of it exists.
    public static func of(_ path: String) -> MountedVolume? {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        guard let v = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey, .volumeNameKey]), var root = v.volume?.standardizedFileURL.path else { return nil }
        // Firmlinked folders (/Users, /private/var…) report the hidden Data volume; their paths are on the startup disk.
        if root != "/", !path.hasPrefix(root + "/"), !path.hasPrefix("/Volumes/") { root = "/" }
        return MountedVolume(uuid: v.volumeUUIDString, name: v.volumeName ?? (root as NSString).lastPathComponent, root: root)
    }
    /// Every mounted drive, startup disk included.
    public static func all() -> [MountedVolume] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey, .volumeNameKey], options: [.skipHiddenVolumes]) ?? [])
            .compactMap { url in
                let v = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey])
                let root = url.standardizedFileURL.path
                return MountedVolume(uuid: v?.volumeUUIDString, name: v?.volumeName ?? (root as NSString).lastPathComponent, root: root)
            }
    }
    /// A path's place inside this drive ("DCIM/100CANON/IMG_0001.CR3"), or nil when it isn't on it.
    public func relative(_ path: String) -> String? {
        if root == "/" { return path.hasPrefix("/Volumes/") ? nil : String(path.dropFirst()) }
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
    }
    public func absolute(_ relative: String) -> String { root == "/" ? "/" + relative : root + "/" + relative }
}

/// Where the catalog last saw a photo, by drive identity rather than mount path, so a drive mounted under another name
/// ("/Volumes/Untitled 1") or a renamed drive still finds its photos.
public struct PhotoLocation: Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var size: Int64
    public var volumeUUID: String?
    public var volumeName: String?
    /// The path inside its drive.
    public var relative: String?
}

/// Volume lookups repeat for every photo of an import, so they're remembered per drive until a drive mounts or unmounts.
enum VolumeLookup {
    private static let lock = NSLock()
    private static var known: [MountedVolume] = []
    static func volume(for path: String) -> MountedVolume? {
        lock.lock()
        let hit = known.filter { $0.relative(path) != nil }.max { $0.root.count < $1.root.count }
        lock.unlock()
        // The startup disk matches everything outside /Volumes; a drive mounted since is looked up properly.
        if let hit, hit.root != "/" || !path.hasPrefix("/Volumes/") { return hit }
        guard let found = MountedVolume.of(path) else { return nil }
        lock.lock(); known.removeAll { $0.root == found.root }; known.append(found); lock.unlock()
        return found
    }
    static func reset() { lock.lock(); known = []; lock.unlock() }
}

extension LibraryCatalog {
    func prepareLocations() throws {
        var columns = Set<String>()
        _ = try? run("PRAGMA table_info(photos)") { columns.insert(Self.text($0, 1)) }
        for column in ["volume_uuid", "volume_name", "relative"] where !columns.contains(column) {
            try execute("ALTER TABLE photos ADD COLUMN \(column) TEXT")
        }
        try execute("""
        CREATE TABLE IF NOT EXISTS recent (photo_id TEXT PRIMARY KEY REFERENCES photos(id) ON DELETE CASCADE, used REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS recent_used ON recent(used);
        """)
    }
    /// Records which drive a photo is on, and its path inside it. Unknown drives (nothing of the path exists) are left as they were.
    func recordLocation(_ id: UUID, path: String, volume: MountedVolume? = nil) throws {
        guard let volume = volume ?? VolumeLookup.volume(for: path), let relative = volume.relative(path) else { return }
        try run("UPDATE photos SET volume_uuid = ?, volume_name = ?, relative = ? WHERE id = ?",
                [volume.uuid.map { .text($0) } ?? .null, .text(volume.name), .text(relative), .text(id.uuidString)])
    }
    /// Fills in the drive for photos indexed before drives were recorded, on drives that are connected now.
    public func recordMissingLocations() {
        var rows: [(UUID, String)] = []
        _ = try? run("SELECT id, path FROM photos WHERE relative IS NULL") { s in if let id = UUID(uuidString: Self.text(s, 0)) { rows.append((id, Self.text(s, 1))) } }
        guard !rows.isEmpty else { return }
        try? transaction { for (id, path) in rows where FileManager.default.fileExists(atPath: path) { try recordLocation(id, path: path) } }
    }
    public func locations(ids: Set<UUID>? = nil) -> [PhotoLocation] {
        var out: [PhotoLocation] = []
        _ = try? run("SELECT id, path, size, volume_uuid, volume_name, relative FROM photos WHERE master_id IS NULL") { s in
            guard let id = UUID(uuidString: Self.text(s, 0)), ids?.contains(id) ?? true else { return }
            func optional(_ i: Int32) -> String? { sqlite3_column_type(s, i) == SQLITE_NULL ? nil : Self.text(s, i) }
            var location = PhotoLocation(id: id, path: Self.text(s, 1), size: sqlite3_column_int64(s, 2), volumeUUID: optional(3), volumeName: optional(4), relative: optional(5))
            // Photos indexed before drives were recorded: an external drive's name and place come from the path.
            if location.relative == nil {
                let parts = location.path.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true)
                if parts.count == 3, parts[0] == "Volumes" { location.volumeName = String(parts[1]); location.relative = String(parts[2]) }
            }
            out.append(location)
        }
        return out
    }
    /// Photos in a folder (and its subfolders), by the catalog's paths: works while the folder's drive isn't connected.
    public func photoPaths(under folder: String) -> [String] {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        var out: [String] = []
        // Paths are compared with substr rather than LIKE so "_" and "%" in folder names aren't wildcards.
        _ = try? run("SELECT path FROM photos WHERE master_id IS NULL AND substr(path, 1, ?) = ?", [.int(Int64(prefix.count)), .text(prefix)]) { out.append(Self.text($0, 0)) }
        return out
    }

    // MARK: Recent photos
    /// Marks a photo as just worked on, for the Catalog's "Recent" list and the library cache.
    public func touchRecent(_ id: UUID, at date: Date = Date()) {
        _ = try? run("INSERT INTO recent(photo_id, used) SELECT ?, ? WHERE EXISTS (SELECT 1 FROM photos WHERE id = ?) ON CONFLICT(photo_id) DO UPDATE SET used = excluded.used",
                     [.text(id.uuidString), .real(date.timeIntervalSince1970), .text(id.uuidString)])
    }
    /// Recently worked-on photos, newest first.
    public func recent(limit: Int = 500) -> [UUID] {
        var out: [UUID] = []
        _ = try? run("SELECT photo_id FROM recent ORDER BY used DESC LIMIT ?", [.int(Int64(limit))]) { if let id = UUID(uuidString: Self.text($0, 0)) { out.append(id) } }
        return out
    }
}

// MARK: - Relinking when a drive or card comes back

/// What to do with the photos of a drive that was just connected.
public struct RelinkPlan: Equatable, Sendable {
    public struct Move: Equatable, Sendable {
        public var id: UUID; public var from: String; public var to: String
        public init(id: UUID, from: String, to: String) { self.id = id; self.from = from; self.to = to }
    }
    /// The same drive (same identity, or same name with the same files): relinked without asking.
    public var automatic: [Move] = []
    /// Another drive holding the same files at the same places (a card copied, or reformatted and refilled): asks first.
    public var suggested: [Move] = []
    /// The drive name the suggested photos were on, for the question.
    public var suggestedFrom: String?
    public var isEmpty: Bool { automatic.isEmpty && suggested.isEmpty }
}

public enum LibraryRelocator {
    /// Finds catalog photos that belong on `volume` but whose recorded path is missing.
    /// - A photo recorded on this drive's UUID moves to the same place under the current mount point.
    /// - A photo from a drive with the same name and no UUID match (an SD card's ID can change) moves when its file is
    ///   there with the same size.
    /// - Photos from another drive whose files are all here, same places, same sizes, are suggested (asked first).
    ///   At least three must match, so one stray file of the same name doesn't relink a folder.
    public static func plan(for volume: MountedVolume, locations: [PhotoLocation],
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                            size: (String) -> Int64? = { path in (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value }) -> RelinkPlan {
        var plan = RelinkPlan()
        var others: [String: [RelinkPlan.Move]] = [:]
        for location in locations {
            guard let relative = location.relative, !exists(location.path) else { continue }
            let target = volume.absolute(relative)
            guard target != location.path, exists(target) else { continue }
            let move = RelinkPlan.Move(id: location.id, from: location.path, to: target)
            let sameSize = location.size <= 0 || size(target) == location.size
            if let uuid = volume.uuid, location.volumeUUID == uuid { plan.automatic.append(move) }
            else if location.volumeName == volume.name, sameSize { plan.automatic.append(move) }
            else if sameSize { others[location.volumeName ?? "another drive", default: []].append(move) }
        }
        // One question at a time: the drive with the most matching photos.
        if let (name, moves) = others.max(by: { $0.value.count < $1.value.count }), moves.count >= 3 {
            plan.suggested = moves; plan.suggestedFrom = name
        }
        return plan
    }

    /// For "Locate…": the same files of a folder found under another folder (same names under it, same sizes).
    public static func plan(from oldFolder: String, to newFolder: String, locations: [PhotoLocation],
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                            size: (String) -> Int64? = { path in (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value }) -> [RelinkPlan.Move] {
        let prefix = oldFolder.hasSuffix("/") ? oldFolder : oldFolder + "/"
        let base = newFolder.hasSuffix("/") ? String(newFolder.dropLast()) : newFolder
        return locations.compactMap { location in
            guard location.path.hasPrefix(prefix), !exists(location.path) else { return nil }
            let target = base + "/" + location.path.dropFirst(prefix.count)
            guard exists(target), location.size <= 0 || size(target) == location.size else { return nil }
            return RelinkPlan.Move(id: location.id, from: location.path, to: target)
        }
    }

    /// Points the photos at their new paths: records, catalog rows and drive identity. Returns how many moved.
    @discardableResult public static func apply(_ moves: [RelinkPlan.Move], store: PhotoRecordStore = EditStorage.records) -> Int {
        guard let catalog = store.catalog, !moves.isEmpty else { return 0 }
        VolumeLookup.reset()
        var moved = 0
        for move in moves {
            guard (try? store.relocate(move.id, to: move.to)) != nil else { continue }
            let values = try? URL(fileURLWithPath: move.to).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            try? catalog.movePhoto(move.id, to: move.to, size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            try? catalog.recordLocation(move.id, path: move.to)
            // Virtual copies follow their original.
            for copy in catalog.virtualCopies(of: move.id) { try? store.relocate(copy, to: move.to) }
            try? catalog.moveCopies(of: move.id, to: move.to)
            moved += 1
        }
        return moved
    }
}

extension PhotoRecordStore {
    /// Points a record at the file's new place. Only the path changes, so no recovery copy is kept (relinking a card
    /// rewrites thousands of records at once).
    public func relocate(_ id: UUID, to path: String) throws {
        var record = try read(id)
        guard record.sourcePath != path else { return }
        record.sourcePath = path
        record.bookmark = try? URL(fileURLWithPath: path).bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        try writeWithoutRecovery(record)
    }
}

// MARK: - Library cache: recently worked-on photos stay visible

/// Like Lightroom's previews: the last look of each photo you worked on, kept at 2560 pixels, so it still shows in the
/// Library and Develop while its card or drive isn't connected. View only: editing a missing photo needs a Smart Preview.
public enum LibraryCache {
    public static let longEdge = 2560
    /// How many recent photos keep a cached look.
    public static var limit: Int {
        get { let v = UserDefaults.standard.integer(forKey: "OpenStillLibraryCacheLimit"); return v > 0 ? v : 1000 }
        set { UserDefaults.standard.set(max(50, newValue), forKey: "OpenStillLibraryCacheLimit") }
    }
    public static func directory(root: URL = EditStorage.root) -> URL { root.appendingPathComponent("LibraryCache", isDirectory: true) }
    static func url(_ id: UUID, root: URL) -> URL { directory(root: root).appendingPathComponent(id.uuidString + ".heic") }
    static func stamp(_ id: UUID, root: URL) -> URL { directory(root: root).appendingPathComponent(id.uuidString + ".revision") }

    /// The revision cached for this photo, to skip re-encoding an unchanged look.
    public static func revision(of id: UUID, root: URL = EditStorage.root) -> String? {
        (try? String(contentsOf: stamp(id, root: root), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Saves a photo's current look. `revision` identifies the edit it shows.
    public static func store(_ image: CGImage, for id: UUID, revision: String, root: URL = EditStorage.root) {
        let folder = directory(root: root)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var image = image
        let longest = max(image.width, image.height)
        if longest > longEdge, let scaled = scale(image, by: Double(longEdge) / Double(longest)) { image = scaled }
        let data = NSMutableData()
        // HEIC keeps a 2560-pixel look to a few hundred KB; JPEG where HEIC encoding isn't available.
        let type = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) == nil ? "public.jpeg" : "public.heic"
        guard let writer = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { return }
        try? (data as Data).write(to: url(id, root: root), options: .atomic)
        try? revision.write(to: stamp(id, root: root), atomically: true, encoding: .utf8)
    }
    public static func image(for id: UUID, maximum: Int? = nil, root: URL = EditStorage.root) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url(id, root: root) as CFURL, nil) else { return nil }
        if let maximum {
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maximum, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    /// When the cached look was saved.
    public static func date(of id: UUID, root: URL = EditStorage.root) -> Date? {
        (try? url(id, root: root).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
    /// Keeps the looks of the `keep` most recent photos and removes the rest.
    public static func prune(keeping recent: [UUID], keep: Int = limit, root: URL = EditStorage.root) {
        let kept = Set(recent.prefix(keep).map(\.uuidString))
        for file in (try? FileManager.default.contentsOfDirectory(atPath: directory(root: root).path)) ?? [] {
            let id = String(file.prefix(36))
            if UUID(uuidString: id) != nil, !kept.contains(id) { try? FileManager.default.removeItem(at: directory(root: root).appendingPathComponent(file)) }
        }
    }
    public static func diskUsage(root: URL = EditStorage.root) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(root: root), includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    public static func clear(root: URL = EditStorage.root) { try? FileManager.default.removeItem(at: directory(root: root)) }
    private static func scale(_ image: CGImage, by factor: Double) -> CGImage? {
        let w = max(1, Int((Double(image.width) * factor).rounded())), h = max(1, Int((Double(image.height) * factor).rounded()))
        guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
