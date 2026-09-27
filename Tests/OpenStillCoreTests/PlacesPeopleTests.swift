import Foundation
import CoreImage
import ImageIO
import Testing
@testable import OpenStillCore

@Suite final class PlacesPeopleTests {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("places-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func photo(_ name: String, exif: [String: Any] = [:], gps: [String: Any]? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let context = try #require(CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        var props: [String: Any] = [:]
        if !exif.isEmpty { props[kCGImagePropertyExifDictionary as String] = exif }
        if let gps { props[kCGImagePropertyGPSDictionary as String] = gps }
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), props as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
    static let utc: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
    func date(_ s: String) -> Date { Self.utc.date(from: s)! }
    func vector(_ seed: Int, noise: Float = 0, dimension: Int = 64) -> [Float] {
        var state = UInt64(seed) &* 6364136223846793005 &+ 1442695040888963407
        func next() -> Float { state = state &* 6364136223846793005 &+ 1442695040888963407; return Float(state >> 33) / Float(1 << 31) - 0.5 }
        return (0..<dimension).map { _ in next() }
    }
    func near(_ base: [Float], _ seed: Int, amount: Float) -> [Float] {
        FaceClustering.normalized(zip(base, vector(seed)).map { $0 + $1 * amount })
    }

    // MARK: Locations

