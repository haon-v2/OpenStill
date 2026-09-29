import Foundation

/// A color grading wheel in a preset: hue in degrees, saturation 0…1, luminance −1…1.
public struct PresetWheel: Codable, Equatable {
    public var hue: Double, saturation: Double, luminance: Double?
}
public struct PresetGrading: Codable, Equatable {
    public var shadows: PresetWheel?, midtones: PresetWheel?, highlights: PresetWheel?, global: PresetWheel?
    public var blending: Double?, balance: Double?
    var colorGrading: ColorGrading {
        var g = ColorGrading()
        func wheel(_ w:PresetWheel?) -> GradeWheel { w.map { GradeWheel(hue:$0.hue,saturation:$0.saturation,luminance:$0.luminance ?? 0) } ?? GradeWheel() }
        g.shadows = wheel(shadows); g.midtones = wheel(midtones); g.highlights = wheel(highlights); g.global = wheel(global)
        g.blending = blending ?? 0.5; g.balance = balance ?? 0
        return g.sanitized
    }
}
public struct PresetLUT: Codable, Equatable {
    public var id: String
    public var amount: Double
}

/// A develop preset: bundled ones are readable recipes (Resources/Presets/presets.json); your own keep a full edit.
public struct PresetRecipe: Codable, Equatable {
    public var id: String
    public var name: String
    public var category: String
    public var description: String
    /// Slider name (see `PresetRecipe.settings`) → value on that slider's scale.
    public var adjustments: [String:Double]
    /// HSL band name (`ColorMixer.names`) → [hue, saturation, luminance], each −1…1.
    public var hsl: [String:[Double]]?
    public var grading: PresetGrading?
    /// Black & white mix, eight bands −1…1.
    public var grayMix: [Double]?
    public var lut: PresetLUT?
    /// Saved from a photo (My Presets); applied as a whole instead of from `adjustments`.
    public var snapshot: PhotoEdits?

    public init(id:String,name:String,category:String,description:String,adjustments:[String:Double] = [:],hsl:[String:[Double]]? = nil,
                grading:PresetGrading? = nil,grayMix:[Double]? = nil,lut:PresetLUT? = nil,snapshot:PhotoEdits? = nil) {
        self.id = id; self.name = name; self.category = category; self.description = description; self.adjustments = adjustments
        self.hsl = hsl; self.grading = grading; self.grayMix = grayMix; self.lut = lut; self.snapshot = snapshot
    }

    public struct Setting {
        public let name: String
        public let path: WritableKeyPath<PhotoEdits,Double>
        public let range: ClosedRange<Double>
        public let neutral: Double
        /// Tone and color settings every preset starts from neutral, as OpenStill's presets always have.
        public let resets: Bool
    }
    public static let settings: [Setting] = [
        Setting(name:"exposure",path:\.exposure,range:-4...4,neutral:0,resets:true),
        Setting(name:"contrast",path:\.contrast,range:0.5...1.5,neutral:1,resets:true),
        Setting(name:"highlights",path:\.highlightsAmount,range:-1...1,neutral:0,resets:true),
        Setting(name:"shadows",path:\.shadowsAmount,range:-1...1,neutral:0,resets:true),
        Setting(name:"whites",path:\.whites,range:-1...1,neutral:0,resets:true),
        Setting(name:"blacks",path:\.blacks,range:-1...1,neutral:0,resets:true),
        Setting(name:"temperature",path:\.temperature,range:2500...10000,neutral:6500,resets:true),
        Setting(name:"tint",path:\.tint,range:-100...100,neutral:0,resets:true),
        Setting(name:"vibrance",path:\.vibrance,range:-1...1,neutral:0,resets:true),
        Setting(name:"saturation",path:\.saturation,range:0...2,neutral:1,resets:true),
        Setting(name:"clarity",path:\.clarity,range:-1...1,neutral:0,resets:true),
        Setting(name:"texture",path:\.texture,range:-1...1,neutral:0,resets:true),
        Setting(name:"dehaze",path:\.dehaze,range:-1...1,neutral:0,resets:true),
        Setting(name:"monochrome",path:\.monochrome,range:0...1,neutral:0,resets:true),
        Setting(name:"vignette",path:\.vignette,range:-1...1,neutral:0,resets:false),
        Setting(name:"grain",path:\.grainAmount,range:0...1,neutral:0,resets:false),
        Setting(name:"grainSize",path:\.grainSize,range:0...1,neutral:0.25,resets:false),
        Setting(name:"grainRoughness",path:\.grainRoughness,range:0...1,neutral:0.5,resets:false),
        Setting(name:"sharpness",path:\.sharpness,range:0...2,neutral:0,resets:false),
        Setting(name:"curveShadows",path:\.parametricShadows,range:-1...1,neutral:0,resets:false),
        Setting(name:"curveDarks",path:\.parametricDarks,range:-1...1,neutral:0,resets:false),
        Setting(name:"curveLights",path:\.parametricLights,range:-1...1,neutral:0,resets:false),
        Setting(name:"curveHighlights",path:\.parametricHighlights,range:-1...1,neutral:0,resets:false),
    ]

