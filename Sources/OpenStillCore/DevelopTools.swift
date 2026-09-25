import Foundation
import CoreImage

/// One color grading wheel. Hue is in degrees, saturation 0…1, luminance −1…1.
public struct GradeWheel: Codable, Equatable {
    public var hue = 0.0, saturation = 0.0, luminance = 0.0
    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) { self.hue = hue; self.saturation = saturation; self.luminance = luminance }
    public var isNeutral: Bool { saturation == 0 && luminance == 0 }
}
public struct ColorGrading: Codable, Equatable {
    public var shadows = GradeWheel(), midtones = GradeWheel(), highlights = GradeWheel(), global = GradeWheel()
    /// 0 keeps the tonal ranges apart, 1 overlaps them widely.
    public var blending = 0.5
    /// Negative favors shadows, positive favors highlights.
    public var balance = 0.0
    public init() {}
    public var isIdentity: Bool { [shadows, midtones, highlights, global].allSatisfy(\.isNeutral) }
    public var sanitized: ColorGrading {
        func wheel(_ w: GradeWheel) -> GradeWheel {
            let hue = w.hue.isFinite ? (w.hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) : 0
            return GradeWheel(hue: hue, saturation: limit(w.saturation, 0, 1), luminance: limit(w.luminance, -1, 1))
        }
        var r = self
        r.shadows = wheel(shadows); r.midtones = wheel(midtones); r.highlights = wheel(highlights); r.global = wheel(global)
        r.blending = limit(blending, 0, 1, 0.5); r.balance = limit(balance, -1, 1)
        return r
    }
}
public struct GrainSettings: Codable, Equatable {
    public var amount = 0.0, size = 0.25, roughness = 0.5
    public init() {}
    public var sanitized: GrainSettings {
        var r = self; r.amount = limit(amount, 0, 1); r.size = limit(size, 0, 1, 0.25); r.roughness = limit(roughness, 0, 1, 0.5); return r
    }
}
/// Removes purple and green fringes along high-contrast edges. Hue ranges are in degrees.
public struct DefringeSettings: Codable, Equatable {
    public var purpleAmount = 0.0, purpleLow = 260.0, purpleHigh = 330.0
    public var greenAmount = 0.0, greenLow = 80.0, greenHigh = 160.0
    public init() {}
    public var hasEffect: Bool { purpleAmount > 0 || greenAmount > 0 }
    public var sanitized: DefringeSettings {
        var r = self
        r.purpleAmount = limit(purpleAmount, 0, 1); r.greenAmount = limit(greenAmount, 0, 1)
        r.purpleLow = limit(purpleLow, 180, 360, 260); r.purpleHigh = max(r.purpleLow, limit(purpleHigh, 180, 360, 330))
        r.greenLow = limit(greenLow, 30, 200, 80); r.greenHigh = max(r.greenLow, limit(greenHigh, 30, 200, 160))
        return r
    }
}
private func limit(_ value: Double, _ low: Double, _ high: Double, _ fallback: Double = 0) -> Double { value.isFinite ? min(high, max(low, value)) : fallback }

