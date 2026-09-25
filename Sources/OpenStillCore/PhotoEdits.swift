import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

public struct PhotoEdits: Codable, Equatable {
    public var exposure = 0.0
    public var contrast = 1.0
    public var highlights = 1.0
    public var shadows = 0.0
    public var temperature = 6500.0
    public var tint = 0.0
    public var saturation = 1.0
    public var vibrance = 0.0
    public var structure = 0.0
    public var sharpness = 0.0
    public var denoise = 0.0
    public var vignette = 0.0
    public var blackAndWhite = false
    public var autoEnhance = false
    public var rotation = 0
    public var flip = false
    public var crop: EditRect?
    public var sunrays = 0.0
    public var sunX = 0.7
    public var sunY = 0.8
    public var opacity = 1.0
    public var baseAsset: String?
    public var overlayAsset: String?
    public var overlayOpacity = 0.5
    public var overlayBlend = "CISourceOverCompositing"
    public var advanced: AdvancedEdits?
    public var schemaVersion: Int? = 2
    public var monochrome: Double { get { advanced?.monochrome ?? (blackAndWhite ? 1 : 0) } set { ensureAdvanced(); advanced!.monochrome = newValue; blackAndWhite = false } }
    public var blacks: Double { get { advanced?.blacks ?? 0 } set { ensureAdvanced(); advanced!.blacks = newValue } }
    public var whites: Double { get { advanced?.whites ?? 0 } set { ensureAdvanced(); advanced!.whites = newValue } }
    public var straighten: Double { get { advanced?.straighten ?? 0 } set { ensureAdvanced(); advanced!.straighten = newValue } }
    public var lutAmount: Double { get { advanced?.lutAmount ?? 1 } set { ensureAdvanced(); advanced!.lutAmount = newValue } }
    public var sunLength: Double { get { advanced?.sunLength ?? 0.4 } set { ensureAdvanced(); advanced!.sunLength = newValue } }
    public mutating func ensureAdvanced() { if advanced == nil { advanced = AdvancedEdits(); advanced!.monochrome = blackAndWhite ? 1 : 0 } }
    public mutating func setMask(_ mask: AdjustmentMask?, for key: String) { ensureAdvanced(); advanced!.masks[key] = mask }
    public init() {}
    public var isOriginal: Bool { self == PhotoEdits() }
    public var sanitized: PhotoEdits {
        var e = self
        func clamp(_ value: Double, _ low: Double, _ high: Double, _ fallback: Double = 0) -> Double { value.isFinite ? min(high, max(low, value)) : fallback }
        e.exposure = clamp(exposure,-4,4); e.contrast = clamp(contrast,0.5,1.5,1)
        e.highlights = clamp(highlights,0,1,1); e.shadows = clamp(shadows,0,1)
        e.temperature = clamp(temperature,2500,10000,6500); e.tint = clamp(tint,-100,100)
        e.saturation = clamp(saturation,0,2,1); e.vibrance = clamp(vibrance,-1,1)
        e.structure = clamp(structure,0,1); e.sharpness = clamp(sharpness,0,2)
        e.denoise = clamp(denoise,0,1); e.vignette = clamp(schemaVersion == nil ? -vignette : vignette,-1,1); e.schemaVersion = 2
        e.sunrays = clamp(sunrays,0,1); e.sunX = clamp(sunX,0,1); e.sunY = clamp(sunY,0,1)
        e.opacity = clamp(opacity,0,1,1); e.overlayOpacity = clamp(overlayOpacity,0,1,0.5)
        e.rotation = ((rotation % 4)+4)%4
        if e.advanced != nil {
            if let sun = e.advanced!.sunSettings { e.advanced!.sunSettings = sun.sanitized }
            if let glow = e.advanced!.glow { e.advanced!.glow = glow.sanitized }
            if let value = e.advanced!.clarity { e.advanced!.clarity = clamp(value,-1,1) }
            if let value = e.advanced!.texture { e.advanced!.texture = clamp(value,-1,1) }
            if let value = e.advanced!.dehaze { e.advanced!.dehaze = clamp(value,-1,1) }
            if let grading = e.advanced!.colorGrading { e.advanced!.colorGrading = grading.sanitized }
            if let grain = e.advanced!.grain { e.advanced!.grain = grain.sanitized }
            if let defringe = e.advanced!.defringe { e.advanced!.defringe = defringe.sanitized }
            if let profile = e.advanced!.profile { let clean = profile.sanitized; e.advanced!.profile = clean == ProfileSettings() ? nil : clean }
            if let calibration = e.advanced!.calibration { let clean = calibration.sanitized; e.advanced!.calibration = clean.hasEffect ? clean : nil }
            if let options = e.advanced!.rawOptions { let clean = options.sanitized; e.advanced!.rawOptions = clean.isDefault ? nil : clean }
            if let transform = e.advanced!.transform { let clean = transform.sanitized; e.advanced!.transform = clean == TransformSettings() ? nil : clean }
            e.monochrome = clamp(e.monochrome,0,1); e.blacks = clamp(e.blacks,-1,1); e.whites = clamp(e.whites,-1,1)
            e.straighten = clamp(e.straighten,-20,20); e.lutAmount = clamp(e.lutAmount,0,1); e.sunLength = clamp(e.sunLength,0,1)
            e.advanced!.colors = Array((e.advanced!.colors + [ColorBand](repeating:ColorBand(),count:8)).prefix(8))
            for i in 0..<8 { e.advanced!.colors[i].hue = clamp(e.advanced!.colors[i].hue,-1,1); e.advanced!.colors[i].saturation = clamp(e.advanced!.colors[i].saturation,-1,1); if let lightness = e.advanced!.colors[i].lightness { e.advanced!.colors[i].lightness = clamp(lightness,-1,1) } }
            for key in e.advanced!.masks.keys { e.advanced!.masks[key]!.feather = clamp(e.advanced!.masks[key]!.feather,0,1) }
        }
        return e
    }
}
public struct EditRect: Codable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(_ rect: CGRect) { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
public struct EditStep: Codable, Equatable {
    public var title: String
    public var edits: PhotoEdits
    public init(_ title: String, _ edits: PhotoEdits) { self.title = title; self.edits = edits }
}
public struct EditDocument: Codable {
    public var fingerprint: String
    public var steps: [EditStep] = [EditStep("Original", PhotoEdits())]
    public var cursor = 0
    public var current: PhotoEdits { steps.isEmpty ? PhotoEdits() : steps[min(max(cursor, 0), steps.count - 1)].edits }
    public init(fingerprint: String) { self.fingerprint = fingerprint }
    public mutating func commit(_ edits: PhotoEdits, title: String) {
        guard edits != current else { return }
        steps = Array(steps.prefix(cursor + 1))
        steps.append(EditStep(title, edits))
        cursor = steps.count - 1
    }
    public mutating func undo() { cursor = max(0, cursor - 1) }
    public mutating func redo() { cursor = min(steps.count - 1, cursor + 1) }
}
public enum EditStorage {
    private static let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent("OpenStill-Tests-" + UUID().uuidString)
    public static var root: URL {
        if let path = ProcessInfo.processInfo.environment["OPENSTILL_STORAGE_ROOT"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        if ProcessInfo.processInfo.arguments.first?.contains(".xctest") == true { return testRoot }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenStill", isDirectory: true)
    }
    private static let recordLock = NSRecursiveLock()
    private static var stores: [URL: PhotoRecordStore] = [:]
    public static var records: PhotoRecordStore {
        recordLock.lock(); defer { recordLock.unlock() }
        if let store = stores[root] { return store }
        let store = PhotoRecordStore(root: root); stores[root] = store; return store
    }
    public static var assets: URL { root.appendingPathComponent("EditAssets", isDirectory: true) }
    public static func fingerprint(_ source: URL) -> String {
        let fresh = URL(fileURLWithPath: source.path)
        let v = try? fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(v?.fileSize ?? -1):\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }
    private static func documentURL(_ source: URL) -> URL {
        let hash = SHA256.hash(data: Data(source.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("Edits/\(hash).json")
    }
    private static func legacyDocument(_ source: URL) -> EditDocument? {
        let fingerprint = fingerprint(source)
        if let data = try? Data(contentsOf: documentURL(source)),
           let document = try? JSONDecoder().decode(EditDocument.self, from: data), document.fingerprint == fingerprint,
           !document.steps.isEmpty, document.steps.indices.contains(document.cursor) {
            var migrated = document
            migrated.steps = document.steps.map { EditStep($0.title, $0.edits.sanitized) }
            return migrated
        }
        return nil
    }
    public static func record(_ source: URL) throws -> PhotoRecord { try records.record(for: source, legacy: legacyDocument(source)) }
    public static func load(_ source: URL) -> EditDocument {
        (try? record(source).active.document) ?? legacyDocument(source) ?? EditDocument(fingerprint: fingerprint(source))
    }
    public static func save(_ document: EditDocument, for source: URL) throws {
        guard document.fingerprint == fingerprint(source) else { throw WorkflowError.changedSource }
        var record = try self.record(source)
        record.updateDocument(document)
        try records.save(record)
    }
    public static func newAsset(extension ext: String = "png") throws -> URL {
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        return assets.appendingPathComponent(UUID().uuidString + "." + ext)
    }
    public static func asset(_ name: String) -> URL { assets.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent) }
}
public enum EditError: LocalizedError {
    case render, invalidCrop, originalDestination, missingAsset
    public var errorDescription: String? {
        switch self {
        case .render: return "The edit couldn’t be rendered on this Mac."
        case .invalidCrop: return "Draw a larger crop inside the photo."
        case .originalDestination: return "Choose a different filename. OpenStill keeps your original photo untouched."
        case .missingAsset: return "An image used by this edit is missing. Return to an earlier step in Edits."
        }
    }
}
public enum PhotoEditor {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    public static func render(_ original: CGImage, edits: PhotoEdits, lutOverride: CubeLUT? = nil, previewMaxDimension: Int? = nil) throws -> CGImage {
        let e = edits.sanitized
        var effective = e
        if effective.glow.amount == 0 {
            effective.advanced?.glow = nil
            if effective.advanced == AdvancedEdits() { effective.advanced = nil }
        }
        if effective.isOriginal && lutOverride == nil && previewMaxDimension == nil { return original }
        let base: CGImage
        if let asset = e.baseAsset { base = try PhotoDecoder.decode(EditStorage.asset(asset),maxPixelSize:previewMaxDimension) }
        else if let maximum = previewMaxDimension, max(original.width,original.height) > maximum {
            let scale = Double(max(1,maximum))/Double(max(original.width,original.height))
            let small = CIImage(cgImage:original).applyingFilter("CILanczosScaleTransform",parameters:[kCIInputScaleKey:scale,kCIInputAspectRatioKey:1])
            guard let cg = context.createCGImage(small,from:small.extent) else { throw EditError.render }; base = cg
        } else { base = original }
        let image = try process(CIImage(cgImage:base), sourceSize:CGSize(width:base.width,height:base.height), edits:e, lutOverride:lutOverride, previewMaxDimension:previewMaxDimension)
        guard let rendered = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw EditError.render }
        return rendered
    }
    static func process(_ baseImage: CIImage, sourceSize: CGSize, edits e: PhotoEdits, lutOverride: CubeLUT? = nil, previewMaxDimension: Int? = nil, modern: Bool = false, stopBeforeTool: String? = nil) throws -> CIImage {
        func assetImage(_ name: String) throws -> CIImage {
            if modern { return try ModernRenderer.readImage(EditStorage.asset(name)) }
            return CIImage(cgImage:try PhotoDecoder.decode(EditStorage.asset(name), maxPixelSize:previewMaxDimension))
        }
        let geometry = EditGeometry(size:sourceSize,edits:e)
        guard geometry.extent.width >= 1, geometry.extent.height >= 1 else { throw EditError.invalidCrop }
        var baseImage = baseImage
        if let background = e.advanced?.aiBackgroundAsset, let key = e.advanced?.aiFeatureKey,
           let mask = e.advanced?.masks[key] {
            let prior = try assetImage(background)
            baseImage = baseImage.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:prior,kCIInputMaskImageKey:try mask.coverage(geometry:EditGeometry(size:sourceSize,edits:PhotoEdits()),lens:LensSettings(),input:prior,modern:modern)])
        }
        let retouched=modern && !e.retouch.isEmpty ? try Retouch.apply(baseImage,strokes:e.retouch):baseImage
        if modern { baseImage = try LensCorrections.apply(baseImage,settings:e.optics) }
        let retouchImage=modern && !e.retouch.isEmpty ? geometry.apply(try LensCorrections.apply(retouched,settings:e.optics)):nil
        var image = geometry.apply(baseImage)
        let originalExtent = image.extent, unadjusted = image
        func masked(_ before: CIImage, _ after: CIImage, _ key: String) throws -> CIImage {
            guard let mask = e.advanced?.masks[key] else { return after.cropped(to:originalExtent) }
            let selection = try mask.coverage(geometry:geometry,lens:e.optics,input:before,modern:modern)
            return after.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:before,kCIInputMaskImageKey:selection]).cropped(to:originalExtent)
        }
        if stopBeforeTool == "Retouch" {return image}
        if let retouchImage {image=try masked(image,retouchImage,"Retouch")}
        if stopBeforeTool == "Profile" { return image }
        if modern && (e.profile.hasEffect || e.calibration.hasEffect) {
            image = try CameraProfiles.apply(image,profile:e.profile,calibration:e.calibration).cropped(to:originalExtent)
        }
        var before = image
        if stopBeforeTool == "Enhance" { return image }
        if e.autoEnhance {
            for filter in image.autoAdjustmentFilters(options:[.enhance:true,.redEye:false,.crop:false,.level:false]) {
                filter.setValue(image,forKey:kCIInputImageKey); if let output = filter.outputImage { image = output.cropped(to:originalExtent) }
            }
        }
        image = try masked(before,image,"Enhance")
        if e.defringe.hasEffect { image = try DevelopTools.defringe(image,settings:e.defringe) }
        before = image
        if stopBeforeTool == "Develop" { return image }
        if modern, e.neutralBalance != NeutralBalance() { image = ToneTools.balance(image,settings:e.neutralBalance) }
        if e.exposure != 0 { image = image.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:e.exposure]) }
        if e.temperature != 6500 || e.tint != 0 { image = image.applyingFilter("CITemperatureAndTint",parameters:["inputNeutral":CIVector(x:6500,y:0),"inputTargetNeutral":CIVector(x:e.temperature,y:e.tint)]) }
        if e.highlights != 1 || e.shadows != 0 { image = image.applyingFilter("CIHighlightShadowAdjust",parameters:["inputHighlightAmount":e.highlights,"inputShadowAmount":e.shadows]) }
        if e.contrast != 1 { image = image.applyingFilter("CIColorControls",parameters:[kCIInputContrastKey:e.contrast]) }
        image = try masked(before,image,"Develop"); before = image
        if stopBeforeTool == "Dehaze" { return image }
        if e.dehaze != 0 { image = try masked(before,try DevelopTools.dehaze(image,amount:e.dehaze),"Dehaze"); before = image }
        if stopBeforeTool == "Curves" { return image }
        if modern, !e.curves.isIdentity { image = try ToneTools.applyCurves(image,settings:e.curves); image = try masked(before,image,"Curves"); before = image }
        if stopBeforeTool == "Color" { return image }
        if e.saturation != 1 { image = image.applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:e.saturation]) }
        if e.vibrance != 0 { image = image.applyingFilter("CIVibrance",parameters:[kCIInputAmountKey:e.vibrance]) }
        if let bands = e.advanced?.colors, bands.contains(where: { $0.hue != 0 || $0.saturation != 0 || ($0.lightness ?? 0) != 0 }) { image = ColorMixer.apply(image,bands:bands) }
        image = try masked(before,image,"Color"); before = image
        if stopBeforeTool == "Color grading" { return image }
        if !e.colorGrading.isIdentity { image = try masked(before,try DevelopTools.colorGrade(image,settings:e.colorGrading),"Color grading"); before = image }
        if stopBeforeTool == "Black & white" { return image }
        if e.monochrome > 0 { image = image.applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:1-e.monochrome]) }
        if e.blacks != 0 || e.whites != 0 {
            image = image.applyingFilter("CIToneCurve",parameters:["inputPoint0":CIVector(x:0,y:max(0,e.blacks)*0.15),"inputPoint1":CIVector(x:0.25,y:0.25+e.blacks*0.15),"inputPoint2":CIVector(x:0.5,y:0.5),"inputPoint3":CIVector(x:0.75,y:0.75+e.whites*0.15),"inputPoint4":CIVector(x:1,y:1+min(0,e.whites)*0.15)])
        }
        image = try masked(before,image,"Black & white"); before = image
        if stopBeforeTool == "Denoise" { return image }
        if e.denoise > 0 { image = image.applyingFilter("CINoiseReduction",parameters:["inputNoiseLevel":e.denoise*0.1,kCIInputSharpnessKey:0.2]) }
        image = try masked(before,image,"Denoise"); before = image
        if stopBeforeTool == "Structure" { return image }
        if e.structure > 0 { image = image.clampedToExtent().applyingFilter("CIUnsharpMask",parameters:[kCIInputRadiusKey:max(1,Double(sourceSize.width)/200),kCIInputIntensityKey:e.structure*0.8]).cropped(to:originalExtent) }
        image = try masked(before,image,"Structure"); before = image
        if stopBeforeTool == "Clarity" { return image }
        if e.clarity != 0 { image = try masked(before,try DevelopTools.clarity(image,amount:e.clarity),"Clarity"); before = image }
        if stopBeforeTool == "Texture" { return image }
        if e.texture != 0 { image = try masked(before,try DevelopTools.texture(image,amount:e.texture),"Texture"); before = image }
        if stopBeforeTool == "Details" { return image }
        if e.sharpness > 0 { image = image.applyingFilter("CISharpenLuminance",parameters:[kCIInputSharpnessKey:e.sharpness]) }
        image = try masked(before,image,"Details"); before = image
        if stopBeforeTool == "Glow" { return image }
        if e.glow.amount > 0 {
            if modern {
                let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
                guard let converted = image.matchedFromWorkingSpace(to: linearSRGB) else { throw EditError.render }
                let effect = try PhotographicGlow.apply(converted, settings:e.glow, sourceSize:geometry.sourceSize)
                guard let matched = effect.matchedToWorkingSpace(from: linearSRGB) else { throw EditError.render }
                image = matched
            } else { image = try PhotographicGlow.apply(image, settings:e.glow, sourceSize:geometry.sourceSize) }
            image = try masked(before,image,"Glow")
        }
        before = image
        if stopBeforeTool == "Vignette" { return image }
        if e.vignette != 0 {
            let w = originalExtent.width, h = originalExtent.height
            let radial = CIFilter(name:"CIRadialGradient",parameters:["inputCenter":CIVector(x:0.5,y:0.5),"inputRadius0":0.25,"inputRadius1":0.72,"inputColor0":CIColor(red:0,green:0,blue:0),"inputColor1":CIColor(red:abs(e.vignette),green:abs(e.vignette),blue:abs(e.vignette))])!.outputImage!.transformed(by:CGAffineTransform(scaleX:w,y:h)).cropped(to:originalExtent)
            let value = e.vignette > 0 ? 1.0 : 0.0
            image = CIImage(color:CIColor(red:value,green:value,blue:value)).cropped(to:originalExtent).applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:image,kCIInputMaskImageKey:radial])
        }
        image = try masked(before,image,"Vignette"); before = image
        if stopBeforeTool == "Sunrays" { return image }
        if let sun = e.advanced?.sunSettings {
            if modern {
                let space = CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
                guard let converted = image.matchedFromWorkingSpace(to:space) else {throw EditError.render}
                let effect = try PhotographicSunrays.apply(converted,settings:sun,geometry:geometry)
                guard let matched = effect.matchedToWorkingSpace(from:space) else {throw EditError.render}
                image = matched
            } else { image = try PhotographicSunrays.apply(image,settings:sun,geometry:geometry) }
        } else if e.sunrays > 0 {
            // Light shafts originate from real highlights; no synthetic starburst or sun disk.
            let highlights = image.applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:0,kCIInputContrastKey:3,kCIInputBrightnessKey:-0.65]).applyingFilter("CIColorClamp",parameters:["inputMinComponents":CIVector(x:0,y:0,z:0,w:0),"inputMaxComponents":CIVector(x:1,y:1,z:1,w:1)])
            let rays = highlights.clampedToExtent().applyingFilter("CIZoomBlur",parameters:[kCIInputCenterKey:CIVector(x:e.sunX*originalExtent.width,y:e.sunY*originalExtent.height),kCIInputAmountKey:10+e.sunLength*70]).cropped(to:originalExtent)
                .applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:e.sunrays*0.22,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:e.sunrays*0.20,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:e.sunrays*0.16,w:0)])
            image = rays.applyingFilter("CIScreenBlendMode",parameters:[kCIInputBackgroundImageKey:image])
        }
        image = try masked(before,image,"Sunrays"); before = image
        if stopBeforeTool == "LUT" {return image}
        if e.lutAmount > 0, let lut = try lutOverride ?? e.advanced?.lutAsset.map({ try CubeLUT.load(EditStorage.asset($0)) }) {
            let graded = lut.apply(image)
            image = before.applyingFilter("CIDissolveTransition",parameters:[kCIInputTargetImageKey:graded,kCIInputTimeKey:e.lutAmount])
        }
        image = try masked(before,image,"LUT"); before = image
        if stopBeforeTool == "Grain" { return image }
        if e.grain.amount > 0 { image = try masked(before,try DevelopTools.grain(image,settings:e.grain),"Grain") }
        if e.opacity < 1 { image = unadjusted.applyingFilter("CIDissolveTransition",parameters:[kCIInputTargetImageKey:image,kCIInputTimeKey:e.opacity]) }
        if let overlay = e.overlayAsset {
            before = image
            var top = try assetImage(overlay)
            let scale = max(originalExtent.width/top.extent.width,originalExtent.height/top.extent.height)
            top = top.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            top = top.transformed(by:CGAffineTransform(translationX:(originalExtent.width-top.extent.width)/2,y:(originalExtent.height-top.extent.height)/2)).cropped(to:originalExtent)
            top = top.applyingFilter("CIColorMatrix",parameters:["inputAVector":CIVector(x:0,y:0,z:0,w:e.overlayOpacity)])
            let blend = ["CISourceOverCompositing","CIScreenBlendMode","CIMultiplyBlendMode"].contains(e.overlayBlend) ? e.overlayBlend : "CISourceOverCompositing"
            image = try masked(before,top.applyingFilter(blend,parameters:[kCIInputBackgroundImageKey:image]),"Layers")
        }
        return image
    }
    public static func render(source: URL, edits: PhotoEdits) throws -> CGImage { try render(PhotoDecoder.decode(source), edits: edits) }
    public static func write(_ image: CGImage, to url: URL, source: URL? = nil, type: UTType = .png) throws {
        if let source, source.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() { throw EditError.originalDestination }
        var props: [String: Any] = [:]
        if let source, let io = CGImageSourceCreateWithURL(source as CFURL, nil), let original = CGImageSourceCopyPropertiesAtIndex(io, 0, nil) as? [String: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary] { props[key as String] = original[key as String] }
        }
        props[kCGImagePropertyOrientation as String] = 1
        var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff["Orientation"] = 1
        tiff["Software"] = "OpenStill"
        props[kCGImagePropertyTIFFDictionary as String] = tiff
        var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif["PixelXDimension"] = image.width; exif["PixelYDimension"] = image.height
        exif.removeValue(forKey: "MakerNote")
        props[kCGImagePropertyExifDictionary as String] = exif
        props[kCGImageDestinationLossyCompressionQuality as String] = 0.95
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw EditError.render }
        var outputImage = image
        if type == .jpeg {
            guard let canvas = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw EditError.render }
            canvas.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            canvas.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let flattened = canvas.makeImage() else { throw EditError.render }
            outputImage = flattened
        }
        CGImageDestinationAddImage(destination, outputImage, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EditError.render }
        try (data as Data).write(to: url, options: .atomic)
    }
}
