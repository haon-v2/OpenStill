import Foundation
import CoreImage

/// The sliders of one mask layer. All start at 0 (no change) and run from −1 to 1, except Exposure (−4…4 stops).
public struct LocalSettings: Codable, Equatable, Sendable {
    public var exposure = 0.0, contrast = 0.0, highlights = 0.0, shadows = 0.0, whites = 0.0, blacks = 0.0
    public var temperature = 0.0, tint = 0.0, saturation = 0.0
    public var clarity = 0.0, texture = 0.0, dehaze = 0.0, sharpness = 0.0, noise = 0.0
    public init() {}
    public var isNeutral: Bool { self == LocalSettings() }
    public static let sliders: [(String, WritableKeyPath<LocalSettings, Double>, ClosedRange<Double>)] = [
        ("Temp", \.temperature, -1...1), ("Tint", \.tint, -1...1),
        ("Exposure", \.exposure, -4...4), ("Contrast", \.contrast, -1...1), ("Highlights", \.highlights, -1...1), ("Shadows", \.shadows, -1...1),
        ("Whites", \.whites, -1...1), ("Blacks", \.blacks, -1...1),
        ("Texture", \.texture, -1...1), ("Clarity", \.clarity, -1...1), ("Dehaze", \.dehaze, -1...1),
        ("Saturation", \.saturation, -1...1), ("Sharpness", \.sharpness, -1...1), ("Noise", \.noise, 0...1),
    ]
    public var sanitized: LocalSettings {
        var s = self
        for (_, path, range) in Self.sliders { let v = s[keyPath: path]; s[keyPath: path] = v.isFinite ? min(range.upperBound, max(range.lowerBound, v)) : 0 }
        return s
    }
}
/// One mask layer: a name, its sliders and whether it's shown. Its mask lives in the edits' masks under `maskKey`,
/// so every mask tool (brush, linear, radial, AI subject/sky, color and luminance range, depth) works on it.
public struct LocalAdjustment: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var settings = LocalSettings()
    public var hidden = false
    public init(name: String) { self.name = name }
    public var maskKey: String { LocalAdjustment.keyPrefix + id.uuidString }
    public static let keyPrefix = "Mask-"
    public var sanitized: LocalAdjustment { var s = self; s.settings = settings.sanitized; s.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)); if s.name.isEmpty { s.name = "Mask" }; return s }
}
extension PhotoEdits {
    public var localAdjustments: [LocalAdjustment] {
        get { advanced?.localAdjustments ?? [] }
        set { ensureAdvanced(); let l = Array(newValue.prefix(64)).map(\.sanitized); advanced!.localAdjustments = l.isEmpty ? nil : l }
    }
    /// Adds a layer and returns its mask key; the caller then adds a selection to that mask.
    @discardableResult public mutating func addLocalAdjustment(named name: String? = nil) -> LocalAdjustment {
        let layer = LocalAdjustment(name: name ?? "Mask \(localAdjustments.count + 1)")
        localAdjustments.append(layer); return layer
    }
    /// Removes a layer and its mask.
    public mutating func removeLocalAdjustment(_ id: UUID) {
        guard let layer = localAdjustments.first(where: { $0.id == id }) else { return }
        localAdjustments.removeAll { $0.id == id }; setMask(nil, for: layer.maskKey)
    }
    /// A copy of a layer with its own copy of the mask.
    @discardableResult public mutating func duplicateLocalAdjustment(_ id: UUID) -> LocalAdjustment? {
        guard let layer = localAdjustments.first(where: { $0.id == id }) else { return nil }
        var copy = LocalAdjustment(name: layer.name + " copy"); copy.settings = layer.settings; copy.hidden = layer.hidden
        if let mask = advanced?.masks[layer.maskKey] { setMask(mask.independentCopy(), for: copy.maskKey) }
        localAdjustments.append(copy); return copy
    }
    public mutating func updateLocalAdjustment(_ id: UUID, _ change: (inout LocalAdjustment) -> Void) {
        var layers = localAdjustments
        guard let i = layers.firstIndex(where: { $0.id == id }) else { return }
        change(&layers[i]); localAdjustments = layers
    }
}
/// Renders one layer's settings on the whole image; the pipeline then blends it in through the layer's mask.
public enum LocalAdjustments {
    public static func apply(_ input: CIImage, settings raw: LocalSettings, sourceSize: CGSize) throws -> CIImage {
        let s = raw.sanitized, extent = input.extent
        var image = input
        if s.temperature != 0 || s.tint != 0 {
            // ±1 moves white balance about ±2000 K and ±50 tint, like a strong Lightroom mask. Positive is warmer: a lower target neutral warms the photo.
            image = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 - s.temperature * 2000, y: s.tint * 50)])
        }
        if s.exposure != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: s.exposure]) }
        if s.highlights < 0 || s.shadows > 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 1 + min(0, s.highlights), "inputShadowAmount": max(0, s.shadows)])
        }
        if s.contrast != 0 { image = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + s.contrast * 0.5]) }
        // Brighter highlights, deeper shadows, whites and blacks as a gentle tone curve.
        let lift = max(0, s.highlights), crush = min(0, s.shadows)
        if lift != 0 || crush != 0 || s.whites != 0 || s.blacks != 0 {
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: max(0, s.blacks * 0.15)),
                "inputPoint1": CIVector(x: 0.25, y: 0.25 + crush * 0.08 + s.blacks * 0.05),
                "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + lift * 0.08 + s.whites * 0.05),
                "inputPoint4": CIVector(x: 1, y: 1 + min(0, s.whites) * 0.15)])
        }
        if s.saturation != 0 { image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + s.saturation]) }
        image = image.cropped(to: extent)
        if s.dehaze != 0 { image = try DevelopTools.dehaze(image, amount: s.dehaze) }
        if s.clarity != 0 { image = try DevelopTools.clarity(image, amount: s.clarity) }
        if s.texture != 0 { image = try DevelopTools.texture(image, amount: s.texture) }
        if s.noise > 0 { image = image.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": s.noise * 0.08, kCIInputSharpnessKey: 0.2]) }
        if s.sharpness > 0 { image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: s.sharpness * 1.5]) }
        else if s.sharpness < 0 { image = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: -s.sharpness * max(1, sourceSize.width / 1500)]) }
        return image.cropped(to: extent)
    }
}