extension PhotoEdits {
    public var clarity: Double { get { advanced?.clarity ?? 0 } set { ensureAdvanced(); advanced!.clarity = newValue == 0 ? nil : newValue } }
    public var texture: Double { get { advanced?.texture ?? 0 } set { ensureAdvanced(); advanced!.texture = newValue == 0 ? nil : newValue } }
    public var dehaze: Double { get { advanced?.dehaze ?? 0 } set { ensureAdvanced(); advanced!.dehaze = newValue == 0 ? nil : newValue } }
    public var colorGrading: ColorGrading {
        get { advanced?.colorGrading ?? ColorGrading() }
        set { ensureAdvanced(); advanced!.colorGrading = newValue == ColorGrading() ? nil : newValue }
    }
    public var grain: GrainSettings {
        get { advanced?.grain ?? GrainSettings() }
        set { ensureAdvanced(); advanced!.grain = newValue == GrainSettings() ? nil : newValue }
    }
    public var defringe: DefringeSettings {
        get { advanced?.defringe ?? DefringeSettings() }
        set { ensureAdvanced(); advanced!.defringe = newValue == DefringeSettings() ? nil : newValue }
    }
    // Slider bindings for nested settings.
    public var grainAmount: Double { get { grain.amount } set { var g = grain; g.amount = newValue; grain = g } }
    public var grainSize: Double { get { grain.size } set { var g = grain; g.size = newValue; grain = g } }
    public var grainRoughness: Double { get { grain.roughness } set { var g = grain; g.roughness = newValue; grain = g } }
    public var defringePurple: Double { get { defringe.purpleAmount } set { var d = defringe; d.purpleAmount = newValue; defringe = d } }
    public var defringePurpleLow: Double { get { defringe.purpleLow } set { var d = defringe; d.purpleLow = newValue; defringe = d } }
    public var defringePurpleHigh: Double { get { defringe.purpleHigh } set { var d = defringe; d.purpleHigh = newValue; defringe = d } }
    public var defringeGreen: Double { get { defringe.greenAmount } set { var d = defringe; d.greenAmount = newValue; defringe = d } }
    public var defringeGreenLow: Double { get { defringe.greenLow } set { var d = defringe; d.greenLow = newValue; defringe = d } }
    public var defringeGreenHigh: Double { get { defringe.greenHigh } set { var d = defringe; d.greenHigh = newValue; defringe = d } }
    public var gradeBlending: Double { get { colorGrading.blending } set { var c = colorGrading; c.blending = newValue; colorGrading = c } }
    public var gradeBalance: Double { get { colorGrading.balance } set { var c = colorGrading; c.balance = newValue; colorGrading = c } }
}

/// Clarity, Texture, Dehaze, Color grading, Grain and Defringe. OpenStill's own algorithms, not Adobe's.
/// Kernels run on gamma-encoded extended sRGB so tonal weights match what the eye sees; radii scale with the image.
enum DevelopTools {
    private static let gamma = CGColorSpace(name: CGColorSpace.extendedSRGB)!
    private static let luma = "vec3(0.2126,0.7152,0.0722)"

