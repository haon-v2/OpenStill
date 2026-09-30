import Foundation
import CoreImage

/// Smart Contrast: contrast that pivots on the photo's own middle tone, rolls off gently at both ends so nothing clips,
/// works on brightness only (colors keep their hue and saturation), and adds a little local contrast when raised.
public enum SmartContrast {
    private static let kernel = CIColorKernel(source: """
    kernel vec4 smartContrast(__sample s, float pivot, float amount) {
        vec3 c = max(s.rgb, vec3(0.0));
        float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
        if (lum <= 0.00001) { return s; }
        float p = pow(lum, 1.0 / 2.2);
        if (p >= 1.0) { return s; }
        float f;
        if (amount >= 0.0) {
            // An S-curve through the pivot; ends stay at black and white.
            float k = 1.0 + amount * 0.9;
            float up = p < pivot ? pivot * pow(p / pivot, k) : 1.0 - (1.0 - pivot) * pow((1.0 - p) / (1.0 - pivot), k);
            f = mix(p, up, 0.85);
        } else {
            // Lower contrast pulls midtones toward the pivot. The squared weight leaves deep shadows and highlights nearly alone (no milky blacks).
            float w = 4.0 * p * (1.0 - p);
            f = p + (-amount) * 0.9 * (pivot - p) * w * w;
        }
        float ratio = pow(max(f, 0.0), 2.2) / lum;
        return vec4(s.rgb * ratio, s.a);
    }
    """)
    /// The middle tone: the average brightness in perceptual terms, kept between 0.3 and 0.7.
    public static func pivot(_ image: CIImage) -> Double {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite else { return 0.5 }
        let scale = min(1, 256 / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let gamma = small.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1 / 2.2])
        let average = gamma.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: small.extent)])
        var rgba = [Float](repeating: 0, count: 4)
        ModernRenderer.context.render(average, toBitmap: &rgba, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        let lum = Double(0.2126 * rgba[0] + 0.7152 * rgba[1] + 0.0722 * rgba[2])
        return lum.isFinite ? min(0.7, max(0.3, lum)) : 0.5
    }
    /// `contrast` is the slider value: 1 is neutral, 0.5 the flattest, 1.5 the strongest.
    public static func apply(_ image: CIImage, contrast: Double, pivot fixed: Double? = nil, localContrast: Bool = true) throws -> CIImage {
        let amount = min(1, max(-1, (contrast.isFinite ? contrast : 1) - 1) * 2)
        guard amount != 0, let kernel else { return image }
        let pivot = fixed ?? pivot(image)
        guard var out = kernel.apply(extent: image.extent, arguments: [image, pivot, amount]) else { throw EditError.render }
        // Raised contrast also gets a touch of broad local contrast, so midtones gain depth rather than just steepness.
        if amount > 0 && localContrast { out = try DevelopTools.clarity(out, amount: amount * 0.12) }
        return out.cropped(to: image.extent)
    }
}
extension PhotoEdits {
    /// Whether Contrast uses Smart Contrast. Edits saved before it existed keep the original curve until Contrast is changed.
    public var usesSmartContrast: Bool {
        get { advanced?.contrastModel == "smart" }
        set { ensureAdvanced(); advanced!.contrastModel = newValue ? "smart" : nil }
    }
    /// Called with the previous edits: a changed Contrast switches this edit to Smart Contrast, a changed Temp or Tint to the
    /// corrected white balance. Once switched, an edit stays switched: the panel can hand over a copy made before the
    /// switch (for example the final value when a slider is released), which must not quietly switch it back.
    public mutating func adoptSmartContrast(changedFrom old: PhotoEdits) {
        if (contrast != old.contrast || old.usesSmartContrast) && !usesSmartContrast { usesSmartContrast = true }
        if (temperature != old.temperature || tint != old.tint || old.usesCorrectedWhiteBalance) && !usesCorrectedWhiteBalance { usesCorrectedWhiteBalance = true }
    }
    /// Whether Temperature and Tint on rendered photos go the right way (higher warms, positive Tint adds magenta).
    /// Edits saved before the fix keep their original look until Temperature or Tint is changed. RAW photos were always right.
    public var usesCorrectedWhiteBalance: Bool {
        get { advanced?.whiteBalanceModel == "corrected" }
        set { ensureAdvanced(); advanced!.whiteBalanceModel = newValue ? "corrected" : nil }
    }
}
