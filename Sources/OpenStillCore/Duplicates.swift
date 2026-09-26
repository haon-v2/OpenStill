import Foundation
import Vision
import ImageIO

/// A set of photos that are the same or nearly the same.
public struct DuplicateGroup: Identifiable, Equatable {
    public enum Kind: String { case exact, similar }
    public let id = UUID()
    public var kind: Kind
    public var urls: [URL]
    /// Largest Vision feature-print distance inside the group (0 for exact copies).
    public var spread: Float = 0
    public static func == (a: Self, b: Self) -> Bool { a.kind == b.kind && a.urls == b.urls }
}

/// Finds exact copies (same SHA-256) and near-duplicates such as bursts and re-exports (Vision image feature prints).
/// Everything runs on this Mac; nothing is deleted.
public enum DuplicateFinder {
    /// Exact copies among these files, by size and then content hash.
    public static func exact(_ urls: [URL], cancelled: () -> Bool = { false }) -> [DuplicateGroup] {
        var bySize: [Int64: [URL]] = [:]
        for url in urls {
            let size = Int64((try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
            if size > 0 { bySize[size, default: []].append(url) }
        }
        var groups: [DuplicateGroup] = []
        for (_, same) in bySize where same.count > 1 {
            if cancelled() { break }
            var byHash: [String: [URL]] = [:]
            for url in same { if let hash = try? PhotoRecordStore.contentHash(url) { byHash[hash, default: []].append(url) } }
            for (_, copies) in byHash where copies.count > 1 { groups.append(DuplicateGroup(kind: .exact, urls: copies.sorted { $0.path < $1.path })) }
        }
        return groups.sorted { $0.urls[0].path < $1.urls[0].path }
    }

    /// A Vision feature print for a small rendition of the photo.
    public static func featurePrint(_ url: URL, maxPixelSize: Int = 512) -> VNFeaturePrintObservation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: maxPixelSize] as CFDictionary) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return nil }
        return request.results?.first
    }
    public static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        var d: Float = 0
        do { try a.computeDistance(&d, to: b) } catch { return nil }
        return d
    }

    /// Photos that look nearly the same. `threshold` is a feature-print distance: about 0.3 finds bursts and small edits,
    /// larger values also group similar compositions.
    public static func similar(_ urls: [URL], threshold: Float = 0.35, progress: (Int, Int) -> Void = { _, _ in }, cancelled: () -> Bool = { false }) -> [DuplicateGroup] {
        var prints: [(URL, VNFeaturePrintObservation)] = []
        for (i, url) in urls.enumerated() {
            if cancelled() { return [] }
            progress(i, urls.count)
            if let p = featurePrint(url) { prints.append((url, p)) }
        }
        progress(urls.count, urls.count)
        // Single-linkage clustering with union-find: any pair closer than the threshold joins the same group.
        var parent = Array(prints.indices)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        var closest: [Int: Float] = [:]
        for i in prints.indices {
            if cancelled() { return [] }
            for j in (i + 1)..<prints.count {
                guard let d = distance(prints[i].1, prints[j].1), d <= threshold else { continue }
                let a = root(i), b = root(j)
                if a != b { parent[b] = a }
                closest[i] = max(closest[i] ?? 0, d); closest[j] = max(closest[j] ?? 0, d)
            }
        }
        var clusters: [Int: [Int]] = [:]
        for i in prints.indices { clusters[root(i), default: []].append(i) }
        return clusters.values.filter { $0.count > 1 }.map { members in
            DuplicateGroup(kind: .similar, urls: members.map { prints[$0].0 }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending },
                           spread: members.compactMap { closest[$0] }.max() ?? 0)
        }.sorted { $0.urls[0].lastPathComponent.localizedStandardCompare($1.urls[0].lastPathComponent) == .orderedAscending }
    }

    /// The photo to keep in a group: the highest rated, then picked, then the largest file, then the first by name.
    public static func best(_ group: DuplicateGroup, records: [URL: PhotoRecord]) -> URL {
        group.urls.max { a, b in
            let ra = records[a], rb = records[b]
            let ka = ((ra?.rating ?? 0), ra?.flag == .pick ? 1 : 0, ra?.flag == .reject ? 0 : 1), kb = ((rb?.rating ?? 0), rb?.flag == .pick ? 1 : 0, rb?.flag == .reject ? 0 : 1)
            if ka != kb { return ka < kb }
            let sa = (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, sb = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if sa != sb { return sa < sb }
            return a.lastPathComponent > b.lastPathComponent
        } ?? group.urls[0]
    }
}
