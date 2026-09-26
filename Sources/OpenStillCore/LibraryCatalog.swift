import Foundation
import ImageIO
import SQLite3

// MARK: - Labels and IPTC metadata stored with each photo record

/// Lightroom-style color labels. Keys 6–9 set red, yellow, green and blue.
public enum ColorLabel: String, Codable, CaseIterable, Sendable {
    case none, red, yellow, green, blue, purple
    public var title: String { self == .none ? "No label" : rawValue.capitalized }
    /// The number key that sets this label in the library, if any.
    public var key: Int? { switch self { case .red: return 6; case .yellow: return 7; case .green: return 8; case .blue: return 9; default: return nil } }
    public static func forKey(_ key: Int) -> ColorLabel? { allCases.first { $0.key == key } }
}

/// Descriptive metadata the photographer writes. Kept in the photo record and written to exports as IPTC.
public struct IPTCMetadata: Codable, Equatable, Sendable {
    public var title = "", caption = "", creator = "", copyright = ""
    /// Hierarchical keywords use ">" between levels, e.g. "Places > France > Paris".
    public var keywords: [String] = []
    public var location = "", city = "", state = "", country = ""
    public init() {}
    public var isEmpty: Bool { self == IPTCMetadata() }
    public var sanitized: Self {
        /// Drops control characters; only the caption keeps line breaks.
        func clean(_ s: String, _ limit: Int = 256, lines: Bool = false) -> String {
            let scalars = s.unicodeScalars.map { $0.value == 10 && !lines ? " " : $0 }.filter { $0.value >= 32 || ($0.value == 10 && lines) }
            return String(String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
        }
        var s = self
        s.title = clean(title, 256); s.caption = clean(caption, 2000, lines: true); s.creator = clean(creator, 256); s.copyright = clean(copyright, 512)
        s.location = clean(location, 256); s.city = clean(city, 256); s.state = clean(state, 256); s.country = clean(country, 256)
        var seen = Set<String>()
        s.keywords = keywords.map { Self.normalizeKeyword($0) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.prefix(500).map { $0 }
        return s
    }
    static func normalizeKeyword(_ k: String) -> String {
        k.split(separator: ">").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " > ")
    }
    /// Every level of every keyword ("Places > France" gives "Places" and "Places > France"), for searching and XMP.
    public var keywordPaths: [String] {
        var out: [String] = []
        for k in keywords { let parts = k.components(separatedBy: " > "); for i in 1...max(1, parts.count) { let path = parts.prefix(i).joined(separator: " > "); if !out.contains(path) { out.append(path) } } }
        return out
    }
    /// The leaf names, as IPTC "Keywords" expects.
    public var flatKeywords: [String] {
        var out: [String] = []
        for k in keywords { if let leaf = k.components(separatedBy: " > ").last, !out.contains(leaf) { out.append(leaf) } }
        return out
    }
    /// Applies another set on top: non-empty fields replace, keywords are added.
    public func applying(_ other: IPTCMetadata) -> IPTCMetadata {
        var r = self
        for path in [\IPTCMetadata.title, \.caption, \.creator, \.copyright, \.location, \.city, \.state, \.country] where !other[keyPath: path].isEmpty { r[keyPath: path] = other[keyPath: path] }
        r.keywords += other.keywords
        return r.sanitized
    }
    /// Keywords typed as "a, b; c" or one per line.
    public static func parseKeywords(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",;\n")).map(normalizeKeyword).filter { !$0.isEmpty }
    }
    /// ImageIO properties for an exported file.
    public var imageProperties: [String: Any] {
        let s = sanitized
        var iptc: [String: Any] = [:]
        if !s.title.isEmpty { iptc[kCGImagePropertyIPTCObjectName as String] = s.title; iptc[kCGImagePropertyIPTCHeadline as String] = s.title }
        if !s.caption.isEmpty { iptc[kCGImagePropertyIPTCCaptionAbstract as String] = s.caption }
        if !s.creator.isEmpty { iptc[kCGImagePropertyIPTCByline as String] = [s.creator] }
        if !s.copyright.isEmpty { iptc[kCGImagePropertyIPTCCopyrightNotice as String] = s.copyright }
        if !s.keywords.isEmpty { iptc[kCGImagePropertyIPTCKeywords as String] = s.flatKeywords }
        if !s.location.isEmpty { iptc[kCGImagePropertyIPTCSubLocation as String] = s.location }
        if !s.city.isEmpty { iptc[kCGImagePropertyIPTCCity as String] = s.city }
        if !s.state.isEmpty { iptc[kCGImagePropertyIPTCProvinceState as String] = s.state }
        if !s.country.isEmpty { iptc[kCGImagePropertyIPTCCountryPrimaryLocationName as String] = s.country }
        var tiff: [String: Any] = [:]
        if !s.caption.isEmpty { tiff[kCGImagePropertyTIFFImageDescription as String] = s.caption }
        if !s.creator.isEmpty { tiff[kCGImagePropertyTIFFArtist as String] = s.creator }
        if !s.copyright.isEmpty { tiff[kCGImagePropertyTIFFCopyright as String] = s.copyright }
        var props: [String: Any] = [:]
        if !iptc.isEmpty { props[kCGImagePropertyIPTCDictionary as String] = iptc }
        if !tiff.isEmpty { props[kCGImagePropertyTIFFDictionary as String] = tiff }
        return props
    }
}

