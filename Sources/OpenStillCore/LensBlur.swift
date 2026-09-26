import Foundation
import CoreImage

/// Depth-driven background (and foreground) blur, like a wide-aperture lens. OpenStill's own approximation:
/// a variable Gaussian-like blur whose radius grows with distance from the focus range, not a physical bokeh simulation.
public struct LensBlurSettings: Codable, Equatable, Sendable {
    /// 0…1: how strong the blur gets far from focus.
    public var amount = 0.0
    /// 0…1 depth kept sharp (0 = far, 1 = near) and how wide that band is.
    public var focus = 0.85
    public var range = 0.25
    /// Grayscale depth map in source orientation (near = white).
    public var depthAsset: String?
    /// Where the depth map came from: "camera" (photo's depth data), "ai" (estimated), or "subject" (subject kept sharp).
    public var depthSource: String?
    /// Blur things nearer than the focus band too.
    public var blurForeground = true
    public init() {}
    public var hasEffect: Bool { amount > 0 && depthAsset != nil }
    public var sanitized: Self {
        var s = self
        func clamp(_ x: Double, _ fallback: Double) -> Double { x.isFinite ? min(1, max(0, x)) : fallback }
        s.amount = clamp(amount, 0); s.focus = clamp(focus, 0.85); s.range = clamp(range, 0.25)
        return s
    }
}

extension PhotoEdits {
    public var lensBlur: LensBlurSettings {
        get { advanced?.lensBlur ?? LensBlurSettings() }
        set { ensureAdvanced(); advanced!.lensBlur = newValue == LensBlurSettings() ? nil : newValue.sanitized }
    }
    public var lensBlurAmount: Double { get { lensBlur.amount } set { var s = lensBlur; s.amount = newValue; lensBlur = s } }
    public var lensBlurFocus: Double { get { lensBlur.focus } set { var s = lensBlur; s.focus = newValue; lensBlur = s } }
    public var lensBlurRange: Double { get { lensBlur.range } set { var s = lensBlur; s.range = newValue; lensBlur = s } }
    public var lensBlurForeground: Bool { get { lensBlur.blurForeground } set { var s = lensBlur; s.blurForeground = newValue; lensBlur = s } }
}

public enum LensBlur {
    /// Blur strength per pixel: 0 inside the focus band, rising to 1 at a distance of 0.35 from it.
    static let mapKernel = CIColorKernel(source: """
    kernel vec4 lensBlurMap(__sample d, float focus, float halfRange, float foreground) {
        float depth = clamp(d.r, 0.0, 1.0);
        float behind = max(0.0, (focus - halfRange) - depth);
        float front = max(0.0, depth - (focus + halfRange)) * foreground;
        float v = smoothstep(0.0, 0.35, max(behind, front));
        return vec4(v, v, v, 1.0);
    }
    """)
    /// The blur strength map in output (geometry) space.
    public static func strengthMap(settings: LensBlurSettings, geometry: EditGeometry, lens: OpticalCorrection, input: CIImage, modern: Bool) throws -> CIImage {
        let s = settings.sanitized
        var depth = AdjustmentMask(kind: "depthMap"); depth.asset = s.depthAsset; depth.feather = 0
        let map = try depth.coverage(geometry: geometry, lens: lens, input: input, modern: modern)
        guard let strength = mapKernel?.apply(extent: map.extent, arguments: [map, s.focus, s.range / 2, s.blurForeground ? 1.0 : 0.0]) else { throw EditError.render }
        return strength.cropped(to: geometry.extent)
    }
    public static func apply(_ image: CIImage, settings: LensBlurSettings, geometry: EditGeometry, lens: OpticalCorrection, modern: Bool) throws -> CIImage {
        let s = settings.sanitized
        guard s.hasEffect else { return image }
        let extent = image.extent
        let map = try strengthMap(settings: s, geometry: geometry, lens: lens, input: image, modern: modern)
        // Radius relative to the photo so previews match full-size exports.
        let radius = s.amount * Double(min(geometry.sourceSize.width, geometry.sourceSize.height)) * 0.025
        let blurred = image.clampedToExtent().applyingFilter("CIMaskedVariableBlur", parameters: [kCIInputRadiusKey: max(0.5, radius), "inputMask": map.clampedToExtent()])
        return blurred.cropped(to: extent)
    }
}

/// Marks a RAW version whose base image is the AI-denoised sensor data: every edit stays live on top of it.
/// White balance was baked in at `temperature`/`tint`; later changes are applied relative to that.
public struct RawDenoiseBase: Codable, Equatable, Sendable {
    public var temperature: Double, tint: Double
    public init(temperature: Double, tint: Double) { self.temperature = temperature; self.tint = tint }
    /// Only what the RAW decoder uses, so the denoised image is the plain decoded photo.
    public static func decodeOnly(_ edits: PhotoEdits) -> PhotoEdits {
        var e = PhotoEdits()
        e.temperature = edits.temperature; e.tint = edits.tint
        if let a = edits.advanced { e.ensureAdvanced(); e.advanced!.rawRecovery = a.rawRecovery; e.advanced!.rawWhiteBalance = a.rawWhiteBalance; e.advanced!.rawOptions = a.rawOptions }
        return e
    }
}