    private static func encoded(_ image: CIImage) throws -> CIImage {
        guard let out = image.matchedFromWorkingSpace(to: gamma) else { throw EditError.render }
        return out
    }
    private static func decoded(_ image: CIImage) throws -> CIImage {
        guard let out = image.matchedToWorkingSpace(from: gamma) else { throw EditError.render }
        return out
    }
    private static func blur(_ image: CIImage, _ radius: Double) -> CIImage {
        guard radius > 0.05 else { return image }
        return image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: image.extent)
    }
    private static func shortSide(_ extent: CGRect) -> Double { Double(max(1, min(extent.width, extent.height))) }

    // MARK: Clarity & Texture

    private static let localContrast = CIColorKernel(source: """
    kernel vec4 localContrast(__sample pixel, __sample near, __sample far, float amount, float mode) {
        vec4 p = unpremultiply(pixel);
        float l = dot(p.rgb, \(luma));
        float ln = dot(unpremultiply(near).rgb, \(luma));
        float lf = dot(unpremultiply(far).rgb, \(luma));
        float shift;
        if (mode < 0.5) {
            // Clarity: large-radius local contrast, strongest in the midtones.
            float mid = clamp(1.0 - pow(abs(2.0 * clamp(l, 0.0, 1.0) - 1.0), 2.0), 0.0, 1.0);
            shift = (amount > 0.0 ? amount * 1.4 : amount) * (l - lf) * mid;
        } else {
            // Texture: the medium-detail band; negative values smooth toward the wider blur.
            float guard0 = smoothstep(0.01, 0.08, l);
            shift = amount > 0.0 ? amount * 2.0 * (ln - lf) * guard0 : amount * (l - lf);
        }
        p.rgb = p.rgb + vec3(shift);
        return premultiply(p);
    }
    """)
    static func clarity(_ image: CIImage, amount: Double) throws -> CIImage {
        guard amount != 0 else { return image }
        let input = try encoded(image)
        let far = blur(input, shortSide(image.extent) * 0.02)
        guard let out = localContrast?.apply(extent: image.extent, arguments: [input, input, far, amount, 0]) else { throw EditError.render }
        return try decoded(out)
    }
    static func texture(_ image: CIImage, amount: Double) throws -> CIImage {
        guard amount != 0 else { return image }
        let input = try encoded(image), side = shortSide(image.extent)
        let near = blur(input, max(0.5, side * 0.0025)), far = blur(input, max(1.5, side * 0.01))
        guard let out = localContrast?.apply(extent: image.extent, arguments: [input, near, far, amount, 1]) else { throw EditError.render }
        return try decoded(out)
    }

    // MARK: Dehaze

    private static let darkChannel = CIColorKernel(source: """
    kernel vec4 darkChannel(__sample pixel) {
        vec3 c = unpremultiply(pixel).rgb;
        float d = clamp(min(c.r, min(c.g, c.b)), 0.0, 1.0);
        return vec4(d, d, d, 1.0);
    }
    """)
    private static let dehazeKernel = CIColorKernel(source: """
    kernel vec4 dehaze(__sample pixel, __sample dark, __sample air, float amount) {
        vec4 p = unpremultiply(pixel);
        vec3 a = clamp(unpremultiply(air).rgb, vec3(0.2), vec3(1.0));
        float haze = dark.r / max(0.2, dot(a, vec3(0.3333)));
        vec3 j;
        if (amount >= 0.0) {
            // Dark channel prior: I = J t + A (1 - t)  →  J = (I - A) / t + A
            float t = clamp(1.0 - 0.95 * amount * haze, 0.1, 1.0);
            j = (p.rgb - a) / t + a;
        } else {
            j = mix(p.rgb, a, -amount * 0.6 * (1.0 - 0.5 * haze));
        }
        p.rgb = j;
        return premultiply(p);
    }
    """)
    static func dehaze(_ image: CIImage, amount: Double) throws -> CIImage {
        guard amount != 0 else { return image }
        let input = try encoded(image), extent = image.extent
        // Estimate haze at about 512 px so the cost is independent of resolution.
        let scale = min(1, 512 / Double(max(extent.width, extent.height)))
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let darkSmall = darkChannel?.apply(extent: small.extent, arguments: [small]) else { throw EditError.render }
        let patch = darkSmall.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 6]).cropped(to: small.extent)
        let smooth = blur(patch, 10)
        let dark = smooth.clampedToExtent().transformed(by: CGAffineTransform(scaleX: 1/scale, y: 1/scale)).cropped(to: extent)
        // Airlight: the brightest color of the smoothed frame (blur keeps small specular highlights out).
        let air = blur(small, 8).applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: small.extent)]).clampedToExtent()
        guard let out = dehazeKernel?.apply(extent: extent, arguments: [input, dark, air, amount]) else { throw EditError.render }
        return try decoded(out)
    }

    // MARK: Color grading

    private static let gradeKernel = CIColorKernel(source: """
    kernel vec4 colorGrade(__sample pixel, vec3 ts, vec3 tm, vec3 th, vec3 tg, vec4 lum, vec2 split) {
        vec4 p = unpremultiply(pixel);
        float l = clamp(dot(p.rgb, \(luma)), 0.0, 1.0);
        float c = split.x, w = split.y;
        float sh = 1.0 - smoothstep(c - w, c, l);
        float hi = smoothstep(c, c + w, l);
        float mi = clamp(1.0 - sh - hi, 0.0, 1.0);
        p.rgb += sh * ts + mi * tm + hi * th + tg;
        p.rgb += vec3((sh * lum.x + mi * lum.y + hi * lum.z + lum.w) * 0.25);
        return premultiply(p);
    }
    """)
    /// Neutral-luminance tint pointing toward a hue, scaled by saturation.
    static func tint(_ wheel: GradeWheel) -> CIVector {
        let h = wheel.hue / 60, x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        let (r, g, b): (Double, Double, Double) = switch Int(h) % 6 {
            case 0: (1, x, 0); case 1: (x, 1, 0); case 2: (0, 1, x)
            case 3: (0, x, 1); case 4: (x, 0, 1); default: (1, 0, x)
        }
        let y = 0.2126*r + 0.7152*g + 0.0722*b, k = wheel.saturation * 0.3
        return CIVector(x: (r-y)*k, y: (g-y)*k, z: (b-y)*k)
    }
    static func colorGrade(_ image: CIImage, settings: ColorGrading) throws -> CIImage {
        let s = settings.sanitized
        guard !s.isIdentity else { return image }
        let input = try encoded(image)
        let lum = CIVector(x: s.shadows.luminance, y: s.midtones.luminance, z: s.highlights.luminance, w: s.global.luminance)
        let split = CIVector(x: 0.5 - s.balance * 0.25, y: 0.2 + s.blending * 0.3)
        guard let out = gradeKernel?.apply(extent: image.extent, arguments: [input, tint(s.shadows), tint(s.midtones), tint(s.highlights), tint(s.global), lum, split]) else { throw EditError.render }
        return try decoded(out)
    }

    // MARK: Grain

    private static let grainKernel = CIColorKernel(source: """
    kernel vec4 filmGrain(__sample pixel, __sample noise, float amount) {
        vec4 p = unpremultiply(pixel);
        float l = clamp(dot(p.rgb, \(luma)), 0.0, 1.0);
        float mid = 0.3 + 0.7 * clamp(1.0 - pow(abs(2.0 * l - 1.0), 2.0), 0.0, 1.0);
        float n = (noise.g - 0.5) * 2.0;
        p.rgb += vec3(n * amount * 0.12 * mid);
        return premultiply(p);
    }
    """)
    static func grain(_ image: CIImage, settings: GrainSettings) throws -> CIImage {
        let s = settings.sanitized
        guard s.amount > 0 else { return image }
        let extent = image.extent
        // Grain size is relative to the frame so previews and full-size exports look alike.
        let cell = max(1, (0.6 + s.size * 2.4) * Double(max(extent.width, extent.height)) / 3000)
        var noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.transformed(by: CGAffineTransform(scaleX: cell, y: cell))
        noise = blur(noise.cropped(to: extent), cell * (1 - s.roughness) * 0.6)
        let input = try encoded(image)
        guard let out = grainKernel?.apply(extent: extent, arguments: [input, noise, s.amount]) else { throw EditError.render }
        return try decoded(out)
    }

    // MARK: Defringe

    private static let edgeKernel = CIColorKernel(source: """
    kernel vec4 fringeEdges(__sample pixel, __sample soft) {
        float l = dot(unpremultiply(pixel).rgb, \(luma));
        float ls = dot(unpremultiply(soft).rgb, \(luma));
        float e = smoothstep(0.015, 0.08, abs(l - ls));
        return vec4(e, e, e, 1.0);
    }
    """)
    private static let defringeKernel = CIColorKernel(source: """
    float hueOf(vec3 c) {
        float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b)), d = mx - mn;
        if (d < 0.0001) return -1.0;
        float h;
        if (mx == c.r) h = mod((c.g - c.b) / d, 6.0);
        else if (mx == c.g) h = (c.b - c.r) / d + 2.0;
        else h = (c.r - c.g) / d + 4.0;
        return h * 60.0;
    }
    float inRange(float h, vec2 r) { return h < 0.0 ? 0.0 : smoothstep(r.x - 15.0, r.x, h) * (1.0 - smoothstep(r.y, r.y + 15.0, h)); }
    kernel vec4 defringe(__sample pixel, __sample edges, vec3 purple, vec3 green) {
        vec4 p = unpremultiply(pixel);
        vec3 c = clamp(p.rgb, 0.0, 1.0);
        float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
        float sat = mx > 0.0001 ? (mx - mn) / mx : 0.0;
        float h = hueOf(c);
        float w = edges.r * smoothstep(0.08, 0.25, sat) * max(purple.x * inRange(h, purple.yz), green.x * inRange(h, green.yz));
        float l = dot(p.rgb, \(luma));
        p.rgb = mix(p.rgb, vec3(l), clamp(w, 0.0, 1.0));
        return premultiply(p);
    }
    """)
    static func defringe(_ image: CIImage, settings: DefringeSettings) throws -> CIImage {
        let s = settings.sanitized
        guard s.hasEffect else { return image }
        let input = try encoded(image), side = shortSide(image.extent)
        guard let edges = edgeKernel?.apply(extent: image.extent, arguments: [input, blur(input, max(1, side * 0.0015))]) else { throw EditError.render }
        let spread = blur(edges, max(1, side * 0.001))
        let purple = CIVector(x: s.purpleAmount, y: s.purpleLow, z: s.purpleHigh)
        let green = CIVector(x: s.greenAmount, y: s.greenLow, z: s.greenHigh)
        guard let out = defringeKernel?.apply(extent: image.extent, arguments: [input, spread, purple, green]) else { throw EditError.render }
        return try decoded(out)
    }
}

