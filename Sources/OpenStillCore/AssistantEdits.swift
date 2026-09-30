import Foundation
import CoreGraphics

/// The whole edit as an AI assistant reads and changes it: the same Codable document OpenStill saves, with every
/// section shown (defaults where unset), changed through JSON merge patches (RFC 7386). New Develop features reach
/// the assistant with no new tool: they appear in the document, and `reference` must describe them (a test checks).
public enum AssistantEdits {
    // MARK: What the assistant sees
    /// Kept by OpenStill itself: older-edit compatibility, AI results and files. Hidden, and refused in patches.
    static let hiddenTop: Set<String> = ["blackAndWhite", "schemaVersion", "baseAsset", "overlayAsset", "overlayOpacity", "overlayBlend", "sunrays", "sunX", "sunY"]
    static let hiddenAdvanced: Set<String> = ["toneModel", "contrastModel", "whiteBalanceModel", "toneHighlights", "toneShadows", "rawWhiteBalance", "rawRecovery",
                                              "rawDenoise", "aiBackgroundAsset", "aiFeatureKey", "lutAsset", "lutName", "lutID", "sunLength"]
    /// Highlights and Shadows are shown on the Lightroom-style −1…1 scale; the stored fields depend on the edit's age.
    static let virtualTop = ["highlights", "shadows"]

