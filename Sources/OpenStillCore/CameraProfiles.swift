import Foundation
import CoreImage

/// OpenStill's own starting looks. They are not copies of any camera maker's or Adobe's profiles.
public enum ProfileLook: String, Codable, CaseIterable, Sendable {
    case standard, neutral, vivid, portrait, landscape, monochrome
    public var title: String { rawValue.capitalized }
}
public struct ProfileSettings: Codable, Equatable, Sendable {
    public var look: ProfileLook = .standard
    /// 0…2. Blends between no profile and a stronger version of it.
    public var amount = 1.0
    /// An imported DNG Camera Profile (.dcp) stored with the edit assets. Replaces `look` when set.
    public var dcpAsset: String?
    public var dcpName: String?
    public init() {}
    public var sanitized: Self { var s = self; s.amount = amount.isFinite ? min(2, max(0, amount)) : 1; return s }
    public var hasEffect: Bool { let s = sanitized; return s.amount > 0 && (s.dcpAsset != nil || s.look != .standard) }
}
/// Primary hue and saturation, like a camera calibration panel. Hues move each primary around the color wheel
/// (positive: red → yellow, green → cyan, blue → magenta); saturation scales its purity.
public struct CalibrationSettings: Codable, Equatable, Sendable {
    public var shadowsTint = 0.0
    public var redHue = 0.0, redSaturation = 0.0
    public var greenHue = 0.0, greenSaturation = 0.0
    public var blueHue = 0.0, blueSaturation = 0.0
    public init() {}
    public var sanitized: Self {
        func c(_ x: Double) -> Double { x.isFinite ? min(1, max(-1, x)) : 0 }
        var s = self
        s.shadowsTint = c(shadowsTint); s.redHue = c(redHue); s.redSaturation = c(redSaturation)
        s.greenHue = c(greenHue); s.greenSaturation = c(greenSaturation); s.blueHue = c(blueHue); s.blueSaturation = c(blueSaturation)
        return s
    }
    public var hasEffect: Bool { sanitized != CalibrationSettings() }
    /// Row-major 3×3 in linear Rec.2020 that keeps neutrals neutral.
    public var matrix: [Double] {
        let s = sanitized, luma = [0.2627, 0.6780, 0.0593]
        // Column j is where primary j goes. A hue shift leaks it toward its neighbor on the wheel.
        let hues = [s.redHue, s.greenHue, s.blueHue], sats = [s.redSaturation, s.greenSaturation, s.blueSaturation]
        var columns: [[Double]] = []
        for j in 0..<3 {
            var col = [0.0, 0.0, 0.0]; col[j] = 1
            let forward = (j+1) % 3, backward = (j+2) % 3
            if hues[j] > 0 { col[forward] += hues[j]*0.35 } else { col[backward] += -hues[j]*0.35 }
            let y = zip(col, luma).map(*).reduce(0, +)
            col = col.map { y + ($0 - y)*(1 + sats[j]*0.6) }
            columns.append(col)
        }
        var m = (0..<9).map { columns[$0 % 3][$0 / 3] }
        for row in 0..<3 {
            let sum = m[row*3] + m[row*3+1] + m[row*3+2]
            if abs(sum) > 1e-6 { for k in 0..<3 { m[row*3+k] /= sum } }
        }
        return m
    }
}
public enum RawDemosaic: String, Codable, CaseIterable, Sendable {
    case ahd, aahd, dcb, dht, vng, ppg, linear
    public var title: String {
        switch self { case .ahd: return "AHD (default)"; case .aahd: return "AAHD"; case .dcb: return "DCB"; case .dht: return "DHT"; case .vng: return "VNG"; case .ppg: return "PPG"; case .linear: return "Bilinear (fast)" }
    }
    /// LibRaw `user_qual`.
    public var libraw: Int32 { switch self { case .linear: return 0; case .vng: return 1; case .ppg: return 2; case .ahd: return 3; case .dcb: return 4; case .dht: return 11; case .aahd: return 12 } }
}
/// LibRaw decoding choices for RAW sources.
public struct RawOptions: Codable, Equatable, Hashable, Sendable {
    public var demosaic: RawDemosaic = .ahd
    /// 0…1, LibRaw's wavelet luminance denoise before demosaicing.
    public var noise = 0.0
    /// 0…3 median passes after demosaicing, which clean up color noise and maze artifacts.
    public var colorNoise = 0
    /// 0 off, 1 light, 2 full FBDD impulse noise reduction.
    public var impulseNoise = 0
    public init() {}
    public var sanitized: Self {
        var s = self
        s.noise = noise.isFinite ? min(1, max(0, noise)) : 0
        s.colorNoise = min(3, max(0, colorNoise)); s.impulseNoise = min(2, max(0, impulseNoise))
        return s
    }
    public var isDefault: Bool { sanitized == RawOptions() }
    var waveletThreshold: Float { Float(sanitized.noise * 500) }
}