/// Saved metadata templates (e.g. creator + copyright) for applying to many photos.
public struct MetadataPreset: Codable, Identifiable, Equatable {
    public var id = UUID(), name: String, metadata: IPTCMetadata
    public init(name: String, metadata: IPTCMetadata) { self.name = name; self.metadata = metadata.sanitized }
}
public enum MetadataPresets {
    static func file(_ root: URL) -> URL { root.appendingPathComponent("MetadataPresets.json") }
    public static func load(root: URL = EditStorage.root) -> [MetadataPreset] { (try? JSONDecoder().decode([MetadataPreset].self, from: Data(contentsOf: file(root)))) ?? [] }
    public static func save(_ presets: [MetadataPreset], root: URL = EditStorage.root) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(presets).write(to: file(root), options: .atomic)
    }
}

extension PhotoRecord {
    public var colorLabel: ColorLabel { get { label ?? .none } set { label = newValue == .none ? nil : newValue } }
    public var iptc: IPTCMetadata { get { metadata ?? IPTCMetadata() } set { let s = newValue.sanitized; metadata = s.isEmpty ? nil : s } }
    /// Whether any version has edits beyond the untouched original.
    public var isEdited: Bool { versions.contains { $0.document.steps.count > 1 || !$0.document.current.isOriginal } }
}

// MARK: - Facts read from the file

/// The searchable, typed facts about one photo, as stored in the catalog.
public struct CatalogPhoto: Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var size: Int64 = 0
    public var modified: Double = 0
    public var fingerprint = ""
    public var captured: Date?
    public var camera = "", lens = ""
    public var iso: Double?, focalLength: Double?, aperture: Double?
    public var width = 0, height = 0
    public var latitude: Double?, longitude: Double?
    public var rating = 0
    public var flag: PhotoFlag = .none
    public var label: ColorLabel = .none
    public var edited = false
    public var title = "", caption = ""
    public var keywords: [String] = []
    public var filename: String { (path as NSString).lastPathComponent }
    public init(id: UUID, path: String) { self.id = id; self.path = path }

    /// EXIF, TIFF and GPS facts plus file size and modification time.
    public static func read(_ url: URL, id: UUID) -> CatalogPhoto {
        var p = CatalogPhoto(id: id, path: url.standardizedFileURL.path)
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        p.size = Int64(values?.fileSize ?? 0); p.modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        guard let io = CGImageSourceCreateWithURL(url as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(io, 0, nil) as? [String: Any] else { return p }
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        let meta = PhotoMetadata(properties: props)
        if meta.camera != "Not recorded" { p.camera = meta.camera }
        if meta.lens != "Not recorded" { p.lens = meta.lens }
        func number(_ v: Any?) -> Double? { (v as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite ? $0 : nil } }
        p.iso = (exif["ISOSpeedRatings"] as? [NSNumber])?.first?.doubleValue ?? number(exif["PhotographicSensitivity"])
        p.focalLength = number(exif["FocalLength"]); p.aperture = number(exif["FNumber"])
        p.width = Int(number(props["PixelWidth"]) ?? 0); p.height = Int(number(props["PixelHeight"]) ?? 0)
        if let orientation = number(props["Orientation"]), orientation >= 5, orientation <= 8 { swap(&p.width, &p.height) }
        if let stamp = exif["DateTimeOriginal"] as? String {
            let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.timeZone = TimeZone(secondsFromGMT: 0); parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
            p.captured = parser.date(from: stamp)
        }
        if let lat = number(gps["Latitude"]), let lon = number(gps["Longitude"]) {
            p.latitude = (gps["LatitudeRef"] as? String) == "S" ? -lat : lat
            p.longitude = (gps["LongitudeRef"] as? String) == "W" ? -lon : lon
        }
        return p
    }
    mutating func apply(_ record: PhotoRecord) {
        id = record.id; fingerprint = record.contentFingerprint; rating = record.rating; flag = record.flag; label = record.colorLabel
        edited = record.isEdited; let m = record.iptc; title = m.title; caption = m.caption; keywords = m.keywordPaths
    }
    /// True when free text matches the filename, title, caption, keywords, camera or lens.
    public func matches(text: String) -> Bool {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return q.split(separator: " ").allSatisfy { word in
            [filename, title, caption, camera, lens].contains { $0.localizedCaseInsensitiveContains(word) } || keywords.contains { $0.localizedCaseInsensitiveContains(word) }
        }
    }
}

