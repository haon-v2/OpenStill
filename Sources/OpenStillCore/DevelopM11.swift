import Foundation
import CoreImage
import Accelerate

// MARK: - Point curve and parametric curve

/// A point on a free tone curve, both coordinates 0–1.
public struct CurvePoint: Codable, Equatable, Sendable {
    public var x: Double, y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let identity = [CurvePoint(0, 0), CurvePoint(1, 1)]
    public static let maximumCount = 16
    /// Sorted, clamped, without duplicate x, 2–16 points.
    public static func cleaned(_ points: [CurvePoint]) -> [CurvePoint] {
        var out: [CurvePoint] = []
        for p in points.filter({ $0.x.isFinite && $0.y.isFinite }).map({ CurvePoint(min(1, max(0, $0.x)), min(1, max(0, $0.y))) }).sorted(by: { $0.x < $1.x }) {
            if let last = out.last, abs(last.x - p.x) < 0.002 { out[out.count - 1] = p } else { out.append(p) }
        }
        if out.count > maximumCount { out = Array(out.prefix(maximumCount - 1)) + [out[out.count - 1]] }
        return out.count >= 2 ? out : identity
    }
    /// Monotone cubic (Fritsch–Carlson) through the points; flat before the first and after the last point.
    /// Beyond 0…1 (extended-range pixels) the curve continues along its end slope.
    public static func value(at x: Double, points raw: [CurvePoint]) -> Double {
        let p = raw.count >= 2 ? raw : identity, n = p.count
        let slopes = tangents(p)
        if x <= p[0].x { return x < 0 && p[0].x == 0 ? p[0].y + x * slopes[0] : p[0].y }
        if x >= p[n - 1].x { return x > 1 && p[n - 1].x == 1 ? p[n - 1].y + (x - 1) * slopes[n - 1] : p[n - 1].y }
        var i = 0
        while i < n - 2 && x > p[i + 1].x { i += 1 }
        let h = p[i + 1].x - p[i].x, t = (x - p[i].x) / h
        let h00 = 2 * t * t * t - 3 * t * t + 1, h10 = t * t * t - 2 * t * t + t, h01 = -2 * t * t * t + 3 * t * t, h11 = t * t * t - t * t
        return h00 * p[i].y + h10 * h * slopes[i] + h01 * p[i + 1].y + h11 * h * slopes[i + 1]
    }
    static func tangents(_ p: [CurvePoint]) -> [Double] {
        let n = p.count
        let d = (0..<(n - 1)).map { (p[$0 + 1].y - p[$0].y) / max(1e-9, p[$0 + 1].x - p[$0].x) }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1..<max(1, n - 1) where n > 2 { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        for i in 0..<(n - 1) {
            if d[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i], s = a * a + b * b
            if s > 9 { let t = 3 / s.squareRoot(); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        return m
    }
}

/// Lightroom-style parametric curve: four tonal regions (−1…1) separated by three split points.
public struct ParametricCurve: Codable, Equatable, Sendable {
    public var shadows = 0.0, darks = 0.0, lights = 0.0, highlights = 0.0
    public var shadowSplit = 0.25, midtoneSplit = 0.5, highlightSplit = 0.75
    public init() {}
    public var isIdentity: Bool { shadows == 0 && darks == 0 && lights == 0 && highlights == 0 }
    public var sanitized: ParametricCurve {
        func c(_ v: Double, _ lo: Double, _ hi: Double, _ f: Double) -> Double { v.isFinite ? min(hi, max(lo, v)) : f }
        var s = self
        s.shadows = c(shadows, -1, 1, 0); s.darks = c(darks, -1, 1, 0); s.lights = c(lights, -1, 1, 0); s.highlights = c(highlights, -1, 1, 0)
        s.shadowSplit = c(shadowSplit, 0.1, 0.4, 0.25); s.midtoneSplit = c(midtoneSplit, s.shadowSplit + 0.05, 0.7, 0.5); s.highlightSplit = c(highlightSplit, max(s.midtoneSplit + 0.05, 0.6), 0.9, 0.75)
        return s
    }
    /// Each region pushes a smooth bump over its range (overlapping its neighbours, like Lightroom's zones).
    /// End points stay fixed and the bumps are small enough that the curve keeps rising.
    public func value(at x: Double) -> Double {
        let s = sanitized
        guard x >= 0 && x <= 1 else { return x }
        let edges = [0.0, s.shadowSplit, s.midtoneSplit, s.highlightSplit, 1.0], amounts = [s.shadows, s.darks, s.lights, s.highlights]
        var y = x
        for i in 0..<4 where amounts[i] != 0 {
            let lo = i == 0 ? 0 : (edges[i - 1] + edges[i]) / 2, hi = i == 3 ? 1 : (edges[i + 1] + edges[i + 2]) / 2
            guard x > lo, x < hi else { continue }
            let t = (x - lo) / (hi - lo), bump = sin(Double.pi * t) * sin(Double.pi * t)
            let room = min(1, 2 * (amounts[i] > 0 ? 1 - x : x))
            y += amounts[i] * bump * 0.2 * (hi - lo) * room
        }
        return min(1, max(0, y))
    }
}

/// Renders point and parametric curves through per-channel 1D lookup tables (Core Image's color curves).
enum PointCurves {
    static let domain = (-0.25, 2.0), samples = 2048
    static func table(_ settings: ToneCurves) -> Data {
        var values = [Float](); values.reserveCapacity(samples * 3)
        var previous = [Double](repeating: -.infinity, count: 3)
        for i in 0..<samples {
            let x = domain.0 + (domain.1 - domain.0) * Double(i) / Double(samples - 1)
            for c in 0..<3 {
                var v = settings.output(x, channel: c + 1)
                // Point curves may dip; keep what the person drew but never produce NaN.
                if !v.isFinite { v = previous[c].isFinite ? previous[c] : x }
                previous[c] = v; values.append(Float(v))
            }
        }
        return values.withUnsafeBytes { Data($0) }
    }
    static func apply(_ image: CIImage, settings: ToneCurves) throws -> CIImage {
        let sRGB = CGColorSpace(name: CGColorSpace.extendedSRGB)!
        let output = image.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": table(settings), "inputCurvesDomain": CIVector(x: domain.0, y: domain.1), "inputColorSpace": sRGB])
        return output.cropped(to: image.extent)
    }
}

// MARK: - Black & white mix

enum GrayMix {
    private static let cache = NSCache<NSString, NSData>()
    /// A cube mapping each color to its gray: luminance lifted or lowered by the mix of its hue band.
    static func cube(_ mix: [Double]) -> Data {
        let key = mix.map { String($0) }.joined(separator: ",") as NSString
        if let cached = cache.object(forKey: key) { return cached as Data }
        let n = 33; var values: [Float] = []; values.reserveCapacity(n * n * n * 4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let rgb = [Double(r) / 32, Double(g) / 32, Double(b) / 32]
            let (h, s, _) = HSL.of(rgb)
            let luminance = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
            var shift = 0.0
            for i in 0..<8 { shift += mix[i] * HSL.bandWeight(h, band: i) }
            let gray = min(1, max(0, luminance * (1 + shift * 0.9 * min(1, s * 2.5))))
            values += [Float(gray), Float(gray), Float(gray), 1]
        } } }
        let data = values.withUnsafeBytes { Data($0) }
        cache.countLimit = 8; cache.setObject(data as NSData, forKey: key)
        return data
    }
    static func apply(_ image: CIImage, mix raw: [Double], amount: Double) -> CIImage {
        let mix = (raw + [Double](repeating: 0, count: 8)).prefix(8).map { $0.isFinite ? min(1, max(-1, $0)) : 0 }
        let gray = image.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": 33, "inputCubeData": cube(mix), "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!])
        return amount >= 1 ? gray : image.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: gray, kCIInputTimeKey: amount])
    }
}

