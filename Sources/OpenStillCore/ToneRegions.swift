import Foundation
import CoreImage

/// Highlights and Shadows the way Lightroom's work: sliders from −1 to +1 centred at 0 (no change).
/// Highlights − darkens bright tones to bring back detail, + brightens them; Shadows + lifts dark tones, − deepens them.
/// Each only reaches its own half of the range, black and white stay where they are, tones never swap order,
/// and only brightness changes, so colors keep their hue.
public enum ToneRegions {
    private static let kernel = CIColorKernel(source: """
    kernel vec4 toneRegions(__sample s, float highlights, float shadows) {
        vec3 c = max(s.rgb, vec3(0.0));
        float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
        if (lum <= 0.00001) { return s; }
        float p = pow(lum, 1.0 / 2.2);
        if (p >= 1.0) { return s; }
        float f = p;
        // Highlights act above 0.4 and Shadows below 0.6 (perceptual). Slopes stay between 0.1 and 1.9, so the curve never folds.
        if (p > 0.4) { f += highlights * 1.5 * (p - 0.4) * (1.0 - p); }
        if (p < 0.6) { f += shadows * 1.5 * p * (0.6 - p); }
        float ratio = pow(max(f, 0.0), 2.2) / lum;
        return vec4(s.rgb * ratio, s.a);
    }
    """)
    public static func apply(_ image: CIImage, highlights: Double, shadows: Double) throws -> CIImage {
        let h = highlights.isFinite ? min(1, max(-1, highlights)) : 0, sh = shadows.isFinite ? min(1, max(-1, shadows)) : 0
        guard h != 0 || sh != 0, let kernel else { return image }
        guard let out = kernel.apply(extent: image.extent, arguments: [image, h, sh]) else { throw EditError.render }
        return out
    }
}
extension PhotoEdits {
    /// Whether Highlights and Shadows use the Lightroom-style sliders. Older edits keep their original rendering until one is moved.
    public var usesToneRegions: Bool { advanced?.toneModel == "regions" }
    /// Highlights from −1 (recover) to +1 (brighten), 0 = no change. For an older edit, its original value shown on the new scale.
    public var highlightsAmount: Double {
        get { usesToneRegions ? (advanced?.toneHighlights ?? 0) : -(1 - highlights) }
        set { guard newValue != highlightsAmount else { return }; adoptToneRegions(); advanced!.toneHighlights = newValue == 0 ? nil : newValue }
    }
    /// Shadows from −1 (deepen) to +1 (lift), 0 = no change.
    public var shadowsAmount: Double {
        get { usesToneRegions ? (advanced?.toneShadows ?? 0) : shadows }
        set { guard newValue != shadowsAmount else { return }; adoptToneRegions(); advanced!.toneShadows = newValue == 0 ? nil : newValue }
    }
    /// Moves an older edit onto the Lightroom-style sliders, carrying its values across.
    private mutating func adoptToneRegions() {
        ensureAdvanced()
        guard !usesToneRegions else { return }
        let h = -(1 - highlights), s = shadows
        advanced!.toneModel = "regions"
        advanced!.toneHighlights = h == 0 ? nil : h; advanced!.toneShadows = s == 0 ? nil : s
        highlights = 1; shadows = 0
    }
}
