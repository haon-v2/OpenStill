import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import OpenStillCore

/// Editing speed (M19): screen-size rendering, shared decodes, and the caches that keep a slider drag from redoing work.
/// Timings print to the CI log; limits are loose so a slow runner doesn't fail them, and the comparisons check the shape.
@Suite(.serialized) final class RenderSpeedTests {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("speed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func seconds(_ label: String, _ body: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try body()
        let d = ContinuousClock.now - start
        let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        print("⏱ \(label): \(String(format: "%.3f", s)) s")
        return s
    }
    /// A 24 MP "decoded photo" held in memory, like a RAW decode, with some texture so the filters have work to do.
    func largeSource(width: Int = 6000, height: Int = 4000) throws -> CIImage {
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let gradient = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: CGFloat(width), y: CGFloat(height)),
                                                                    "inputColor0": CIColor(red: 0.05, green: 0.1, blue: 0.2), "inputColor1": CIColor(red: 0.9, green: 0.8, blue: 0.6)])!.outputImage!
        let mixed = noise.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.2, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.2, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0.2, w: 0)])
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: gradient]).cropped(to: noise.extent)
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        ModernRenderer.context.render(mixed, toBitmap: &pixels, rowBytes: width * 8, bounds: mixed.extent, format: .RGBA16, colorSpace: ModernRenderer.workingSpace)
        return CIImage(bitmapData: Data(bytes: pixels, count: pixels.count * 2), bytesPerRow: width * 8, size: CGSize(width: width, height: height), format: .RGBA16, colorSpace: ModernRenderer.workingSpace)
    }
    var typicalEdits: PhotoEdits {
        var e = PhotoEdits(); e.exposure = 0.3; e.contrast = 1.2; e.usesSmartContrast = true; e.clarity = 0.3; e.vibrance = 0.25; e.highlightsAmount = -0.4; e.shadowsAmount = 0.3
        return e
    }

    /// Renders every pixel of `image` (createCGImage alone may defer the work).
    func finish(_ image: CIImage) {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var pixels = [UInt16](repeating: 0, count: w * h * 4)
        ModernRenderer.context.render(image, toBitmap: &pixels, rowBytes: w * 8, bounds: image.extent, format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
    }
    @Test func screenSizeRenderIsMuchCheaperThanFullSize() throws {
        let source = try largeSource()
        let edits = typicalEdits
        var proxy = source
        _ = try seconds("make the screen-size copy (once per photo)") { proxy = try RenderCache.materialize(source) }
        #expect(max(proxy.extent.width, proxy.extent.height) == CGFloat(RenderCache.longEdge))
        // Warm the kernels at both sizes, then time a second run of each.
        finish(try ModernRenderer.process(proxy, edits: edits)); finish(try ModernRenderer.process(source, edits: edits))
        let full = try seconds("24 MP edit, full size (0.0.15 on every slider release)") { finish(try ModernRenderer.process(source, edits: edits)) }
        let screen = try seconds("24 MP edit from the screen-size copy (each frame while dragging)") { finish(try ModernRenderer.process(proxy, edits: edits)) }
        // As in the app: the whole-frame render measured the image once; the zoomed-in region reuses that.
        try RenderAnalysis.withKey("benchmark") { finish(try ModernRenderer.process(proxy, edits: edits)) }
        let region = try seconds("24 MP edit, 100% region of a 1600×1000 view") {
            try RenderAnalysis.withKey("benchmark") { finish(try ModernRenderer.process(source, edits: edits).cropped(to: CGRect(x: 2200, y: 1500, width: 1600, height: 1000))) }
        }
        // Timings depend on what else the machine is running (the suite runs in parallel), so they are printed, not
        // compared. What is checked is the work: a frame while dragging and a zoomed-in region are a fraction of the pixels.
        let frame = try ModernRenderer.process(proxy, edits: edits).extent, whole = try ModernRenderer.process(source, edits: edits).extent
        #expect(frame.width * frame.height < whole.width * whole.height / 2)
        #expect(1600 * 1000 < whole.width * whole.height / 10)
        #expect(screen < 30 && region < 60 && full < 120, "screen \(screen) s, region \(region) s, full \(full) s")
    }

    @Test func previewOpensWithoutTheFullReadback() throws {
        let source = try largeSource(width: 4000, height: 3000)
        var madeFull = 0
        let photo = DecodedPhoto(preview: try ModernRenderer.screenImage(source), pixelSize: source.extent.size, rendering: .original, sourceImage: source) {
            madeFull += 1; return try ModernRenderer.display(source)
        }
        #expect(max(photo.preview.width, photo.preview.height) == ModernRenderer.screenEdge)
        #expect(photo.pixelSize == CGSize(width: 4000, height: 3000))
        #expect(madeFull == 0, "opening must not build the full frame")
        #expect(photo.image.width == 4000 && photo.image.height == 3000)
        #expect(madeFull == 1, "the full frame is built once, when asked for")
        let small = try ModernRenderer.screenImage(source.cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600)))
        #expect(small.width == 800, "small images are never scaled up")
    }

    @Test func oneDecodeServesSmallerRequests() throws {
        let url = try writeJPEG(width: 640, height: 480)
        let full = try ModernRenderer.source(url, mode: .original, fast: true)
        let half = try ModernRenderer.source(url, mode: .original, halfSize: true, fast: true)
        let quality = try ModernRenderer.source(url, mode: .original, halfSize: true, fast: false)
        #expect(full === half && half === quality, "a decode already in memory is reused for smaller or quicker requests")
        let uncachedURL = try writeJPEG(width: 320, height: 240)
        let browsing = try ModernRenderer.source(uncachedURL, mode: .original, keep: false)
        let editing = try ModernRenderer.source(uncachedURL, mode: .original)
        #expect(browsing !== editing, "grid renders don't keep their decode")
    }

    @Test func wholeImageMeasurementsAreSharedBetweenRendersOfTheSameEdit() throws {
        var measured = 0
        let key = "photo|edits-1"
        let first = RenderAnalysis.withKey(key) { RenderAnalysis.pivot { measured += 1; return 0.42 } }
        let second = RenderAnalysis.withKey(key) { RenderAnalysis.pivot { measured += 1; return 0.99 } }
        #expect(first == 0.42 && second == 0.42 && measured == 1)
        _ = RenderAnalysis.withKey("photo|edits-2") { RenderAnalysis.pivot { measured += 1; return 0.5 } }
        _ = RenderAnalysis.pivot { measured += 1; return 0.5 }   // no key: always measured
        #expect(measured == 3)
        // The key follows the edits: changing a slider gives a new key.
        let url = try writeJPEG(width: 64, height: 48)
        var edits = PhotoEdits(); let a = RenderAnalysis.key(source: url, mode: .original, raw: RawSettings(), edits: edits)
        edits.exposure = 0.5; let b = RenderAnalysis.key(source: url, mode: .original, raw: RawSettings(), edits: edits)
        #expect(a != nil && a != b)
        // A Smart Contrast render with a key gives the same pixels as one without.
        var smart = PhotoEdits(); smart.contrast = 1.3; smart.usesSmartContrast = true
        let source = try ModernRenderer.readImage(url)
        let plain = try ModernRenderer.display(ModernRenderer.process(source, edits: smart))
        let cached = try RenderAnalysis.withKey("same-photo") { try ModernRenderer.display(ModernRenderer.process(source, edits: smart)) }
        let again = try RenderAnalysis.withKey("same-photo") { try ModernRenderer.display(ModernRenderer.process(source, edits: smart)) }
        #expect(pixels(plain) == pixels(cached) && pixels(cached) == pixels(again))
    }

    @Test func brushStrokesAreKeyedBySizeAndContent() throws {
        let stroke = MaskStroke(points: [MaskPoint(CGPoint(x: 0.2, y: 0.2)), MaskPoint(CGPoint(x: 0.6, y: 0.5))], radius: 0.05, subtract: false)
        let small = CGSize(width: 800, height: 600)
        #expect(MaskRasters.strokeKey(stroke, size: small) == MaskRasters.strokeKey(stroke, size: small))
        #expect(MaskRasters.strokeKey(stroke, size: small) != MaskRasters.strokeKey(stroke, size: CGSize(width: 1600, height: 1200)))
        var moved = stroke; moved.points.append(MaskPoint(CGPoint(x: 0.9, y: 0.9)))
        var softer = stroke; softer.softness = 0.5
        #expect(MaskRasters.strokeKey(moved, size: small) != MaskRasters.strokeKey(stroke, size: small))
        #expect(MaskRasters.strokeKey(softer, size: small) != MaskRasters.strokeKey(stroke, size: small))
    }

    @Test func cacheKeepsTheMostRecentlyUsedWithinItsBudget() {
        let cache = ByteLimitedCache<Int>(limit: 100)
        cache.insert(1, for: "a", bytes: 40); cache.insert(2, for: "b", bytes: 40)
        #expect(cache["a"] == 1)                       // "a" is now the most recently used
        cache.insert(3, for: "c", bytes: 40)           // over budget: the least recently used ("b") goes
        #expect(cache["a"] == 1 && cache["b"] == nil && cache["c"] == 3)
        cache.insert(4, for: "a", bytes: 90)           // replacing an entry frees its old bytes first
        #expect(cache["a"] == 4 && cache["c"] == nil)
        cache.insert(5, for: "huge", bytes: 500)       // one entry larger than the budget is still kept
        #expect(cache["huge"] == 5)
    }

    @Test func previewCacheReplacesOlderPreviewsWithoutListingTheFolderEachTime() throws {
        var record = PhotoRecord(source: URL(fileURLWithPath: "/Sample/IMG_0001.jpg"), fingerprint: "f", version: EditVersion(name: "Original", renderer: .linear2020, sourceMode: .original, document: EditDocument(fingerprint: "f")))
        let image = try ModernRenderer.display(CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16)))
        let first = RenderRequest(photo: record, maximumDimension: 420)
        PreviewCache.write(image, for: first, root: directory)
        PreviewCache.write(image, for: RenderRequest(photo: record, maximumDimension: 1024), root: directory)
        record.versions[0].revision = UUID()
        let second = RenderRequest(photo: record, maximumDimension: 420)
        PreviewCache.write(image, for: second, root: directory)
        let files = try FileManager.default.contentsOfDirectory(atPath: PreviewCache.directory(root: directory).path).sorted()
        #expect(files.count == 2, "the old 420 px preview is replaced; the 1024 px one stays: \(files)")
        #expect(PreviewCache.read(second, root: directory) != nil && PreviewCache.read(first, root: directory) == nil)
        let many = seconds("write 2,000 previews") {
            for _ in 0..<2000 {
                let r = PhotoRecord(source: URL(fileURLWithPath: "/Sample/\(UUID().uuidString).jpg"), fingerprint: "g", version: EditVersion(name: "Original", renderer: .linear2020, sourceMode: .original, document: EditDocument(fingerprint: "g")))
                PreviewCache.write(image, for: RenderRequest(photo: r, maximumDimension: 420), root: directory)
            }
        }
        #expect(many < 60)
    }

    @Test func recordSavesDecodeThePreviousVersionOnce() throws {
        let store = PhotoRecordStore(root: directory), file = try writeJPEG(width: 32, height: 24)
        var record = try store.record(for: file)
        var edits = PhotoEdits(); edits.exposure = 0.7
        let updated = try store.update(record.id) { saved in var document = saved.active.document; document.commit(edits, title: "Exposure"); saved.updateDocument(document) }
        record = try store.read(record.id)
        #expect(updated.active.document.current.exposure == 0.7 && record.active.document.current.exposure == 0.7)
        let recovery = directory.appendingPathComponent("Recovery/\(record.id.uuidString)/0.json")
        #expect(FileManager.default.fileExists(atPath: recovery.path), "the previous version is still kept for recovery")
    }

    // MARK: helpers
    func writeJPEG(width: Int, height: Int) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".jpg")
        let image = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: width, height: height)).applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.2, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.2, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0.2, w: 0)])])
        let cg = try ModernRenderer.display(image.cropped(to: CGRect(x: 0, y: 0, width: width, height: height)), profile: .sRGB)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg, nil); CGImageDestinationFinalize(destination)
        return url
    }
    func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }
}