extension PhotoEdits {
    public var profile: ProfileSettings {
        get { advanced?.profile ?? ProfileSettings() }
        set { let s = newValue.sanitized; if s == ProfileSettings() && advanced == nil { return }; ensureAdvanced(); advanced!.profile = s == ProfileSettings() ? nil : s }
    }
    public var profileAmount: Double { get { profile.amount } set { profile.amount = newValue } }
    public var calibration: CalibrationSettings {
        get { advanced?.calibration ?? CalibrationSettings() }
        set { let s = newValue.sanitized; if !s.hasEffect && advanced == nil { return }; ensureAdvanced(); advanced!.calibration = s.hasEffect ? s : nil }
    }
    public var calibrationShadowsTint: Double { get { calibration.shadowsTint } set { calibration.shadowsTint = newValue } }
    public var calibrationRedHue: Double { get { calibration.redHue } set { calibration.redHue = newValue } }
    public var calibrationRedSaturation: Double { get { calibration.redSaturation } set { calibration.redSaturation = newValue } }
    public var calibrationGreenHue: Double { get { calibration.greenHue } set { calibration.greenHue = newValue } }
    public var calibrationGreenSaturation: Double { get { calibration.greenSaturation } set { calibration.greenSaturation = newValue } }
    public var calibrationBlueHue: Double { get { calibration.blueHue } set { calibration.blueHue = newValue } }
    public var calibrationBlueSaturation: Double { get { calibration.blueSaturation } set { calibration.blueSaturation = newValue } }
    public var rawOptions: RawOptions {
        get { advanced?.rawOptions ?? RawOptions() }
        set { let s = newValue.sanitized; if s.isDefault && advanced == nil { return }; ensureAdvanced(); advanced!.rawOptions = s.isDefault ? nil : s }
    }
    public var rawNoise: Double { get { rawOptions.noise } set { rawOptions.noise = newValue } }
}

// MARK: - DNG Camera Profiles

