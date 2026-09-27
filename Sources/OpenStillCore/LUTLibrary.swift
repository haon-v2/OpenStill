import Foundation
import CryptoKit

public struct LUTCatalogEntry: Codable, Equatable {
    public let id: String
    public let name: String
    public let category: String
    public let filename: String
    public let creator: String
    public let source: String
    public let license: String
    public let checksum: String
    public let description: String
}
public struct LUTCatalog: Codable {
    public let version: Int
    public let revision: String
    public let entries: [LUTCatalogEntry]
}
public struct LUTItem: Equatable {
    public let entry: LUTCatalogEntry
    public let url: URL
    public let isBundled: Bool
    public func load() throws -> CubeLUT {
        if isBundled {
            let bytes = try Data(contentsOf:url)
            guard SHA256.hash(data:bytes).map({ String(format:"%02x",$0) }).joined() == entry.checksum else { throw LUTError.invalid }
        }
        return try CubeLUT.load(url)
    }
    /// Keep applied looks independent of library updates or removal of an imported file.
    public func applying(to edits:PhotoEdits) throws -> PhotoEdits {
        _ = try load()
        let asset = try EditStorage.newAsset(extension:"cube")
        try FileManager.default.copyItem(at:url,to:asset)
        var next = edits; next.ensureAdvanced()
        next.advanced!.lutAsset = asset.lastPathComponent; next.advanced!.lutName = entry.name
        next.advanced!.lutID = entry.id; next.lutAmount = 0.7
        return next
    }
}
public struct LUTLibrary {
    public static let categories = ["All","Portraits","Cityscape & Street","Automotive","Nature & Landscape","Imported"]
    public let items: [LUTItem]
    public init(bundled folder:URL, imported:URL) throws {
        let catalog = try JSONDecoder().decode(LUTCatalog.self,from:Data(contentsOf:folder.appendingPathComponent("catalog.json")))
        guard catalog.version == 1, Set(catalog.entries.map(\.id)).count == catalog.entries.count else { throw LUTError.invalid }
        var result:[LUTItem] = []
        for entry in catalog.entries {
            guard entry.filename == URL(fileURLWithPath:entry.filename).lastPathComponent,
                  entry.filename.hasSuffix(".cube"), Self.categories[1...4].contains(entry.category), entry.license == "CC0-1.0",
                  entry.checksum.count == 64 else { throw LUTError.invalid }
            result.append(LUTItem(entry:entry,url:folder.appendingPathComponent(entry.filename),isBundled:true))
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
    public func filtered(_ category:String) -> [LUTItem] { category == "All" ? items : items.filter { $0.entry.category == category } }
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
