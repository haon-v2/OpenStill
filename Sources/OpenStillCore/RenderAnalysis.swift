import CoreImage
import Foundation

/// Measurements that need the whole picture upstream of a tool: Smart Contrast's middle tone and Auto Enhance's analysis.
/// They depend on the photo and its edits, not on the render size, so the renders that share both (the whole frame, then
/// the zoomed-in detail, the mask overlay, an export) measure once. Like darktable's per-module cache, but only for the
/// two steps that force a full render of everything before them.
enum RenderAnalysis {
    private static let cache = ByteLimitedCache<Any>(limit: 64)   // one "byte" per entry: the last 64 measurements
    private static let threadKey = "OpenStill.RenderAnalysis.key"
    /// Runs `body` with measurements cached under `key` (nil: measure every time).
    static func withKey<T>(_ key: String?, _ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[threadKey]
        dictionary[threadKey] = key
        defer { dictionary[threadKey] = previous }
        return try body()
    }
    private static var current: String? { Thread.current.threadDictionary[threadKey] as? String }
    static func pivot(_ measure: () -> Double) -> Double {
        guard let key = current.map({ $0 + "|pivot" }) else { return measure() }
        if let known = cache[key] as? Double { return known }
        let value = measure()
        cache.insert(value, for: key, bytes: 1)
        return value
    }
    /// Auto Enhance's filters, analysed once; each render gets its own copies (filters aren't shared across threads).
    static func enhanceFilters(_ analyse: () -> [CIFilter]) -> [CIFilter] {
        guard let key = current.map({ $0 + "|enhance" }) else { return analyse() }
        if let known = cache[key] as? [CIFilter] { return known.compactMap { $0.copy() as? CIFilter } }
        let filters = analyse()
        cache.insert(filters.compactMap { $0.copy() as? CIFilter }, for: key, bytes: 1)
        return filters
    }
    /// A key for one photo with one set of edits.
    static func key(source: URL, mode: SourceMode, raw: RawSettings, edits: PhotoEdits) -> String? {
        guard let data = try? JSONEncoder().encode(edits) else { return nil }
        var hasher = Hasher(); hasher.combine(data)
        return "\(source.standardizedFileURL.path)|\(EditStorage.fingerprint(source))|\(mode.rawValue)|\(raw.cacheKey)|\(hasher.finalize())"
    }
}