public enum DCPError: LocalizedError, Equatable {
    case unreadable, noLook
    public var errorDescription: String? {
        switch self {
        case .unreadable: return "This isn’t a readable DNG Camera Profile (.dcp)."
        case .noLook: return "This profile has only color matrices. OpenStill applies a profile’s hue/saturation map, look table and tone curve, and this one has none of them."
        }
    }
}
/// The parts of a DCP that describe its look. OpenStill decodes RAW files with LibRaw's camera matrices, so the
/// profile's own ColorMatrix/ForwardMatrix are not used; its HueSatMap, LookTable and tone curve are applied in
/// linear ProPhoto RGB, as the DNG specification describes.
public struct DNGCameraProfile: Equatable {
    public struct HSVTable: Equatable {
        public var hues: Int, sats: Int, vals: Int
        /// (hue shift in degrees, saturation scale, value scale) per entry, value-major then hue then saturation.
        public var data: [Float]
        public var srgbEncoded = false
        var isValid: Bool { hues >= 1 && sats >= 2 && vals >= 1 && data.count == hues*sats*vals*3 && data.allSatisfy(\.isFinite) }
    }
    public var name: String?
    public var hueSatMap: HSVTable?
    public var lookTable: HSVTable?
    /// (x, y) pairs on 0…1.
    public var toneCurve: [(Double, Double)]?
    public static func == (a: Self, b: Self) -> Bool {
        a.name == b.name && a.hueSatMap == b.hueSatMap && a.lookTable == b.lookTable
            && (a.toneCurve?.map { [$0.0, $0.1] } ?? []) == (b.toneCurve?.map { [$0.0, $0.1] } ?? [])
    }

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { throw DCPError.unreadable }
        let little: Bool
        switch (bytes[0], bytes[1]) { case (0x49, 0x49): little = true; case (0x4D, 0x4D): little = false; default: throw DCPError.unreadable }
        func u16(_ o: Int) -> Int? { guard o >= 0, o+2 <= bytes.count else { return nil }; return little ? Int(bytes[o]) | Int(bytes[o+1]) << 8 : Int(bytes[o]) << 8 | Int(bytes[o+1]) }
        func u32(_ o: Int) -> Int? { guard o >= 0, o+4 <= bytes.count else { return nil }; let b = (0..<4).map { Int(bytes[o+$0]) }; return little ? b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24 : b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3] }
        guard let magic = u16(2), magic == 0x4352 || magic == 42, let ifd = u32(4), let count = u16(ifd), count < 4096 else { throw DCPError.unreadable }
        struct Entry { let type: Int, count: Int, offset: Int }
        var entries: [Int: Entry] = [:]
        let sizes = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 9: 4, 10: 8, 11: 4, 12: 8]
        for i in 0..<count {
            let e = ifd + 2 + i*12
            guard let tag = u16(e), let type = u16(e+2), let n = u32(e+4), let size = sizes[type], n <= 10_000_000 else { continue }
            let offset = n*size <= 4 ? e+8 : (u32(e+8) ?? -1)
            guard offset >= 0, offset + n*size <= bytes.count else { continue }
            entries[tag] = Entry(type: type, count: n, offset: offset)
        }
        func numbers(_ tag: Int) -> [Double]? {
            guard let e = entries[tag] else { return nil }
            return (0..<e.count).compactMap { i -> Double? in
                switch e.type {
                case 3: return u16(e.offset + i*2).map(Double.init)
                case 4: return u32(e.offset + i*4).map(Double.init)
                case 9: return u32(e.offset + i*4).map { Double(Int32(truncatingIfNeeded: $0)) }
                case 11: return u32(e.offset + i*4).map { Double(Float(bitPattern: UInt32($0))) }
                case 5, 10:
                    guard let n = u32(e.offset + i*8), let d = u32(e.offset + i*8 + 4), d != 0 else { return nil }
                    return e.type == 10 ? Double(Int32(truncatingIfNeeded: n))/Double(Int32(truncatingIfNeeded: d)) : Double(n)/Double(d)
                case 12:
                    guard let a = u32(e.offset + i*8), let b = u32(e.offset + i*8 + 4) else { return nil }
                    let bits = little ? UInt64(UInt32(b)) << 32 | UInt64(UInt32(a)) : UInt64(UInt32(a)) << 32 | UInt64(UInt32(b))
                    return Double(bitPattern: bits)
                default: return nil
                }
            }
        }
        if let e = entries[50936], e.type == 2 || e.type == 1 {
            let raw = bytes[e.offset..<(e.offset + e.count)].prefix { $0 != 0 }
            name = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if name?.isEmpty == true { name = nil }
        }
        func table(dims: Int, data tags: [Int], encoding: Int) -> HSVTable? {
            guard let d = numbers(dims), d.count >= 2 else { return nil }
            let hues = Int(d[0]), sats = Int(d[1]), vals = d.count > 2 ? max(1, Int(d[2])) : 1
            guard hues > 0, sats > 0, hues*sats*vals <= 1_000_000 else { return nil }
            for tag in tags {
                if let values = numbers(tag) {
                    let t = HSVTable(hues: hues, sats: sats, vals: vals, data: values.map(Float.init), srgbEncoded: numbers(encoding)?.first == 1)
                    if t.isValid { return t }
                }
            }
            return nil
        }
        // With two calibrations prefer the daylight-like one (D65 = 21, D55 = 20, D50 = 23, daylight = 1).
        let daylight: Set<Double> = [1, 20, 21, 23]
        let secondIsDaylight = numbers(50779)?.first.map { daylight.contains($0) } ?? false
        hueSatMap = table(dims: 50937, data: secondIsDaylight ? [50939, 50938] : [50938, 50939], encoding: 51107)
        lookTable = table(dims: 50981, data: [50982], encoding: 51108)
        if let curve = numbers(50940), curve.count >= 4, curve.count % 2 == 0 {
            let pairs = stride(from: 0, to: curve.count, by: 2).map { (curve[$0], curve[$0+1]) }
            if pairs.allSatisfy({ $0.0.isFinite && $0.1.isFinite }) { toneCurve = pairs.sorted { $0.0 < $1.0 } }
        }
        guard hueSatMap != nil || lookTable != nil || toneCurve != nil else { throw DCPError.noLook }
    }

    /// Applies the look to one linear ProPhoto RGB value.
    func apply(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        var c = rgb
        if let hueSatMap { c = Self.apply(hueSatMap, c) }
        if let lookTable { c = Self.apply(lookTable, c) }
        if let toneCurve { c = Self.tone(c, curve: toneCurve) }
        return c
    }
    static func apply(_ t: HSVTable, _ rgb: SIMD3<Double>) -> SIMD3<Double> {
        var (h, s, v) = hsv(rgb)
        guard v > 0 else { return rgb }
        // Hue wraps; saturation and value are clamped to the table.
        let hs = t.hues > 1 ? h/6*Double(t.hues) : 0
        let ss = s*Double(t.sats-1)
        var vIndex = min(1, v)
        if t.srgbEncoded { vIndex = vIndex <= 0.0031308 ? vIndex*12.92 : 1.055*pow(vIndex, 1/2.4) - 0.055 }
        let vs = vIndex*Double(max(0, t.vals-1))
        let h0 = Int(floor(hs)) % max(1, t.hues), h1 = (h0+1) % max(1, t.hues), hf = hs - floor(hs)
        let s0 = min(t.sats-2, max(0, Int(ss))), sf = min(1, max(0, ss - Double(s0)))
        let v0 = t.vals > 1 ? min(t.vals-2, max(0, Int(vs))) : 0, vf = t.vals > 1 ? min(1, max(0, vs - Double(v0))) : 0
        func entry(_ hi: Int, _ si: Int, _ vi: Int) -> SIMD3<Double> {
            let i = ((vi*t.hues + hi)*t.sats + si)*3
            return SIMD3(Double(t.data[i]), Double(t.data[i+1]), Double(t.data[i+2]))
        }
        func atValue(_ vi: Int) -> SIMD3<Double> {
            let a = entry(h0, s0, vi)*(1-sf) + entry(h0, s0+1, vi)*sf
            let b = entry(h1, s0, vi)*(1-sf) + entry(h1, s0+1, vi)*sf
            return a*(1-hf) + b*hf
        }
        let e = t.vals > 1 ? atValue(v0)*(1-vf) + atValue(v0+1)*vf : atValue(0)
        h += e.x*6/360; h = h.truncatingRemainder(dividingBy: 6); if h < 0 { h += 6 }
        s = min(1, max(0, s*e.y)); v *= e.z
        return rgbFrom(h, s, v)
    }
    static func hsv(_ c: SIMD3<Double>) -> (Double, Double, Double) {
        let maxV = max(c.x, c.y, c.z), minV = min(c.x, c.y, c.z), delta = maxV - minV
        guard maxV > 0 else { return (0, 0, 0) }
        var h = 0.0
        if delta > 0 {
            if maxV == c.x { h = (c.y - c.z)/delta } else if maxV == c.y { h = 2 + (c.z - c.x)/delta } else { h = 4 + (c.x - c.y)/delta }
            if h < 0 { h += 6 }
        }
        return (h, delta/maxV, maxV)
    }
    static func rgbFrom(_ h: Double, _ s: Double, _ v: Double) -> SIMD3<Double> {
        let i = Int(floor(h)) % 6, f = h - floor(h), p = v*(1-s), q = v*(1-s*f), t = v*(1-s*(1-f))
        switch i { case 0: return SIMD3(v, t, p); case 1: return SIMD3(q, v, p); case 2: return SIMD3(p, v, t); case 3: return SIMD3(p, q, v); case 4: return SIMD3(t, p, v); default: return SIMD3(v, p, q) }
    }
    /// Hue-preserving RGB tone: the curve sets the largest and smallest channels, the middle one keeps its place between.
    static func tone(_ c: SIMD3<Double>, curve: [(Double, Double)]) -> SIMD3<Double> {
        func f(_ x: Double) -> Double {
            if x >= 1 { return x - 1 + (curve.last?.1 ?? 1) }
            if x <= 0 { return x }
            guard let upper = curve.firstIndex(where: { $0.0 >= x }) else { return curve.last?.1 ?? x }
            if upper == 0 { return curve[0].1 * x / max(curve[0].0, 1e-9) }
            let a = curve[upper-1], b = curve[upper], span = b.0 - a.0
            return span <= 0 ? b.1 : a.1 + (b.1 - a.1)*(x - a.0)/span
        }
        var v = [c.x, c.y, c.z]
        let order = [0, 1, 2].sorted { v[$0] < v[$1] }
        let lo = v[order[0]], mid = v[order[1]], hi = v[order[2]]
        let newLo = f(lo), newHi = f(hi)
        let newMid = hi > lo ? newLo + (newHi - newLo)*(mid - lo)/(hi - lo) : f(mid)
        v[order[0]] = newLo; v[order[1]] = newMid; v[order[2]] = newHi
        return SIMD3(v[0], v[1], v[2])
    }
}

