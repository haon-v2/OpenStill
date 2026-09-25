import Foundation
import CoreImage

/// Percentage controls; the center is in oriented source coordinates and may be outside 0...1.
public struct SunraysSettings: Codable, Equatable {
    public var amount = 0.0, overallLook = 50.0, length = 65.0, penetration = 40.0
    public var sunRadius = 20.0, glowRadius = 40.0, glowAmount = 35.0
    public var rayCount = 35.0, randomize = 0.0, sunWarmth = 30.0, raysWarmth = 30.0
    public var centerX = 0.7, centerY = 0.8
    public init() {}
    public var sanitized: Self {
        var s = self
        for path in [\Self.amount, \.overallLook, \.length, \.penetration, \.sunRadius, \.glowRadius, \.glowAmount, \.randomize, \.sunWarmth, \.raysWarmth] {
            let value = s[keyPath:path]; s[keyPath:path] = value.isFinite ? min(100,max(0,value)) : Self()[keyPath:path]
        }
        s.rayCount = rayCount.isFinite ? min(100,max(1,rayCount.rounded())) : 35
        // A generous numerical safety bound, not a photo-edge clamp.
        s.centerX = centerX.isFinite ? min(100,max(-100,centerX)) : 0.7
        s.centerY = centerY.isFinite ? min(100,max(-100,centerY)) : 0.8
        return s
    }
    public func displayedCenter(geometry: EditGeometry) -> CGPoint {
        let p = CGPoint(x:centerX*geometry.sourceSize.width,y:centerY*geometry.sourceSize.height).applying(geometry.transform)
        return CGPoint(x:p.x/max(1,geometry.extent.width),y:p.y/max(1,geometry.extent.height))
    }
    public mutating func place(at point: CGPoint, geometry: EditGeometry) {
        let p = CGPoint(x:point.x*geometry.extent.width,y:point.y*geometry.extent.height).applying(geometry.transform.inverted())
        centerX = p.x/max(1,geometry.sourceSize.width); centerY = p.y/max(1,geometry.sourceSize.height)
        self = sanitized
    }
}

extension PhotoEdits {
    public var sunSettings: SunraysSettings {
        get {
            if let value = advanced?.sunSettings { return value }
            var s = SunraysSettings(); s.amount = sunrays*100; s.length = sunLength*100
            s.centerX = sunX; s.centerY = sunY
            return s
        }
        set { ensureAdvanced(); advanced!.sunSettings = newValue.sanitized }
    }
    /// Convert the old output-relative center only when the user first edits the new tool.
    public func editableSunSettings(sourceSize: CGSize) -> SunraysSettings {
        var s = sunSettings
        if advanced?.sunSettings == nil { s.place(at:CGPoint(x:sunX,y:sunY),geometry:EditGeometry(size:sourceSize,edits:self)) }
        return s
    }
}

/// OpenStill's local renderer. These controls follow the photographic Sunrays vocabulary;
/// they do not implement or embed Skylum's proprietary algorithm.
enum PhotographicSunrays {
    private static let composite = CIColorKernel(source: """
    kernel vec4 sunlight(__sample original, __sample visibility, vec2 center, float scale,
        float amount, float look, float rayLength, float penetration, float radius,
        float glowRadius, float glowAmount, float count, float seed, float sunWarmth, float raysWarmth) {
        vec4 p = unpremultiply(original);
        vec2 delta = (destCoord() - center) / scale;
        float distance = length(delta);
        float angle = atan(delta.y, delta.x);
        // Periodic angular lobes with irregular width and intensity; stable under scaling.
        float phase = angle * count + seed * 2.39996;
        float wobble = sin(angle * 7.0 + seed) * 1.1 + sin(angle * 13.0 - seed * 0.7) * 0.45;
        float spokes = pow(max(0.0, 0.5 + 0.5 * cos(phase + wobble)), 3.8);
        float variation = 0.35 + 0.65 * pow(0.5 + 0.5 * sin(angle * 11.0 + seed * 1.7), 2.0);
        float reach = max(0.001, rayLength * 1.65);
        float falloff = exp(-distance * 2.5 / reach) * (1.0 - smoothstep(reach * 0.6, reach, distance));
        float transmission = mix(clamp(visibility.r, 0.0, 1.0), 1.0, penetration * penetration);
        float rays = spokes * variation * falloff * transmission * smoothstep(0.0, 0.02, rayLength);
        float diskRadius = radius * 0.045;
        float disk = (1.0 - smoothstep(diskRadius * 0.35, max(0.00001,diskRadius), distance)) * step(0.00001,radius);
        float haloSize = max(0.0001,glowRadius * 0.25);
        float halo = exp(-distance * distance / (haloSize * haloSize)) * glowAmount * step(0.00001,glowRadius);
        vec3 sunColor = mix(vec3(1.0), vec3(1.0,0.68,0.32), sunWarmth);
        vec3 rayColor = mix(vec3(1.0), vec3(1.0,0.72,0.40), raysWarmth);
        vec3 light = (sunColor * (disk * 4.0 + halo * 0.30) + rayColor * rays * 0.28) * (0.35 + look * 1.3);
        // Screen-like illumination preserves highlights above SDR white instead of clipping them.
        vec3 result = p.rgb + max(vec3(0.0), vec3(1.0)-p.rgb) * (vec3(1.0)-exp(-light * amount));
        return premultiply(vec4(result * pow(2.0,(look-0.5)*0.4*amount),p.a));
    }
    """)

    static func apply(_ image: CIImage, settings: SunraysSettings, geometry: EditGeometry) throws -> CIImage {
        let s = settings.sanitized
        guard s.amount > 0 else { return image }
        let extent = image.extent, point = s.displayedCenter(geometry:geometry)
        let center = CIVector(x:point.x*extent.width,y:point.y*extent.height)
        // Low-resolution radial transmission avoids an expensive full-resolution ray march.
        let factor = min(1,512/max(extent.width,extent.height))
        let small = image.transformed(by:CGAffineTransform(scaleX:factor,y:factor))
        let visibility = small.applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:0,kCIInputContrastKey:2,kCIInputBrightnessKey:-0.12])
            .clampedToExtent().applyingFilter("CIZoomBlur",parameters:[kCIInputCenterKey:CIVector(x:center.x*factor,y:center.y*factor),kCIInputAmountKey:45])
            .applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:1.2]).transformed(by:CGAffineTransform(scaleX:1/factor,y:1/factor)).cropped(to:extent)
        guard let output = composite?.apply(extent:extent,arguments:[image,visibility,center,max(geometry.sourceSize.width,geometry.sourceSize.height),s.amount/100,s.overallLook/100,s.length/100,s.penetration/100,s.sunRadius/100,s.glowRadius/100,s.glowAmount/100,s.rayCount,s.randomize,s.sunWarmth/100,s.raysWarmth/100]) else {throw EditError.render}
        return output.cropped(to:extent)
    }
}
