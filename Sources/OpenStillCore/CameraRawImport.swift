import Foundation

/// Maps Adobe Camera Raw / Lightroom develop settings (the `crs:` XMP namespace) onto OpenStill's sliders.
/// This is a best-effort translation: OpenStill's tools are its own, so results look close but not identical.
/// Anything that can't be carried over is listed in `unsupported` instead of being silently dropped.
public struct CameraRawImport {
    public var edits: PhotoEdits
    /// Settings that were approximated, e.g. "White balance (relative, approximate)".
    public var approximated: [String] = []
    /// Settings that OpenStill can't reproduce, with their values.
    public var unsupported: [String] = []
    public var applied: Int = 0
    public var isEmpty: Bool { applied == 0 }

    /// - Parameter raw: true when the photo is developed from RAW, so white balance is an absolute temperature.
    public init(_ xmp: XMPMetadata, raw: Bool, base: PhotoEdits = PhotoEdits()) {
        edits = base
        var used = XMPSidecar.bookkeeping
        let crs = xmp.cameraRaw
        func number(_ key: String) -> Double? {
            guard let text = crs[key]?.trimmingCharacters(in: .whitespaces), let value = Double(text.hasPrefix("+") ? String(text.dropFirst()) : text), value.isFinite else { return nil }
            return value
        }
        /// Reads a setting; returns nil (and marks it used) when it is missing or at its default.
        func take(_ key: String, default value: Double = 0) -> Double? {
            used.insert(key)
            guard let v = number(key), abs(v - value) > 1e-9 else { return nil }
            applied += 1; return v
        }
        func flag(_ key: String) -> Bool { used.insert(key); return ["true", "1"].contains(crs[key]?.lowercased() ?? "") }

        // Process version: sliders before 2012 (PV2010 and older) had different ranges.
        if let version = crs["ProcessVersion"], let major = Double(version.split(separator: ".").first ?? ""), major < 10 {
            approximated.append("Settings from Camera Raw process version \(version) (older than 2012) are read as if they were 2012")
        }
        // Basic
        if let v = take("Exposure2012") ?? take("Exposure") { edits.exposure = v }
        if let v = take("Contrast2012") ?? take("Contrast") { edits.contrast = 1 + v / 200 }
        if let v = take("Highlights2012") ?? take("HighlightRecovery") {
            if v < 0 || crs["Highlights2012"] == nil { edits.highlights = 1 - abs(v) / 100 } else { applied -= 1; unsupported.append("Highlights +\(Int(v)) (OpenStill’s Highlights only recovers)") }
        }
        if let v = take("Shadows2012") ?? take("FillLight") {
            if v > 0 { edits.shadows = v / 100 } else { edits.blacks = max(-1, edits.blacks + v / 200); approximated.append("Shadows \(Int(v)) (applied as Blacks)") }
        }
        if let v = take("Whites2012") { edits.whites = v / 100 }
        if let v = take("Blacks2012") { edits.blacks = v / 100 }
        else if let v = take("Shadows", default: 5) { edits.blacks = -v / 100 }   // before 2012, "Shadows" set the black point
        if let v = take("Vibrance") { edits.vibrance = v / 100 }
        if let v = take("Saturation") { edits.saturation = 1 + v / 100 }
        if let v = take("Clarity2012") ?? take("Clarity") { edits.clarity = v / 100 }
        if let v = take("Texture") { edits.texture = v / 100 }
        if let v = take("Dehaze") { edits.dehaze = v / 100 }
        if flag("ConvertToGrayscale") { edits.monochrome = 1; applied += 1 }

        // White balance
        used.formUnion(["WhiteBalance", "Temperature", "Tint", "IncrementalTemperature", "IncrementalTint"])
        let balance = crs["WhiteBalance"] ?? ""
        if raw {
            if balance != "" && balance != "As Shot", let k = number("Temperature") {
                edits.temperature = min(10000, max(2500, k)); applied += 1
                if k < 2500 || k > 10000 { approximated.append("Temperature \(Int(k)) K (limited to 2500–10000 K)") }
                if let t = number("Tint") { edits.tint = min(100, max(-100, t)) }
            }
        } else {
            let t = number("IncrementalTemperature") ?? 0, g = number("IncrementalTint") ?? 0
            if t != 0 || g != 0 {
                edits.temperature = min(10000, max(2500, 6500 + t * 35)); edits.tint = min(100, max(-100, g)); applied += 1
                approximated.append("White balance (Temperature \(Int(t)), Tint \(Int(g)) mapped to OpenStill’s relative white balance)")
            }
        }

        // Tone curve: sampled at OpenStill's five points.
        func curve(_ key: String) -> [Double]? {
            used.insert(key)
            guard let items = xmp.cameraRawLists[key] else { return nil }
            let points = items.compactMap { item -> (Double, Double)? in
                let parts = item.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                return parts.count == 2 ? (parts[0] / 255, parts[1] / 255) : nil
            }.sorted { $0.0 < $1.0 }
            guard points.count >= 2 else { return nil }
            let sampled = ToneCurves.identity.map { x -> Double in
                if x <= points[0].0 { return points[0].1 }
                if x >= points[points.count - 1].0 { return points[points.count - 1].1 }
                let i = points.firstIndex { $0.0 >= x }!, a = points[i - 1], b = points[i]
                return b.0 == a.0 ? b.1 : a.1 + (b.1 - a.1) * (x - a.0) / (b.0 - a.0)
            }
            return zip(sampled, ToneCurves.identity).allSatisfy { abs($0 - $1) < 1e-4 } ? nil : sampled
        }
        var curves = edits.curves, curved = false
        if let c = curve("ToneCurvePV2012") ?? curve("ToneCurve") { curves.master = c; curved = true }
        if let c = curve("ToneCurvePV2012Red") { curves.red = c; curved = true }
        if let c = curve("ToneCurvePV2012Green") { curves.green = c; curved = true }
        if let c = curve("ToneCurvePV2012Blue") { curves.blue = c; curved = true }
        if curved {
            edits.curves = curves; applied += 1
            if (xmp.cameraRawLists["ToneCurvePV2012"]?.count ?? 0) > 5 { approximated.append("Point curve (sampled at five points)") }
        }
        let parametric = ["ParametricShadows", "ParametricDarks", "ParametricLights", "ParametricHighlights"].compactMap { key -> String? in take(key).map { "\(key.dropFirst(10)) \(Int($0))" } }
        used.formUnion(["ParametricShadowSplit", "ParametricMidtoneSplit", "ParametricHighlightSplit"])
        if !parametric.isEmpty { applied -= parametric.count; unsupported.append("Parametric curve (" + parametric.joined(separator: ", ") + ")") }

        // HSL / Color mixer
        let bands = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
        for (i, band) in bands.enumerated() {
            let hue = take("HueAdjustment\(band)"), saturation = take("SaturationAdjustment\(band)"), luminance = take("LuminanceAdjustment\(band)")
            guard hue != nil || saturation != nil || luminance != nil else { continue }
            edits.ensureAdvanced()
            var b = edits.advanced!.colors[i]
            if let hue { b.hue = hue / 100 }
            if let saturation { b.saturation = saturation / 100 }
            if let luminance { b.lightness = luminance / 100 }
            b.displayMode = "hsl"; edits.advanced!.colors[i] = b
        }
        let grays = bands.compactMap { band in take("GrayMixer\(band)").map { "\(band) \(Int($0))" } }
        if !grays.isEmpty { applied -= grays.count; unsupported.append("Black & white mix (" + grays.joined(separator: ", ") + ")") }

        // Color grading (and the older split toning)
        var grading = edits.colorGrading, graded = false
        func wheel(_ w: inout GradeWheel, _ hueKey: String, _ satKey: String, _ lumKey: String?) {
            let h = take(hueKey), s = take(satKey), l = lumKey.flatMap { take($0) }
            if let h { w.hue = h }
            if let s { w.saturation = s / 100 }
            if let l { w.luminance = l / 100 }
            if h != nil || s != nil || l != nil { graded = true }
        }
        wheel(&grading.shadows, "ColorGradeShadowHue", "ColorGradeShadowSat", "ColorGradeShadowLum")
        wheel(&grading.midtones, "ColorGradeMidtoneHue", "ColorGradeMidtoneSat", "ColorGradeMidtoneLum")
        wheel(&grading.highlights, "ColorGradeHighlightHue", "ColorGradeHighlightSat", "ColorGradeHighlightLum")
        wheel(&grading.global, "ColorGradeGlobalHue", "ColorGradeGlobalSat", "ColorGradeGlobalLum")
        if grading.shadows.isNeutral && grading.highlights.isNeutral {
            wheel(&grading.shadows, "SplitToningShadowHue", "SplitToningShadowSaturation", nil)
            wheel(&grading.highlights, "SplitToningHighlightHue", "SplitToningHighlightSaturation", nil)
        } else { used.formUnion(["SplitToningShadowHue", "SplitToningShadowSaturation", "SplitToningHighlightHue", "SplitToningHighlightSaturation"]) }
        if let v = take("ColorGradeBlending", default: 50) { grading.blending = v / 100; graded = true }
        if let v = take("ColorGradeBalance") ?? take("SplitToningBalance") { grading.balance = v / 100; graded = true }
        if graded { edits.colorGrading = grading.sanitized }

        // Detail
        if let v = take("Sharpness", default: raw ? 40 : 0) { edits.sharpness = min(2, v / 75) }
        used.formUnion(["SharpenRadius", "SharpenDetail", "SharpenEdgeMasking", "LuminanceNoiseReductionDetail", "LuminanceNoiseReductionContrast", "ColorNoiseReductionDetail", "ColorNoiseReductionSmoothness"])
        if let v = take("LuminanceSmoothing") { edits.denoise = v / 100 }
        if let v = take("ColorNoiseReduction", default: raw ? 25 : 0) { applied -= 1; approximated.append("Color noise reduction \(Int(v)) (use RAW decoding → Color noise in Profile & calibration)") }

        // Effects
        if let v = take("PostCropVignetteAmount") { edits.vignette = v / 100 }
        used.formUnion(["PostCropVignetteMidpoint", "PostCropVignetteFeather", "PostCropVignetteRoundness", "PostCropVignetteStyle", "PostCropVignetteHighlightContrast"])
        var grain = edits.grain
        if let v = take("GrainAmount") {
            grain.amount = v / 100
            if let s = take("GrainSize", default: 25) { grain.size = s / 100 }
            if let r = take("GrainFrequency", default: 50) { grain.roughness = r / 100 }
            edits.grain = grain.sanitized
        } else { used.formUnion(["GrainSize", "GrainFrequency"]) }

        // Lens corrections
        if let v = take("VignetteAmount") { applied -= 1; unsupported.append("Lens vignetting \(Int(v))") }
        used.insert("VignetteMidpoint")
        if flag("LensProfileEnable") { unsupported.append("Lens profile corrections (turn on Lens corrections in OpenStill; its profiles are matched separately)") }
        if flag("AutoLateralCA") { unsupported.append("Remove chromatic aberration (use Defringe in Lens corrections)") }
        used.formUnion(["LensProfileSetup", "LensProfileName", "LensProfileFilename", "LensProfileDigest", "LensProfileDistortionScale", "LensProfileVignettingScale", "LensProfileChromaticAberrationScale", "LensManualDistortionAmount", "LensProfileIsEmbedded"])
        let defringe = ["DefringePurpleAmount", "DefringeGreenAmount"].compactMap { key in take(key).map { (key, $0) } }
        if !defringe.isEmpty {
            var d = edits.defringe
            for (key, v) in defringe { if key.contains("Purple") { d.purpleAmount = min(1, v / 20) } else { d.greenAmount = min(1, v / 20) } }
            edits.defringe = d.sanitized
        }
        used.formUnion(["DefringePurpleHueLo", "DefringePurpleHueHi", "DefringeGreenHueLo", "DefringeGreenHueHi"])

        // Transform (manual sliders; Upright is solved again by OpenStill)
        var transform = edits.transform, transformed = false
        for (key, path, scale): (String, WritableKeyPath<TransformSettings, Double>, Double) in [("PerspectiveVertical", \TransformSettings.vertical, 100.0), ("PerspectiveHorizontal", \.horizontal, 100), ("PerspectiveRotate", \.rotate, 1),
                                   ("PerspectiveAspect", \.aspect, 100), ("PerspectiveX", \.offsetX, 100), ("PerspectiveY", \.offsetY, 100)] {
            if let v = take(key) { transform[keyPath: path] = v / scale; transformed = true }
        }
        if let v = take("PerspectiveScale", default: 100) { transform.scale = v / 100; transformed = true }
        if let v = take("PerspectiveUpright") {
            applied -= 1
            let modes: [Double: UprightMode] = [1: .auto, 2: .full, 3: .level, 4: .vertical]
            unsupported.append(modes[v].map { "Upright \($0.title) (choose it again in Transform; OpenStill finds the lines itself)" } ?? "Guided Upright (draw the guides again in Transform)")
        }
        used.formUnion(["UprightVersion", "UprightCenterMode", "UprightCenterNormX", "UprightCenterNormY", "UprightFocalMode", "UprightFocalLength35mm", "UprightPreview", "UprightTransformCount", "UprightDependentDigest", "UprightGuidedDependentDigest", "UprightFourSegmentsCount", "UprightFourSegments_0", "UprightFourSegments_1", "UprightFourSegments_2", "UprightFourSegments_3"])
        if transformed { edits.transform = transform.sanitized; approximated.append("Transform sliders (OpenStill’s perspective model, so the result is close but not identical)") }

        // Crop: Camera Raw stores the crop in the unrotated image with a top-left origin.
        if flag("HasCrop") || crs["CropLeft"] != nil {
            used.formUnion(["CropTop", "CropLeft", "CropBottom", "CropRight", "CropAngle", "CropUnit", "CropWidth", "CropHeight"])
            if let top = number("CropTop"), let left = number("CropLeft"), let bottom = number("CropBottom"), let right = number("CropRight"),
               right > left, bottom > top, !(left <= 0 && top <= 0 && right >= 1 && bottom >= 1) || (number("CropAngle") ?? 0) != 0 {
                let l = min(1, max(0, left)), r = min(1, max(0, right)), t = min(1, max(0, top)), b = min(1, max(0, bottom))
                edits.crop = EditRect(CGRect(x: l, y: 1 - b, width: r - l, height: b - t)); applied += 1
                if let angle = number("CropAngle"), angle != 0 {
                    edits.straighten = min(20, max(-20, -angle))
                    approximated.append("Crop angle \(String(format: "%.2f", angle))° (OpenStill straightens, then crops, so the framing can differ slightly)")
                }
            }
        }

        // Profiles and everything else
        if let profile = crs["CameraProfile"] {
            used.insert("CameraProfile")
            if profile.localizedCaseInsensitiveContains("monochrome") { edits.monochrome = 1; applied += 1 }
            else if !["Adobe Standard", "Adobe Color", "Embedded"].contains(profile) { unsupported.append("Camera profile “\(profile)” (choose a look in Profile & calibration)") }
        }
        used.insert("Look")
        if let look = crs["LookName"], !look.isEmpty { unsupported.append("Profile look “\(look)” (choose a look in Profile & calibration)") }
        else if crs["Look"] != nil { unsupported.append("Profile look (choose a look in Profile & calibration)") }
        for key in crs.keys.sorted() where !used.contains(key) && !key.hasPrefix("Enable") && !key.hasPrefix("Supports") {
            let value = crs[key]!
            if let v = number(key), v == 0 { continue }
            if value.lowercased() == "false" || value.isEmpty { continue }
            unsupported.append("\(Self.title(key)) (\(value.count > 30 ? "set" : value))")
        }
        for key in xmp.cameraRawLists.keys.sorted() where !used.contains(key) && !(xmp.cameraRawLists[key]?.isEmpty ?? true) {
            unsupported.append(Self.title(key))
        }
        edits = edits.sanitized
    }