/// Hue, saturation and lightness helpers shared by the mixers (hue 0–1).
public enum HSL {
    public static func of(_ rgb: [Double]) -> (Double, Double, Double) {
        let maxV = rgb.max()!, minV = rgb.min()!, delta = maxV - minV
        var h = 0.0
        if delta > 0 {
            if maxV == rgb[0] { h = ((rgb[1] - rgb[2]) / delta).truncatingRemainder(dividingBy: 6) / 6 }
            else if maxV == rgb[1] { h = ((rgb[2] - rgb[0]) / delta + 2) / 6 }
            else { h = ((rgb[0] - rgb[1]) / delta + 4) / 6 }
            if h < 0 { h += 1 }
        }
        let l = (maxV + minV) / 2
        return (h, delta == 0 ? 0 : delta / max(0.000001, 1 - abs(2 * l - 1)), l)
    }
    /// How much a hue belongs to one of the 8 mixer bands (same bands as the Color mixer).
    public static func bandWeight(_ h: Double, band i: Int) -> Double {
        let d = abs(h - ColorMixer.centers[i]), distance = min(d, 1 - d)
        let width = (i == 1 || i == 6) ? 0.085 : 0.13
        return pow(max(0, 1 - max(0, distance - 0.02) / (width - 0.02)), 2)
    }
}