// MARK: - Smart collection rules

public struct SmartRule: Codable, Equatable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable {
        case rating, flag, label, keyword, camera, lens, iso, captured, filename, edited, text
        public var title: String {
            switch self { case .rating: return "Rating"; case .flag: return "Flag"; case .label: return "Label"; case .keyword: return "Keyword"; case .camera: return "Camera"; case .lens: return "Lens"
            case .iso: return "ISO"; case .captured: return "Capture date"; case .filename: return "Filename"; case .edited: return "Edited"; case .text: return "Any text" }
        }
    }
    public enum Operation: String, Codable, CaseIterable, Sendable { case atLeast, atMost, equals, contains, notContains, between, isTrue, isFalse }
    /// The operations offered for a field, with their menu titles.
    public static func operations(for field: Field) -> [(Operation, String)] {
        switch field {
        case .rating, .iso: return [(.atLeast, "is at least"), (.atMost, "is at most"), (.equals, "is")]
        case .captured: return [(.atLeast, "is on or after"), (.atMost, "is on or before")]
        case .flag, .label: return [(.equals, "is")]
        case .edited: return [(.isTrue, "is yes"), (.isFalse, "is no")]
        case .keyword, .camera, .lens, .filename, .text: return [(.contains, "contains"), (.notContains, "doesn’t contain"), (.equals, "is")]
        }
    }
    /// Suggested values for fields with a fixed set.
    public static func choices(for field: Field) -> [String] {
        switch field { case .flag: return PhotoFlag.allCases.map(\.rawValue); case .label: return ColorLabel.allCases.map(\.rawValue); default: return [] }
    }
    /// Builds a rule from what's typed in the editor. Numbers for rating and ISO, YYYY-MM-DD for dates. Nil when unusable.
    public static func make(_ field: Field, _ operation: Operation, value: String) -> SmartRule? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field {
        case .rating, .iso:
            guard let n = Double(v), n.isFinite else { return nil }
            return SmartRule(field, operation, low: operation == .atMost ? nil : n, high: operation == .atMost ? n : nil)
        case .captured:
            let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.timeZone = TimeZone(secondsFromGMT: 0); parser.dateFormat = "yyyy-MM-dd"
            guard let day = parser.date(from: v) else { return nil }
            // "On or before" includes the whole day.
            return operation == .atMost ? SmartRule(field, .atMost, high: day.timeIntervalSince1970 + 86399.999) : SmartRule(field, .atLeast, low: day.timeIntervalSince1970)
        case .flag: return PhotoFlag(rawValue: v.lowercased()).map { SmartRule(field, .equals, text: $0.rawValue) }
        case .label: return ColorLabel(rawValue: v.lowercased()).map { SmartRule(field, .equals, text: $0.rawValue) }
        case .edited: return SmartRule(field, operation == .isFalse ? .isFalse : .isTrue)
        default: return v.isEmpty ? nil : SmartRule(field, operation, text: v)
        }
    }
    public var field: Field, operation: Operation
    public var text = ""
    public var low: Double?, high: Double?
    public init(_ field: Field, _ operation: Operation, text: String = "", low: Double? = nil, high: Double? = nil) {
        self.field = field; self.operation = operation; self.text = text; self.low = low; self.high = high
    }
    public func matches(_ p: CatalogPhoto) -> Bool {
        func compare(_ value: Double?) -> Bool {
            guard let value else { return false }
            switch operation {
            case .atLeast: return low.map { value >= $0 } ?? true
            case .atMost: return high.map { value <= $0 } ?? (low.map { value <= $0 } ?? true)
            case .equals: return low.map { value == $0 } ?? false
            case .between: return (low.map { value >= $0 } ?? true) && (high.map { value <= $0 } ?? true)
            default: return false
            }
        }
        func string(_ value: String) -> Bool {
            switch operation {
            case .contains: return text.isEmpty || value.localizedCaseInsensitiveContains(text)
            case .notContains: return text.isEmpty || !value.localizedCaseInsensitiveContains(text)
            case .equals: return value.caseInsensitiveCompare(text) == .orderedSame
            default: return false
            }
        }
        switch field {
        case .rating: return compare(Double(p.rating))
        case .iso: return compare(p.iso)
        case .captured: return compare(p.captured?.timeIntervalSince1970)
        case .flag: return p.flag.rawValue == text
        case .label: return p.label.rawValue == text
        case .keyword:
            let any = p.keywords.contains { operation == .equals ? $0.caseInsensitiveCompare(text) == .orderedSame || $0.components(separatedBy: " > ").last?.caseInsensitiveCompare(text) == .orderedSame : $0.localizedCaseInsensitiveContains(text) }
            return operation == .notContains ? !any : any
        case .camera: return string(p.camera)
        case .lens: return string(p.lens)
        case .filename: return string(p.filename)
        case .edited: return operation == .isFalse ? !p.edited : p.edited
        case .text: return operation == .notContains ? !p.matches(text: text) : p.matches(text: text)
        }
    }
}
public struct SmartRules: Codable, Equatable, Sendable {
    public var matchAll = true
    public var rules: [SmartRule] = []
    public init(matchAll: Bool = true, rules: [SmartRule] = []) { self.matchAll = matchAll; self.rules = rules }
    public func matches(_ p: CatalogPhoto) -> Bool {
        guard !rules.isEmpty else { return true }
        return matchAll ? rules.allSatisfy { $0.matches(p) } : rules.contains { $0.matches(p) }
    }
}
public struct PhotoCollection: Identifiable, Equatable, Sendable {
    public var id: UUID, name: String
    public var smart: SmartRules?
    public var isSmart: Bool { smart != nil }
}

