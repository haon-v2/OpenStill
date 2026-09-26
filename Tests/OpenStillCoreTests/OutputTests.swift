import Foundation
import CoreImage
import ImageIO
import AVFoundation
import Testing
@testable import OpenStillCore

@Suite struct OutputTests {
    func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenStill-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func flat(_ r: Double, _ g: Double, _ b: Double, _ w: Int, _ h: Int) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: ModernRenderer.workingSpace)!).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }
    func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> [Float] {
        var p = [Float](repeating: 0, count: 4)
        ModernRenderer.context.render(image, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: ModernRenderer.workingSpace)
        return p
    }
    /// Small JPEG photos on disk with library records, like photos opened in the library.
    func photos(_ count: Int, in folder: URL) throws -> [ShootItem] {
        let store = PhotoRecordStore(root: folder.appendingPathComponent("records"))
        return try (0..<count).map { i in
            let url = folder.appendingPathComponent("Photo \(i + 1).jpg")
            try ModernRenderer.export(flat(0.1 + 0.2 * Double(i), 0.4, 0.6, 300, 200), to: url, source: nil, settings: ExportSettings())
            return ShootItem(url: url, record: try store.record(for: url), captured: Date())
        }
    }

    /// A later edit of the active version.
    func bump(_ record: inout PhotoRecord) {
        if let i = record.versions.firstIndex(where: { $0.id == record.activeVersionID }) { record.versions[i].revision = UUID() }
    }

    // MARK: Print

    @Test func printLayoutsPlacePhotosOnPages() throws {
        var layout = PrintLayout()
        #expect(PrintLayoutEngine.cells(layout).count == 1)
        let single = PrintLayoutEngine.cells(layout)[0]
        #expect(abs(single.minX - 36) < 0.01 && abs(single.maxX - 576) < 0.01 && abs(single.maxY - 756) < 0.01)
        // A 3:2 landscape photo fills the width of a portrait page and is centred vertically.
        let fitted = PrintLayoutEngine.fit(CGSize(width: 3000, height: 2000), in: single, caption: false)
        #expect(abs(fitted.width - 540) < 0.01 && abs(fitted.height - 360) < 0.01 && abs(fitted.midY - single.midY) < 0.01)
        layout.style = .contactSheet
        #expect(layout.perPage == 24 && PrintLayoutEngine.cells(layout).count == 24)
        #expect(PrintLayoutEngine.pages(count: 50, layout: layout).map(\.count) == [24, 24, 2])
        layout.style = .grid; layout.rows = 2; layout.columns = 3; layout.landscape = true
        let cells = PrintLayoutEngine.cells(layout)
        #expect(cells.count == 6 && layout.pageSize == CGSize(width: 792, height: 612))
        // Row by row from the top, never overlapping.
        #expect(cells[0].minY > cells[3].maxY && cells[0].maxX <= cells[1].minX)
        layout.rows = 99; layout.margin = .nan; layout.dpi = 5
        #expect(layout.sanitized.rows == 12 && layout.sanitized.margin == 36 && layout.sanitized.dpi == 72)
    }

    @Test(.timeLimit(.minutes(1))) func printPDFAndJPEGPages() throws {
        let folder = try temp(); defer { try? FileManager.default.removeItem(at: folder) }
        let items = (0..<5).map { PrintItem(image: flat(0.8, 0.1, 0.1, 600, 400), filename: "IMG_\($0).jpg", title: $0 == 0 ? "Sample title" : "") }
        var layout = PrintLayout(); layout.style = .grid; layout.rows = 2; layout.columns = 2; layout.caption = .title; layout.dpi = 100
        let pdf = folder.appendingPathComponent("print.pdf")
        try PrintLayoutEngine.pdf(items, layout: layout, to: pdf)
        let document = try #require(CGPDFDocument(pdf as CFURL))
        #expect(document.numberOfPages == 2)
        let box = try #require(document.page(at: 1)?.getBoxRect(.mediaBox))
        #expect(box.size == CGSize(width: 612, height: 792))
        let pages = try PrintLayoutEngine.jpegs(items, layout: layout, to: folder)
        #expect(pages.map(\.lastPathComponent) == ["Print-1.jpg", "Print-2.jpg"])
        let page = try #require(CGImageSourceCreateWithURL(pages[0] as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(page.width == 850 && page.height == 1100)
        // The page is white paper with the photo printed in the first cell.
        let image = CIImage(cgImage: page)
        #expect(pixel(image, 5, 1095)[0] > 0.95 && pixel(image, 5, 1095)[1] > 0.95)
        let cell = PrintLayoutEngine.fit(CGSize(width: 600, height: 400), in: PrintLayoutEngine.cells(layout)[0], caption: true)
        let px = Int(cell.midX * 100 / 72), py = Int(cell.midY * 100 / 72)
        let inside = pixel(image, px, py)
        #expect(inside[0] > 0.5 && inside[1] < 0.2, "\(inside)")
    }

    @Test func printSharpeningScalesAndSharpens() {
        let edge = flat(0.2, 0.2, 0.2, 400, 400).composited(over: flat(0.8, 0.8, 0.8, 800, 400))
        var layout = PrintLayout(); layout.dpi = 144; layout.sharpening = .none
        // 2 × 1 inch at 144 dpi = 288 px long side.
        let plain = PrintLayoutEngine.prepare(edge, printedSize: CGSize(width: 144, height: 72), layout: layout)
        #expect(abs(plain.extent.width - 288) < 1.5)
        layout.sharpening = .high
        let sharp = PrintLayoutEngine.prepare(edge, printedSize: CGSize(width: 144, height: 72), layout: layout)
        // Sharpening overshoots on both sides of the edge (near x = 144): darker darks, brighter lights.
        let xs = 136..<152
        let before = xs.map { pixel(plain, $0, 72)[0] }, after = xs.map { pixel(sharp, $0, 72)[0] }
        #expect(after.min()! < before.min()! - 0.003 && after.max()! > before.max()! + 0.003, "\(before) → \(after)")
    }

    // MARK: Web gallery

    @Test(.timeLimit(.minutes(1))) func webGalleryIsSelfContained() throws {
        let folder = try temp(); defer { try? FileManager.default.removeItem(at: folder) }
        let items = try photos(3, in: folder)
        var gallery = (0..<3).map { GalleryItem(source: items[$0].url, recipe: items[$0].record.active.recipe) }
        gallery[0].title = "Dunes <at> dusk & \"sun\""; gallery[1].caption = "Second"
        var settings = WebGallerySettings(); settings.title = "Sample Studio"; settings.imageEdge = 240; settings.thumbnailEdge = 120
        let out = folder.appendingPathComponent("site", isDirectory: true)
        let index = try WebGallery.build(gallery, settings: settings, into: out)
        let html = try String(contentsOf: index, encoding: .utf8)
        #expect(html.contains("<title>Sample Studio</title>"))
        #expect(html.contains("Dunes &lt;at&gt; dusk &amp; &quot;sun&quot;") && !html.contains("<at>"))
        #expect(html.components(separatedBy: "<figure>").count - 1 == 3)
        #expect(!html.contains("http://") && !html.contains("https://"))   // no outside resources
        let names = try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("images").path).sorted()
        #expect(names == ["001-photo-1.jpg", "002-photo-2.jpg", "003-photo-3.jpg"])
        let thumb = try #require(CGImageSourceCreateWithURL(out.appendingPathComponent("thumbs/001-photo-1.jpg") as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let large = try #require(CGImageSourceCreateWithURL(out.appendingPathComponent("images/001-photo-1.jpg") as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(thumb.width == 120 && large.width == 300)   // photos are never enlarged
        // Building again replaces the images rather than adding to them.
        try WebGallery.build(Array(gallery.prefix(1)), settings: settings, into: out)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("images").path).count == 1)
        #expect(WebGallery.escape("a'b") == "a&#39;b")
    }

    // MARK: Slideshow

    @Test func slideshowFramesAndTransitions() {
        let size = CGSize(width: 320, height: 180)
        let red = flat(1, 0, 0, 400, 400), blue = flat(0, 0, 1, 600, 300)
        var s = SlideshowSettings(); s.kenBurns = false; s.secondsPerSlide = 2; s.transitionSeconds = 1; s.loop = false
        // A square photo is pillarboxed on black.
        let first = SlideshowRenderer.frame(at: 0.2, slides: [red, blue], settings: s, size: size)
        #expect(first.extent == CGRect(origin: .zero, size: size))
        #expect(pixel(first, 160, 90)[0] > 0.95 && pixel(first, 5, 90)[0] < 0.01)
        // Halfway through the crossfade both slides contribute.
        let mid = pixel(SlideshowRenderer.frame(at: 1.5, slides: [red, blue], settings: s, size: size), 160, 90)
        #expect(mid[0] > 0.2 && mid[0] < 0.8 && mid[2] > 0.2 && mid[2] < 0.8, "\(mid)")
        #expect(pixel(SlideshowRenderer.frame(at: 2.2, slides: [red, blue], settings: s, size: size), 160, 90)[2] > 0.95)
        // The last slide doesn't fade into anything unless the show loops.
        #expect(pixel(SlideshowRenderer.frame(at: 3.8, slides: [red, blue], settings: s, size: size), 160, 90)[2] > 0.95)
        s.transition = .fadeThroughBlack
        let dark = pixel(SlideshowRenderer.frame(at: 1.5, slides: [red, blue], settings: s, size: size), 160, 90)
        #expect(dark[0] < 0.05 && dark[2] < 0.05)
        s.transition = .cut
        #expect(pixel(SlideshowRenderer.frame(at: 1.9, slides: [red, blue], settings: s, size: size), 160, 90)[0] > 0.95)
        s.kenBurns = true
        let zoomed = SlideshowRenderer.frame(at: 1.9, slides: [red, blue], settings: s, size: size)
        #expect(zoomed.extent == CGRect(origin: .zero, size: size))
        s.secondsPerSlide = .infinity; s.width = 99_999
        #expect(s.sanitized.secondsPerSlide == 4 && s.sanitized.width == 3840 && s.duration(slides: 3) == 12)
    }

    /// Two seconds of a 440 Hz tone as 16-bit stereo WAV.
    func tone(_ url: URL, seconds: Double = 0.75) throws {
        let rate = 44_100, frames = Int(Double(rate) * seconds)
        var pcm = Data()
        for n in 0..<frames {
            let v = Int16(8000 * sin(2 * Double.pi * 440 * Double(n) / Double(rate)))
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0); pcm.append(contentsOf: $0) }
        }
        var wav = Data("RIFF".utf8)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { wav.append(contentsOf: $0) } }
        u32(36 + pcm.count); wav.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16)
        wav.append(Data("data".utf8)); u32(pcm.count); wav.append(pcm)
        try wav.write(to: url)
    }

    @Test(.timeLimit(.minutes(2))) func slideshowExportsVideoWithMusic() async throws {
        let folder = try temp(); defer { try? FileManager.default.removeItem(at: folder) }
        let music = folder.appendingPathComponent("tone.wav"); try tone(music)
        var s = SlideshowSettings(); s.width = 320; s.height = 180; s.fps = 12; s.secondsPerSlide = 1; s.transitionSeconds = 0.4; s.musicPath = music.path
        let movie = folder.appendingPathComponent("show.mov")
        try await SlideshowRenderer.exportVideo([flat(1, 0, 0, 800, 600), flat(0, 1, 0, 600, 800), flat(0, 0, 1, 500, 500)], settings: s, to: movie)
        let asset = AVURLAsset(url: movie)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        #expect(abs(duration - 3) < 0.25, "\(duration)")
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(video.count == 1 && audio.count == 1)
        let size = try #require(try await video.first?.load(.naturalSize))
        #expect(size == CGSize(width: 320, height: 180))
        // The 0.75 s tone loops to fill the show.
        let audioLength = CMTimeGetSeconds(try await audio[0].load(.timeRange).duration)
        #expect(audioLength > 2.5, "\(audioLength)")
        await #expect(throws: SlideshowError.self) { try await SlideshowRenderer.exportVideo([], settings: s, to: movie) }
    }

    // MARK: Publish

    @Test func oauthSignatureMatchesTheSpecExample() {
        // The worked example from the OAuth Core 1.0 specification (appendix A.5).
        let url = URL(string: "http://photos.example.net/photos?file=vacation.jpg&size=original")!
        let oauth = [("oauth_consumer_key", "dpf43f3p2l4k3l03"), ("oauth_token", "nnch734d00sl2jdk"), ("oauth_signature_method", "HMAC-SHA1"),
                     ("oauth_timestamp", "1191242096"), ("oauth_nonce", "kllo9940pd9333jh"), ("oauth_version", "1.0")]
        #expect(OAuth1.signature(method: "GET", url: url, parameters: oauth, consumerSecret: "kd94hf93k423kf44", tokenSecret: "pfkkdhi9sl3r4s00") == "tR3+Ty81lMeYAr/Fid0kMTYa/WM=")
        let credentials = OAuthCredentials(consumerKey: "dpf43f3p2l4k3l03", consumerSecret: "kd94hf93k423kf44", token: "nnch734d00sl2jdk", tokenSecret: "pfkkdhi9sl3r4s00")
        let header = OAuth1.header(method: "GET", url: url, credentials: credentials, nonce: "kllo9940pd9333jh", timestamp: "1191242096")
        #expect(header.hasPrefix("OAuth ") && header.contains("oauth_signature=\"tR3%2BTy81lMeYAr%2FFid0kMTYa%2FWM%3D\""))
        #expect(OAuth1.encode("a b&c=d/é~") == "a%20b%26c%3Dd%2F%C3%A9~")
        #expect(OAuth1.formDecode("oauth_token=ab%2Bc&oauth_token_secret=x&flag") == ["oauth_token": "ab+c", "oauth_token_secret": "x", "flag": ""])
    }

    @Test func collectionsTrackNewModifiedAndRemovedPhotos() throws {
        let folder = try temp(); defer { try? FileManager.default.removeItem(at: folder) }
        var record = PhotoRecord(source: URL(fileURLWithPath: "/fixtures/a.jpg"), fingerprint: "sha", version: EditVersion(name: "Main", renderer: .linear2020, sourceMode: .original, document: EditDocument(fingerprint: "stat")))
        var collection = PublishCollection(name: "Portfolio", kind: .folder)
        collection.add([record.id, record.id])
        #expect(collection.photos == [record.id] && collection.state(of: record) == .new)
        collection.published[record.id] = PublishedPhoto(remoteID: "a.jpg", versionID: record.active.id, revision: record.active.revision, date: Date())
        #expect(collection.state(of: record) == .published)
        bump(&record)
        #expect(collection.state(of: record) == .modified)
        collection.remove([record.id])
        #expect(collection.photos.isEmpty && collection.pendingRemoval.map(\.remoteID) == ["a.jpg"])
        try PublishStore.save([collection], root: folder)
        #expect(PublishStore.load(root: folder) == [collection])
        #expect(throws: PublishError.noFolder) { try PublishStore.service(for: collection) }
        var flickr = PublishCollection(name: "Flickr", kind: .flickr); flickr.id = UUID()
        #expect(throws: PublishError.notConnected) { try PublishStore.service(for: flickr) }
    }

    @Test(.timeLimit(.minutes(1))) func folderPublishingReplacesAndRemoves() async throws {
        let folder = try temp(); defer { try? FileManager.default.removeItem(at: folder) }
        var items = try photos(2, in: folder)
        let target = folder.appendingPathComponent("Published", isDirectory: true)
        var collection = PublishCollection(name: "Synced", kind: .folder); collection.folderPath = target.path; collection.export.longestEdge = 100
        collection.add(items.map(\.id))
        let service = try PublishStore.service(for: collection)
        var library = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let first = await Publisher.run(&collection, items: library, service: service)
        #expect(first.published == 2 && first.failures.isEmpty, "\(first.failures)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).sorted() == ["Photo 1.jpg", "Photo 2.jpg"])
        // Nothing changed: nothing to do.
        #expect(await Publisher.run(&collection, items: library, service: service).published == 0)
        // An edit republishes that photo in place.
        bump(&items[0].record); library[items[0].id] = items[0]
        #expect(collection.state(of: items[0].record) == .modified)
        #expect(await Publisher.run(&collection, items: library, service: service).published == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).sorted() == ["Photo 1.jpg", "Photo 2.jpg"])
        let written = try #require(CGImageSourceCreateWithURL(target.appendingPathComponent("Photo 1.jpg") as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(written.width == 100)
        // Taking a photo out of the collection removes its published copy.
        collection.remove([items[1].id])
        let last = await Publisher.run(&collection, items: library, service: service)
        #expect(last.removed == 1 && collection.pendingRemoval.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["Photo 1.jpg"])
    }
}