/// Lightroom-style Auto: reads the tonal distribution entering Develop and proposes slider values
/// the photographer can keep refining. Operates on the sRGB luminance histogram.
public enum AutoTone {
    static func percentile(_ bins: [Int], _ fraction: Double) -> Double {
        let total = bins.reduce(0, +)
        guard total > 0 else { return 0.5 }
        let target = Double(total) * fraction
        var running = 0
        for (i, count) in bins.enumerated() { running += count; if Double(running) >= target { return Double(i)/255 } }
        return 1
    }
    private static func linear(_ v: Double) -> Double { v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055, 2.4) }
    private static func encode(_ v: Double) -> Double { let v = max(0, v); return v <= 0.0031308 ? v*12.92 : 1.055*pow(v, 1/2.4)-0.055 }
    /// Returns `edits` with exposure, contrast, highlights, shadows, whites, blacks and vibrance set.
    public static func apply(_ histogram: PhotoHistogram, to edits: PhotoEdits) -> PhotoEdits {
        let bins = histogram.luminance
        guard bins.reduce(0, +) > 0 else { return edits }
        let p01 = percentile(bins, 0.01), p05 = percentile(bins, 0.05), p10 = percentile(bins, 0.10)
        let p50 = percentile(bins, 0.50), p90 = percentile(bins, 0.90), p99 = percentile(bins, 0.99)
        // Exposure brings the median toward middle gray, damped so bright or dark scenes keep their key.
        let ev = min(2, max(-2, log2(linear(0.46)/max(0.002, linear(max(p50, 0.01)))) * 0.75))
        func shifted(_ v: Double) -> Double { min(1.2, encode(linear(v) * pow(2, ev))) }
        let top = shifted(p99), bottom = shifted(p01), low = shifted(p05)
        var next = edits
        next.exposure = (ev * 100).rounded() / 100
        next.highlights = top > 0.97 ? max(0.45, 1 - (top - 0.9) * 2.5) : 1
        next.whites = top < 0.9 ? min(0.5, (0.95 - top) * 2) : (top > 1 ? -min(0.4, (top - 1) * 2) : 0)
        next.shadows = low < 0.1 ? min(0.5, (0.12 - low) * 3) : 0
        next.blacks = bottom > 0.05 ? -min(0.5, (bottom - 0.02) * 3) : (bottom < 0.004 ? 0.08 : 0)
        let spread = shifted(p90) - shifted(p10)
        next.contrast = spread < 0.55 ? 1 + min(0.25, (0.6 - spread) * 0.6) : (spread > 0.85 ? 0.92 : 1)
        next.vibrance = max(edits.vibrance, 0.15)
        for path in [\PhotoEdits.highlights, \.whites, \.shadows, \.blacks, \.contrast] { next[keyPath: path] = (next[keyPath: path] * 100).rounded() / 100 }
        return next
    }
}