// MARK: - Rendering

public enum CameraProfiles {
    /// Linear light up to this level passes through the profile LUT (about two stops above white); brighter values clip there.
    static let headroom = 4.0
    static let dimension = 33
    /// Linear Rec.2020 → linear ProPhoto (D65-adapted, rows).
    static let toProPhoto: [Double] = [0.8617, 0.0788, 0.0595, 0.0264, 0.9540, 0.0196, -0.0044, 0.0132, 0.9912]
    static let fromProPhoto: [Double] = { invert(toProPhoto) }()
    static func invert(_ m: [Double]) -> [Double] {
        let c0 = m[4]*m[8]-m[5]*m[7], c1 = m[5]*m[6]-m[3]*m[8], c2 = m[3]*m[7]-m[4]*m[6], det = m[0]*c0 + m[1]*c1 + m[2]*c2
        return [c0, m[2]*m[7]-m[1]*m[8], m[1]*m[5]-m[2]*m[4], c1, m[0]*m[8]-m[2]*m[6], m[2]*m[3]-m[0]*m[5], c2, m[1]*m[6]-m[0]*m[7], m[0]*m[4]-m[1]*m[3]].map { $0/det }
    }
    private static let cache: NSCache<NSString, NSData> = { let c = NSCache<NSString, NSData>(); c.countLimit = 8; return c }()
    private static let dcpCache: NSCache<NSString, DCPBox> = { let c = NSCache<NSString, DCPBox>(); c.countLimit = 8; return c }()
    private final class DCPBox { let value: DNGCameraProfile; init(_ v: DNGCameraProfile) { value = v } }