    /// Problems that would make this recipe apply differently than written; empty when it is valid.
    public var problems: [String] {
        var result:[String] = []
        for (key,value) in adjustments {
            guard let setting = Self.settings.first(where:{ $0.name == key }) else { result.append("unknown setting \(key)"); continue }
            if !setting.range.contains(value) { result.append("\(key) \(value) is outside \(setting.range)") }
        }
        for (band,values) in hsl ?? [:] where !ColorMixer.names.contains(band) || values.count != 3 || values.contains(where:{ abs($0) > 1 }) { result.append("bad HSL band \(band)") }
        if let grayMix, grayMix.count != 8 || grayMix.contains(where:{ abs($0) > 1 }) { result.append("gray mix needs eight values −1…1") }
        if let lut, !(0...1).contains(lut.amount) { result.append("LUT amount \(lut.amount) is outside 0…1") }
        return result
    }

    /// The photo-specific parts of `current` that a preset never changes: geometry, retouching, masks, AI results, the look.
    public static func keepingPhotoSpecifics(_ preset:PhotoEdits, from current:PhotoEdits) -> PhotoEdits {
        var p = preset.sanitized, c = current
        p.baseAsset = c.baseAsset; p.overlayAsset = c.overlayAsset; p.crop = c.crop; p.rotation = c.rotation; p.flip = c.flip
        p.ensureAdvanced(); c.ensureAdvanced(); p.straighten = c.straighten
        p.advanced!.masks = c.advanced!.masks; p.advanced!.transform = c.advanced!.transform; p.advanced!.lensBlur = c.advanced!.lensBlur
        p.advanced!.rawDenoise = c.advanced!.rawDenoise; p.advanced!.rawWhiteBalance = c.advanced!.rawWhiteBalance
        p.advanced!.eyeFixes = c.advanced!.eyeFixes; p.advanced!.autoCA = c.advanced!.autoCA; p.advanced!.localAdjustments = c.advanced!.localAdjustments
        p.advanced!.aiBackgroundAsset = c.advanced!.aiBackgroundAsset; p.advanced!.aiFeatureKey = c.advanced!.aiFeatureKey
        p.advanced!.lutAsset = c.advanced!.lutAsset; p.advanced!.lutName = c.advanced!.lutName; p.advanced!.lutID = c.advanced!.lutID; p.lutAmount = c.lutAmount
        p.advanced!.sky = c.advanced!.sky
        return p
    }
    /// A photo's edits made ready to save as a preset: the photo-specific parts are cleared.
    public static func snapshot(of edits:PhotoEdits) -> PhotoEdits {
        var p = keepingPhotoSpecifics(edits, from:PhotoEdits())
        p.advanced!.lutAsset = nil; p.advanced!.lutName = nil; p.advanced!.lutID = nil; p.lutAmount = 1
        return p
    }

