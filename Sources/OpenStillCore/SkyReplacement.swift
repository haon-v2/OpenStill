import Foundation
import CoreImage

/// A replacement sky, composited through the photo's "Sky" mask (made with the on-device sky AI) and relighting the
/// rest of the scene to match: a dark, stormy sky darkens and cools the land, a sunset warms it, as in Luminar's Sky AI.
/// The sky image is copied into the photo's assets, so saved edits never change when the library does.
public struct SkyReplacement: Codable, Equatable {
    /// The bundled sky it came from (for the browser); nil for your own photo.
    public var id: String?
    public var name: String
    public var asset: String
    /// The sky image's average color and the color along its lower edge, linear sRGB 0…1.
    public var mean: [Double]
    public var horizonColor: [Double]
    /// 0…1: how strongly the rest of the photo takes on the sky's brightness and color.
    public var relight = 0.6
    /// −1…1: moves the sky down or up.
    public var horizon = 0.0
    /// −2…2 stops on the sky alone.
    public var exposure = 0.0
    /// 0…1: blurs the sky, as if out of focus.
    public var defocus = 0.0
    /// 0…1: a haze of the sky's horizon color over the land, for depth.
    public var atmosphere = 0.15
    public var flip = false

    public init(id: String?, name: String, asset: String, mean: [Double], horizonColor: [Double], relight: Double = 0.6) {
        self.id = id; self.name = name; self.asset = asset; self.mean = mean; self.horizonColor = horizonColor; self.relight = relight
    }
    public var sanitized: SkyReplacement {
        func c(_ v: Double, _ lo: Double, _ hi: Double, _ f: Double) -> Double { v.isFinite ? min(hi, max(lo, v)) : f }
        func color(_ v: [Double]) -> [Double] { v.count == 3 ? v.map { c($0, 0, 1, 0.5) } : [0.35, 0.47, 0.7] }
        var s = self
        s.mean = color(mean); s.horizonColor = color(horizonColor)
        s.relight = c(relight, 0, 1, 0.6); s.horizon = c(horizon, -1, 1, 0); s.exposure = c(exposure, -2, 2, 0)
        s.defocus = c(defocus, 0, 1, 0); s.atmosphere = c(atmosphere, 0, 1, 0.15)
        return s
    }

    /// A clear daylight sky's average (linear), the reference a new sky's light is compared with.
    static let reference = [0.34, 0.47, 0.72]
    static func luminance(_ c: [Double]) -> Double { 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2] }
    /// Per-channel gains for the land: brightness follows the sky's brightness, color follows its tint.
    public var sceneGains: [Double] {
        let s = sanitized, lum = max(Self.luminance(s.mean), 1e-4), refLum = Self.luminance(Self.reference)
        let brightness = min(1.6, max(0.1, pow(lum / refLum, 0.6 * s.relight)))
        return (0..<3).map { i in
            let tint = (s.mean[i] / lum) / (Self.reference[i] / refLum)
            return min(2.5, max(0.05, brightness * pow(max(tint, 1e-3), 0.45 * s.relight)))
        }
    }
    /// Darker skies also mute the land's color a little.
    public var sceneSaturation: Double {
        let s = sanitized
        return 1 - 0.45 * s.relight * max(0, 1 - Self.luminance(s.mean) / Self.luminance(Self.reference))
    }

    /// The sky image placed over the frame: fills it, top-anchored, moved by `horizon`, then exposure, defocus and flip.
    static func plate(_ sky: CIImage, extent: CGRect, settings s: SkyReplacement) -> CIImage {
        var image = sky
        if s.flip { image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -image.extent.maxX - image.extent.minX, y: 0)) }
        // A little taller than the frame, so the horizon control has room to move.
        let scale = max(extent.width / image.extent.width, extent.height * 1.25 / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Horizon −1 lines up the tops (more of the sky's lower part is hidden behind the land), +1 the bottoms.
        let spare = image.extent.height - extent.height
        let bottom = extent.minY - spare * (1 - (s.horizon + 1) / 2)
        image = image.transformed(by: CGAffineTransform(translationX: extent.midX - image.extent.midX, y: bottom - image.extent.minY))
        if s.exposure != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: s.exposure]) }
        if s.defocus > 0 {
            image = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: s.defocus * max(extent.width, extent.height) * 0.012])
        }
        return image.cropped(to: extent)
    }
    /// The land relit to match the sky.
    static func relight(_ image: CIImage, extent: CGRect, settings s: SkyReplacement) -> CIImage {
        var out = image
        if s.relight > 0 {
            let g = s.sceneGains
            out = out.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: g[0], y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: g[1], z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: g[2], w: 0)])
            let saturation = s.sceneSaturation
            if saturation < 0.999 { out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: saturation]) }
        }
        if s.atmosphere > 0 {
            let g = s.relight > 0 ? s.sceneGains : [1, 1, 1], a = s.atmosphere * 0.22
            let h = (0..<3).map { min(1, s.horizonColor[$0] * g[$0] / max(g.max()!, 1e-3) * max(g.max()!, 0.2)) }
            out = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 - a, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1 - a, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 1 - a, w: 0),
                "inputBiasVector": CIVector(x: h[0] * a, y: h[1] * a, z: h[2] * a, w: 0)])
        }
        return out.cropped(to: extent)
    }
}