    public static func loadDCP(_ url: URL) throws -> DNGCameraProfile {
        let key = (url.path + EditStorage.fingerprint(url)) as NSString
        if let cached = dcpCache.object(forKey: key) { return cached.value }
        let data = try Data(contentsOf: url)
        guard data.count < 64_000_000 else { throw DCPError.unreadable }
        let profile = try DNGCameraProfile(data: data); dcpCache.setObject(DCPBox(profile), forKey: key); return profile
    }

    /// A built-in look applied to one linear ProPhoto value.
    static func look(_ look: ProfileLook, _ c: SIMD3<Double>) -> SIMD3<Double> {
        let weights = SIMD3(0.2880, 0.7119, 0.0001)
        var contrast = 0.0, saturation = 1.0, warmth = 0.0, mono = false
        switch look {
        case .standard: return c
        case .neutral: contrast = -0.6; saturation = 0.9
        case .vivid: contrast = 0.8; saturation = 1.28
        case .portrait: contrast = -0.25; saturation = 0.95; warmth = 0.025
        case .landscape: contrast = 0.5; saturation = 1.18; warmth = -0.01
        case .monochrome: contrast = 0.35; mono = true
        }
        var rgb = c
        if mono { let y = (rgb*SIMD3(0.33, 0.56, 0.11)).sum(); rgb = SIMD3(repeating: y) }
        let y = (rgb*weights).sum()
        if y > 1e-6 {
            // S-curve in a perceptual encoding that keeps black, white and brighter-than-white where they are.
            let p = pow(y, 1/2.2)
            let q = p < 1 ? p + contrast*(p - 0.5)*p*(1 - p)*1.6 : p
            rgb *= pow(max(0, q), 2.2)/y
        }
        if saturation != 1 { let yy = (rgb*weights).sum(); rgb = SIMD3(repeating: yy) + (rgb - SIMD3(repeating: yy))*saturation }
        if warmth != 0 {
            let before = (rgb*weights).sum(); rgb.x *= 1 + warmth; rgb.z *= 1 - warmth
            let after = (rgb*weights).sum(); if after > 1e-9 { rgb *= before/after }
        }
        return rgb
    }

