import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

extension ExportProfile {
    public var colorSpace: CGColorSpace {
        let name: CFString
        switch self {
        case .sRGB: name = CGColorSpace.sRGB
        case .displayP3: name = CGColorSpace.displayP3
        case .adobeRGB: name = CGColorSpace.adobeRGB1998
        case .proPhotoRGB: name = CGColorSpace.rommrgb
        }
        return CGColorSpace(name: name)!
    }
    public var title: String {
        switch self { case .sRGB: return "sRGB"; case .displayP3: return "Display P3"; case .adobeRGB: return "Adobe RGB"; case .proPhotoRGB: return "ProPhoto RGB" }
    }
}
private final class SourceImageBox {
    let image:CIImage
    init(_ image:CIImage) { self.image = image }
}
public enum ModernRenderer {
    private static let sourceCache: NSCache<NSString,SourceImageBox> = {
        let cache = NSCache<NSString,SourceImageBox>(); cache.totalCostLimit = 384*1024*1024; cache.countLimit = 2; return cache
    }()
    private static let sensorCache = NSCache<NSString,NSNumber>()
    public static func sensorClipping(_ source:URL) -> Double? { sensorCache.object(forKey:(source.path+EditStorage.fingerprint(source)) as NSString)?.doubleValue }
    public static func clearSourceCache() { sourceCache.removeAllObjects() }
    public static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    public static let context = CIContext(options: [.workingColorSpace: workingSpace, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
    public static func readImage(_ url: URL) throws -> CIImage {
        if url.pathExtension == "osfloat" { return try FloatImageBridge.read(url) }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]), !image.extent.isEmpty else { throw PhotoReadError.unreadable }
        return image
    }
    public static func source(_ url: URL, mode: SourceMode, raw: RawSettings = RawSettings(), halfSize:Bool = false) throws -> CIImage {
        let rawKey = raw.cacheKey
        let key = "\(url.standardizedFileURL.path)|\(EditStorage.fingerprint(url))|\(mode.rawValue)|\(rawKey)|\(halfSize)" as NSString
        if let cached = sourceCache.object(forKey:key) { return cached.image }
        let image:CIImage
        if RawDecoder.isRAW(url) {
            switch mode {
            case .raw:
                let result = try RawDecoder.decode(url, settings:raw,halfSize:halfSize); image = result.image
                if let fraction = result.sensorClippedFraction { sensorCache.setObject(NSNumber(value:fraction),forKey:(url.path+EditStorage.fingerprint(url)) as NSString) }
            case .cameraLook: image = try RawDecoder.cameraPreview(url)
            case .original: throw RawDecodeError(message:"Choose RAW or Camera Look for this file")
            }
        } else { image = try readImage(url) }
        sourceCache.setObject(SourceImageBox(image),forKey:key,cost:Int(image.extent.width*image.extent.height)*8)
        return image
    }
    public static func process(_ source: CIImage, edits: PhotoEdits, maximumDimension: Int? = nil, lutOverride: CubeLUT? = nil, stopBeforeTool:String? = nil) throws -> CIImage {
        let edits = edits.sanitized
        var image = try edits.baseAsset.map { try readImage(EditStorage.asset($0)) } ?? source
        if let maximum = maximumDimension, max(image.extent.width, image.extent.height) > Double(maximum) {
            let scale = Double(max(1, maximum))/max(image.extent.width, image.extent.height)
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        }
        return try PhotoEditor.process(image, sourceSize: image.extent.size, edits: edits, lutOverride: lutOverride, modern: true, stopBeforeTool:stopBeforeTool)
    }
    public static func render(source url: URL, recipe: RenderRecipe, maximumDimension: Int? = nil, lutOverride:CubeLUT? = nil, stopBeforeTool:String? = nil) throws -> CIImage {
        let recipe = RenderRecipe(renderer:recipe.renderer, sourceMode:recipe.sourceMode, raw:recipe.raw, edits:recipe.edits)
        if recipe.renderer == .legacy {
            return CIImage(cgImage:try PhotoEditor.render(PhotoDecoder.decode(url), edits: recipe.edits, lutOverride:lutOverride, previewMaxDimension: maximumDimension))
        }
        var edits = recipe.edits
        if let asset = edits.baseAsset {
            var base = try readImage(EditStorage.asset(asset))
            if recipe.sourceMode == .raw, let denoised = edits.advanced?.rawDenoise {
                // The denoised sensor data already carries the white balance it was decoded with; apply only the change since.
                if denoised.temperature != edits.temperature || denoised.tint != edits.tint {
                    let g = denoised.gains(to:edits.temperature,tint:edits.tint)
                    base = base.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:g.red,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:g.green,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:g.blue,w:0)])
                }
                edits.temperature = 6500; edits.tint = 0; edits.neutralBalance = NeutralBalance()
            }
            return try process(base, edits:edits, maximumDimension:maximumDimension, lutOverride:lutOverride, stopBeforeTool:stopBeforeTool)
        }
        let input = try source(url, mode:recipe.sourceMode, raw:recipe.raw,halfSize:maximumDimension.map{$0<=2048} ?? false)
        if recipe.sourceMode == .raw { edits.temperature = 6500; edits.tint = 0; edits.neutralBalance = NeutralBalance() }
        return try process(input, edits:edits, maximumDimension:maximumDimension, lutOverride:lutOverride, stopBeforeTool:stopBeforeTool)
    }
    public static func display(_ image: CIImage, profile: ExportProfile = .displayP3) throws -> CGImage {
        guard let result = context.createCGImage(image, from: image.extent, format: .RGBAh, colorSpace: profile.colorSpace) else { throw EditError.render }
        return result
    }
    /// Simulate the bounded output profile only at the display boundary.
    public static func outputPreview(_ image:CIImage,settings:ExportSettings)throws->CIImage {
        let settings=settings.sanitized
        guard let cg=context.createCGImage(image,from:image.extent,format:settings.bitDepth == 16 ? .RGBA16:.RGBA8,colorSpace:settings.profile.colorSpace) else{throw EditError.render}
        return CIImage(cgImage:cg)
    }
    public static func prepareOutput(_ image:CIImage,settings:ExportSettings)throws->CIImage {
        let settings=settings.sanitized
        var image = image
        if let edge = settings.longestEdge {
            let scale = Double(edge)/max(image.extent.width, image.extent.height)
            if scale < 1 || settings.allowUpscaling {
                image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            }
        }
        if settings.sharpening > 0 { image = image.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: settings.sharpening]).cropped(to: image.extent) }
        if let watermark=settings.watermark {image=try Watermarks.apply(image,settings:watermark)}
        if settings.format == .jpeg { image = image.composited(over: CIImage(color: .white).cropped(to: image.extent)) }
        return image.cropped(to:CGRect(x:0,y:0,width:image.extent.width.rounded(.down),height:image.extent.height.rounded(.down)))
    }
    public static func export(_ image: CIImage, to destination: URL, source: URL?, settings: ExportSettings, metadata: IPTCMetadata? = nil) throws {
        let settings = settings.sanitized
        if let source {
            guard source.standardizedFileURL.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath() else { throw EditError.originalDestination }
            if FileManager.default.fileExists(atPath: destination.path),
               let a = try? FileManager.default.attributesOfItem(atPath: source.path),
               let b = try? FileManager.default.attributesOfItem(atPath: destination.path),
               let ai = a[.systemFileNumber] as? NSNumber, let bi = b[.systemFileNumber] as? NSNumber,
               ai == bi, (a[.systemNumber] as? NSNumber) == (b[.systemNumber] as? NSNumber) { throw EditError.originalDestination }
        }
        let image = try prepareOutput(image,settings:settings)
        let format: CIFormat = settings.bitDepth == 16 ? .RGBA16 : .RGBA8
        guard let cg = context.createCGImage(image, from: image.extent.integral, format: format, colorSpace: settings.profile.colorSpace) else { throw EditError.render }
        var props: [String: Any] = [:]
        if settings.keepMetadata, let source, let io = CGImageSourceCreateWithURL(source as CFURL, nil), let original = CGImageSourceCopyPropertiesAtIndex(io, 0, nil) as? [String: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary] { props[key as String] = original[key as String] }
            if settings.keepGPS { props[kCGImagePropertyGPSDictionary as String] = original[kCGImagePropertyGPSDictionary as String] }
        }
        props[kCGImagePropertyOrientation as String] = 1
        var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff["Orientation"] = 1; tiff["Software"] = "OpenStill"; props[kCGImagePropertyTIFFDictionary as String] = tiff
        var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif["PixelXDimension"] = cg.width; exif["PixelYDimension"] = cg.height; exif.removeValue(forKey: "MakerNote")
        props[kCGImagePropertyExifDictionary as String] = exif
        // The photographer's title, caption, keywords, creator and copyright replace what the camera wrote.
        if let metadata, !metadata.isEmpty {
            for (key, value) in metadata.imageProperties {
                var merged = props[key] as? [String: Any] ?? [:]
                for (k, v) in value as? [String: Any] ?? [:] { merged[k] = v }
                props[key] = merged
            }
        }
        props[kCGImageDestinationLossyCompressionQuality as String] = settings.quality
        let type: UTType = settings.format == .jpeg ? .jpeg : (settings.format == .png ? .png : .tiff)
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw EditError.render }
        CGImageDestinationAddImage(writer, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw EditError.render }
        try (data as Data).write(to: destination, options: .atomic)
    }
}

