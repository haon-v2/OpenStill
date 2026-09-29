import CoreImage
import CryptoKit
import Foundation

/// A RAW photo decoded once and kept at screen size, in memory and on disk, like Lightroom's Camera Raw cache.
/// Opening a photo seen before, and every screen-size render of it, starts from this proxy instead of running LibRaw
/// again; the full-size decode happens only when something needs every pixel (100% zoom, export, AI tools).
public enum RenderCache {
    public static let longEdge = ModernRenderer.screenEdge
    /// The disk budget; the oldest proxies are removed past it.
    public static var limitBytes: Int64 {
        get { let v = UserDefaults.standard.object(forKey: "OpenStillRenderCacheLimit") as? Int64; return v ?? 10 << 30 }
        set { UserDefaults.standard.set(max(1 << 30, newValue), forKey: "OpenStillRenderCacheLimit") }
    }
    public static func directory(root: URL = EditStorage.root) -> URL { root.appendingPathComponent("RenderCache", isDirectory: true) }
    public struct Proxy {
        public let image: CIImage
        /// The full decode's pixel size.
        public let fullSize: CGSize
        public let sensorClipped: Double?
    }
    private struct Info: Codable { var width: Double; var height: Double; var sensorClipped: Double? }
    private final class Box { let proxy: Proxy; init(_ p: Proxy) { proxy = p } }
    private static let memory: NSCache<NSString, Box> = { let c = NSCache<NSString, Box>(); c.totalCostLimit = 1 << 30; return c }()
    private static let lock = NSLock()
    private static let writer = DispatchQueue(label: "OpenStill.renderCache", qos: .utility)

    /// Whether this photo is developed from RAW, the case the cache is for (other formats decode quickly).
    public static func applies(_ url: URL, mode: SourceMode) -> Bool { mode == .raw && RawDecoder.isRAW(url) && FileManager.default.fileExists(atPath: url.path) }

    static func name(_ url: URL, mode: SourceMode, raw: RawSettings) -> String {
        let key = "\(EditStorage.fingerprint(url))|\(mode.rawValue)|\(raw.cacheKey)"
        return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// Whether a proxy is already made (browsing uses one if it exists but doesn't make new ones).
    public static func has(_ url: URL, mode: SourceMode, raw: RawSettings, root: URL = EditStorage.root) -> Bool {
        let name = name(url, mode: mode, raw: raw)
        return memory.object(forKey: name as NSString) != nil || FileManager.default.fileExists(atPath: directory(root: root).appendingPathComponent(name + ".json").path)
    }
    /// The proxy for a RAW photo: from memory, else from disk, else made from `decode` (the full decode) and saved.
    public static func proxy(_ url: URL, mode: SourceMode, raw: RawSettings, root: URL = EditStorage.root, decode: () throws -> (image: CIImage, sensorClipped: Double?)) throws -> Proxy {
        let name = name(url, mode: mode, raw: raw)
        if let known = memory.object(forKey: name as NSString) { return known.proxy }
        let folder = directory(root: root)
        let imageURL = folder.appendingPathComponent(name + ".tiff"), infoURL = folder.appendingPathComponent(name + ".json")
        if let data = try? Data(contentsOf: infoURL), let info = try? JSONDecoder().decode(Info.self, from: data),
           let image = CIImage(contentsOf: imageURL), !image.extent.isEmpty {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: imageURL.path)   // recently used
            let proxy = Proxy(image: image, fullSize: CGSize(width: info.width, height: info.height), sensorClipped: info.sensorClipped)
            memory.setObject(Box(proxy), forKey: name as NSString, cost: Int(image.extent.width * image.extent.height) * 8)
            return proxy
        }
        let (full, clipped) = try decode()
        let proxy = Proxy(image: try materialize(full), fullSize: full.extent.size, sensorClipped: clipped)
        memory.setObject(Box(proxy), forKey: name as NSString, cost: Int(proxy.image.extent.width * proxy.image.extent.height) * 8)
        let info = Info(width: Double(full.extent.width), height: Double(full.extent.height), sensorClipped: clipped)
        writer.async { save(proxy.image, info: info, image: imageURL, info: infoURL, folder: folder) }
        return proxy
    }
    /// Scales to the proxy size and renders into memory (half float, extended linear), so later renders start from pixels
    /// rather than from the decode and a resample.
    static func materialize(_ image: CIImage) throws -> CIImage {
        var image = image
        let longest = max(image.extent.width, image.extent.height)
        if longest > CGFloat(longEdge) {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: CGFloat(longEdge) / longest, kCIInputAspectRatioKey: 1])
        }
        let bounds = CGRect(x: 0, y: 0, width: image.extent.width.rounded(.down), height: image.extent.height.rounded(.down))
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)).cropped(to: bounds)
        let w = Int(bounds.width), h = Int(bounds.height)
        guard w > 0, h > 0 else { throw EditError.render }
        var data = Data(count: w * h * 8)
        data.withUnsafeMutableBytes { bytes in
            ModernRenderer.context.render(image, toBitmap: bytes.baseAddress!, rowBytes: w * 8, bounds: bounds, format: .RGBAh, colorSpace: ModernRenderer.workingSpace)
        }
        return CIImage(bitmapData: data, bytesPerRow: w * 8, size: bounds.size, format: .RGBAh, colorSpace: ModernRenderer.workingSpace)
    }
    private static func save(_ image: CIImage, info: Info, image imageURL: URL, info infoURL: URL, folder: URL) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(".writing-" + UUID().uuidString + ".tiff")
        do {
            try ModernRenderer.context.writeTIFFRepresentation(of: image, to: temp, format: .RGBAh, colorSpace: ModernRenderer.workingSpace)
            try? FileManager.default.removeItem(at: imageURL)
            try FileManager.default.moveItem(at: temp, to: imageURL)
            try JSONEncoder().encode(info).write(to: infoURL, options: .atomic)
        } catch { try? FileManager.default.removeItem(at: temp); return }
        prune(folder)
    }
    /// Removes the least recently used proxies past the limit.
    static func prune(_ folder: URL, limit: Int64 = limitBytes) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []).filter { $0.pathExtension == "tiff" }
        var entries = files.map { url -> (URL, Int64, Date) in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return (url, Int64(v?.fileSize ?? 0), v?.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > limit else { return }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > limit {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("json"))
            total -= size
        }
    }
    /// Disk space used, for Settings.
    public static func diskUsage(root: URL = EditStorage.root) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(root: root), includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    /// Empties the cache (Settings → Clear Cache). Photos decode again the next time they open.
    public static func clear(root: URL = EditStorage.root) {
        memory.removeAllObjects()
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory(root: root))
    }
}