// MARK: - Point Color

/// A color picked from the photo, and how to shift colors near it.
public struct PointColor: Codable, Equatable, Sendable {
    public var hue: Double, saturation: Double, lightness: Double
    public var hueShift = 0.0, saturationShift = 0.0, lightnessShift = 0.0
    /// How far from the picked color the change reaches (0 narrow … 1 wide).
    public var range = 0.5
    public init(hue: Double, saturation: Double, lightness: Double) { self.hue = hue; self.saturation = saturation; self.lightness = lightness }
    public init(rgb: [Double]) { let (h, s, l) = HSL.of(rgb.map { min(1, max(0, $0.isFinite ? $0 : 0)) }); self.init(hue: h, saturation: s, lightness: l) }
    public var sanitized: PointColor {
        func c(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v.isFinite ? min(hi, max(lo, v)) : 0 }
        var s = self
        s.hue = hue.isFinite ? (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) : 0
        s.saturation = c(saturation, 0, 1); s.lightness = c(lightness, 0, 1)
        s.hueShift = c(hueShift, -1, 1); s.saturationShift = c(saturationShift, -1, 1); s.lightnessShift = c(lightnessShift, -1, 1)
        s.range = range.isFinite ? min(1, max(0, range)) : 0.5
        return s
    }
    public var hasEffect: Bool { hueShift != 0 || saturationShift != 0 || lightnessShift != 0 }
    /// 1 at the picked color, fading to 0 by hue, saturation and lightness distance.
    public func weight(hue h: Double, saturation s: Double, lightness l: Double) -> Double {
        let d = abs(h - hue), dh = min(d, 1 - d)
        let hueWidth = 0.02 + range * 0.12, width = 0.12 + range * 0.5
        func fall(_ x: Double, _ w: Double) -> Double { let t = max(0, 1 - x / w); return t * t * (3 - 2 * t) }
        // Near-gray picks and pixels have no reliable hue, so hue matters less there.
        let hueTerm = saturation < 0.08 ? 1 : fall(dh, hueWidth)
        return hueTerm * fall(abs(s - saturation), width) * fall(abs(l - lightness), width) * min(1, s * 6 + (saturation < 0.08 ? 1 : 0))
    }
}

public enum PointColors {
    static func apply(_ image: CIImage, colors raw: [PointColor]) -> CIImage {
        let colors = raw.map(\.sanitized).filter(\.hasEffect)
        guard !colors.isEmpty else { return image }
        let n = 33; var values: [Float] = []; values.reserveCapacity(n * n * n * 4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let rgb = [Double(r) / 32, Double(g) / 32, Double(b) / 32]
            var (h, s, l) = HSL.of(rgb)
            var dh = 0.0, ds = 0.0, dl = 0.0
            for c in colors {
                let w = c.weight(hue: h, saturation: s, lightness: l)
                dh += c.hueShift * w * 0.1; ds += c.saturationShift * w; dl += c.lightnessShift * w * 0.35
            }
            h = (h + dh + 1).truncatingRemainder(dividingBy: 1)
            s = min(1, max(0, s * (1 + ds)))
            l = min(1, max(0, dl >= 0 ? l + (1 - l) * dl : l + l * dl))
            let out = ColorMixer.rgb(hue: h, saturation: s, lightness: l)
            values += [Float(out[0]), Float(out[1]), Float(out[2]), 1]
        } } }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": 33, "inputCubeData": values.withUnsafeBytes { Data($0) }, "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!])
    }
    /// The average color of a small patch of the photo (0–1 from the bottom left), for picking a Point Color.
    public static func sample(_ image: CIImage, at point: CGPoint) -> [Double]? {
        let e = image.extent
        let x = e.minX + min(1, max(0, point.x)) * e.width, y = e.minY + min(1, max(0, point.y)) * e.height
        let region = CGRect(x: x - 3, y: y - 3, width: 7, height: 7).intersection(e)
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: region)])
        var rgba = [Float](repeating: 0, count: 4)
        ModernRenderer.context.render(average, toBitmap: &rgba, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        guard rgba[3] > 0.01 else { return nil }
        return rgba[0...2].map { Double(min(1, max(0, $0))) }
    }
}
extension PointColor { public static func sample(_ image: CIImage, at point: CGPoint) -> PointColor? { PointColors.sample(image, at: point).map { PointColor(rgb: $0) } } }