/// OSF1: magic (4 bytes), little-endian uint32 width/height, then float32 RGBA,
/// top row first, unassociated alpha, extended sRGB. Model inputs use [0,1] sRGB;
/// residuals outside that range are retained by the worker rather than quantized.
public enum FloatImageBridge {
    public static func write(_ image: CIImage, to url: URL) throws {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        guard w > 0, h > 0, w <= 65535, h <= 65535 else { throw EditError.render }
        var pixels = [Float](repeating: 0, count: w*h*4)
        ModernRenderer.context.render(image, toBitmap: &pixels, rowBytes: w*16, bounds: image.extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!)
        // Core Image bitmap output is top row first. Strip premultiplication explicitly.
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = pixels[i+3]
            if alpha > 0 { for c in 0..<3 { pixels[i+c] /= alpha } }
        }
        var data = Data("OSF1".utf8)
        for value in [UInt32(w), UInt32(h)] { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        pixels.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url, options: .atomic)
    }
    public static func read(_ url: URL) throws -> CIImage {
        let data = try Data(contentsOf: url)
        guard data.count >= 12, data.prefix(4) == Data("OSF1".utf8) else { throw PhotoReadError.unreadable }
        let w = Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) })
        let h = Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) })
        guard w > 0, h > 0, w <= 65535, h <= 65535, data.count == 12+w*h*16 else { throw PhotoReadError.unreadable }
        var payload = Data(data.dropFirst(12))
        try payload.withUnsafeMutableBytes { bytes in
            let values = bytes.bindMemory(to: Float.self)
            for i in stride(from: 0, to: values.count, by: 4) {
                guard values[i].isFinite, values[i+1].isFinite, values[i+2].isFinite, values[i+3].isFinite else { throw PhotoReadError.unreadable }
                let alpha = min(1, max(0, values[i+3])); values[i+3] = alpha
                for c in 0..<3 { values[i+c] *= alpha }
            }
        }
        return CIImage(bitmapData: payload, bytesPerRow: w*16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!)
    }
}
