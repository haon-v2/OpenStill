import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

/// Timings for a large library, printed so CI logs show them. Limits are generous so a slow CI machine doesn't fail them,
/// but they catch anything that becomes quadratic.
@Suite(.serialized) final class PerformanceTests {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("perf-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func time<T>(_ label: String, limit: Double, _ body: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        let result = try body()
        let d = ContinuousClock.now - start
        let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        print("⏱ \(label): \(String(format: "%.3f", seconds)) s")
        #expect(seconds < limit, "\(label) took \(seconds) s (limit \(limit) s)")
        return result
    }

    @Test func fiftyThousandPhotoLibrary() throws {
        let count = 50_000
        let cameras = ["Sample Camera A", "Sample Camera B", "Sample Camera C"], words = ["harbor", "portrait", "street", "forest", "wedding", "studio"]
        let start = Date(timeIntervalSince1970: 1_600_000_000)
        let records: [PhotoRecord] = time("create 50k records", limit: 60) {
            (0..<count).map { i in
                var r = PhotoRecord(source: URL(fileURLWithPath: "/Sample Library/\(i / 1000)/IMG_\(String(format: "%05d", i)).jpg"), fingerprint: String(format: "%064x", i),
                                    version: EditVersion(name: "Original", renderer: .linear2020, sourceMode: .original, document: EditDocument(fingerprint: String(i))))
                r.bookmark = nil; r.rating = i % 6; r.flag = i % 11 == 0 ? .pick : .none; r.colorLabel = i % 7 == 0 ? .green : .none
                var m = IPTCMetadata(); m.title = words[i % words.count] + " \(i)"; m.keywords = ["Places > Coast", words[(i / 3) % words.count]]; r.iptc = m
                return r
            }
        }
        let facts = records.enumerated().map { i, r -> CatalogPhoto in
            var p = CatalogPhoto(id: r.id, path: r.sourcePath)
            p.size = Int64(1_000_000 + i); p.modified = start.timeIntervalSince1970 + Double(i)
            p.captured = start.addingTimeInterval(Double(i) * 3600); p.camera = cameras[i % cameras.count]; p.lens = "Sample 35mm"
            p.iso = Double(100 << (i % 5)); p.width = 6000; p.height = 4000
            if i % 4 == 0 { p.latitude = 40 + Double(i % 100) / 100; p.longitude = -70 - Double(i % 50) / 100 }
            return p
        }
        let catalog = try LibraryCatalog(url: directory.appendingPathComponent("Catalog.sqlite"))
        try time("index 50k photos in the catalog", limit: 60) { try catalog.upsert(Array(zip(records, facts)).map { (record: $0.0, facts: $0.1) }) }
        #expect(catalog.photoCount == count)

        let all = time("read every catalog row", limit: 20) { catalog.photos() }
        #expect(all.count == count && all.first { $0.id == records[42].id }?.keywords.contains("Places > Coast") == true)
        let hits = time("text search over 50k", limit: 10) { all.filter { $0.matches(text: "harbor coast") } }
        #expect(hits.count == records.filter { $0.iptc.title.hasPrefix("harbor") || $0.iptc.keywords.contains("harbor") }.count && !hits.isEmpty)
        var rules = SmartRules(); rules.rules = [SmartRule.make(.rating, .atLeast, value: "4")!, SmartRule.make(.camera, .contains, value: "Camera B")!]
        let smart = time("smart collection rules over 50k", limit: 10) { all.filter(rules.matches) }
        #expect(!smart.isEmpty && smart.allSatisfy { $0.rating >= 4 && $0.camera.hasSuffix("B") })
        let keywords = time("keyword counts", limit: 10) { catalog.keywordCounts() }
        #expect(keywords.first { $0.0 == "Places" }?.1 == count)
        let timeline = time("timeline of 50k", limit: 10) { Timeline(all) }
        #expect(timeline.count == count)
        time("1,000 lookups by file facts", limit: 10) {
            for i in stride(from: 0, to: count, by: 50) {
                #expect(catalog.recordID(path: facts[i].path, size: facts[i].size, modified: facts[i].modified) == records[i].id)
            }
        }
        time("fetch 5,000 photos by id", limit: 10) { #expect(catalog.photos(ids: Set(records.prefix(5000).map(\.id))).count == 5000) }

        // The library view's filter and sort over the whole set.
        let items = records.enumerated().map { i, r in ShootItem(url: URL(fileURLWithPath: r.sourcePath), record: r, captured: facts[i].captured!, facts: facts[i]) }
        let rated = time("library filter + sort by capture date", limit: 20) { ShootWorkflow.filter(items, minimumRating: 3, flag: .all, sort: .captured) }
        #expect(rated.count == items.filter { $0.record.rating >= 3 }.count && rated.first!.captured <= rated.last!.captured)
        let named = time("library filter + sort by name", limit: 30) { ShootWorkflow.filter(items, minimumRating: 0, flag: .picks, sort: .filename, text: "portrait") }
        #expect(!named.isEmpty && named.allSatisfy { $0.record.flag == .pick })
    }

    @Test func faceGroupingScales() {
        // 5,000 faces of 50 people: grouping cost grows with faces × groups, not faces².
        var state: UInt64 = 7
        func next() -> Float { state = state &* 6364136223846793005 &+ 1442695040888963407; return Float(state >> 33) / Float(1 << 31) - 0.5 }
        let people = (0..<50).map { _ in FaceClustering.normalized((0..<128).map { _ in next() }) }
        let faces = (0..<5000).map { i in FaceClustering.normalized(zip(people[i % 50], (0..<128).map { _ in next() }).map { $0 + $1 * 0.05 }) }
        let labels = time("group 5,000 faces", limit: 20) { FaceClustering.cluster(faces, threshold: 0.6) }
        #expect(Set(labels).count == 50)
        for p in 0..<50 { #expect(Set(stride(from: p, to: 5000, by: 50).map { labels[$0] }).count == 1) }
    }

    @Test func pixelConversionsMatchTheSimpleLoops() throws {
        let w = 37, h = 5
        var rgb = [UInt16](repeating: 0, count: w * h * 3)
        for i in rgb.indices { rgb[i] = UInt16(truncatingIfNeeded: i &* 2654435761 >> 7) }
        let data = rgb.withUnsafeBufferPointer { PixelConversion.rgb16ToRGBA16($0.baseAddress!, width: w, height: h) }
        let rgba = data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        for i in 0..<(w * h) { #expect(Array(rgba[4*i..<4*i+4]) == [rgb[3*i], rgb[3*i+1], rgb[3*i+2], .max]) }

        var pixels: [Float] = (0..<(w * h)).flatMap { i -> [Float] in [Float(i % 5) * 0.3, 2.5, -0.25, Float(i % 4) / 3] }
        var expected = pixels
        for i in stride(from: 0, to: expected.count, by: 4) where expected[i+3] > 0 { for c in 0..<3 { expected[i+c] /= expected[i+3] } }
        PixelConversion.unpremultiply(&pixels, width: w, height: h)
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i+3] > 0 { for c in 0..<3 { #expect(abs(pixels[i+c] - expected[i+c]) < 1e-5) } }

        var straight: [Float] = (0..<(w * h)).flatMap { i -> [Float] in [0.5, 3, -1, Float(i % 5) * 0.4 - 0.2] }
        let ok = straight.withUnsafeMutableBufferPointer { PixelConversion.premultiplyValidating($0, width: w, height: h) }
        #expect(ok)
        for i in stride(from: 0, to: straight.count, by: 4) {
            let a = min(1, max(0, Float((i / 4) % 5) * 0.4 - 0.2))
            #expect(straight[i+3] == a && abs(straight[i] - 0.5 * a) < 1e-6 && abs(straight[i+1] - 3 * a) < 1e-6)
        }
        var bad: [Float] = [0.5, .nan, 0, 1] + [Float](repeating: 0.5, count: (w * h - 1) * 4)
        #expect(!bad.withUnsafeMutableBufferPointer { PixelConversion.premultiplyValidating($0, width: w, height: h) })
        var huge: [Float] = [Float](repeating: 3e38, count: w * h * 4)
        #expect(huge.withUnsafeMutableBufferPointer { PixelConversion.premultiplyValidating($0, width: w, height: h) })
    }

    @Test func rendererContextsAreShared() throws {
        // Only the app's few long-lived contexts exist, however many renders run (other tests render in parallel too).
        let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        for _ in 0..<5 { _ = try ModernRenderer.display(image) }
        #expect(RenderContexts.created >= 1 && RenderContexts.created <= 4)
    }
}
