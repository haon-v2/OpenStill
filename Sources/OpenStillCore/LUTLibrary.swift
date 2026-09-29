import Foundation
import CryptoKit

public struct LUTCatalogEntry: Codable, Equatable {
    public let id: String
    public let name: String
    public let category: String
    /// A loose `.cube` next to the catalog (version 1 catalogs and imports); nil for looks stored in the pack.
    public let filename: String?
    public let creator: String
    public let source: String
    public let license: String
    public let checksum: String
    public let description: String
    public var tags: [String]? = nil
    public var dimension: Int? = nil
    public var offset: Int? = nil
    public var length: Int? = nil
    /// Push/pull versions of one look share a family; `variant` names each ("−2" … "+2", "Normal").
    /// Precision of packed values (value / (2^bits − 1)); 16 when absent.
    public var bits: Int? = nil
    public var family: String? = nil
    public var variant: String? = nil
    public init(id:String,name:String,category:String,filename:String?,creator:String,source:String,license:String,checksum:String,description:String,
                tags:[String]? = nil,dimension:Int? = nil,offset:Int? = nil,length:Int? = nil,family:String? = nil,variant:String? = nil) {
        self.id = id; self.name = name; self.category = category; self.filename = filename; self.creator = creator; self.source = source
        self.license = license; self.checksum = checksum; self.description = description; self.tags = tags; self.dimension = dimension
        self.offset = offset; self.length = length; self.family = family; self.variant = variant
    }
    /// The name with its push/pull variant, for places that show one look on its own.
    public var displayName: String { variant.map { $0 == "Normal" ? name : "\(name) \($0)" } ?? name }
}
public struct LUTCatalog: Codable {
    public let version: Int
    public let revision: String?
    public let pack: String?
    public let entries: [LUTCatalogEntry]
}
public struct LUTItem: Equatable {
    public let entry: LUTCatalogEntry
    /// The `.cube` file, or the pack file for packed looks.
    public let url: URL
    public let isBundled: Bool
    public var isPacked: Bool { entry.offset != nil }
    public func load() throws -> CubeLUT {
        if isPacked { return try CubeLUT(text:LUTPack.cubeText(pack:url,entry:entry)) }
        if isBundled {
            let bytes = try Data(contentsOf:url)
            guard SHA256.hash(data:bytes).map({ String(format:"%02x",$0) }).joined() == entry.checksum else { throw LUTError.invalid }
        }
        return try CubeLUT.load(url)
    }
    /// Keep applied looks independent of library updates or removal of an imported file.
    public func applying(to edits:PhotoEdits, amount:Double = 0.7) throws -> PhotoEdits {
        _ = try load()
        let asset = try EditStorage.newAsset(extension:"cube")
        if isPacked { try Data(LUTPack.cubeText(pack:url,entry:entry).utf8).write(to:asset,options:.atomic) }
        else { try FileManager.default.copyItem(at:url,to:asset) }
        var next = edits; next.ensureAdvanced()
        next.advanced!.lutAsset = asset.lastPathComponent; next.advanced!.lutName = entry.displayName
        next.advanced!.lutID = entry.id; next.lutAmount = amount
        return next
    }
}
public struct LUTLibrary {
    /// Category order in the browser; bundled looks must use one of these.
    public static let bundledCategories = ["Film · Color","Film · Slide","Film · Instant","Film · Black & White","Cinematic","Moody",
        "Vintage & Faded","Portrait","Landscape & Nature","Seasons","City & Night","Vibrant","Creative","Black & White","Utility"]
    public static let licenses = ["CC0-1.0","CC-BY-SA-4.0"]
    public let items: [LUTItem]
    public init(bundled folder:URL, imported:URL) throws {
        let catalog = try JSONDecoder().decode(LUTCatalog.self,from:Data(contentsOf:folder.appendingPathComponent("catalog.json")))
        guard [1,2].contains(catalog.version), Set(catalog.entries.map(\.id)).count == catalog.entries.count else { throw LUTError.invalid }
        let pack = catalog.pack.map { folder.appendingPathComponent($0) }
        if let pack { guard catalog.pack == pack.lastPathComponent, FileManager.default.fileExists(atPath:pack.path) else { throw LUTError.invalid } }
        var result:[LUTItem] = []
        for entry in catalog.entries {
            guard !entry.name.isEmpty, !entry.creator.isEmpty, Self.licenses.contains(entry.license), entry.checksum.count == 64,
                  catalog.version == 1 || Self.bundledCategories.contains(entry.category) else { throw LUTError.invalid }
            if let filename = entry.filename {
                guard filename == URL(fileURLWithPath:filename).lastPathComponent, filename.hasSuffix(".cube") else { throw LUTError.invalid }
                result.append(LUTItem(entry:entry,url:folder.appendingPathComponent(filename),isBundled:true))
            } else {
                guard let pack, entry.offset != nil, entry.length != nil, entry.dimension != nil else { throw LUTError.invalid }
                result.append(LUTItem(entry:entry,url:pack,isBundled:true))
            }
        }
        self.items = result + Self.imports(at:imported)
    }
    public init(imported:URL) { items = Self.imports(at:imported) }
    private static func imports(at folder:URL) -> [LUTItem] {
        let files = ((try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "cube" }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let provenance = (try? Data(contentsOf:folder.appendingPathComponent("sources.json"))).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [[String:Any]] } ?? []
        return files.map { url in
            let name = url.deletingPathExtension().lastPathComponent
            let source = provenance.first { record in (record["name"] as? String).map { name == $0 || name.hasPrefix($0+" — ") } ?? false }
            let id = "imported-"+SHA256.hash(data:Data(url.lastPathComponent.utf8)).map { String(format:"%02x",$0) }.joined()
            let entry = LUTCatalogEntry(id:id,name:name,category:"Imported",filename:url.lastPathComponent,creator:source?["creator"] as? String ?? "Imported on this Mac",source:source?["source"] as? String ?? "",license:"Local import",checksum:"",description:"Your imported look. Adjust intensity to suit this photograph.")
            return LUTItem(entry:entry,url:url,isBundled:false)
        }
    }
    /// "All", the bundled categories in browser order, then "Imported" when there are imports.
    public var categories: [String] {
        let present = Set(items.map(\.entry.category))
        return ["All"] + Self.bundledCategories.filter(present.contains) + (present.subtracting(Self.bundledCategories).sorted())
    }
    public func filtered(_ category:String) -> [LUTItem] { category == "All" ? items : items.filter { $0.entry.category == category } }
    /// Case- and accent-insensitive match on name, category, tags and creator; every word must match.
    public func search(_ text:String, in items:[LUTItem]? = nil) -> [LUTItem] {
        let words = text.split(whereSeparator:\.isWhitespace).map { $0.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:nil) }
        guard !words.isEmpty else { return items ?? self.items }
        return (items ?? self.items).filter { item in
            let e = item.entry
            let hay = ([e.displayName,e.category,e.creator,e.description] + (e.tags ?? [])).joined(separator:" ").folding(options:[.caseInsensitive,.diacriticInsensitive],locale:nil)
            return words.allSatisfy { hay.contains($0) }
        }
    }
    /// All variants of the look's family in push/pull order (just the look when it has none).
    public func variants(of item:LUTItem) -> [LUTItem] {
        guard let family = item.entry.family else { return [item] }
        return items.filter { $0.entry.family == family }
    }
    /// One item per family, preferring the "Normal" variant, for grids that list looks rather than every variant.
    public func collapsed(_ items:[LUTItem]) -> [LUTItem] {
        var seen:[String:Int] = [:], result:[LUTItem] = []
        for item in items {
            guard let family = item.entry.family else { result.append(item); continue }
            if let index = seen[family] { if item.entry.variant == "Normal" { result[index] = item } }
            else { seen[family] = result.count; result.append(item) }
        }
        return result
    }
    public func selected(for edits:PhotoEdits) -> LUTItem? {
        guard edits.advanced?.lutAsset != nil else { return nil }
        if let id = edits.advanced?.lutID { return items.first { $0.entry.id == id } }
        return items.first { $0.entry.name == edits.advanced?.lutName }
    }
}

/// Thread-safe invalidation shared by background thumbnail work and its main-thread delivery.
public final class LUTPreviewGeneration {
    private let lock = NSLock()
    private var token = UUID()
    public init() {}
    @discardableResult public func begin() -> UUID { lock.lock();defer { lock.unlock() };token = UUID();return token }
    public func isCurrent(_ value:UUID) -> Bool { lock.lock();defer { lock.unlock() };return token == value }
}