    @Test func locationsValidateAndConvert() throws {
        #expect(GeoLocation(latitude: 0, longitude: 0).valid == nil)
        #expect(GeoLocation(latitude: .nan, longitude: 2).valid == nil && GeoLocation(latitude: 91, longitude: 2).valid == nil)
        let paris = GeoLocation(latitude: 48.8566, longitude: 2.3522, altitude: 35), london = GeoLocation(latitude: 51.5074, longitude: -0.1278)
        #expect(abs(paris.distance(to: london) - 343_500) < 2_000)
        // EXIF GPS round trip, including the southern and western hemispheres and altitude below sea level.
        let south = GeoLocation(latitude: -33.8688, longitude: -70.6483, altitude: -12)
        let back = try #require(GeoLocation(gps: south.gpsProperties))
        #expect(abs(back.latitude - south.latitude) < 1e-9 && abs(back.longitude - south.longitude) < 1e-9 && back.altitude == -12)
        // XMP coordinates as Lightroom writes them.
        #expect(GeoLocation.xmpCoordinate(48.8566, positive: "N", negative: "S").hasSuffix("N"))
        let parsed = try #require(GeoLocation.parseXMPCoordinate(GeoLocation.xmpCoordinate(-70.6483, positive: "E", negative: "W")))
        #expect(abs(parsed + 70.6483) < 1e-6)
        #expect(abs(GeoLocation.parseXMPCoordinate("48,51,23.76N")! - 48.8566) < 1e-4)
        #expect(GeoLocation.parseXMPCoordinate("48.5") == 48.5 && GeoLocation.parseXMPCoordinate("north") == nil)
    }
    @Test func captureTimesUseTheFileOffset() throws {
        #expect(CaptureTime.parseOffset("+02:00") == 7200 && CaptureTime.parseOffset("-0530") == -19800 && CaptureTime.parseOffset("02:00") == nil)
        let withOffset = try photo("offset.jpg", exif: ["DateTimeOriginal": "2026:06:01 14:30:00", "OffsetTimeOriginal": "+02:00"])
        let time = try #require(CaptureTime.read(withOffset))
        #expect(time.wallClock == date("2026-06-01 14:30:00") && time.offset == 7200)
        #expect(time.utc(assumedOffset: -18000) == date("2026-06-01 12:30:00"))
        let plain = try #require(CaptureTime.read(try photo("plain.jpg", exif: ["DateTimeOriginal": "2026:06:01 14:30:00"])))
        #expect(plain.offset == nil && plain.utc(assumedOffset: -14400) == date("2026-06-01 18:30:00"))
    }
    @Test func gpxTracksInterpolateAndRespectGaps() throws {
        let gpx = """
        <?xml version="1.0"?><gpx version="1.1" creator="Sample Logger" xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg>
        <trkpt lat="48.0" lon="2.0"><ele>100</ele><time>2026-06-01T12:00:00Z</time></trkpt>
        <trkpt lat="48.1" lon="2.2"><ele>200</ele><time>2026-06-01T12:10:00.000Z</time></trkpt>
        <trkpt lat="48.2" lon="2.4"><time>2026-06-01T14:00:00Z</time></trkpt>
        <trkpt lat="bad" lon="2.4"><time>2026-06-01T14:05:00Z</time></trkpt>
        <trkpt lat="48.3" lon="2.5"></trkpt>
        </trkseg></trk></gpx>
        """
        let track = try GPXTrack.parse(Data(gpx.utf8))
        #expect(track.points.count == 3 && track.start == date("2026-06-01 12:00:00"))
        let mid = try #require(track.location(at: date("2026-06-01 12:05:00")))
        #expect(abs(mid.latitude - 48.05) < 1e-9 && abs(mid.longitude - 2.1) < 1e-9 && mid.altitude == 150)
        // Just past the end, within tolerance: the last point. Far outside the track: nothing.
        #expect(track.location(at: date("2026-06-01 14:01:00"))?.latitude == 48.2)
        #expect(track.location(at: date("2026-06-01 15:00:00")) == nil && track.location(at: date("2026-06-01 11:00:00")) == nil)
        // In the middle of a long gap (logger off): not guessed. Close to one side: that side.
        #expect(track.location(at: date("2026-06-01 13:00:00")) == nil)
        #expect(track.location(at: date("2026-06-01 12:11:00"))?.latitude == 48.1)
        // Matching photos: camera clock in local time (UTC+2) and running a minute slow.
        let id = UUID(), other = UUID()
        let matches = track.match([(id, CaptureTime(wallClock: date("2026-06-01 14:04:00"))), (other, CaptureTime(wallClock: date("2026-06-01 20:00:00")))],
                                  assumedOffset: 7200, clockCorrection: 60)
        #expect(abs((matches[id]?.latitude ?? 0) - 48.05) < 1e-9 && matches[other] == nil)
        #expect(throws: GPXError.self) { try GPXTrack.parse(Data("<gpx></gpx>".utf8)) }
        #expect(throws: GPXError.self) { try GPXTrack.parse(Data("not xml at all".utf8)) }
    }
    @Test func interpolationCrossesTheDateLine() throws {
        let t0 = date("2026-01-01 00:00:00")
        let track = GPXTrack(points: [.init(time: t0, location: GeoLocation(latitude: 10, longitude: 179)), .init(time: t0.addingTimeInterval(100), location: GeoLocation(latitude: 10, longitude: -179))])
        let lon = try #require(track.location(at: t0.addingTimeInterval(75))?.longitude)
        #expect(abs(lon - (-179.5)) < 1e-9)
    }
    @Test func geotagsFollowTheRecordIntoCatalogXMPAndExports() throws {
        let store = PhotoRecordStore(root: directory.appendingPathComponent("app"))
        let file = try photo("tagged.jpg", gps: [kCGImagePropertyGPSLatitude as String: 10.0, kCGImagePropertyGPSLatitudeRef as String: "N",
                                                 kCGImagePropertyGPSLongitude as String: 20.0, kCGImagePropertyGPSLongitudeRef as String: "E"])
        let catalog = try #require(store.catalog)
        let record = try store.record(for: file)
        #expect(catalog.photo(record.id)?.latitude == 10)
        let place = GeoLocation(latitude: 43.2965, longitude: 5.3698, altitude: 12)
        let updated = try store.update(record.id) { $0.geotag = place }
        #expect(catalog.photo(record.id)?.latitude == 43.2965 && catalog.photo(record.id)?.longitude == 5.3698)
        // Old records without a location still decode.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(updated)) as! [String: Any]
        json.removeValue(forKey: "location")
        #expect(try JSONDecoder().decode(PhotoRecord.self, from: JSONSerialization.data(withJSONObject: json)).geotag == nil)
        // XMP round trip.
        let xmp = try #require(XMPSidecar.parse(try XMPSidecar.xmpData(XMPMetadata(record: updated))))
        #expect(abs((xmp.location?.latitude ?? 0) - 43.2965) < 1e-6 && abs((xmp.location?.longitude ?? 0) - 5.3698) < 1e-6 && xmp.location?.altitude == 12)
        var fresh = try store.read(record.id); fresh.geotag = nil; xmp.apply(to: &fresh)
        #expect(abs((fresh.geotag?.latitude ?? 0) - 43.2965) < 1e-6)
        // Exports write the geotag only when keeping GPS.
        var settings = ExportSettings(); settings.keepMetadata = true; settings.keepGPS = true
        let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let out = directory.appendingPathComponent("export.jpg"), stripped = directory.appendingPathComponent("stripped.jpg")
        try ModernRenderer.export(image, to: out, source: file, settings: settings, location: updated.geotag)
        settings.keepGPS = false
        try ModernRenderer.export(image, to: stripped, source: file, settings: settings, location: updated.geotag)
        func gps(_ url: URL) -> GeoLocation? {
            let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as? [String: Any]
            return (props?[kCGImagePropertyGPSDictionary as String] as? [String: Any]).flatMap(GeoLocation.init(gps:))
        }
        #expect(abs((gps(out)?.latitude ?? 0) - 43.2965) < 1e-4 && gps(stripped) == nil)
    }