// MARK: - Detail: sharpening and noise reduction

/// Lightroom's Detail sliders beyond Amount and Luminance.
public struct DetailSettings: Codable, Equatable, Sendable {
    /// Sharpening radius (0.5–3) and how much fine detail it emphasizes (0–1).
    public var radius = 1.0, detail = 0.25
    /// Masking (0–1): 0 sharpens everything, higher values only sharpen edges.
    public var masking = 0.0
    /// Luminance noise reduction detail and contrast (0–1).
    public var noiseDetail = 0.5, noiseContrast = 0.0
    /// Color noise reduction (0–1) and its detail (0–1).
    public var color = 0.0, colorDetail = 0.5
    public init() {}
    public var sanitized: DetailSettings {
        func c(_ v: Double, _ lo: Double, _ hi: Double, _ f: Double) -> Double { v.isFinite ? min(hi, max(lo, v)) : f }
        var s = self
        s.radius = c(radius, 0.5, 3, 1); s.detail = c(detail, 0, 1, 0.25); s.masking = c(masking, 0, 1, 0)
        s.noiseDetail = c(noiseDetail, 0, 1, 0.5); s.noiseContrast = c(noiseContrast, 0, 1, 0); s.color = c(color, 0, 1, 0); s.colorDetail = c(colorDetail, 0, 1, 0.5)
        return s
    }
}

enum Detail {
    private static let sharpenKernel = CIColorKernel(source: """
    float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
    kernel vec4 detailSharpen(__sample pixel, __sample coarse, __sample fine, __sample edges, vec4 p) {
        vec4 c = unpremultiply(pixel);
        float l = luma(c.rgb);
        float boost = p.x * ((l - luma(coarse.rgb)) + p.y * 1.5 * (l - luma(fine.rgb)));
        float edge = max(edges.r, max(edges.g, edges.b));
        float gate = p.z <= 0.0 ? 1.0 : smoothstep(p.z * 0.12, p.z * 0.12 + 0.05, edge);
        c.rgb += boost * gate;
        return premultiply(c);
    }
    """)
    private static let chromaKernel = CIColorKernel(source: """
    float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
    kernel vec4 chromaOnly(__sample pixel, __sample soft) {
        vec4 c = unpremultiply(pixel); vec4 s = unpremultiply(soft);
        c.rgb = s.rgb + (luma(c.rgb) - luma(s.rgb));
        return premultiply(c);
    }
    """)
    /// Pixel radius scaled to the photo, so previews and full-size exports sharpen alike.
    static func pixels(_ radius: Double, _ size: CGSize) -> Double { max(0.3, radius * max(size.width, size.height) / 4000) }
    static func sharpen(_ image: CIImage, amount: Double, settings raw: DetailSettings, sourceSize: CGSize) throws -> CIImage {
        let s = raw.sanitized, extent = image.extent, r = pixels(s.radius, sourceSize)
        let clamped = image.clampedToExtent()
        let coarse = clamped.applyingGaussianBlur(sigma: r).cropped(to: extent)
        let fine = clamped.applyingGaussianBlur(sigma: max(0.3, r * 0.5)).cropped(to: extent)
        let edges = s.masking > 0 ? clamped.applyingGaussianBlur(sigma: r).applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 4]).cropped(to: extent) : image
        guard let out = sharpenKernel?.apply(extent: extent, arguments: [image, coarse, fine, edges, CIVector(x: amount * 1.4, y: s.detail, z: s.masking, w: 0)]) else { throw EditError.render }
        return out
    }
    static func denoise(_ image: CIImage, amount: Double, settings raw: DetailSettings, sourceSize: CGSize) throws -> CIImage {
        let s = raw.sanitized, extent = image.extent
        var out = image
        if amount > 0 {
            out = out.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": amount * 0.1 * (1.4 - s.noiseDetail * 0.8), kCIInputSharpnessKey: 0.2 + s.noiseContrast * 1.5])
        }
        if s.color > 0 {
            let radius = max(0.5, s.color * max(sourceSize.width, sourceSize.height) / 400 * (1.2 - s.colorDetail))
            let soft = out.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
            guard let chroma = chromaKernel?.apply(extent: extent, arguments: [out, soft]) else { throw EditError.render }
            out = chroma
        }
        return out.cropped(to: extent)
    }
}