// MARK: - The SQLite catalog

public enum CatalogError: LocalizedError {
    case sqlite(String)
    public var errorDescription: String? { if case .sqlite(let m) = self { return "The library catalog couldn’t be updated: \(m)" }; return nil }
}

/// A local SQLite index of every photo OpenStill has opened: file facts for fast lookup and typed search, plus keywords
/// and collections. Photo records (JSON) remain the source of truth for edits, ratings, flags, labels and metadata;
/// the catalog mirrors them and can be rebuilt from them.
public final class LibraryCatalog {
    public let url: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    public static let schemaVersion = 1

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"; sqlite3_close(db); db = nil
            throw CatalogError.sqlite(message)
        }
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("""
        CREATE TABLE IF NOT EXISTS photos (
            id TEXT PRIMARY KEY, path TEXT NOT NULL, size INTEGER, modified REAL, fingerprint TEXT,
            captured REAL, camera TEXT, lens TEXT, iso REAL, focal REAL, aperture REAL, width INTEGER, height INTEGER,
            latitude REAL, longitude REAL, rating INTEGER DEFAULT 0, flag TEXT DEFAULT 'none', label TEXT DEFAULT 'none',
            edited INTEGER DEFAULT 0, title TEXT DEFAULT '', caption TEXT DEFAULT '');
        CREATE INDEX IF NOT EXISTS photos_path ON photos(path);
        CREATE INDEX IF NOT EXISTS photos_fingerprint ON photos(fingerprint);
        CREATE TABLE IF NOT EXISTS photo_keywords (photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE, keyword TEXT NOT NULL, PRIMARY KEY(photo_id, keyword));
        CREATE INDEX IF NOT EXISTS keywords_keyword ON photo_keywords(keyword);
        CREATE TABLE IF NOT EXISTS collections (id TEXT PRIMARY KEY, name TEXT NOT NULL, rules TEXT, created REAL);
        CREATE TABLE IF NOT EXISTS collection_members (collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE, photo_id TEXT NOT NULL, added REAL, PRIMARY KEY(collection_id, photo_id));
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        """)
        try execute("INSERT OR IGNORE INTO meta(key, value) VALUES('schema', '\(Self.schemaVersion)')")
    }
    deinit { sqlite3_close(db) }

    // MARK: SQLite helpers
    private func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown error"; sqlite3_free(error)
            throw CatalogError.sqlite(message)
        }
    }
    private enum Value { case text(String), int(Int64), real(Double), null }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    @discardableResult
    private func run(_ sql: String, _ values: [Value] = [], row: ((OpaquePointer) -> Void)? = nil) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw CatalogError.sqlite(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(statement, index, s, -1, Self.transient)
            case .int(let n): sqlite3_bind_int64(statement, index, n)
            case .real(let d): sqlite3_bind_double(statement, index, d)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        var rows = 0
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW { rows += 1; row?(statement); continue }
            if step == SQLITE_DONE { break }
            throw CatalogError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return rows
    }
    private func transaction(_ body: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw error }
    }
    private static func text(_ s: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
    private static func real(_ s: OpaquePointer, _ i: Int32) -> Double? { sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_double(s, i) }
    private func optional(_ d: Double?) -> Value { d.map { .real($0) } ?? .null }

    public func value(_ key: String) -> String? {
        var out: String?; _ = try? run("SELECT value FROM meta WHERE key = ?", [.text(key)]) { out = Self.text($0, 0) }; return out
    }
    public func setValue(_ value: String, for key: String) throws { try run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [.text(key), .text(value)]) }

    // MARK: Photos
    /// The record ID for a file whose path, size and modification time are unchanged since it was indexed.
    public func recordID(path: String, size: Int64, modified: Double) -> UUID? {
        var id: UUID?
        _ = try? run("SELECT id FROM photos WHERE path = ? AND size = ? AND abs(modified - ?) < 0.001 LIMIT 1", [.text(path), .int(size), .real(modified)]) { id = UUID(uuidString: Self.text($0, 0)) }
        return id
    }
    public func recordIDs(fingerprint: String) -> [UUID] {
        var ids: [UUID] = []
        _ = try? run("SELECT id FROM photos WHERE fingerprint = ?", [.text(fingerprint)]) { if let id = UUID(uuidString: Self.text($0, 0)) { ids.append(id) } }
        return ids
    }
    public var photoCount: Int {
        var n = 0; _ = try? run("SELECT count(*) FROM photos") { n = Int(sqlite3_column_int64($0, 0)) }; return n
    }
    /// Adds or refreshes one photo: file facts from `facts`, everything else from the record.
    public func upsert(_ record: PhotoRecord, facts: CatalogPhoto) throws {
        var p = facts; p.apply(record)
        try transaction {
            try run("""
            INSERT INTO photos(id, path, size, modified, fingerprint, captured, camera, lens, iso, focal, aperture, width, height, latitude, longitude, rating, flag, label, edited, title, caption)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET path=excluded.path, size=excluded.size, modified=excluded.modified, fingerprint=excluded.fingerprint,
              captured=excluded.captured, camera=excluded.camera, lens=excluded.lens, iso=excluded.iso, focal=excluded.focal, aperture=excluded.aperture,
              width=excluded.width, height=excluded.height, latitude=excluded.latitude, longitude=excluded.longitude, rating=excluded.rating,
              flag=excluded.flag, label=excluded.label, edited=excluded.edited, title=excluded.title, caption=excluded.caption
            """, [.text(p.id.uuidString), .text(p.path), .int(p.size), .real(p.modified), .text(p.fingerprint), optional(p.captured?.timeIntervalSince1970),
                  .text(p.camera), .text(p.lens), optional(p.iso), optional(p.focalLength), optional(p.aperture), .int(Int64(p.width)), .int(Int64(p.height)),
                  optional(p.latitude), optional(p.longitude), .int(Int64(p.rating)), .text(p.flag.rawValue), .text(p.label.rawValue), .int(p.edited ? 1 : 0), .text(p.title), .text(p.caption)])
            try replaceKeywords(p.id, p.keywords)
        }
    }
    /// Mirrors a saved record (rating, flag, label, metadata, edited state) into an existing row.
    public func updateRecord(_ record: PhotoRecord) throws {
        var p = CatalogPhoto(id: record.id, path: record.sourcePath); p.apply(record)
        try transaction {
            let changed = try run("UPDATE photos SET rating=?, flag=?, label=?, edited=?, title=?, caption=?, fingerprint=? WHERE id=? RETURNING id",
                                  [.int(Int64(p.rating)), .text(p.flag.rawValue), .text(p.label.rawValue), .int(p.edited ? 1 : 0), .text(p.title), .text(p.caption), .text(p.fingerprint), .text(p.id.uuidString)])
            if changed > 0 { try replaceKeywords(p.id, p.keywords) }
        }
    }
    private func replaceKeywords(_ id: UUID, _ keywords: [String]) throws {
        try run("DELETE FROM photo_keywords WHERE photo_id = ?", [.text(id.uuidString)])
        for k in Set(keywords) { try run("INSERT OR IGNORE INTO photo_keywords(photo_id, keyword) VALUES(?, ?)", [.text(id.uuidString), .text(k)]) }
    }
    public func remove(_ id: UUID) throws { try run("DELETE FROM photos WHERE id = ?", [.text(id.uuidString)]) }

    public func photos(ids: Set<UUID>? = nil) -> [CatalogPhoto] {
        var byID: [UUID: CatalogPhoto] = [:], order: [UUID] = []
        let columns = "SELECT id, path, size, modified, fingerprint, captured, camera, lens, iso, focal, aperture, width, height, latitude, longitude, rating, flag, label, edited, title, caption FROM photos"
        // Specific photos are fetched by ID in chunks; everything else in one pass.
        let chunks: [[UUID]] = ids.map { set in let all = Array(set); return stride(from: 0, to: all.count, by: 400).map { Array(all[$0..<min(all.count, $0 + 400)]) } } ?? [[]]
        for chunk in chunks {
            if ids != nil && chunk.isEmpty { continue }
            let filter = ids == nil ? "" : " WHERE id IN (" + chunk.map { _ in "?" }.joined(separator: ",") + ")"
            _ = try? run(columns + filter, chunk.map { .text($0.uuidString) }) { s in
            guard let id = UUID(uuidString: Self.text(s, 0)) else { return }
            var p = CatalogPhoto(id: id, path: Self.text(s, 1))
            p.size = sqlite3_column_int64(s, 2); p.modified = sqlite3_column_double(s, 3); p.fingerprint = Self.text(s, 4)
            p.captured = Self.real(s, 5).map { Date(timeIntervalSince1970: $0) }; p.camera = Self.text(s, 6); p.lens = Self.text(s, 7)
            p.iso = Self.real(s, 8); p.focalLength = Self.real(s, 9); p.aperture = Self.real(s, 10)
            p.width = Int(sqlite3_column_int64(s, 11)); p.height = Int(sqlite3_column_int64(s, 12))
            p.latitude = Self.real(s, 13); p.longitude = Self.real(s, 14); p.rating = Int(sqlite3_column_int64(s, 15))
            p.flag = PhotoFlag(rawValue: Self.text(s, 16)) ?? .none; p.label = ColorLabel(rawValue: Self.text(s, 17)) ?? .none
            p.edited = sqlite3_column_int64(s, 18) != 0; p.title = Self.text(s, 19); p.caption = Self.text(s, 20)
            byID[id] = p; order.append(id)
            }
            let keywordFilter = ids == nil ? "" : " WHERE photo_id IN (" + chunk.map { _ in "?" }.joined(separator: ",") + ")"
            _ = try? run("SELECT photo_id, keyword FROM photo_keywords" + keywordFilter + " ORDER BY keyword", chunk.map { .text($0.uuidString) }) { s in
                if let id = UUID(uuidString: Self.text(s, 0)), byID[id] != nil { byID[id]!.keywords.append(Self.text(s, 1)) }
            }
        }
        return order.compactMap { byID[$0] }
    }
    public func photo(_ id: UUID) -> CatalogPhoto? { photos(ids: [id]).first }
    /// Every keyword in use and how many photos carry it.
    public func keywordCounts() -> [(String, Int)] {
        var out: [(String, Int)] = []
        _ = try? run("SELECT keyword, count(*) FROM photo_keywords GROUP BY keyword ORDER BY keyword COLLATE NOCASE") { out.append((Self.text($0, 0), Int(sqlite3_column_int64($0, 1)))) }
        return out
    }

    // MARK: Collections
    public func collections() -> [PhotoCollection] {
        var out: [PhotoCollection] = []
        _ = try? run("SELECT id, name, rules FROM collections ORDER BY name COLLATE NOCASE") { s in
            guard let id = UUID(uuidString: Self.text(s, 0)) else { return }
            let rules = sqlite3_column_type(s, 2) == SQLITE_NULL ? nil : try? JSONDecoder().decode(SmartRules.self, from: Data(Self.text(s, 2).utf8))
            out.append(PhotoCollection(id: id, name: Self.text(s, 1), smart: rules))
        }
        return out
    }
    @discardableResult public func createCollection(name: String, smart: SmartRules? = nil) throws -> PhotoCollection {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let collection = PhotoCollection(id: UUID(), name: clean.isEmpty ? "Untitled collection" : String(clean.prefix(200)), smart: smart)
        let rules: Value = try smart.map { .text(String(decoding: try JSONEncoder().encode($0), as: UTF8.self)) } ?? .null
        try run("INSERT INTO collections(id, name, rules, created) VALUES(?, ?, ?, ?)", [.text(collection.id.uuidString), .text(collection.name), rules, .real(Date().timeIntervalSince1970)])
        return collection
    }
    public func renameCollection(_ id: UUID, to name: String) throws { try run("UPDATE collections SET name = ? WHERE id = ?", [.text(name), .text(id.uuidString)]) }
    public func deleteCollection(_ id: UUID) throws { try run("DELETE FROM collections WHERE id = ?", [.text(id.uuidString)]) }
    public func add(_ photos: [UUID], to collection: UUID) throws {
        try transaction { for id in photos { try run("INSERT OR IGNORE INTO collection_members(collection_id, photo_id, added) VALUES(?, ?, ?)", [.text(collection.uuidString), .text(id.uuidString), .real(Date().timeIntervalSince1970)]) } }
    }
    public func remove(_ photos: [UUID], from collection: UUID) throws {
        try transaction { for id in photos { try run("DELETE FROM collection_members WHERE collection_id = ? AND photo_id = ?", [.text(collection.uuidString), .text(id.uuidString)]) } }
    }
    /// Members of a regular collection, or the photos matching a smart collection's rules.
    public func members(of collection: PhotoCollection) -> [CatalogPhoto] {
        if let rules = collection.smart { return photos().filter { rules.matches($0) } }
        var ids = Set<UUID>()
        _ = try? run("SELECT photo_id FROM collection_members WHERE collection_id = ?", [.text(collection.id.uuidString)]) { if let id = UUID(uuidString: Self.text($0, 0)) { ids.insert(id) } }
        return ids.isEmpty ? [] : photos(ids: ids)
    }
}