    static func json<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }
    static func object(_ value: JSONValue) -> [String: JSONValue] { if case .object(let o) = value { return o }; return [:] }

    /// Every section with its defaults. Special keys: "[]" is the template of an array's items, "{}" of a dictionary's
    /// values, and "?" marks a part that is filled only when it is already there (its presence changes the meaning).
    static let template: [String: JSONValue] = {
        var a = AdvancedEdits()
        a.lens = LensSettings(); a.neutralBalance = NeutralBalance(); a.glow = GlowSettings(); a.sunSettings = SunraysSettings()
        a.clarity = 0; a.texture = 0; a.dehaze = 0; a.colorGrading = ColorGrading(); a.grain = GrainSettings(); a.defringe = DefringeSettings()
        a.profile = ProfileSettings(); a.calibration = CalibrationSettings(); a.rawOptions = RawOptions()
        a.lensBlur = LensBlurSettings(); a.hdr = HDRSettings(); a.grayMix = PhotoEdits.neutralGrayMix; a.detail = DetailSettings()
        a.autoCA = AutoCASettings(enabled: false)
        var curves = ToneCurves(); curves.parametric = ParametricCurve(); a.curves = curves
        var transform = TransformSettings(); transform.upright = UprightSolution(mode: .off); a.transform = transform
        var edits = PhotoEdits(); edits.advanced = a
        var root = (try? json(edits)).map(object) ?? [:]
        var advanced = object(root["advanced"] ?? .null)
        func items(_ value: JSONValue) -> JSONValue { .object(["[]": value]) }
        var mask = object((try? json(AdjustmentMask())) ?? .null)
        mask["strokes"] = items((try? json(MaskStroke(points: [MaskPoint(CGPoint(x: 0.5, y: 0.5))], radius: 0.03))) ?? .null)
        mask["range"] = .object(["?": (try? json(RangeSelection())) ?? .null])
        var component = object((try? json(MaskComponent(name: "Component", selection: AdjustmentMask()))) ?? .null)
        component["selection"] = .object(mask)
        mask["components"] = .object(["?": items(.object(component))])
        advanced["masks"] = .object(["{}": .object(mask)])
        advanced["colors"] = items(.object(object((try? json(ColorBand())) ?? .null).merging(["lightness": .number(0)]) { a, _ in a }))
        advanced["pointColors"] = items((try? json(PointColor(hue: 0, saturation: 0.5, lightness: 0.5))) ?? .null)
        advanced["eyeFixes"] = items((try? json(EyeFix(kind: .redEye, center: CGPoint(x: 0.5, y: 0.5), radiusX: 0.02, radiusY: 0.02))) ?? .null)
        advanced["retouch"] = items((try? json(RetouchStroke(mode: .heal, source: CGPoint(x: 0.4, y: 0.5), destination: CGPoint(x: 0.5, y: 0.5),
                                                            points: [CGPoint(x: 0.5, y: 0.5)], radius: 0.025, feather: 0.5, opacity: 1))) ?? .null)
        advanced["localAdjustments"] = items((try? json(LocalAdjustment(name: "Mask"))) ?? .null)
        var curvesObject = object(advanced["curves"] ?? .null)
        for key in ["masterPoints", "redPoints", "greenPoints", "bluePoints"] { curvesObject[key] = items((try? json(CurvePoint(0, 0))) ?? .null) }
        advanced["curves"] = .object(curvesObject)
        var transformObject = object(advanced["transform"] ?? .null)
        transformObject["guides"] = items((try? json(GuideLine(CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5)))) ?? .null)
        advanced["transform"] = .object(transformObject)
        root["advanced"] = .object(advanced)
        root["crop"] = .object(["?": (try? json(EditRect(CGRect(x: 0, y: 0, width: 1, height: 1)))) ?? .null])
        return root
    }()

    /// A template's value when the part is missing: containers start empty, "?" parts stay missing.
    static func materialize(_ t: JSONValue) -> JSONValue? {
        guard case .object(let o) = t else { return t }
        if o["[]"] != nil { return .array([]) }
        if o["{}"] != nil { return .object([:]) }
        if o["?"] != nil { return nil }
        return .object(o.compactMapValues(materialize))
    }
    /// Adds the template's missing parts (and fills each array item and dictionary value from its template).
    static func fill(_ value: JSONValue, _ t: JSONValue) -> JSONValue {
        guard case .object(let to) = t else { return value }
        if let item = to["[]"] { if case .array(let list) = value { return .array(list.map { fill($0, item) }) }; return value }
        if let item = to["{}"] { if case .object(let o) = value { return .object(o.mapValues { fill($0, item) }) }; return value }
        if let inner = to["?"] { return fill(value, inner) }
        guard case .object(var o) = value else { return value }
        for (key, sub) in to {
            if let present = o[key] { o[key] = fill(present, sub) } else if let made = materialize(sub) { o[key] = made }
        }
        return .object(o)
    }
    /// Drops parts that were missing before, were only filled in, and are unchanged: the saved edit stays as small as before.
    static func unfill(_ merged: JSONValue, filled: JSONValue, original: JSONValue?) -> JSONValue {
        guard case .object(var m) = merged, case .object(let f) = filled else { return merged }
        let o: [String: JSONValue]? = { if case .object(let o)? = original { return o }; return nil }()
        for (key, value) in m {
            guard let before = f[key] else { continue }
            if o?[key] == nil && value == before { m[key] = nil; continue }
            if case .object = value { m[key] = unfill(value, filled: before, original: o?[key]) }
        }
        return .object(m)
    }
    /// RFC 7386: objects merge, `null` removes, anything else replaces.
    static func merge(_ target: JSONValue, _ patch: JSONValue) -> JSONValue {
        guard case .object(let p) = patch else { return patch }
        var t = object(target)
        for (key, value) in p {
            if value == .null { t[key] = nil } else { t[key] = merge(t[key] ?? .null, value) }
        }
        return .object(t)
    }

    /// The photo's whole edit as the assistant sees it.
    public static func view(_ edits: PhotoEdits) throws -> JSONValue {
        var root = object(fill(try json(edits), .object(template)))
        for key in hiddenTop { root[key] = nil }
        var advanced = object(root["advanced"] ?? .null)
        for key in hiddenAdvanced { advanced[key] = nil }
        root["advanced"] = .object(advanced)
        root["highlights"] = .number(edits.highlightsAmount); root["shadows"] = .number(edits.shadowsAmount)
        return .object(root)
    }

    // MARK: Changing it
    public struct Result {
        public let edits: PhotoEdits
        /// "path: before → after" for everything that changed.
        public let changed: [String]
        /// Requested values that OpenStill limited or adjusted, with the value it kept.
        public let adjusted: [String]
    }
    /// Applies a JSON merge patch to the edit. Unknown keys, wrong types, hidden fields and files that aren't part of
    /// this photo are refused; everything is limited to its range exactly as the sliders are.
    public static func apply(_ patch: JSONValue, to current: PhotoEdits) throws -> Result {
        guard case .object(var p) = patch, !p.isEmpty else { throw AssistantError.message("Give a patch object, e.g. {\"advanced\": {\"glow\": {\"amount\": 30}}}.") }
        for key in p.keys where hiddenTop.contains(key) { throw AssistantError.message("“\(key)” is kept by OpenStill and can't be set. See edit_reference.") }
        if case .object(let a)? = p["advanced"] {
            for key in a.keys where hiddenAdvanced.contains(key) {
                throw AssistantError.message("“advanced.\(key)” is kept by OpenStill and can't be set" + (key.hasPrefix("lut") ? "; apply or remove LUTs with apply_lut / run_command remove_lut." : "."))
            }
        } else if let a = p["advanced"], a != .null { throw AssistantError.message("“advanced” must be an object.") }
        let virtuals = virtualTop.compactMap { key -> (String, Double)? in
            guard let value = p.removeValue(forKey: key) else { return nil }
            return (key, value.double ?? .nan)
        }
        for (key, value) in virtuals where !value.isFinite { throw AssistantError.message("“\(key)” needs a number from −1 to 1.") }
        let original = try json(current)
        let filled = fill(original, .object(template))
        try checkKeys(.object(p), against: .object(template), path: "")
        var merged = fill(merge(filled, .object(p)), .object(template))
        merged = unfill(merged, filled: filled, original: original)
        try checkAssets(merged, allowed: Set(assets(in: original)))
        var next: PhotoEdits
        do { next = try JSONDecoder().decode(PhotoEdits.self, from: JSONEncoder().encode(merged)) }
        catch let error as DecodingError { throw AssistantError.message(describe(error)) }
        for (key, value) in virtuals {
            let v = min(1, max(-1, value))
            if key == "highlights" { next.highlightsAmount = v } else { next.shadowsAmount = v }
        }
        next = next.sanitized
        let before = flatten(try view(current)), after = flatten(try view(next))
        let changed = Set(before.keys).union(after.keys).sorted().compactMap { key -> String? in
            let a = before[key], b = after[key]
            return a == b ? nil : "\(key): \(text(a)) → \(text(b))"
        }
        var requested = flatten(.object(p))
        for (key, value) in virtuals { requested[key] = .number(value) }
        let adjusted = requested.keys.sorted().compactMap { key -> String? in
            guard let asked = requested[key], asked != .null, let kept = after[key], !same(asked, kept) else { return nil }
            return "\(key): asked \(text(asked)), kept \(text(kept))"
        }
        return Result(edits: next, changed: changed, adjusted: adjusted)
    }
    /// Refuses keys the edit doesn't have, naming where, before decoding would give a vaguer error.
    static func checkKeys(_ patch: JSONValue, against t: JSONValue, path: String) throws {
        guard case .object(let p) = patch, case .object(var to) = t else { return }
        if let inner = to["?"], case .object(let unwrapped) = inner { to = unwrapped }
        if let item = to["{}"] { for (key, value) in p { try checkKeys(value, against: item, path: path + key + ".") }; return }
        if to["[]"] != nil { return }
        // Parts with no template (for example a sky, which only run_command can add) are checked when decoding.
        guard !to.isEmpty else { return }
        for (key, value) in p {
            guard let sub = to[key] else {
                let known = to.keys.filter { !$0.hasPrefix("[") && $0 != "{}" && $0 != "?" }.sorted().joined(separator: ", ")
                if path.isEmpty && (key == "advanced" || virtualTop.contains(key)) { continue }
                throw AssistantError.message("Unknown key “\(path + key)”. Keys here: \(known).")
            }
            if case .object(let so) = sub, so["[]"] != nil, case .array(let list) = value {
                for (i, item) in list.enumerated() { try checkKeys(item, against: so["[]"]!, path: path + key + "[\(i)].") }
            } else {
                try checkKeys(value, against: sub, path: path + key + ".")
            }
        }
    }
    /// File names under "asset" keys (masks, depth maps, profiles, skies…).
    static func assets(in value: JSONValue, key: String = "") -> [String] {
        switch value {
        case .object(let o): return o.flatMap { assets(in: $0.value, key: $0.key) }
        case .array(let list): return list.flatMap { assets(in: $0, key: key) }
        case .string(let s): return key == "asset" || key.hasSuffix("Asset") ? [s] : []
        default: return []
        }
    }
    static func checkAssets(_ value: JSONValue, allowed: Set<String>) throws {
        for name in assets(in: value) where !allowed.contains(name) {
            let path = EditStorage.asset(name).path
            guard !name.contains("/"), !name.hasPrefix("."), FileManager.default.fileExists(atPath: path) else {
                throw AssistantError.message("“\(name)” isn't a file of this photo. OpenStill makes those files itself: use add_mask_layer for AI selections, run_command for skies, depth and AI tools.")
            }
        }
    }
    static func describe(_ error: DecodingError) -> String {
        func at(_ c: DecodingError.Context) -> String {
            let joined = c.codingPath.map { key in key.intValue.map { "[\($0)]" } ?? "." + key.stringValue }.joined()
            return String(joined.drop(while: { $0 == "." }))
        }
        switch error {
        case .keyNotFound(let key, let c): return "“\(at(c).isEmpty ? key.stringValue : at(c) + "." + key.stringValue)” is required here. See edit_reference for the full item."
        case .typeMismatch(_, let c), .valueNotFound(_, let c): return "“\(at(c))” has the wrong type: \(c.debugDescription)"
        case .dataCorrupted(let c): return "“\(at(c))”: \(c.debugDescription)"
        @unknown default: return "The edit couldn't be read: \(error.localizedDescription)"
        }
    }
    /// Leaf values by path ("advanced.glow.amount", "advanced.colors[2].hue").
    public static func flatten(_ value: JSONValue, _ path: String = "") -> [String: JSONValue] {
        switch value {
        case .object(let o) where !o.isEmpty:
            return o.reduce(into: [:]) { r, e in r.merge(flatten(e.value, path.isEmpty ? e.key : path + "." + e.key)) { a, _ in a } }
        case .array(let list) where list.contains(where: { if case .object = $0 { return true }; return false }):
            return list.enumerated().reduce(into: [:]) { r, e in r.merge(flatten(e.element, "\(path)[\(e.offset)]")) { a, _ in a } }
        default: return [path: value]
        }
    }
    static func same(_ a: JSONValue, _ b: JSONValue) -> Bool {
        if let x = a.double, let y = b.double, case .number = a, case .number = b { return abs(x - y) < 1e-6 }
        return a == b
    }
    public static func text(_ value: JSONValue?) -> String {
        switch value {
        case nil: return "—"
        case .number(let n)?: return n == n.rounded() && abs(n) < 1e9 ? String(Int(n)) : String((n * 10000).rounded() / 10000)
        case .string(let s)?: return "\"\(s)\""
        case let v?: return (try? String(decoding: JSONEncoder().encode(v), as: UTF8.self)).map { $0.count > 80 ? String($0.prefix(77)) + "…" : $0 } ?? "?"
        }
    }

    // MARK: Reference
    /// What every part of the edit means. Keys are paths; "[]" is any item of a list, "{}" any entry of a dictionary.
    /// A test walks the template and requires each field to be named in its own entry or its section's.
    public static let reference: [(String, String)] = [
        ("", """
        The edit document is the photo's whole Develop state, exactly what OpenStill saves. Change it with `edit` and a JSON merge patch: \
        give only what changes, nested like the document ({"advanced": {"glow": {"amount": 30}}}); an object merges, null removes a part \
        (turning it off), and a list is replaced whole (send the full list). Every value is limited to its range, like the sliders. \
        Each `edit` is one undo step and shows up live. Coordinates in the document are fractions of the photo (0…1) with x from the left \
        and y from the BOTTOM (0 = bottom edge) — unlike the mask tools, which take y from the top. Masks, retouch and eye fixes are placed \
        on the original photo before crop and rotation.
        """),
        ("exposure", "Basic · exposure: stops, −4…4 (0 = no change)."),
        ("contrast", "Basic · contrast: 0.5…1.5, 1 = no change (Smart Contrast)."),
        ("highlights", "Basic · highlights: −1…1, 0 = no change; − recovers bright areas, + brightens them."),
        ("shadows", "Basic · shadows: −1…1, 0 = no change; − deepens, + lifts."),
        ("temperature", "Basic · white balance temperature in kelvin, 2500…10000, 6500 = as shot; higher is warmer."),
        ("tint", "Basic · tint: −100…100, 0 = as shot; + magenta, − green."),
        ("saturation", "Basic · saturation: 0…2, 1 = no change, 0 = black and white."),
        ("vibrance", "Basic · vibrance: −1…1, 0 = no change."),
        ("structure", "Detail · structure: 0…1, extra local contrast at a large radius."),
        ("sharpness", "Detail · sharpening amount: 0…2 (radius, detail and masking are in advanced.detail)."),
        ("denoise", "Detail · luminance noise reduction: 0…1 (detail and contrast in advanced.detail)."),
        ("vignette", "Effects · post-crop vignette: −1…1, − darkens the edges, + lightens them."),
        ("autoEnhance", "autoEnhance: true adds OpenStill's automatic enhancement on top of the sliders."),
        ("rotation", "Geometry · rotation: quarter turns clockwise, 0…3."),
        ("flip", "Geometry · flip: true mirrors the photo horizontally."),
        ("crop", "Geometry · crop rectangle as fractions of the rotated photo, from the bottom-left: x, y, width, height (0…1). null removes the crop."),
        ("opacity", "opacity: 0…1, how much of the whole edit is shown over the unedited photo (1 = all)."),
        ("advanced", "Everything beyond the basic sliders, by panel section."),
        ("advanced.monochrome", "Black & white · monochrome: 0 = color, 1 = black and white (mix the channels with advanced.grayMix)."),
        ("advanced.blacks", "Basic · blacks: −1…1, sets the black point."),
        ("advanced.whites", "Basic · whites: −1…1, sets the white point."),
        ("advanced.straighten", "Geometry · straighten: −20…20 degrees."),
        ("advanced.lutAmount", "LUT strength 0…1 (apply a LUT with apply_lut; remove with run_command remove_lut)."),
        ("advanced.clarity", "Presence · clarity: −1…1."),
        ("advanced.texture", "Presence · texture: −1…1."),
        ("advanced.dehaze", "Presence · dehaze: −1…1 (− adds haze)."),
        ("advanced.grayMix", "Black & white mix: 8 values −1…1 (red, orange, yellow, green, aqua, blue, purple, magenta), 0 = neutral. Used when monochrome is 1."),
        ("advanced.colors", "HSL / Color: 8 bands in order red, orange, yellow, green, aqua, blue, purple, magenta. Each band: hue (−1…1 shift), saturation (−1…1), lightness (−1…1). Send all 8 when changing any."),
        ("advanced.curves", """
        Tone Curve. master, red, green, blue: 5 output values (0…1) at inputs 0, 0.25, 0.5, 0.75, 1 (identity [0,0.25,0.5,0.75,1]). \
        masterPoints, redPoints, greenPoints, bluePoints: optional free curves of 2–16 points {x, y} (0…1), used instead of the 5 values when given. \
        parametric: shadows, darks, lights, highlights (−1…1) with shadowSplit (0.1…0.4), midtoneSplit, highlightSplit (…0.9), like Lightroom's region curve.
        """),
        ("advanced.neutralBalance", "White balance picker gains: red, green, blue multipliers (1 = none), set by picking something neutral gray."),
        ("advanced.glow", "Effects · Glow: mode (glow, softFocus, orton, ortonSoft), amount 0…100, softness 0…100, brightness −100…100, contrast −100…100, warmth −100…100."),
        ("advanced.sunSettings", """
        Effects · Sunrays: amount 0…100 (0 = off), overallLook, length, penetration, sunRadius, glowRadius, glowAmount, randomize, sunWarmth, raysWarmth (0…100), \
        rayCount 1…100, centerX and centerY: where the sun is, as fractions of the photo (0…1 from the bottom-left; may lie outside).
        """),
        ("advanced.colorGrading", "Color Grading: shadows, midtones, highlights, global wheels, each hue (0…360°), saturation (0…1), luminance (−1…1); blending 0…1 (0.5), balance −1…1."),
        ("advanced.grain", "Effects · Grain: amount 0…1 (0 = off), size 0…1, roughness 0…1."),
        ("advanced.defringe", "Lens · Defringe: purpleAmount and greenAmount 0…1 (0 = off); purpleLow/purpleHigh hue range 180…360°, greenLow/greenHigh 30…200°."),
        ("advanced.lens", """
        Lens Corrections: enabled; profileID (a lens profile id, or absent for manual only); focal (mm), aperture, distance (m), crop factor; \
        distortion, chromaticAberration, opticalVignette: which profile corrections to use; manualDistortion, manualChromatic, manualVignette −1…1. \
        run_command match_lens_profile picks the profile from the photo's metadata.
        """),
        ("advanced.autoCA", "Lens · automatic chromatic aberration: enabled; redScale and blueScale (≈1) are measured by OpenStill."),
        ("advanced.transform", """
        Transform: vertical, horizontal (−1…1 keystone), rotate (−15…15°), aspect (−1…1), scale (0.5…1.5), offsetX, offsetY (−1…1), \
        constrain (true crops away blank edges). upright: {mode (off, auto, level, vertical, full, guided), rotate, vertical, horizontal} as found by \
        run_command upright; guides: up to 4 lines {x1, y1, x2, y2} for guided Upright.
        """),
        ("advanced.profile", "Profile: look (standard, neutral, vivid, portrait, landscape, monochrome), amount 0…2 (1 = full); dcpAsset and dcpName come from an imported camera profile."),
        ("advanced.calibration", "Calibration: shadowsTint, redHue, redSaturation, greenHue, greenSaturation, blueHue, blueSaturation, each −1…1."),
        ("advanced.rawOptions", "RAW options (RAW photos only): demosaic (ahd, aahd, dcb, dht, vng, ppg, linear), noise 0…1 (wavelet noise reduction), colorNoise 0…3, impulseNoise 0…2."),
        ("advanced.lensBlur", """
        Effects · Lens Blur: amount 0…1 (0 = off), focus 0…1 (the depth kept sharp; 1 = nearest), range 0…1 (depth of the sharp band), \
        blurForeground. depthAsset and depthSource are set by run_command lens_blur_depth (a depth map is needed first).
        """),
        ("advanced.hdr", "HDR: enabled (edit and show highlights brighter than white on HDR displays), headroom 0.5…4 stops."),
        ("advanced.detail", "Detail: radius 0.5…3, detail 0…1, masking 0…1 (sharpening); noiseDetail 0…1, noiseContrast 0…1 (luminance noise reduction); color 0…1, colorDetail 0…1 (color noise reduction)."),
        ("advanced.pointColors", """
        Point Color: up to 8 sampled colors, each changing only colors near it. id; hue (0…1 around the wheel), saturation and lightness (0…1): the sampled color; \
        hueShift, saturationShift, lightnessShift (−1…1): the change; range 0…1: how wide around the sample.
        """),
        ("advanced.eyeFixes", """
        Red Eye / Pet Eye: id; kind (redEye, petEye); center {x, y} and radiusX, radiusY as fractions of the original photo (from the bottom-left); \
        pupil 0…1 (size), darken 0…1; catchlight (pet eye).
        """),
        ("advanced.retouch", """
        Remove (heal and clone) strokes: id; mode (heal, clone); points: the painted path [{x, y}…] and destination {x, y} (its first point); \
        source {x, y}: where to copy from; radius 0.0001…0.5 (fraction of the short side), feather 0…1, opacity 0…1. Fractions of the original photo, from the bottom-left.
        """),
        ("advanced.localAdjustments", """
        Mask layers (Masking panel), applied in order: id; name; hidden; settings: the layer's sliders exposure (−4…4), contrast, highlights, shadows, whites, blacks, \
        temperature, tint, saturation, clarity, texture, dehaze, sharpness (−1…1) and noise (0…1). Each layer's selection is advanced.masks["Mask-<id>"]. \
        The mask tools (add_mask_layer, update_mask_layer, preview_mask) are the easy way; this is the same data.
        """),
        ("advanced.masks", """
        Selections, keyed by what they limit: "Mask-<layer id>" for a mask layer, or a tool's name to limit that whole tool (Erase for run_command ai_erase, \
        Sky, Glow, Vignette, LUT, Details, Clarity, Texture, Dehaze…). Each selection: kind (brush, linear, radial, object, depthMap, stack); \
        start and end {x, y} (linear: no effect at start rising to full at end; radial: center at start, radii to end); feather 0…1; inverted; \
        strokes: brush strokes [{points [{x, y}…], radius (fraction of the short side), subtract, softness 0…1, strength 0…1}]; asset: an AI selection's image \
        (made by OpenStill). components: a stack of parts [{id, name, visible, opacity 0…1, operation (add, subtract, intersect), selection: a selection as above}], \
        used instead of the fields above when present. range: color or luminance range {red, green, blue (the picked color), tolerance, softness, low, high} (0…1).
        """),
    ]
    /// The reference as one text for the assistant.
    public static var referenceText: String {
        reference.map { $0.0.isEmpty ? $0.1 : "\($0.0) — \($0.1)" }.joined(separator: "\n\n")
    }
    /// Every field path of the document (for the completeness test).
    static func fieldPaths(_ t: JSONValue = .object(template), _ path: String = "") -> [String] {
        guard case .object(let o) = t else { return [path] }
        if let item = o["[]"] { return fieldPaths(item, path + "[]") }
        if let item = o["{}"] { return fieldPaths(item, path + "{}") }
        if let inner = o["?"] { return fieldPaths(inner, path) }
        if o.isEmpty { return [path] }
        return o.flatMap { key, value -> [String] in
            let sub = path.isEmpty ? key : path + "." + key
            if path.isEmpty && hiddenTop.contains(key) { return [] }
            if path == "advanced" && hiddenAdvanced.contains(key) { return [] }
            return fieldPaths(value, sub)
        }
    }
}