// MARK: - Automatic chromatic aberration removal

/// Lateral chromatic aberration: the red and blue channels are scaled about the photo's centre to line up with green.
public struct AutoCASettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var redScale = 1.0, blueScale = 1.0
    public init(enabled: Bool = true, redScale: Double = 1, blueScale: Double = 1) { self.enabled = enabled; self.redScale = redScale; self.blueScale = blueScale }
    public var sanitized: AutoCASettings {
        func c(_ v: Double) -> Double { v.isFinite ? min(1.01, max(0.99, v)) : 1 }
        return AutoCASettings(enabled: enabled, redScale: c(redScale), blueScale: c(blueScale))
    }
    public var hasEffect: Bool { enabled && (abs(redScale - 1) > 1e-6 || abs(blueScale - 1) > 1e-6) }
}

public enum AutoCA {
    private static let merge = CIColorKernel(source: "kernel vec4 mergeChannels(__sample r, __sample g, __sample b) { return vec4(r.r, g.g, b.b, g.a); }")
    static func scaled(_ image: CIImage, _ s: Double) -> CIImage {
        let e = image.extent, c = CGPoint(x: e.midX, y: e.midY)
        let t = CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: s, y: s).translatedBy(x: -c.x, y: -c.y)
        return image.clampedToExtent().transformed(by: t).cropped(to: e)
    }
    public static func apply(_ image: CIImage, settings raw: AutoCASettings) -> CIImage {
        let s = raw.sanitized
        guard s.hasEffect, let out = merge?.apply(extent: image.extent, arguments: [scaled(image, s.redScale), image, scaled(image, s.blueScale)]) else { return image }
        return out
    }
    /// Measures the red and blue scales that best line their edges up with green, on a small render of the photo.
    public static func estimate(_ image: CIImage) -> AutoCASettings {
        let e = image.extent, maxSide = 900.0, scale = min(1, maxSide / max(e.width, e.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = Int(small.extent.width.rounded(.down)), h = Int(small.extent.height.rounded(.down))
        guard w > 16, h > 16 else { return AutoCASettings(enabled: true) }
        var rgba = [Float](repeating: 0, count: w * h * 4)
        ModernRenderer.context.render(small, toBitmap: &rgba, rowBytes: w * 16, bounds: CGRect(x: small.extent.minX, y: small.extent.minY, width: CGFloat(w), height: CGFloat(h)), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return estimate(rgba: rgba, width: w, height: h)
    }
    /// The same measurement on an RGBA float buffer (rows from the bottom), for tests.
    public static func estimate(rgba: [Float], width w: Int, height h: Int) -> AutoCASettings {
        func channel(_ k: Int) -> [Float] { (0..<(w * h)).map { rgba[$0 * 4 + k] } }
        let r = channel(0), g = channel(1), b = channel(2)
        // Strong green edges, away from the border.
        var edges: [(Int, Int)] = []
        var magnitudes: [Float] = []
        for y in 2..<(h - 2) { for x in 2..<(w - 2) {
            let i = y * w + x
            let gx = g[i + 1] - g[i - 1], gy = g[i + w] - g[i - w]
            magnitudes.append(gx * gx + gy * gy); edges.append((x, y))
        } }
        guard !magnitudes.isEmpty else { return AutoCASettings(enabled: true) }
        let threshold = magnitudes.sorted()[Int(Double(magnitudes.count) * 0.95)]
        let points = zip(edges, magnitudes).filter { $0.1 > max(threshold, 1e-5) }.map(\.0)
        guard points.count > 20 else { return AutoCASettings(enabled: true) }
        let cx = Double(w - 1) / 2, cy = Double(h - 1) / 2
        func sample(_ c: [Float], _ x: Double, _ y: Double) -> Double? {
            guard x >= 0, y >= 0, x < Double(w - 1), y < Double(h - 1) else { return nil }
            let x0 = Int(x), y0 = Int(y), fx = x - Double(x0), fy = y - Double(y0), i = y0 * w + x0
            let top = Double(c[i]) * (1 - fx) + Double(c[i + 1]) * fx, bottom = Double(c[i + w]) * (1 - fx) + Double(c[i + w + 1]) * fx
            return top * (1 - fy) + bottom * fy
        }
        func best(_ c: [Float]) -> Double {
            var bestScale = 1.0, bestError = Double.infinity
            for step in -60...60 {
                let s = 1 + Double(step) * 0.0001
                var sumC = 0.0, sumG = 0.0, pairs: [(Double, Double)] = []
                for (x, y) in points {
                    guard let v = sample(c, cx + (Double(x) - cx) / s, cy + (Double(y) - cy) / s) else { continue }
                    let gv = Double(g[y * w + x]); pairs.append((v, gv)); sumC += v; sumG += gv
                }
                guard pairs.count > 10, sumG > 0 else { continue }
                let k = sumC / sumG
                let error = pairs.reduce(0) { $0 + ($1.0 - $1.1 * k) * ($1.0 - $1.1 * k) } / Double(pairs.count)
                if error < bestError { bestError = error; bestScale = s }
            }
            return bestScale
        }
        return AutoCASettings(enabled: true, redScale: best(r), blueScale: best(b)).sanitized
    }
}

// MARK: - Red eye and pet eye

public enum EyeFixKind: String, Codable, Sendable { case redEye, petEye }

/// One corrected eye: an ellipse on the source photo (0–1 from the bottom left), like retouch strokes.
public struct EyeFix: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var kind: EyeFixKind
    public var center: MaskPoint
    public var radiusX: Double, radiusY: Double
    /// Pupil size within the ellipse (0.2–1) and how dark it becomes (0–1).
    public var pupil = 0.6, darken = 0.6
    /// Pet eye only: adds a small catchlight.
    public var catchlight = true
    public init(kind: EyeFixKind, center: CGPoint, radiusX: Double, radiusY: Double) {
        self.kind = kind; self.center = MaskPoint(center); self.radiusX = radiusX; self.radiusY = radiusY
    }
    public var sanitized: EyeFix {
        func c(_ v: Double, _ lo: Double, _ hi: Double, _ f: Double) -> Double { v.isFinite ? min(hi, max(lo, v)) : f }
        var s = self
        s.center = MaskPoint(CGPoint(x: c(center.x, -1, 2, 0.5), y: c(center.y, -1, 2, 0.5)))
        s.radiusX = c(radiusX, 0.001, 0.3, 0.02); s.radiusY = c(radiusY, 0.001, 0.3, 0.02)
        s.pupil = c(pupil, 0.2, 1, 0.6); s.darken = c(darken, 0, 1, 0.6)
        return s
    }
}

enum EyeFixes {
    private static let kernel = CIColorKernel(source: """
    kernel vec4 eyeFix(__sample pixel, vec2 center, vec2 radii, vec4 p) {
        vec4 c = unpremultiply(pixel);
        vec2 d = (destCoord() - center) / (radii * p.y);
        float r = length(d);
        float inside = 1.0 - smoothstep(0.75, 1.0, r);
        if (inside <= 0.0) { return pixel; }
        if (p.x < 0.5) {
            float redness = c.r - max(c.g, c.b);
            float amount = inside * smoothstep(0.02, 0.15, redness);
            float neutral = min(c.g, c.b) * (1.0 - 0.7 * p.z);
            c.rgb = mix(c.rgb, vec3(neutral), amount);
        } else {
            vec3 dark = vec3(0.02 + 0.08 * (1.0 - p.z));
            c.rgb = mix(c.rgb, dark, inside);
            if (p.w > 0.5) {
                float glint = 1.0 - smoothstep(0.08, 0.16, length(d - vec2(-0.3, 0.3)));
                c.rgb = mix(c.rgb, vec3(0.95), glint * inside);
            }
        }
        return premultiply(c);
    }
    """)
    static func apply(_ image: CIImage, fixes: [EyeFix]) -> CIImage {
        var out = image
        let e = image.extent
        for fix in fixes.map(\.sanitized) {
            let center = CIVector(x: e.minX + fix.center.x * e.width, y: e.minY + fix.center.y * e.height)
            let radii = CIVector(x: max(1, fix.radiusX * e.width), y: max(1, fix.radiusY * e.height))
            if let fixed = kernel?.apply(extent: e, arguments: [out, center, radii, CIVector(x: fix.kind == .redEye ? 0 : 1, y: fix.pupil, z: fix.darken, w: fix.catchlight ? 1 : 0)]) { out = fixed }
        }
        return out
    }
}

// MARK: - Visualize spots

public enum SpotVisualizer {
    private static let kernel = CIColorKernel(source: """
    kernel vec4 visualizeSpots(__sample pixel, __sample soft, float threshold) {
        float d = abs(dot(pixel.rgb - soft.rgb, vec3(0.3333)));
        float v = smoothstep(threshold, threshold * 2.0, d);
        return vec4(vec3(v), 1.0);
    }
    """)
    /// A black-and-white map where dust and small spots show as white specks (never exported).
    public static func map(_ image: CIImage, threshold: Double) -> CIImage? {
        let e = image.extent
        let soft = image.clampedToExtent().applyingGaussianBlur(sigma: max(1.5, max(e.width, e.height) / 600)).cropped(to: e)
        return kernel?.apply(extent: e, arguments: [image, soft, 0.004 + min(1, max(0, threshold)) * 0.05])
    }
}

// MARK: - Snapshots

/// A named state of a version's edits, kept alongside its history.
public struct EditSnapshot: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var date: Date
    public var edits: PhotoEdits
    public init(name: String, date: Date = Date(), edits: PhotoEdits) { self.name = name; self.date = date; self.edits = edits }
}
extension EditDocument {
    public var snapshotList: [EditSnapshot] { snapshots ?? [] }
    /// Saves the current edits as a named snapshot.
    public mutating func addSnapshot(_ name: String, date: Date = Date()) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if snapshots == nil { snapshots = [] }
        snapshots!.append(EditSnapshot(name: trimmed.isEmpty ? Self.defaultSnapshotName(date) : String(trimmed.prefix(120)), date: date, edits: current))
    }
    public mutating func renameSnapshot(_ id: UUID, to name: String) {
        guard let i = snapshots?.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { snapshots![i].name = String(trimmed.prefix(120)) }
    }
    public mutating func deleteSnapshot(_ id: UUID) { snapshots?.removeAll { $0.id == id }; if snapshots?.isEmpty == true { snapshots = nil } }
    /// Restores a snapshot as a new history step, so it can be undone.
    public mutating func restoreSnapshot(_ id: UUID) {
        guard let snapshot = snapshots?.first(where: { $0.id == id }) else { return }
        commit(snapshot.edits, title: "Snapshot: \(snapshot.name)")
    }
    static func defaultSnapshotName(_ date: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f.string(from: date)
    }
}