    // MARK: Timeline

    @Test func timelineGroupsByYearMonthAndDay() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
        let timeline = Timeline([(a, date("2025-12-31 23:50:00")), (b, date("2026-01-01 00:10:00")), (c, date("2026-01-01 09:00:00")),
                                 (d, nil), (e, date("2026-03-15 12:00:00"))])
        #expect(timeline.years.map(\.year) == [2026, 2025])
        #expect(timeline.years[0].months.map(\.month) == [3, 1])
        #expect(timeline.years[0].months[1].days.first?.photos == [b, c])
        #expect(timeline.years[1].count == 1 && timeline.undated == [d] && timeline.count == 5)
        #expect(timeline.years[0].months[1].days.first?.id == "2026-01-01")
        #expect(Timeline.title(year: 2026, month: 3).contains("2026"))
        #expect(Timeline([(UUID(), Date(timeIntervalSince1970: -3_000_000_000))]).undated.count == 1)
    }

    // MARK: Faces

    @Test func clusteringGroupsSimilarVectors() {
        let alice = FaceClustering.normalized(vector(1)), bob = FaceClustering.normalized(vector(2))
        #expect(FaceClustering.distance(alice, bob) > 1)
        let faces = (0..<5).map { near(alice, 100 + $0, amount: 0.1) } + (0..<3).map { near(bob, 200 + $0, amount: 0.1) } + [FaceClustering.normalized(vector(3))]
        let labels = FaceClustering.cluster(faces, threshold: 0.6)
        #expect(Set(labels[0..<5]).count == 1 && Set(labels[5..<8]).count == 1)
        #expect(labels[0] == 0 && labels[5] == 1 && labels[8] == 2)
        #expect(FaceClustering.cluster([]).isEmpty)
        #expect(FaceClustering.distance([1, 0], [1, 0, 0]) == .infinity)
        let centre = FaceClustering.centroid([alice, alice]) ?? []
        #expect(FaceClustering.distance(centre, alice) < 1e-5)
    }
    @Test func facesArePeopleInTheCatalog() throws {
        let store = PhotoRecordStore(root: directory.appendingPathComponent("people"))
        let catalog = try #require(store.catalog)
        let alice = FaceClustering.normalized(vector(11)), bob = FaceClustering.normalized(vector(12))
        var photos: [PhotoRecord] = []
        for i in 0..<4 { photos.append(try store.record(for: try photo("p\(i).jpg", exif: ["DateTimeOriginal": "2026:0\(i + 1):02 10:00:00"]))) }
        // Two photos of Alice, one of Bob, one with both.
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.3), right = CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.3)
        try catalog.replaceFaces(for: photos[0].id, fingerprint: photos[0].contentFingerprint, [DetectedFace(rect: rect, print: near(alice, 1, amount: 0.1))])
        try catalog.replaceFaces(for: photos[1].id, fingerprint: photos[1].contentFingerprint, [DetectedFace(rect: rect, print: near(alice, 2, amount: 0.1))])
        try catalog.replaceFaces(for: photos[2].id, fingerprint: photos[2].contentFingerprint, [DetectedFace(rect: rect, print: near(bob, 3, amount: 0.1))])
        try catalog.replaceFaces(for: photos[3].id, fingerprint: photos[3].contentFingerprint,
                                 [DetectedFace(rect: rect, print: near(alice, 4, amount: 0.1)), DetectedFace(rect: right, print: near(bob, 5, amount: 0.1))])
        #expect(catalog.faceCount == 5 && !catalog.needsFaceScan(photos[0].id, fingerprint: photos[0].contentFingerprint))
        #expect(catalog.needsFaceScan(photos[0].id, fingerprint: "changed"))
        let stored = catalog.faces(photo: photos[3].id)
        #expect(stored.count == 2 && abs(stored[0].rect.minX - 0.1) < 1e-9 && stored[0].print.count == 64)

        try catalog.updateFaceClusters(threshold: 0.6)
        let groups = catalog.unnamedGroups()
        #expect(groups.map(\.count) == [3, 2])

        // Name the Alice group; the fourth photo's Alice face is suggested once only one face is named.
        let person = try catalog.person(named: "  Sample Person ")
        #expect(try catalog.person(named: "sample person").id == person.id)
        let aliceFaces = groups[0]
        try catalog.assign([aliceFaces[0].id], to: person.id)
        let suggested = catalog.suggestions(for: person.id, threshold: 0.6)
        #expect(Set(suggested.map(\.face.id)) == Set(aliceFaces.dropFirst().map(\.id)))
        // "Not this person" removes it from suggestions for good.
        try catalog.reject([suggested[0].face.id], from: person.id)
        #expect(!catalog.suggestions(for: person.id, threshold: 0.6).contains { $0.face.id == suggested[0].face.id })
        try catalog.assign(aliceFaces.map(\.id), to: person.id)
        #expect(catalog.people().first?.faceCount == 3 && catalog.people().first?.photoCount == 3)
        #expect(Set(catalog.photos(with: person.id)) == Set([photos[0].id, photos[1].id, photos[3].id]))

        // Keywords follow the names.
        #expect(try PeopleKeywords.sync(photos[3].id, catalog: catalog, store: store)?.iptc.keywords == ["People > Sample Person"])
        #expect(try PeopleKeywords.sync(photos[3].id, catalog: catalog, store: store) == nil)
        try catalog.renamePerson(person.id, to: "Renamed Person")
        #expect(try PeopleKeywords.sync(photos[3].id, catalog: catalog, store: store)?.iptc.keywords == ["People > Renamed Person"])
        #expect(catalog.photos(ids: [photos[3].id]).first?.keywords.contains("People > Renamed Person") == true)

        // A rescan keeps the name on a face in the same place.
        try catalog.replaceFaces(for: photos[3].id, fingerprint: "new", [DetectedFace(rect: rect.offsetBy(dx: 0.01, dy: 0), print: near(alice, 6, amount: 0.1))])
        #expect(catalog.faces(photo: photos[3].id).first?.personID == person.id)
        // Deleting the person unnames the faces; removing a photo removes its faces.
        try catalog.deletePerson(person.id)
        #expect(catalog.people().isEmpty && catalog.faces(unnamed: true).count == catalog.faceCount)
        try catalog.remove(photos[2].id)
        #expect(catalog.faces(photo: photos[2].id).isEmpty)
    }
    @Test func noFacesInAPlainPhoto() throws {
        #expect(FaceDetector.detect(try photo("plain-face.jpg")).isEmpty)
    }

    // MARK: Tethering

    @Test func tetheredShotsAreNamedInSequenceAndDeveloped() throws {
        let store = PhotoRecordStore(root: directory.appendingPathComponent("tether"))
        var session = TetherSession(name: "Studio: portraits/test", parent: directory.appendingPathComponent("Sessions"), started: date("2026-09-27 12:00:00"))
        #expect(session.folder.lastPathComponent == "2026-09-27 Studio- portraits-test")
        #expect(TetherSession.clean("..hidden") == "hidden" && TetherSession.clean("   ") == "Session")
        let first = try session.destination(for: "IMG_0001.CR3")
        #expect(first.lastPathComponent == "Studio- portraits-test-0001.CR3")
        try FileManager.default.copyItem(at: try photo("shot.jpg"), to: first)
        #expect(try session.destination(for: "IMG_0002.JPG").lastPathComponent == "Studio- portraits-test-0002.JPG")
        var preset = PhotoEdits(); preset.exposure = 0.7
        session.developPreset = preset; session.developPresetName = "Studio"
        var meta = IPTCMetadata(); meta.creator = "Sample Studio"; session.metadata = meta
        let record = try session.ingest(first, store: store)
        #expect(record.active.document.current.exposure == 0.7 && record.iptc.creator == "Sample Studio")
        #expect(record.active.document.steps.last?.title == "Studio")
    }
}