/// Marks clipped pixels of a displayed render: red where a channel reaches white, blue where a channel reaches black.
/// Thresholds match `PhotoHistogram`, so the overlay shows exactly what the histogram counts.
public enum ClippingOverlay {
    private static let kernel = CIColorKernel(source: """
    kernel vec4 clippingOverlay(__sample pixel) {
        vec3 c = unpremultiply(pixel).rgb;
        if (pixel.a < 0.01) return vec4(0.0);
        if (max(c.r, max(c.g, c.b)) >= 0.998) return vec4(0.85, 0.08, 0.08, 0.85);
        if (min(c.r, min(c.g, c.b)) <= 0.002) return vec4(0.08, 0.3, 0.85, 0.85);
        return vec4(0.0);
    }
    """)
    public static func render(_ displayed: CGImage) -> CGImage? {
        let space = displayed.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let input = CIImage(cgImage: displayed).matchedFromWorkingSpace(to: space),
              let overlay = kernel?.apply(extent: input.extent, arguments: [input]) else { return nil }
        return ModernRenderer.context.createCGImage(overlay, from: input.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
    /// Edits that keep only what changes the frame, so a "before" render lines up with the edited one.
    public static func geometryOnly(_ edits: PhotoEdits) -> PhotoEdits {
        var before = PhotoEdits()
        before.rotation = edits.rotation; before.flip = edits.flip; before.crop = edits.crop
        if edits.straighten != 0 { before.straighten = edits.straighten }
        if edits.lens.hasEffect { before.lens = edits.lens }
        return before
    }
}
