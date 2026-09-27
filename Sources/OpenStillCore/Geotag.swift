import Foundation
import ImageIO

/// A place on Earth, in degrees (WGS 84), with an optional altitude in metres.
public struct GeoLocation: Codable, Equatable, Sendable {
    public var latitude: Double, longitude: Double
    public var altitude: Double?
    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude; self.longitude = longitude; self.altitude = altitude
    }
    /// Nil for NaN, infinities and anything outside ±90° / ±180°; (0, 0) is treated as "no fix", as most cameras write it.
    public var valid: GeoLocation? {
        guard latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180, latitude != 0 || longitude != 0 else { return nil }
        var g = self; if let a = altitude, !a.isFinite || abs(a) > 100_000 { g.altitude = nil }
        return g
    }
    /// Great-circle distance in metres.
    public func distance(to other: GeoLocation) -> Double {
        let r = 6_371_000.0, p1 = latitude * .pi / 180, p2 = other.latitude * .pi / 180
        let dp = p2 - p1, dl = (other.longitude - longitude) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    /// The EXIF GPS dictionary ImageIO writes into exported files.
    public var gpsProperties: [String: Any] {
        var gps: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(latitude), kCGImagePropertyGPSLatitudeRef as String: latitude < 0 ? "S" : "N",
            kCGImagePropertyGPSLongitude as String: abs(longitude), kCGImagePropertyGPSLongitudeRef as String: longitude < 0 ? "W" : "E",
            kCGImagePropertyGPSVersion as String: [2, 3, 0, 0]
        ]
        if let altitude { gps[kCGImagePropertyGPSAltitude as String] = abs(altitude); gps[kCGImagePropertyGPSAltitudeRef as String] = altitude < 0 ? 1 : 0 }
        return gps
    }
    /// Reads an ImageIO GPS dictionary (as found in a photo's properties).
    public init?(gps: [String: Any]) {
        func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }
        guard let lat = number(gps[kCGImagePropertyGPSLatitude as String]), let lon = number(gps[kCGImagePropertyGPSLongitude as String]) else { return nil }
        var g = GeoLocation(latitude: (gps[kCGImagePropertyGPSLatitudeRef as String] as? String)?.uppercased() == "S" ? -lat : lat,
                            longitude: (gps[kCGImagePropertyGPSLongitudeRef as String] as? String)?.uppercased() == "W" ? -lon : lon)
        if let alt = number(gps[kCGImagePropertyGPSAltitude as String]) { g.altitude = (number(gps[kCGImagePropertyGPSAltitudeRef as String]) ?? 0) == 1 ? -alt : alt }
        guard let valid = g.valid else { return nil }
        self = valid
    }

    /// XMP's form, e.g. "48,51.3960N" (degrees, decimal minutes, hemisphere), as Lightroom writes `exif:GPSLatitude`.
    public static func xmpCoordinate(_ value: Double, positive: Character, negative: Character) -> String {
        let a = abs(value), degrees = Int(a), minutes = (a - Double(degrees)) * 60
        return "\(degrees)," + String(format: "%.6f", minutes) + String(value < 0 ? negative : positive)
    }
    /// Parses "48,51.396N", "48,51,23.76N" or a signed decimal "48.8566".
    public static func parseXMPCoordinate(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard !s.isEmpty else { return nil }
        var sign = 1.0
        if let last = s.last, "NSEW".contains(last) { if last == "S" || last == "W" { sign = -1 }; s.removeLast() }
        let parts = s.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0!.isFinite }) else { return nil }
        let v = parts.map { $0! }
        let value = v[0] + (v.count > 1 ? v[1] / 60 : 0) + (v.count > 2 ? v[2] / 3600 : 0)
        return value < 0 ? value : sign * value
    }
}

extension PhotoRecord {
    /// Where the photo was taken: a location set in OpenStill, else nil (the file's own GPS lives in the catalog facts).
    public var geotag: GeoLocation? { get { location?.valid } set { location = newValue?.valid } }
}

// MARK: - Capture time

/// When a photo was taken, as the camera recorded it.
public struct CaptureTime: Equatable, Sendable {
    /// The camera's clock reading, stored as if it were UTC (the convention the catalog uses for capture dates).
    public var wallClock: Date
    /// The camera's offset from UTC in seconds, when the file records it (EXIF OffsetTimeOriginal).
    public var offset: TimeInterval?
    public init(wallClock: Date, offset: TimeInterval? = nil) { self.wallClock = wallClock; self.offset = offset }
    /// The actual moment, using the file's own offset, else `assumedOffset`.
    public func utc(assumedOffset: TimeInterval) -> Date { wallClock.addingTimeInterval(-(offset ?? assumedOffset)) }

    public static func read(_ url: URL) -> CaptureTime? {
        guard let io = CGImageSourceCreateWithURL(url as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(io, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] else { return nil }
        return parse(exif)
    }
    static func parse(_ exif: [String: Any]) -> CaptureTime? {
        guard let stamp = exif["DateTimeOriginal"] as? String ?? exif["DateTimeDigitized"] as? String else { return nil }
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.timeZone = TimeZone(secondsFromGMT: 0); parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard var date = parser.date(from: stamp) else { return nil }
        if let sub = (exif["SubsecTimeOriginal"] as? String).flatMap({ Double("0." + $0.filter(\.isNumber)) }) { date.addTimeInterval(sub) }
        return CaptureTime(wallClock: date, offset: (exif["OffsetTimeOriginal"] as? String ?? exif["OffsetTime"] as? String).flatMap(parseOffset))
    }
    /// "+02:00" / "-0530" → seconds.
    public static func parseOffset(_ text: String) -> TimeInterval? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard let sign = s.first, sign == "+" || sign == "-" else { return nil }
        let digits = s.dropFirst().filter(\.isNumber)
        guard digits.count == 4, let h = Int(digits.prefix(2)), let m = Int(digits.suffix(2)), h <= 14, m < 60 else { return nil }
        return Double(h * 3600 + m * 60) * (sign == "-" ? -1 : 1)
    }
}

