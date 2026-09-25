import Foundation

/// A crop shape. Ratio presets only lock proportions; resolution presets also name the
/// output size they are meant for, so the crop can be checked against it.
public struct CropPreset: Equatable, Sendable {
    public enum Orientation: Sendable { case square, horizontal, vertical }
    public let name: String
    public let width: Int
    public let height: Int
    public let isResolution: Bool

    public init(_ name: String, _ width: Int, _ height: Int, resolution: Bool = false) {
        self.name = name; self.width = width; self.height = height; self.isResolution = resolution
    }
    public var aspect: Double { Double(width)/Double(height) }
    public var orientation: Orientation { width == height ? .square : (width > height ? .horizontal : .vertical) }
    public var ratioLabel: String { CropGeometry.ratioLabel(width: Double(width), height: Double(height)) }
    public var title: String {
        isResolution ? "\(name) · \(width) × \(height) · \(ratioLabel)" : "\(name) · \(ratioLabel)"
    }
    /// True when a crop of this many pixels fills the preset's resolution without enlarging.
    public func isFilled(byWidth pixelWidth: Int, height pixelHeight: Int) -> Bool {
        !isResolution || (pixelWidth >= width && pixelHeight >= height)
    }
    /// The same shape turned 90°: the listed preset with swapped dimensions, else one with the inverse ratio.
    public var rotated: CropPreset? {
        let pool = orientation == .horizontal ? Self.vertical : Self.horizontal
        return pool.first { $0.width == height && $0.height == width }
            ?? pool.first { abs($0.aspect*aspect - 1) < 0.0001 }
    }

    public static let square: [CropPreset] = [
        CropPreset("Square", 1, 1),
        CropPreset("Square post", 1080, 1080, resolution: true),
    ]
    public static let horizontal: [CropPreset] = [
        CropPreset("Photo", 3, 2),
        CropPreset("Standard", 4, 3),
        CropPreset("Print", 5, 4),
        CropPreset("Widescreen", 16, 9),
        CropPreset("Cinema", 21, 9),
        CropPreset("HD 720p", 1280, 720, resolution: true),
        CropPreset("Full HD", 1920, 1080, resolution: true),
        CropPreset("QHD", 2560, 1440, resolution: true),
        CropPreset("4K UHD", 3840, 2160, resolution: true),
        CropPreset("Landscape post", 1080, 566, resolution: true),
    ]
    public static let vertical: [CropPreset] = [
        CropPreset("Photo", 2, 3),
        CropPreset("Standard", 3, 4),
        CropPreset("Print", 4, 5),
        CropPreset("Widescreen", 9, 16),
        CropPreset("Cinema", 9, 21),
        CropPreset("Portrait post", 1080, 1350, resolution: true),
        CropPreset("Story / Reel", 1080, 1920, resolution: true),
        CropPreset("Vertical HD 720p", 720, 1280, resolution: true),
        CropPreset("Vertical QHD", 1440, 2560, resolution: true),
        CropPreset("Vertical 4K UHD", 2160, 3840, resolution: true),
    ]
}

extension CropGeometry {
    private static let commonRatios: [(Double, String)] = [
        (1, "1:1"), (5.0/4, "5:4"), (4.0/5, "4:5"), (4.0/3, "4:3"), (3.0/4, "3:4"), (3.0/2, "3:2"), (2.0/3, "2:3"),
        (16.0/10, "16:10"), (10.0/16, "10:16"), (16.0/9, "16:9"), (9.0/16, "9:16"), (1.85, "1.85:1"), (1.91, "1.91:1"), (1/1.91, "1:1.91"),
        (2, "2:1"), (0.5, "1:2"), (21.0/9, "21:9"), (9.0/21, "9:21"), (2.39, "2.39:1"),
    ]
    /// A readable aspect ratio such as "3:2", "≈ 16:9" or "1.62:1".
    public static func ratioLabel(width: Double, height: Double) -> String {
        guard width.isFinite, height.isFinite, width >= 0.5, height >= 0.5 else { return "—" }
        let value = width/height
        let (ratio, label) = commonRatios.min { abs($0.0/value-1) < abs($1.0/value-1) }!
        // A locked crop that is off by one pixel still reads as the exact ratio.
        if abs(ratio/value-1) <= 1/min(width, height) + 0.0005 { return label }
        let w = Int(width.rounded()), h = Int(height.rounded()), d = gcd(w, h)
        if w/d <= 21 && h/d <= 21 { return "\(w/d):\(h/d)" }
        if abs(ratio/value-1) <= 0.015 { return "≈ " + label }
        return value >= 1 ? String(format: "%.2f:1", value) : String(format: "1:%.2f", 1/value)
    }
    /// Whole-pixel size of a normalized crop rectangle.
    public static func pixelSize(of rect: CGRect, in size: CGSize) -> (width: Int, height: Int) {
        (max(1, Int((rect.width*size.width).rounded())), max(1, Int((rect.height*size.height).rounded())))
    }
    public static func sizeLabel(width: Int, height: Int) -> String {
        "\(width) × \(height) px · " + ratioLabel(width: Double(width), height: Double(height))
    }
    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? max(1, a) : gcd(b, a % b) }
}