    /// The edits at 100%: tone and color start from neutral, then the recipe's settings.
    public func target(from current:PhotoEdits) -> PhotoEdits {
        if let snapshot { return Self.keepingPhotoSpecifics(snapshot, from:current) }
        var e = current; e.ensureAdvanced()
        for s in Self.settings where s.resets { e[keyPath:s.path] = s.neutral }
        e.advanced!.colors = [ColorBand](repeating:ColorBand(),count:8); e.autoEnhance = false
        e.colorGrading = grading?.colorGrading ?? ColorGrading(); e.grayMix = grayMix ?? PhotoEdits.neutralGrayMix; e.pointColors = []
        for (i,band) in ColorMixer.names.enumerated() {
            if let v = hsl?[band], v.count == 3 { e.advanced!.colors[i].hue = v[0]; e.advanced!.colors[i].saturation = v[1]; e.advanced!.colors[i].lightness = v[2] }
        }
        for s in Self.settings { if let v = adjustments[s.name] { e[keyPath:s.path] = min(s.range.upperBound,max(s.range.lowerBound,v)) } }
        return e.sanitized
    }
    /// Amount 0…2 (0–200%): 0 leaves `current` unchanged, 1 is the preset as written, above 1 exaggerates it.
    /// The LUT, when the recipe has one, is applied separately (`apply(to:amount:library:)`).
    public func edits(from current:PhotoEdits, amount:Double = 1) -> PhotoEdits {
        let t = amount.isFinite ? min(2,max(0,amount)) : 1
        if t == 0 { return current }
        let target = target(from:current)
        if t == 1 { return target }
        func mix(_ a:Double,_ b:Double,_ neutral:Double) -> Double { t <= 1 ? a+(b-a)*t : neutral+(b-neutral)*t }
        var e = target; e.ensureAdvanced()
        for s in Self.settings {
            let v = mix(current[keyPath:s.path],target[keyPath:s.path],s.neutral)
            let clamped = min(s.range.upperBound,max(s.range.lowerBound,v))
            if e[keyPath:s.path] != clamped { e[keyPath:s.path] = clamped }
        }
        let from = current.advanced?.colors ?? [], to = target.advanced?.colors ?? []
        for i in 0..<min(8,e.advanced!.colors.count) {
            let a = i < from.count ? from[i] : ColorBand(), b = i < to.count ? to[i] : ColorBand()
            e.advanced!.colors[i].hue = mix(a.hue,b.hue,0); e.advanced!.colors[i].saturation = mix(a.saturation,b.saturation,0)
            e.advanced!.colors[i].lightness = mix(a.lightness ?? 0,b.lightness ?? 0,0)
        }
        e.grayMix = zip(current.grayMix,target.grayMix).map { mix($0,$1,0) }
        var g = target.colorGrading; let c = current.colorGrading
        func wheel(_ a:GradeWheel,_ b:GradeWheel) -> GradeWheel {
            GradeWheel(hue:b.saturation > 0 ? b.hue : a.hue,saturation:mix(a.saturation,b.saturation,0),luminance:mix(a.luminance,b.luminance,0))
        }
        g.shadows = wheel(c.shadows,g.shadows); g.midtones = wheel(c.midtones,g.midtones); g.highlights = wheel(c.highlights,g.highlights); g.global = wheel(c.global,g.global)
        g.blending = mix(c.blending,g.blending,0.5); g.balance = mix(c.balance,g.balance,0)
        e.colorGrading = g
        return e.sanitized
    }
    /// The preset applied at `amount`, including its LUT (copied into the photo's assets like any applied look).
    public func apply(to current:PhotoEdits, amount:Double = 1, library:LUTLibrary?) throws -> PhotoEdits {
        var e = edits(from:current,amount:amount)
        if let lut, amount > 0, let item = library?.items.first(where:{ $0.entry.id == lut.id }) {
            e = try item.applying(to:e,amount:min(1,lut.amount*min(2,amount)))
        }
        return e
    }
}

public struct PresetCatalog: Codable {
    public let version: Int
    public let presets: [PresetRecipe]
}

/// The bundled presets plus My Presets (`<root>/Presets/*.openstillpreset`, each a saved edit).
public struct PresetLibrary {
    public static let myPresets = "My Presets"
    public static let categoryOrder = ["Natural & Clean","Portrait","Landscape","Street","Film","Black & White","Cinematic","Moody",
                                       "Bright & Airy","Vibrant & Travel","Night","Vintage","Creative",myPresets]
    public static let fileExtension = "openstillpreset"
    public let presets: [PresetRecipe]
    public let folder: URL