// MARK: - Edit accessors

extension PhotoEdits {
    public static let neutralGrayMix = [Double](repeating: 0, count: 8)
    public var grayMix: [Double] {
        get { let m = advanced?.grayMix ?? []; return m.count == 8 ? m : Self.neutralGrayMix }
        set { ensureAdvanced(); let m = newValue.count == 8 ? newValue.map { $0.isFinite ? min(1, max(-1, $0)) : 0 } : Self.neutralGrayMix; advanced!.grayMix = m.allSatisfy { $0 == 0 } ? nil : m }
    }
    public var detail: DetailSettings {
        get { advanced?.detail ?? DetailSettings() }
        set { ensureAdvanced(); advanced!.detail = newValue.sanitized }
    }
    /// Whether the newer sharpening and noise reduction are in use (older edits keep their original look).
    public var usesDetailSettings: Bool { advanced?.detail != nil }
    public var autoCA: AutoCASettings {
        get { advanced?.autoCA ?? AutoCASettings(enabled: false) }
        set { ensureAdvanced(); advanced!.autoCA = newValue.enabled ? newValue.sanitized : nil }
    }
    public var pointColors: [PointColor] {
        get { advanced?.pointColors ?? [] }
        set { ensureAdvanced(); let c = Array(newValue.prefix(8)).map(\.sanitized); advanced!.pointColors = c.isEmpty ? nil : c }
    }
    public var eyeFixes: [EyeFix] {
        get { advanced?.eyeFixes ?? [] }
        set { ensureAdvanced(); let f = newValue.map(\.sanitized); advanced!.eyeFixes = f.isEmpty ? nil : f }
    }
    // Slider-friendly accessors (key paths for the editor panel).
    public var sharpenRadius: Double { get { detail.radius } set { var d = detail; d.radius = newValue; detail = d } }
    public var sharpenDetail: Double { get { detail.detail } set { var d = detail; d.detail = newValue; detail = d } }
    public var sharpenMasking: Double { get { detail.masking } set { var d = detail; d.masking = newValue; detail = d } }
    public var noiseDetail: Double { get { detail.noiseDetail } set { var d = detail; d.noiseDetail = newValue; detail = d } }
    public var noiseContrast: Double { get { detail.noiseContrast } set { var d = detail; d.noiseContrast = newValue; detail = d } }
    public var colorNoise: Double { get { detail.color } set { var d = detail; d.color = newValue; detail = d } }
    public var colorNoiseDetail: Double { get { detail.colorDetail } set { var d = detail; d.colorDetail = newValue; detail = d } }
    public var parametricShadows: Double { get { curves.parametric?.shadows ?? 0 } set { setParametric { $0.shadows = newValue } } }
    public var parametricDarks: Double { get { curves.parametric?.darks ?? 0 } set { setParametric { $0.darks = newValue } } }
    public var parametricLights: Double { get { curves.parametric?.lights ?? 0 } set { setParametric { $0.lights = newValue } } }
    public var parametricHighlights: Double { get { curves.parametric?.highlights ?? 0 } set { setParametric { $0.highlights = newValue } } }
    public var parametricShadowSplit: Double { get { curves.parametric?.shadowSplit ?? 0.25 } set { setParametric { $0.shadowSplit = newValue } } }
    public var parametricMidtoneSplit: Double { get { curves.parametric?.midtoneSplit ?? 0.5 } set { setParametric { $0.midtoneSplit = newValue } } }
    public var parametricHighlightSplit: Double { get { curves.parametric?.highlightSplit ?? 0.75 } set { setParametric { $0.highlightSplit = newValue } } }
    // Black & white mix bands, for the mix sliders.
    public var grayMixRed: Double { get { grayMix[0] } set { setGray(0, newValue) } }
    public var grayMixOrange: Double { get { grayMix[1] } set { setGray(1, newValue) } }
    public var grayMixYellow: Double { get { grayMix[2] } set { setGray(2, newValue) } }
    public var grayMixGreen: Double { get { grayMix[3] } set { setGray(3, newValue) } }
    public var grayMixAqua: Double { get { grayMix[4] } set { setGray(4, newValue) } }
    public var grayMixBlue: Double { get { grayMix[5] } set { setGray(5, newValue) } }
    public var grayMixPurple: Double { get { grayMix[6] } set { setGray(6, newValue) } }
    public var grayMixMagenta: Double { get { grayMix[7] } set { setGray(7, newValue) } }
    private mutating func setGray(_ i: Int, _ v: Double) { var m = grayMix; m[i] = v; grayMix = m }
    // The most recent eye fix, for its sliders.
    public var eyePupil: Double { get { eyeFixes.last?.pupil ?? 0.6 } set { editLastEye { $0.pupil = newValue } } }
    public var eyeDarken: Double { get { eyeFixes.last?.darken ?? 0.6 } set { editLastEye { $0.darken = newValue } } }
    public var eyeCatchlight: Bool { get { eyeFixes.last?.catchlight ?? true } set { editLastEye { $0.catchlight = newValue } } }
    private mutating func editLastEye(_ change: (inout EyeFix) -> Void) { var f = eyeFixes; guard !f.isEmpty else { return }; change(&f[f.count - 1]); eyeFixes = f }
    private mutating func setParametric(_ change: (inout ParametricCurve) -> Void) {
        var c = curves, p = c.parametric ?? ParametricCurve(); change(&p); c.parametric = p; curves = c
    }
}