/// Things a person does with a button rather than a value, run exactly as the button does.
public enum AssistantCommands {
    public struct Command {
        public let name: String, help: String
        /// The app command; "%@" is replaced with the argument.
        public let action: String
        public let argument: String?
        public let usesAI: Bool
    }
    public static let all: [Command] = [
        Command(name: "auto_tone", help: "Automatic exposure, contrast, highlights, shadows, whites, blacks and vibrance.", action: "autoTone", argument: nil, usesAI: false),
        Command(name: "previous_settings", help: "Apply the settings of the photo edited before this one.", action: "previousSettings", argument: nil, usesAI: false),
        Command(name: "reset", help: "Reset every edit (one undo step).", action: "reset", argument: nil, usesAI: false),
        Command(name: "undo", help: "Undo the last change.", action: "undo", argument: nil, usesAI: false),
        Command(name: "redo", help: "Redo.", action: "redo", argument: nil, usesAI: false),
        Command(name: "rotate", help: "Rotate a quarter turn.", action: "rotate", argument: nil, usesAI: false),
        Command(name: "flip", help: "Mirror horizontally.", action: "flip", argument: nil, usesAI: false),
        Command(name: "reset_crop", help: "Remove the crop and straighten.", action: "resetCrop", argument: nil, usesAI: false),
        Command(name: "reset_white_balance", help: "White balance back to as shot.", action: "resetWhiteBalance", argument: nil, usesAI: false),
        Command(name: "match_lens_profile", help: "Pick the lens profile from the photo's metadata and turn on lens corrections.", action: "matchLens", argument: nil, usesAI: false),
        Command(name: "auto_straighten", help: "Level the photo from its lines.", action: "autoStraighten", argument: nil, usesAI: false),
        Command(name: "level_horizon", help: "Find the horizon on this Mac and level it.", action: "horizon", argument: nil, usesAI: false),
        Command(name: "upright", help: "Perspective correction like Lightroom's Upright.", action: "upright:%@", argument: "auto | level | vertical | full | off", usesAI: false),
        Command(name: "reset_transform", help: "Remove Transform and Upright.", action: "resetTransform", argument: nil, usesAI: false),
        Command(name: "remove_lut", help: "Remove the applied LUT.", action: "removeLUT", argument: nil, usesAI: false),
        Command(name: "apply_sky", help: "Replace the sky (finds it on this Mac the first time). Sky ids from list_skies.", action: "sky:%@", argument: "sky id", usesAI: true),
        Command(name: "remove_sky", help: "Remove the replaced sky.", action: "removeSky", argument: nil, usesAI: false),
        Command(name: "flip_sky", help: "Mirror the replacement sky.", action: "skyFlip", argument: nil, usesAI: false),
        Command(name: "lens_blur_depth", help: "Make the depth map Lens Blur uses: camera (the photo's own depth), ai (estimated on this Mac), subject (keep the subject sharp), remove.", action: "lensBlur:%@", argument: "camera | ai | subject | remove", usesAI: true),
        Command(name: "ai_denoise", help: "On-device AI noise removal (a new base image; the edit stays adjustable).", action: "ai:denoise", argument: nil, usesAI: true),
        Command(name: "ai_raw_denoise", help: "On-device AI noise removal on the RAW data (RAW photos).", action: "ai:rawdenoise", argument: nil, usesAI: true),
        Command(name: "ai_detail", help: "On-device AI detail restoration.", action: "ai:detail", argument: nil, usesAI: true),
        Command(name: "ai_upscale", help: "On-device AI super resolution (2×).", action: "ai:upscale", argument: nil, usesAI: true),
        Command(name: "ai_erase", help: "On-device AI object removal inside advanced.masks[\"Erase\"] (paint or place that selection first with edit).", action: "ai:erase", argument: nil, usesAI: true),
        Command(name: "snapshot", help: "Save the current edit as a named snapshot.", action: "", argument: "name", usesAI: false),
        Command(name: "restore_snapshot", help: "Go back to a snapshot (ids from get_edits' snapshots).", action: "snapshot:restore:%@", argument: "snapshot id", usesAI: false),
    ]
    public static func named(_ name: String) -> Command? { all.first { $0.name == name } }
}