extension PhotoEdits {
    public var sky: SkyReplacement? {
        get { advanced?.sky }
        set { ensureAdvanced(); advanced!.sky = newValue?.sanitized }
    }
    private mutating func editSky(_ change: (inout SkyReplacement) -> Void) { guard var s = sky else { return }; change(&s); sky = s }
    public var skyRelight: Double { get { sky?.relight ?? 0.6 } set { editSky { $0.relight = newValue } } }
    public var skyHorizon: Double { get { sky?.horizon ?? 0 } set { editSky { $0.horizon = newValue } } }
    public var skyExposure: Double { get { sky?.exposure ?? 0 } set { editSky { $0.exposure = newValue } } }
    public var skyDefocus: Double { get { sky?.defocus ?? 0 } set { editSky { $0.defocus = newValue } } }
    public var skyAtmosphere: Double { get { sky?.atmosphere ?? 0.15 } set { editSky { $0.atmosphere = newValue } } }
    /// The mask key the sky is composited through; it holds the on-device AI sky selection and can be refined like any mask.
    public static let skyMaskKey = "Sky"
}

// MARK: - Library

public struct SkyEntry: Codable, Equatable {
    public let id: String
    public let name: String
    public let category: String
    public let file: String
    public let creator: String
    public let source: String
    public let license: String
    public let mean: [Double]
    public let horizon: [Double]
    public var tags: [String]? = nil
}
public struct SkyCatalog: Codable {
    public let version: Int
    public let skies: [SkyEntry]
}
public struct SkyItem: Equatable {
    public let entry: SkyEntry
    public let url: URL
    /// How strongly each kind of sky relights the land by default.
    public static let defaultRelight = ["Blue Sky": 0.45, "Clouds": 0.5, "Sunset & Sunrise": 0.7, "Dramatic": 0.75, "Overcast": 0.6, "Night": 0.9, "Your Skies": 0.6]
    /// Copies the sky into the photo's assets and sets it, keeping the settings of a sky already there.
    public func applying(to edits: PhotoEdits) throws -> PhotoEdits {
        let asset = try EditStorage.newAsset(extension: url.pathExtension.isEmpty ? "jpg" : url.pathExtension)
        try FileManager.default.copyItem(at: url, to: asset)
        var sky = SkyReplacement(id: entry.id, name: entry.name, asset: asset.lastPathComponent, mean: entry.mean, horizonColor: entry.horizon,
                                 relight: Self.defaultRelight[entry.category] ?? 0.6)
        if let previous = edits.sky { sky.horizon = previous.horizon; sky.exposure = previous.exposure; sky.defocus = previous.defocus; sky.atmosphere = previous.atmosphere; sky.flip = previous.flip }
        var next = edits; next.sky = sky
        return next
    }
}
public struct SkyLibrary {
    public static let categories = ["Blue Sky", "Clouds", "Sunset & Sunrise", "Dramatic", "Overcast", "Night", "Your Skies"]
    public let items: [SkyItem]
    public init(bundled folder: URL?, user: URL) throws {
        var result: [SkyItem] = []
        if let folder {
            let catalog = try JSONDecoder().decode(SkyCatalog.self, from: Data(contentsOf: folder.appendingPathComponent("skies.json")))
            guard catalog.version == 1, Set(catalog.skies.map(\.id)).count == catalog.skies.count else { throw LUTError.invalid }
            for entry in catalog.skies {
                guard entry.license == "CC0-1.0", Self.categories.contains(entry.category), entry.file == URL(fileURLWithPath: entry.file).lastPathComponent,
                      entry.mean.count == 3, entry.horizon.count == 3 else { throw LUTError.invalid }
                result.append(SkyItem(entry: entry, url: folder.appendingPathComponent(entry.file)))
            }
        }
        items = result + Self.userSkies(in: user)
    }
    /// Your own skies: images in `<root>/Skies`, measured once into a `.json` beside each.
    public static func userSkies(in folder: URL) -> [SkyItem] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["jpg", "jpeg", "png", "heic", "tif", "tiff"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return files.compactMap { url in
            let sidecar = url.deletingPathExtension().appendingPathExtension("json")
            guard let data = try? Data(contentsOf: sidecar), let entry = try? JSONDecoder().decode(SkyEntry.self, from: data) else { return nil }
            return SkyItem(entry: entry, url: url)
        }
    }
    /// Adds a photo of a sky to Your Skies, measuring its colors.
    @discardableResult public static func importSky(_ file: URL, into folder: URL) throws -> SkyItem {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let image = CIImage(contentsOf: file) else { throw EditError.render }
        let name = file.deletingPathExtension().lastPathComponent
        var target = folder.appendingPathComponent(file.lastPathComponent), n = 2
        while FileManager.default.fileExists(atPath: target.path) { target = folder.appendingPathComponent("\(name) \(n).\(file.pathExtension)"); n += 1 }
        try FileManager.default.copyItem(at: file, to: target)
        let e = image.extent, bottom = CGRect(x: e.minX, y: e.minY, width: e.width, height: e.height / 8)
        let entry = SkyEntry(id: "user-sky-" + target.lastPathComponent, name: target.deletingPathExtension().lastPathComponent, category: "Your Skies",
                             file: target.lastPathComponent, creator: "Your photo", source: "", license: "Your own", mean: try average(image, e), horizon: try average(image, bottom))
        try JSONEncoder().encode(entry).write(to: target.deletingPathExtension().appendingPathExtension("json"))
        return SkyItem(entry: entry, url: target)
    }
    static func average(_ image: CIImage, _ rect: CGRect) throws -> [Double] {
        let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let context = CIContext(options: [.workingColorSpace: linear, .outputColorSpace: linear])
        var pixel = [Float](repeating: 0, count: 4)
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        context.render(average, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
        return pixel.prefix(3).map { min(1, max(0, Double($0))) }
    }
    public func filtered(_ category: String) -> [SkyItem] { category == "All" ? items : items.filter { $0.entry.category == category } }
    public func selected(for edits: PhotoEdits) -> SkyItem? { edits.sky?.id.flatMap { id in items.first { $0.entry.id == id } } }
}