    /// Cube data over encoded ProPhoto (value = headroom·e^2.2), mapping each grid point through `transform`.
    static func bake(_ transform: (SIMD3<Double>) -> SIMD3<Double>) -> Data {
        let n = dimension
        var values = [Float](); values.reserveCapacity(n*n*n*4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let e = SIMD3(Double(r), Double(g), Double(b))/Double(n-1)
            let linear = SIMD3(pow(e.x, 2.2), pow(e.y, 2.2), pow(e.z, 2.2))*headroom
            var out = transform(linear)/headroom
            out = SIMD3(max(0, out.x), max(0, out.y), max(0, out.z))
            values += [Float(pow(out.x, 1/2.2)), Float(pow(out.y, 1/2.2)), Float(pow(out.z, 1/2.2)), 1]
        } } }
        return values.withUnsafeBytes { Data($0) }
    }
    static func cube(_ settings: ProfileSettings) throws -> Data? {
        let key: String
        let transform: (SIMD3<Double>) -> SIMD3<Double>
        if let asset = settings.dcpAsset {
            let url = EditStorage.asset(asset), profile = try loadDCP(url)
            key = "dcp:" + url.lastPathComponent + EditStorage.fingerprint(url); transform = profile.apply
        } else {
            guard settings.look != .standard else { return nil }
            key = "look:" + settings.look.rawValue; let look = settings.look; transform = { Self.look(look, $0) }
        }
        if let cached = cache.object(forKey: key as NSString) { return cached as Data }
        let data = bake(transform); cache.setObject(data as NSData, forKey: key as NSString); return data
    }

    private static let encode = CIColorKernel(source: """
    kernel vec4 profileEncode(__sample c, vec3 r0, vec3 r1, vec3 r2, float headroom) {
        vec3 p = vec3(dot(r0, c.rgb), dot(r1, c.rgb), dot(r2, c.rgb)) / headroom;
        return vec4(pow(clamp(p, 0.0, 1.0), vec3(1.0/2.2)), c.a);
    }
    """)
    private static let decode = CIColorKernel(source: """
    kernel vec4 profileDecode(__sample profiled, __sample original, vec3 r0, vec3 r1, vec3 r2, float headroom, float amount) {
        vec3 p = pow(max(profiled.rgb, vec3(0.0)), vec3(2.2)) * headroom;
        vec3 rgb = vec3(dot(r0, p), dot(r1, p), dot(r2, p));
        rgb = mix(original.rgb, rgb, amount);
        return vec4(rgb, original.a);
    }
    """)
    private static let calibrate = CIColorKernel(source: """
    kernel vec4 calibrate(__sample c, vec3 r0, vec3 r1, vec3 r2, float tint) {
        vec3 rgb = vec3(dot(r0, c.rgb), dot(r1, c.rgb), dot(r2, c.rgb));
        float y = dot(rgb, vec3(0.2627, 0.6780, 0.0593));
        float shadow = 1.0 - smoothstep(0.0, 0.2, y);
        rgb *= vec3(1.0 + tint*0.08*shadow, 1.0 - tint*0.12*shadow, 1.0 + tint*0.08*shadow);
        return vec4(rgb, c.a);
    }
    """)
    static func vectors(_ m: [Double]) -> [CIVector] { (0..<3).map { CIVector(x: m[$0*3], y: m[$0*3+1], z: m[$0*3+2]) } }

    /// Calibration, then the profile look. Both are global (no masks) and run right after the source is decoded.
    public static func apply(_ image: CIImage, profile: ProfileSettings, calibration: CalibrationSettings) throws -> CIImage {
        var result = image
        let extent = image.extent
        if calibration.hasEffect {
            guard let out = calibrate?.apply(extent: extent, arguments: ([result] as [Any]) + vectors(calibration.matrix) + [calibration.sanitized.shadowsTint]) else { throw EditError.render }
            result = out
        }
        let profile = profile.sanitized
        if profile.hasEffect, let data = try cube(profile) {
            guard let encoded = encode?.apply(extent: extent, arguments: ([result] as [Any]) + vectors(toProPhoto) + [headroom]) else { throw EditError.render }
            let profiled = encoded.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": dimension, "inputCubeData": data])
            guard let decoded = decode?.apply(extent: extent, arguments: ([profiled, result] as [Any]) + vectors(fromProPhoto) + [headroom, profile.amount]) else { throw EditError.render }
            result = decoded
        }
        return result.cropped(to: extent)
    }
}