// MARK: - Disk preview cache

/// JPEG previews under <root>/Previews, keyed by photo, version and revision, so the library grid doesn't re-render
/// unchanged photos. A new revision gets a new file; older previews of the same photo are removed when it is written.
public enum PreviewCache {
    public static func directory(root: URL = EditStorage.root) -> URL { root.appendingPathComponent("Previews", isDirectory: true) }
    public static func url(for request: RenderRequest, root: URL = EditStorage.root) -> URL {
        let edge = request.maximumDimension ?? 0
        return directory(root: root).appendingPathComponent("\(request.photoID.uuidString)-\(request.versionID.uuidString)-\(request.revision.uuidString)-\(request.sourceMode.rawValue)-\(edge).jpg")
    }
    public static func read(_ request: RenderRequest, root: URL = EditStorage.root) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url(for: request, root: root) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    public static func write(_ image: CGImage, for request: RenderRequest, root: URL = EditStorage.root) {
        let folder = directory(root: root), destination = url(for: request, root: root)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prefix = request.photoID.uuidString + "-", suffix = "-\(request.maximumDimension ?? 0).jpg"
        for old in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where old.hasPrefix(prefix) && old.hasSuffix(suffix) && old != destination.lastPathComponent {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
        }
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { return }
        try? (data as Data).write(to: destination, options: .atomic)
    }
    public static func clear(root: URL = EditStorage.root) { try? FileManager.default.removeItem(at: directory(root: root)) }
}