    public init(bundled:URL?, user folder:URL) throws {
        self.folder = folder
        var result:[PresetRecipe] = []
        if let bundled {
            let catalog = try JSONDecoder().decode(PresetCatalog.self,from:Data(contentsOf:bundled))
            guard catalog.version == 1, Set(catalog.presets.map(\.id)).count == catalog.presets.count,
                  catalog.presets.allSatisfy({ $0.problems.isEmpty && Self.categoryOrder.contains($0.category) && $0.snapshot == nil }) else { throw LUTError.invalid }
            result = catalog.presets
        }
        presets = result + Self.userPresets(in:folder)
    }
    public static func userPresets(in folder:URL) -> [PresetRecipe] {
        let files = ((try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? [])
            .filter { $0.pathExtension == fileExtension }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return files.compactMap { url in
            guard let edits = try? JSONDecoder().decode(PhotoEdits.self,from:Data(contentsOf:url)) else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            return PresetRecipe(id:"user-"+name,name:name,category:myPresets,description:"Saved from your edits.",snapshot:edits.sanitized)
        }
    }
    public var categories: [String] {
        let present = Set(presets.map(\.category))
        return ["All"] + Self.categoryOrder.filter { present.contains($0) || $0 == Self.myPresets }
    }
    public func filtered(_ category:String) -> [PresetRecipe] { category == "All" ? presets : presets.filter { $0.category == category } }
    public func search(_ text:String, in list:[PresetRecipe]? = nil) -> [PresetRecipe] {
        let words = text.split(whereSeparator:\.isWhitespace).map { $0.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:nil) }
        guard !words.isEmpty else { return list ?? presets }
        return (list ?? presets).filter { p in
            let hay = [p.name,p.category,p.description].joined(separator:" ").folding(options:[.caseInsensitive,.diacriticInsensitive],locale:nil)
            return words.allSatisfy { hay.contains($0) }
        }
    }

    // MARK: My Presets
    public enum PresetError: LocalizedError {
        case badName, exists
        public var errorDescription: String? {
            switch self {
            case .badName: "Use a name without slashes or colons."
            case .exists: "A preset with this name already exists."
            }
        }
    }
    private static func fileURL(_ name:String, in folder:URL) throws -> URL {
        let clean = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 120, !clean.contains("/"), !clean.contains(":"), !clean.hasPrefix(".") else { throw PresetError.badName }
        return folder.appendingPathComponent(clean).appendingPathExtension(fileExtension)
    }
    @discardableResult public static func save(_ edits:PhotoEdits, name:String, in folder:URL, replacing:Bool = false) throws -> URL {
        let url = try fileURL(name,in:folder)
        if !replacing, FileManager.default.fileExists(atPath:url.path) { throw PresetError.exists }
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try JSONEncoder().encode(PresetRecipe.snapshot(of:edits)).write(to:url,options:.atomic)
        return url
    }
    public static func rename(_ name:String, to newName:String, in folder:URL) throws {
        let from = try fileURL(name,in:folder), to = try fileURL(newName,in:folder)
        guard from != to else { return }
        if FileManager.default.fileExists(atPath:to.path) { throw PresetError.exists }
        try FileManager.default.moveItem(at:from,to:to)
    }
    public static func delete(_ name:String, in folder:URL) throws { try FileManager.default.removeItem(at:fileURL(name,in:folder)) }
    /// Copies a `.openstillpreset` from elsewhere into My Presets (the file's name becomes the preset's name).
    @discardableResult public static func importPreset(_ file:URL, into folder:URL) throws -> URL {
        let edits = try JSONDecoder().decode(PhotoEdits.self,from:Data(contentsOf:file))
        var name = file.deletingPathExtension().lastPathComponent, n = 2
        while FileManager.default.fileExists(atPath:try fileURL(name,in:folder).path) { name = file.deletingPathExtension().lastPathComponent+" \(n)"; n += 1 }
        return try save(edits,name:name,in:folder)
    }
}