// MARK: - GPX tracks

public enum GPXError: LocalizedError {
    case unreadable, empty
    public var errorDescription: String? {
        switch self {
        case .unreadable: return "The GPX file couldn’t be read."
        case .empty: return "The GPX file has no track points with times."
        }
    }
}

/// A GPS log (GPX 1.0/1.1) from a phone, watch or logger, used to geotag photos by capture time.
public struct GPXTrack: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public var time: Date
        public var location: GeoLocation
        public init(time: Date, location: GeoLocation) { self.time = time; self.location = location }
    }
    /// Sorted by time; points without a time or position are dropped.
    public private(set) var points: [Point]
    public init(points: [Point]) { self.points = points.sorted { $0.time < $1.time } }
    public var start: Date? { points.first?.time }
    public var end: Date? { points.last?.time }

    public static func read(_ url: URL) throws -> GPXTrack { try parse(Data(contentsOf: url)) }
    public static func parse(_ data: Data) throws -> GPXTrack {
        let delegate = GPXParser(), parser = XMLParser(data: data)
        parser.delegate = delegate; parser.shouldResolveExternalEntities = false
        guard parser.parse() || !delegate.points.isEmpty else { throw GPXError.unreadable }
        guard !delegate.points.isEmpty else { throw GPXError.empty }
        return GPXTrack(points: delegate.points)
    }

    /// The position at `time` (UTC): interpolated between the two surrounding points when they are at most `maxGap` seconds apart,
    /// or the nearest end of the track within `tolerance` seconds. Nil when the track doesn't cover the moment.
    public func location(at time: Date, maxGap: TimeInterval = 600, tolerance: TimeInterval = 120) -> GeoLocation? {
        guard let first = points.first, let last = points.last else { return nil }
        if time <= first.time { return first.time.timeIntervalSince(time) <= tolerance ? first.location : nil }
        if time >= last.time { return time.timeIntervalSince(last.time) <= tolerance ? last.location : nil }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if points[mid].time <= time { lo = mid } else { hi = mid } }
        let a = points[lo], b = points[hi], span = b.time.timeIntervalSince(a.time)
        if span <= 0 { return a.location }
        if span > maxGap {
            // A gap in the log (tunnel, logger off): only trust a point close to one side.
            let da = time.timeIntervalSince(a.time), db = b.time.timeIntervalSince(time)
            return min(da, db) <= tolerance ? (da <= db ? a.location : b.location) : nil
        }
        let f = time.timeIntervalSince(a.time) / span
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
        var lonB = b.location.longitude
        if lonB - a.location.longitude > 180 { lonB -= 360 } else if a.location.longitude - lonB > 180 { lonB += 360 }
        var lon = mix(a.location.longitude, lonB); if lon > 180 { lon -= 360 } else if lon < -180 { lon += 360 }
        let alt: Double? = { if let x = a.location.altitude, let y = b.location.altitude { return mix(x, y) }; return a.location.altitude ?? b.location.altitude }()
        return GeoLocation(latitude: mix(a.location.latitude, b.location.latitude), longitude: lon, altitude: alt)
    }

    /// Positions for photos from their capture times. `assumedOffset` is the camera clock's offset from UTC when a file doesn't record it;
    /// `clockCorrection` is added to the camera clock (for a camera that was a few minutes off).
    public func match(_ photos: [(id: UUID, time: CaptureTime)], assumedOffset: TimeInterval, clockCorrection: TimeInterval = 0,
                      maxGap: TimeInterval = 600, tolerance: TimeInterval = 120) -> [UUID: GeoLocation] {
        var out: [UUID: GeoLocation] = [:]
        for photo in photos {
            let moment = photo.time.utc(assumedOffset: assumedOffset).addingTimeInterval(clockCorrection)
            if let g = location(at: moment, maxGap: maxGap, tolerance: tolerance) { out[photo.id] = g }
        }
        return out
    }
}

private final class GPXParser: NSObject, XMLParserDelegate {
    var points: [GPXTrack.Point] = []
    private var lat: Double?, lon: Double?, ele: Double?, time: Date?
    private var inPoint = false, text = ""
    private let iso = ISO8601DateFormatter(), isoFraction: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        if local == "trkpt" || local == "rtept" {
            inPoint = true; lat = attributes["lat"].flatMap(Double.init); lon = attributes["lon"].flatMap(Double.init); ele = nil; time = nil
        }
        text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inPoint { text += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        guard inPoint else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch local {
        case "ele": ele = Double(value)
        case "time": time = iso.date(from: value) ?? isoFraction.date(from: value)
        case "trkpt", "rtept":
            inPoint = false
            if let lat, let lon, let time, let g = GeoLocation(latitude: lat, longitude: lon, altitude: ele).valid { points.append(.init(time: time, location: g)) }
        default: break
        }
        text = ""
    }
}
