import Foundation
import CoreImage

public enum GlowMode: String, Codable, CaseIterable {
    case glow, softFocus, orton, ortonSoft
    public var title: String {
        switch self {
        case .glow: return "Glow"
        case .softFocus: return "Soft Focus"
        case .orton: return "Orton Effect"
        case .ortonSoft: return "Orton Effect Soft"
        }
    }
}

/// Slider values are stored in the same percentage units displayed in the sidebar.
public struct GlowSettings: Codable, Equatable {
    public var mode: GlowMode = .glow
    public var amount = 0.0
    public var softness = 50.0
    public var brightness = 0.0
    public var contrast = 0.0
    public var warmth = 0.0
    public init() {}
    public var sanitized: GlowSettings {
        var result = self
        func limit(_ value: Double, _ low: Double, _ high: Double, _ fallback: Double = 0) -> Double {
            value.isFinite ? min(high, max(low, value)) : fallback
        }
        result.amount = limit(amount, 0, 100)
        result.softness = limit(softness, 0, 100, 50)
        result.brightness = limit(brightness, -100, 100)
        result.contrast = limit(contrast, -100, 100)
        result.warmth = limit(warmth, -100, 100)
        return result
    }
}

extension PhotoEdits {
    public var glow: GlowSettings {
        get { advanced?.glow ?? GlowSettings() }
        set { ensureAdvanced(); advanced!.glow = newValue == GlowSettings() ? nil : newValue }
    }
}

/// Photographic diffusion in Core Image's linear-light working space.
/// This is OpenStill's own implementation, not a reproduction of proprietary filters.
enum PhotographicGlow {
    private static let highlights = CIColorKernel(source: """
        kernel vec4 glowHighlights(__sample pixel) {
            vec4 p = unpremultiply(pixel);
            float luminance = dot(p.rgb, vec3(0.2126, 0.7152, 0.0722));
            float selection = smoothstep(0.15, 0.65, luminance);
            return premultiply(vec4(p.rgb * selection, p.a));
        }
        """)
    private static let composite = CIColorKernel(source: """
        kernel vec4 photographicGlow(__sample original, __sample diffuse, __sample light,
                                    float mode, float amount, float brightness, float contrast, float warmth) {
            vec4 p = unpremultiply(original);
            vec3 base = p.rgb;
            vec3 blur = unpremultiply(diffuse).rgb;
            vec3 bloom = unpremultiply(light).rgb;
            vec3 tone = vec3(1.0 + warmth * 0.18, 1.0 + warmth * 0.02, 1.0 - warmth * 0.18);
            float gain = pow(2.0, brightness * 0.8);
            float exponent = pow(2.0, contrast * 0.65);
            // A power curve leaves black at zero, avoiding a uniform veil in Glow mode.
            bloom = clamp(pow(max(bloom, vec3(0.0)), vec3(exponent)) * gain * tone, 0.0, 1.0);
            blur = clamp((blur - vec3(0.18)) * (1.0 + contrast * 0.45) + vec3(0.18), 0.0, 1.0);
            blur = clamp(blur * gain * tone, 0.0, 1.0);
            vec3 result;
            if (mode < 0.5) {
                result = 1.0 - (1.0 - base) * (1.0 - bloom * 0.85);
            } else if (mode < 1.5) {
                vec3 focused = mix(base, blur, 0.28);
                result = 1.0 - (1.0 - focused) * (1.0 - bloom * 0.32);
            } else if (mode < 2.5) {
                vec3 luminous = 1.0 - (1.0 - base) * (1.0 - blur);
                vec3 rich = clamp((blur - vec3(0.18)) * 1.25 + vec3(0.18), 0.0, 1.0);
                result = mix(base, clamp(luminous * (rich * 1.65 + vec3(0.20)), 0.0, 1.0), 0.65);
            } else {
                vec3 focused = mix(base, blur, 0.40);
                result = (1.0 - (1.0 - focused) * (1.0 - bloom * 0.40)) * 0.96 + vec3(0.008);
            }
            return premultiply(vec4(mix(base, clamp(result, 0.0, 1.0), amount), p.a));
        }
        """)

    static func apply(_ image: CIImage, settings: GlowSettings, sourceSize: CGSize) throws -> CIImage {
        let s = settings.sanitized
        guard s.amount > 0 else { return image }
        let extent = image.extent
        guard let highlight = highlights?.apply(extent: extent, arguments: [image]) else { throw EditError.render }
        // Source-relative radii keep thumbnail, cropped-view and export diffusion in proportion.
        let dimension = max(sourceSize.width, sourceSize.height)
        let radius = dimension * (0.001 + pow(s.softness / 100, 1.4) * 0.019)
        func blur(_ input: CIImage, _ radius: Double) -> CIImage {
            input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
        }
        let near = blur(highlight, radius * 0.45)
        let far = blur(highlight, radius * 1.65)
        let bloom = near.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: far, kCIInputTimeKey: 0.35])
        let diffused = s.mode == .glow ? image : blur(image, radius)
        let mode = Double(GlowMode.allCases.firstIndex(of: s.mode)!)
        guard let output = composite?.apply(extent: extent, arguments: [image, diffused, bloom, mode, s.amount / 100, s.brightness / 100, s.contrast / 100, s.warmth / 100]) else { throw EditError.render }
        return output.cropped(to: extent)
    }
}
