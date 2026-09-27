import Foundation
import CoreImage
import SQLite3

// MARK: - Stacks

/// Stacks group photos in the catalog: one row per stacked photo, with its stack and its place in it (0 is the top).
extension LibraryCatalog {
    func prepareStacks() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS stacks (photo_id TEXT PRIMARY KEY, stack_id TEXT NOT NULL, position INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS stacks_stack ON stacks(stack_id);
        """)
    }
    /// Every stack and its photos, top first.
    public func stacks() -> [UUID: [UUID]] {
        var rows: [(UUID, UUID, Int)] = []
        _ = try? run("SELECT stack_id, photo_id, position FROM stacks ORDER BY stack_id, position") { s in
            if let stack = UUID(uuidString: Self.text(s, 0)), let photo = UUID(uuidString: Self.text(s, 1)) { rows.append((stack, photo, Int(sqlite3_column_int64(s, 2)))) }
        }
        var out: [UUID: [UUID]] = [:]
        for (stack, photo, _) in rows { out[stack, default: []].append(photo) }
        return out
    }
    /// Groups these photos into one new stack, in this order; they leave any stack they were in. Needs two or more photos.
    @discardableResult public func createStack(_ photos: [UUID]) throws -> UUID? {
        var seen = Set<UUID>(); let ids = photos.filter { seen.insert($0).inserted }
        guard ids.count > 1 else { return nil }
        let stack = UUID()
        try transaction {
            try unstackRows(ids)
            for (i, id) in ids.enumerated() {
                try run("INSERT INTO stacks(photo_id, stack_id, position) VALUES(?, ?, ?)", [.text(id.uuidString), .text(stack.uuidString), .int(Int64(i))])
            }
        }
        return stack
    }
    /// Breaks up a stack; its photos stay in the library.
    public func unstack(_ stack: UUID) throws { try run("DELETE FROM stacks WHERE stack_id = ?", [.text(stack.uuidString)]) }
    /// Takes photos out of their stacks. A stack left with one photo is removed.
    public func removeFromStacks(_ photos: [UUID]) throws { try transaction { try unstackRows(photos) } }
    private func unstackRows(_ photos: [UUID]) throws {
        var touched = Set<String>()
        for id in photos {
            try run("SELECT stack_id FROM stacks WHERE photo_id = ?", [.text(id.uuidString)]) { s in touched.insert(Self.text(s, 0)) }
            try run("DELETE FROM stacks WHERE photo_id = ?", [.text(id.uuidString)])
        }
        for stack in touched { try renumber(stack) }
    }
    /// Makes this photo the top of its stack; the others keep their order below it.
    public func setStackTop(_ photo: UUID) throws {
        var stack: String?
        _ = try run("SELECT stack_id FROM stacks WHERE photo_id = ?", [.text(photo.uuidString)]) { stack = Self.text($0, 0) }
        guard let stack else { return }
        try transaction {
            try run("UPDATE stacks SET position = -1 WHERE photo_id = ?", [.text(photo.uuidString)])
            try renumber(stack)
        }
    }
    private func renumber(_ stack: String) throws {
        var ids: [String] = []
        _ = try run("SELECT photo_id FROM stacks WHERE stack_id = ? ORDER BY position", [.text(stack)]) { ids.append(Self.text($0, 0)) }
        if ids.count < 2 { try run("DELETE FROM stacks WHERE stack_id = ?", [.text(stack)]); return }
        for (i, id) in ids.enumerated() { try run("UPDATE stacks SET position = ? WHERE photo_id = ?", [.int(Int64(i)), .text(id)]) }
    }
    /// A renamed or moved file: the row follows it.
    public func movePhoto(_ id: UUID, to path: String, size: Int64, modified: Double) throws {
        try run("UPDATE photos SET path = ?, size = ?, modified = ? WHERE id = ?", [.text(path), .int(size), .real(modified), .text(id.uuidString)])
    }
    /// Keywords that appear on the same photos as these, most common first, without these or their parents.
    public func keywordSuggestions(for keywords: [String], limit: Int = 9) -> [String] {
        let chosen = keywords.map { IPTCMetadata.normalizeKeyword($0) }.filter { !$0.isEmpty }
        guard !chosen.isEmpty else { return [] }
        let skip = Set(IPTCMetadata(keywords: chosen).keywordPaths.map { $0.lowercased() })
        var out: [(String, Int)] = []
        let marks = chosen.map { _ in "?" }.joined(separator: ",")
        _ = try? run("""
        SELECT b.keyword, count(DISTINCT b.photo_id) FROM photo_keywords a JOIN photo_keywords b ON a.photo_id = b.photo_id
        WHERE a.keyword IN (\(marks)) GROUP BY b.keyword ORDER BY 2 DESC, b.keyword COLLATE NOCASE
        """, chosen.map { .text($0) }) { out.append((Self.text($0, 0), Int(sqlite3_column_int64($0, 1)))) }
        // Suggest leaves, not the parents every child photo also carries.
        let all = out.map(\.0)
        return out.map(\.0).filter { k in !skip.contains(k.lowercased()) && !all.contains { $0.hasPrefix(k + " > ") } }.prefix(limit).map { $0 }
    }
}

extension IPTCMetadata {
    init(keywords: [String]) { self.init(); self.keywords = keywords }
}

/// How stacks show in the grid: a closed stack shows its top photo with a count; an open one shows all its photos together.
public struct StackedItem<Item> {
    public let item: Item
    public let stack: UUID?
    /// 0 for the top photo.
    public let position: Int
    /// Photos of this stack among the ones shown.
    public let count: Int
    public var isTop: Bool { position == 0 }
}
public enum Stacking {
    public static func arrange<Item>(_ items: [Item], id: (Item) -> UUID, stacks: [UUID: [UUID]], expanded: Set<UUID>) -> [StackedItem<Item>] {
        var stackOf: [UUID: UUID] = [:]
        for (stack, members) in stacks { for m in members { stackOf[m] = stack } }
        var byID: [UUID: Item] = [:]
        for item in items { byID[id(item)] = item }
        var done = Set<UUID>(), out: [StackedItem<Item>] = []
        for item in items {
            let photo = id(item)
            guard let stack = stackOf[photo] else { out.append(StackedItem(item: item, stack: nil, position: 0, count: 1)); continue }
            guard done.insert(stack).inserted else { continue }
            // Members hidden by the current filter don't count.
            let present = (stacks[stack] ?? []).compactMap { byID[$0] }
            if present.count < 2 { out.append(StackedItem(item: item, stack: nil, position: 0, count: 1)); continue }
            if expanded.contains(stack) {
                for (i, member) in present.enumerated() { out.append(StackedItem(item: member, stack: stack, position: i, count: present.count)) }
            } else { out.append(StackedItem(item: present[0], stack: stack, position: 0, count: present.count)) }
        }
        return out
    }
}
/// Auto-stack by capture time: photos taken within `gap` seconds of the previous one share a stack.
public enum AutoStack {
    public static func groups(_ photos: [(id: UUID, captured: Date)], gap: TimeInterval) -> [[UUID]] {
        let sorted = photos.filter { $0.captured != .distantPast }.sorted { $0.captured < $1.captured }
        var out: [[UUID]] = [], current: [UUID] = [], last: Date?
        for p in sorted {
            if let last, p.captured.timeIntervalSince(last) <= max(0, gap) { current.append(p.id) }
            else { if current.count > 1 { out.append(current) }; current = [p.id] }
            last = p.captured
        }
        if current.count > 1 { out.append(current) }
        return out
    }
}

// MARK: - Library filter bar

/// The Metadata columns of the Library filter bar. Each column only offers what the columns before it leave.
public enum MetadataColumn: String, CaseIterable, Sendable {
    case date, camera, lens, label, keyword
    public var title: String { switch self { case .date: return "Date"; case .camera: return "Camera"; case .lens: return "Lens"; case .label: return "Label"; case .keyword: return "Keyword" } }
    /// The values a photo has in this column (a photo can carry several keywords).
    public func values(_ item: ShootItem) -> [String] {
        switch self {
        case .date: return [item.captured == .distantPast ? "Unknown date" : String(Calendar(identifier: .gregorian).component(.year, from: item.captured))]
        case .camera: let c = item.facts?.camera ?? ""; return [c.isEmpty ? "Unknown camera" : c]
        case .lens: let l = item.facts?.lens ?? ""; return [l.isEmpty ? "Unknown lens" : l]
        case .label: return [item.record.colorLabel.title]
        case .keyword: let k = item.record.iptc.keywordPaths; return k.isEmpty ? ["No keywords"] : k
        }
    }
}
public struct FacetValue: Equatable, Sendable {
    public let value: String
    public let count: Int
}
public struct LibraryFilter: Equatable {
    public var text = ""
    public var minimumRating = 0
    public var flag = ShootFlagFilter.all
    public var label: ShootLabelFilter = nil
    /// Metadata column choices; a missing column matches everything.
    public var metadata: [MetadataColumn: String] = [:]
    public init() {}
    public var isEmpty: Bool { self == LibraryFilter() }
    func matchesAttributes(_ item: ShootItem) -> Bool {
        ShootWorkflow.filter([item], minimumRating: minimumRating, flag: flag, sort: .filename, label: label, text: text).count == 1
    }
    func matches(_ item: ShootItem, before column: MetadataColumn? = nil) -> Bool {
        for c in MetadataColumn.allCases {
            if c == column { break }
            if let chosen = metadata[c], !c.values(item).contains(chosen) { return false }
        }
        return true
    }
    /// Only the Metadata columns (the text and attribute filters are applied separately).
    public func matchesMetadata(_ item: ShootItem) -> Bool { matches(item) }
    /// The photos that pass the text, attribute and metadata filters.
    public func apply(_ items: [ShootItem]) -> [ShootItem] { items.filter { matchesAttributes($0) && matches($0) } }
    /// A column's values with how many photos have each, given the text, attributes and the columns to its left.
    public func facets(_ items: [ShootItem], column: MetadataColumn) -> [FacetValue] {
        var counts: [String: Int] = [:]
        for item in items where matchesAttributes(item) && matches(item, before: column) { for v in Set(column.values(item)) { counts[v, default: 0] += 1 } }
        let unknown: Set<String> = ["Unknown date", "Unknown camera", "Unknown lens", "No keywords", "No label"]
        return counts.map { FacetValue(value: $0.key, count: $0.value) }.sorted { a, b in
            if unknown.contains(a.value) != unknown.contains(b.value) { return !unknown.contains(a.value) }
            // Newest year first, as Lightroom does; everything else alphabetically.
            if column == .date { return a.value > b.value }
            return a.value.localizedStandardCompare(b.value) == .orderedAscending
        }
    }
    /// Choosing a value clears the columns to its right that no longer apply.
    public mutating func choose(_ value: String?, in column: MetadataColumn, items: [ShootItem]) {
        metadata[column] = value
        var after = false
        for c in MetadataColumn.allCases {
            if c == column { after = true; continue }
            if after, let chosen = metadata[c], !facets(items, column: c).contains(where: { $0.value == chosen }) { metadata[c] = nil }
        }
    }
}

// MARK: - Quick Develop

/// Relative changes from the Library's Quick Develop panel, applied to every selected photo as one undoable batch.
public enum QuickDevelopStep: Equatable, Sendable {
    case exposure(Double), contrast(Double), highlights(Double), shadows(Double), whites(Double), blacks(Double)
    case clarity(Double), vibrance(Double), saturation(Double), temperature(Double), tint(Double)
    case whiteBalance(WhiteBalancePreset)
    case autoTone, resetAll
    public var title: String {
        func signed(_ v: Double, _ format: String = "%.0f", _ unit: String = "") -> String { (v > 0 ? "+" : "") + String(format: format, v) + unit }
        switch self {
        case .exposure(let v): return "Exposure " + signed(v, "%.2f", " EV")
        case .contrast(let v): return "Contrast " + signed(v * 100)
        case .highlights(let v): return "Highlights " + signed(v * 100)
        case .shadows(let v): return "Shadows " + signed(v * 100)
        case .whites(let v): return "Whites " + signed(v * 100)
        case .blacks(let v): return "Blacks " + signed(v * 100)
        case .clarity(let v): return "Clarity " + signed(v * 100)
        case .vibrance(let v): return "Vibrance " + signed(v * 100)
        case .saturation(let v): return "Saturation " + signed(v * 100)
        case .temperature(let v): return "Temperature " + signed(v, "%.0f", " K")
        case .tint(let v): return "Tint " + signed(v)
        case .whiteBalance(let p): return "White balance: " + p.title
        case .autoTone: return "Auto tone"
        case .resetAll: return "Reset all"
        }
    }
}
public enum WhiteBalancePreset: String, CaseIterable, Sendable {
    case asShot, daylight, cloudy, shade, tungsten, fluorescent, flash
    public var title: String { switch self { case .asShot: return "As Shot"; case .daylight: return "Daylight"; case .cloudy: return "Cloudy"; case .shade: return "Shade"; case .tungsten: return "Tungsten"; case .fluorescent: return "Fluorescent"; case .flash: return "Flash" } }
    /// Temperature and tint; As Shot is OpenStill's neutral starting point.
    public var values: (temperature: Double, tint: Double) {
        switch self {
        case .asShot: return (6500, 0); case .daylight: return (5500, 0); case .cloudy: return (6500, 5); case .shade: return (7500, 5)
        case .tungsten: return (2850, 0); case .fluorescent: return (3800, 10); case .flash: return (5500, 0)
        }
    }
}
public enum QuickDevelop {
    /// One step on one photo's current edits. Auto tone needs the photo's histogram.
    public static func apply(_ step: QuickDevelopStep, to edits: PhotoEdits, histogram: PhotoHistogram? = nil) -> PhotoEdits {
        var e = edits
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
        switch step {
        case .exposure(let v): e.exposure = clamp(e.exposure + v, -4, 4)
        case .contrast(let v): e.contrast = clamp(e.contrast + v, 0.5, 1.5); e.usesSmartContrast = true
        case .highlights(let v): e.highlights = clamp(e.highlights + v, 0, 1)
        case .shadows(let v): e.shadows = clamp(e.shadows + v, 0, 1)
        case .whites(let v): e.whites = clamp(e.whites + v, -1, 1)
        case .blacks(let v): e.blacks = clamp(e.blacks + v, -1, 1)
        case .clarity(let v): e.clarity = clamp(e.clarity + v, -1, 1)
        case .vibrance(let v): e.vibrance = clamp(e.vibrance + v, -1, 1)
        case .saturation(let v): e.saturation = clamp(e.saturation + v, 0, 2)
        case .temperature(let v): e.temperature = clamp(e.temperature + v, 2500, 10000)
        case .tint(let v): e.tint = clamp(e.tint + v, -100, 100)
        case .whiteBalance(let p): e.temperature = p.values.temperature; e.tint = p.values.tint
        case .autoTone: if let histogram { e = AutoTone.apply(histogram, to: e) }
        case .resetAll:
            // Like Lightroom's Reset All: the look goes, the crop and retouching stay.
            var fresh = PhotoEdits()
            fresh.crop = e.crop; fresh.rotation = e.rotation; fresh.flip = e.flip; fresh.straighten = e.straighten
            fresh.retouch = e.retouch; fresh.baseAsset = e.baseAsset; fresh.overlayAsset = e.overlayAsset
            e = fresh
        }
        return e.sanitized
    }
    /// The batch for these photos; `histograms` are needed only for Auto tone.
    public static func prepare(_ items: [ShootItem], step: QuickDevelopStep, histograms: [UUID: PhotoHistogram] = [:]) -> BatchTransaction {
        let entries = items.map { item -> BatchEntry in
            let before = item.record.active.document.current
            var entry = BatchEntry(photoID: item.id, sourcePath: item.url.path, sourceHash: item.record.contentFingerprint, versionID: item.record.activeVersionID,
                                   beforeRevision: item.record.active.revision, before: before, after: apply(step, to: before, histogram: histograms[item.id]))
            if step == .autoTone && histograms[item.id] == nil { entry.failure = "Couldn’t read this photo’s tones." }
            return entry
        }
        return BatchTransaction(sourceName: "Quick Develop · " + step.title, entries: entries)
    }
    /// The tones entering Develop, for Auto tone (as the Develop Auto button measures them).
    public static func histogram(_ item: ShootItem) -> PhotoHistogram? {
        var recipe = item.record.active.recipe
        var neutral = recipe.edits
        neutral.exposure = 0; neutral.contrast = 1; neutral.highlights = 1; neutral.shadows = 0; neutral.whites = 0; neutral.blacks = 0
        recipe.edits = neutral
        guard let image = try? ModernRenderer.render(source: item.url, recipe: recipe, maximumDimension: 768, stopBeforeTool: "Develop") else { return nil }
        return PhotoHistogram.measure(image)
    }
}

// MARK: - Keywords: list, sets and suggestions

/// One level of the Keyword List: "Places > France" is the child "France" of "Places".
public struct KeywordNode: Equatable {
    public var name: String
    public var path: String
    public var count: Int
    public var children: [KeywordNode] = []
}
public enum KeywordTree {
    /// Builds the tree from catalog counts (every level is counted, since each photo carries its keyword's parents too).
    public static func build(_ counts: [(String, Int)]) -> [KeywordNode] {
        var roots: [KeywordNode] = []
        func insert(_ parts: ArraySlice<String>, path: String, count: Int, into nodes: inout [KeywordNode]) {
            guard let name = parts.first else { return }
            let here = path.isEmpty ? name : path + " > " + name
            let i: Int
            if let found = nodes.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { i = found }
            else { nodes.append(KeywordNode(name: name, path: here, count: 0)); i = nodes.count - 1 }
            if parts.count == 1 { nodes[i].count = max(nodes[i].count, count) }
            else { insert(parts.dropFirst(), path: here, count: count, into: &nodes[i].children) }
        }
        for (keyword, count) in counts {
            let parts = IPTCMetadata.normalizeKeyword(keyword).components(separatedBy: " > ").filter { !$0.isEmpty }
            insert(parts[...], path: "", count: count, into: &roots)
        }
        func sort(_ nodes: inout [KeywordNode]) {
            nodes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for i in nodes.indices {
                sort(&nodes[i].children)
                // A parent never shows fewer photos than its busiest child.
                nodes[i].count = max(nodes[i].count, nodes[i].children.map(\.count).max() ?? 0)
            }
        }
        sort(&roots)
        return roots
    }
    /// Depth-first rows for display, keeping only paths that contain `filter`.
    public static func rows(_ nodes: [KeywordNode], filter: String = "") -> [(node: KeywordNode, depth: Int)] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        var out: [(KeywordNode, Int)] = []
        func keep(_ n: KeywordNode) -> Bool { q.isEmpty || n.name.localizedCaseInsensitiveContains(q) || n.children.contains(where: keep) }
        func walk(_ nodes: [KeywordNode], _ depth: Int) { for n in nodes where keep(n) { out.append((n, depth)); walk(n.children, depth + 1) } }
        walk(nodes, 0)
        return out.map { (node: $0.0, depth: $0.1) }
    }
}
/// Nine keywords applied with ⌥1–⌥9, like Lightroom's Keyword Sets.
public struct KeywordSet: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var keywords: [String]
    public init(name: String, keywords: [String]) { self.name = name; self.keywords = Array(keywords.prefix(9)) }
}
public enum KeywordSets {
    public static let builtIn: [KeywordSet] = [
        KeywordSet(name: "Outdoor Photography", keywords: ["Landscape", "Wildlife", "Macro", "Sunset", "Flowers", "Snow", "Beach", "Forest", "Mountains"]),
        KeywordSet(name: "Portrait Photography", keywords: ["Portrait", "Family", "Couple", "Children", "Studio", "Headshot", "Black & White", "Candid", "Group"]),
        KeywordSet(name: "Wedding Photography", keywords: ["Ceremony", "Reception", "Bride", "Groom", "Rings", "First Dance", "Cake", "Guests", "Details"]),
    ]
    private static func file(_ root: URL) -> URL { root.appendingPathComponent("KeywordSets.json") }
    private static func recentFile(_ root: URL) -> URL { root.appendingPathComponent("RecentKeywords.json") }
    /// Custom sets, saved with the catalog.
    public static func custom(root: URL = EditStorage.root) -> [KeywordSet] { (try? JSONDecoder().decode([KeywordSet].self, from: Data(contentsOf: file(root)))) ?? [] }
    public static func saveCustom(_ sets: [KeywordSet], root: URL = EditStorage.root) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(sets).write(to: file(root), options: .atomic)
    }
    /// "Recent Keywords" first, then the built-in and custom sets.
    public static func all(root: URL = EditStorage.root) -> [KeywordSet] { [KeywordSet(name: "Recent Keywords", keywords: recent(root: root))] + builtIn + custom(root: root) }
    public static func recent(root: URL = EditStorage.root) -> [String] { (try? JSONDecoder().decode([String].self, from: Data(contentsOf: recentFile(root)))) ?? [] }
    /// Keywords just applied move to the front of Recent Keywords (nine at most).
    public static func noteRecent(_ keywords: [String], root: URL = EditStorage.root) {
        var list = recent(root: root)
        for k in keywords.reversed() { let k = IPTCMetadata.normalizeKeyword(k); guard !k.isEmpty else { continue }; list.removeAll { $0.caseInsensitiveCompare(k) == .orderedSame }; list.insert(k, at: 0) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Array(list.prefix(9))).write(to: recentFile(root), options: .atomic)
    }
}

// MARK: - Batch rename

public enum RenameError: LocalizedError {
    case template, collision(String), missing(String)
    public var errorDescription: String? {
        switch self {
        case .template: return "Use a name with {name}, {index}, {date}, {yyyy}, {MM}, {dd}, {camera} or {title}, without slashes or colons."
        case .collision(let n): return "Another file is already named “\(n)”. Change the template or the start number."
        case .missing(let n): return "“\(n)” is no longer where the library expects it."
        }
    }
}
public struct RenameEntry: Codable, Equatable {
    public let photoID: UUID
    public let from: URL
    public let to: URL
    public var done = false
}
public struct RenameJournal: Codable, Identifiable {
    public var id = UUID(), created = Date()
    public var entries: [RenameEntry]
    public var undone = false
}
public enum BatchRename {
    public static let templates = ["{name}", "{date}_{name}", "{yyyy}{MM}{dd}-{index}", "{title}-{index}", "{camera}_{index}"]
    /// The new file name (with the original extension) for one photo.
    public static func name(_ item: ShootItem, template: String, index: Int) throws -> String {
        let calendar = Calendar(identifier: .gregorian); let d = item.captured == .distantPast ? Date(timeIntervalSince1970: 0) : item.captured
        let parts = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: d)
        func two(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        func safe(_ s: String) -> String { s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "\\", with: "-").trimmingCharacters(in: .whitespaces) }
        let title = item.record.iptc.title
        let tokens: [(String, String)] = [
            ("name", item.url.deletingPathExtension().lastPathComponent), ("index", String(format: "%03d", index)),
            ("yyyy", String(format: "%04d", parts.year ?? 1970)), ("MM", two(parts.month)), ("dd", two(parts.day)),
            ("date", "\(String(format: "%04d", parts.year ?? 1970))-\(two(parts.month))-\(two(parts.day))"),
            ("camera", (item.facts?.camera).flatMap { $0.isEmpty ? nil : $0 } ?? "Camera"), ("title", title.isEmpty ? "Untitled" : title),
        ]
        var stem = template
        for (key, value) in tokens { stem = stem.replacingOccurrences(of: "{\(key)}", with: safe(value)) }
        stem = stem.trimmingCharacters(in: .whitespaces)
        guard !stem.isEmpty, stem != ".", stem != "..", !stem.hasPrefix("."), stem.utf8.count < 200, !stem.contains("/"), !stem.contains(":"), !stem.contains("\\"),
              !stem.contains("{"), !stem.contains("}"), !stem.unicodeScalars.contains(where: { $0.value < 32 }) else { throw RenameError.template }
        let ext = item.url.pathExtension
        return ext.isEmpty ? stem : stem + "." + ext
    }
    /// What each photo would be renamed to. Names that clash with another file (not one being renamed) are refused.
    public static func plan(_ items: [ShootItem], template: String, start: Int = 1, fileManager: FileManager = .default) throws -> [RenameEntry] {
        let moving = Set(items.map { $0.url.standardizedFileURL.path.lowercased() })
        var taken = Set<String>(), out: [RenameEntry] = []
        for (i, item) in items.enumerated() {
            let name = try name(item, template: template, index: start + i)
            let target = item.url.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL
            let key = target.path.lowercased()
            if !taken.insert(key).inserted { throw RenameError.collision(name) }
            if key != item.url.standardizedFileURL.path.lowercased(), !moving.contains(key), fileManager.fileExists(atPath: target.path) { throw RenameError.collision(name) }
            out.append(RenameEntry(photoID: item.id, from: item.url.standardizedFileURL, to: target))
        }
        return out.filter { $0.from != $0.to }
    }
    private static func journalURL(_ id: UUID, store: PhotoRecordStore) -> URL { store.root.appendingPathComponent("RenameHistory/\(id.uuidString).json") }
    private static func save(_ journal: RenameJournal, store: PhotoRecordStore) throws {
        let url = journalURL(journal.id, store: store)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
    }
    /// The most recent rename that can still be undone.
    public static func latest(store: PhotoRecordStore = EditStorage.records) -> RenameJournal? {
        let folder = store.root.appendingPathComponent("RenameHistory")
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? JSONDecoder().decode(RenameJournal.self, from: Data(contentsOf: $0)) }.filter { !$0.undone }.max { $0.created < $1.created }
    }
    /// Renames the files and their XMP sidecars, then points each photo's record and catalog row at the new name.
    /// Files go through a temporary name first, so names can be swapped. The journal makes it undoable.
    @discardableResult public static func perform(_ plan: [RenameEntry], store: PhotoRecordStore = EditStorage.records) throws -> RenameJournal {
        var journal = RenameJournal(entries: plan)
        try save(journal, store: store)
        journal = move(journal, forward: true, store: store)
        try save(journal, store: store)
        return journal
    }
    @discardableResult public static func undo(_ journal: RenameJournal, store: PhotoRecordStore = EditStorage.records) throws -> RenameJournal {
        var result = move(journal, forward: false, store: store)
        result.undone = true
        try save(result, store: store)
        return result
    }
    private static func move(_ journal: RenameJournal, forward: Bool, store: PhotoRecordStore) -> RenameJournal {
        let fm = FileManager.default
        var journal = journal
        let active = journal.entries.indices.filter { forward ? !journal.entries[$0].done : journal.entries[$0].done }
        var staged: [Int: URL] = [:]
        for i in active {
            let e = journal.entries[i], from = forward ? e.from : e.to
            guard fm.fileExists(atPath: from.path) else { continue }
            let temp = from.deletingLastPathComponent().appendingPathComponent(".openstill-rename-\(UUID().uuidString)." + from.pathExtension)
            if (try? fm.moveItem(at: from, to: temp)) != nil { staged[i] = temp }
        }
        for (i, temp) in staged.sorted(by: { $0.key < $1.key }) {
            let e = journal.entries[i], from = forward ? e.from : e.to, to = forward ? e.to : e.from
            guard !fm.fileExists(atPath: to.path), (try? fm.moveItem(at: temp, to: to)) != nil else { try? fm.moveItem(at: temp, to: from); continue }
            let oldSidecar = XMPSidecar.url(for: from), newSidecar = XMPSidecar.url(for: to)
            if fm.fileExists(atPath: oldSidecar.path), !fm.fileExists(atPath: newSidecar.path) { try? fm.moveItem(at: oldSidecar, to: newSidecar) }
            _ = try? store.update(e.photoID) { record in
                record.sourcePath = to.path
                record.bookmark = try? to.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            let values = try? URL(fileURLWithPath: to.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            try? store.catalog?.movePhoto(e.photoID, to: to.path, size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            journal.entries[i].done = forward
        }
        return journal
    }
}

// MARK: - Auto Import

/// A watched folder: photos saved into it are moved (or copied) into the library's destination, with an optional develop preset and metadata.
public struct AutoImportSettings: Codable, Equatable {
    public var enabled = false
    public var watched: URL?
    public var destination: URL?
    public var folderTemplate = "{yyyy}/{yyyy}-{MM}-{dd}"
    public var nameTemplate = "{name}"
    /// Move files out of the watched folder (Lightroom's behavior); off copies them.
    public var move = true
    public var metadata: IPTCMetadata?
    public var developPreset: PhotoEdits?
    public var developPresetName: String?
    public init() {}
    public var isReady: Bool {
        guard enabled, let watched, let destination else { return false }
        let w = watched.standardizedFileURL.path, d = destination.standardizedFileURL.path
        // The destination can't be inside the watched folder, or imports would be imported again.
        return w != d && !d.hasPrefix(w + "/")
    }
}
public enum AutoImport {
    private static func file(_ root: URL) -> URL { root.appendingPathComponent("AutoImport.json") }
    public static func load(root: URL = EditStorage.root) -> AutoImportSettings { (try? JSONDecoder().decode(AutoImportSettings.self, from: Data(contentsOf: file(root)))) ?? AutoImportSettings() }
    public static func save(_ settings: AutoImportSettings, root: URL = EditStorage.root) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: file(root), options: .atomic)
    }
    /// Files still being written are left for the next pass: they must be unchanged for `quiet` seconds.
    public static func settled(_ candidates: [ImportCandidate], now: Date = Date(), quiet: TimeInterval = 3) -> [ImportCandidate] {
        candidates.filter { c in
            let modified = (try? URL(fileURLWithPath: c.url.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return now.timeIntervalSince(modified) >= quiet && c.size > 0
        }
    }
    /// One pass over the watched folder (only its top level, like Lightroom).
    public static func run(_ settings: AutoImportSettings, store: PhotoRecordStore = EditStorage.records, now: Date = Date()) -> ImportReport {
        guard settings.isReady, let watched = settings.watched, let destination = settings.destination else { return ImportReport() }
        let top = watched.standardizedFileURL.path
        let found = PhotoImport.scan(watched, catalog: store.catalog).filter { $0.url.deletingLastPathComponent().standardizedFileURL.path == top }
        var options = ImportSettings(destination: destination)
        options.folderTemplate = settings.folderTemplate; options.nameTemplate = settings.nameTemplate
        options.metadata = settings.metadata; options.developPreset = settings.developPreset; options.developPresetName = settings.developPresetName ?? "Auto Import preset"
        // Moving means the watched copy always goes, even when it was imported before.
        options.skipAlreadyImported = !settings.move
        var report = ImportReport()
        for candidate in settled(found, now: now) {
            let one = PhotoImport.run([candidate], settings: options, store: store)
            report.imported += one.imported; report.failed += one.failed; report.skipped += one.skipped
            if settings.move, !one.imported.isEmpty {
                try? FileManager.default.removeItem(at: candidate.url)
                if let sidecar = candidate.sidecar { try? FileManager.default.removeItem(at: sidecar) }
            }
        }
        return report
    }
}