    /// "PostCropVignetteAmount" → "Post Crop Vignette Amount".
    static func title(_ key: String) -> String {
        var out = ""
        for (i, c) in key.enumerated() {
            if i > 0, c.isUppercase, let previous = out.last, previous.isLowercase || previous.isNumber { out.append(" ") }
            out.append(c)
        }
        return out.replacingOccurrences(of: "2012", with: "").trimmingCharacters(in: .whitespaces)
    }
    /// A short summary for the user.
    public var report: String {
        var lines = ["\(applied) setting\(applied == 1 ? "" : "s") imported."]
        if !approximated.isEmpty { lines.append("Approximated:\n" + approximated.map { "• " + $0 }.joined(separator: "\n")) }
        if !unsupported.isEmpty { lines.append("Not imported:\n" + unsupported.map { "• " + $0 }.joined(separator: "\n")) }
        return lines.joined(separator: "\n\n")
    }
}

extension PhotoRecord {
    /// Adds a version named "Camera Raw" (or `name`) developed with the imported settings, and makes it active.
    /// Returns nil when the settings carry nothing OpenStill can apply.
    @discardableResult public mutating func importCameraRaw(_ xmp: XMPMetadata, name: String = "Camera Raw") -> CameraRawImport? {
        let mode = RawDecoder.defaultMode(for: URL(fileURLWithPath: sourcePath))
        let result = CameraRawImport(xmp, raw: mode == .raw)
        guard !result.isEmpty else { return nil }
        var version = EditVersion(name: name, renderer: .linear2020, sourceMode: mode, document: EditDocument(fingerprint: active.document.fingerprint))
        version.document.commit(result.edits, title: "Imported \(name) settings")
        versions.append(version); activeVersionID = version.id
        return result
    }
}
