import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

@Suite struct AssistantEditTests {
    /// Every field the AI can see is explained: its own entry or its section's names it.
    @Test func everyFieldIsInTheReference() {
        let entries = AssistantEdits.reference
        var missing: [String] = []
        for path in AssistantEdits.fieldPaths() {
            let key = path.split(separator: ".").last.map { String($0).replacingOccurrences(of: "[]", with: "").replacingOccurrences(of: "{}", with: "") } ?? path
            // The entry for the path or its nearest documented ancestor must mention the field by name.
            var candidate = path.replacingOccurrences(of: "[]", with: "").replacingOccurrences(of: "{}", with: "")
            var documented = false
            while true {
                if let entry = entries.first(where: { $0.0 == candidate }) { documented = entry.0 == candidate && (candidate.hasSuffix(key) || entry.1.contains(key)); break }
                guard let dot = candidate.lastIndex(of: ".") else { break }
                candidate = String(candidate[..<dot])
            }
            if !documented { missing.append(path) }
        }
        #expect(missing.isEmpty, "Add these to AssistantEdits.reference: \(missing.sorted().joined(separator: ", "))")
        #expect(AssistantEdits.referenceText.count > 3000)
    }
    @Test func theDocumentShowsEverySectionAndHidesInternals() throws {
        guard case .object(let root) = try AssistantEdits.view(PhotoEdits()), case .object(let advanced)? = root["advanced"] else { Issue.record("no document"); return }
        for section in ["glow", "grain", "pointColors", "colorGrading", "curves", "detail", "lens", "transform", "calibration", "masks", "localAdjustments", "retouch"] {
            #expect(advanced[section] != nil, "\(section)")
        }
        #expect(root["schemaVersion"] == nil && root["baseAsset"] == nil && advanced["toneModel"] == nil && advanced["lutAsset"] == nil)
        #expect(root["highlights"] == .number(0) && root["shadows"] == .number(0))
    }
    @Test func glowGrainAndPointColorAreSetAndRendered() throws {
        let patch = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"advanced": {"glow": {"amount": 60, "mode": "orton"}, "grain": {"amount": 0.5},
                      "pointColors": [{"hue": 0.6, "saturation": 0.6, "lightness": 0.5, "hueShift": 0, "saturationShift": -1, "lightnessShift": 0.5, "range": 0.8}],
                      "colorGrading": {"highlights": {"hue": 40, "saturation": 0.4}}},
         "highlights": -0.5, "exposure": 0.3}
        """.utf8))
        let result = try AssistantEdits.apply(patch, to: PhotoEdits())
        let e = result.edits
        #expect(e.advanced?.glow?.amount == 60 && e.advanced?.glow?.mode == .orton && e.advanced?.grain?.amount == 0.5)
        #expect(e.pointColors.count == 1 && e.pointColors[0].saturationShift == -1)
        #expect(e.colorGrading.highlights.hue == 40 && abs(e.colorGrading.highlights.saturation - 0.4) < 1e-9 && e.colorGrading.shadows.saturation == 0)
        #expect(e.highlightsAmount == -0.5 && e.exposure == 0.3)
        #expect(result.changed.contains { $0.hasPrefix("advanced.glow.amount") } && result.adjusted.isEmpty)
        // Sections the patch didn't touch stay unset, so the saved edit is no bigger than it needs to be.
        #expect(e.advanced?.lens == nil && e.advanced?.lensBlur == nil && e.advanced?.detail == nil && e.advanced?.defringe == nil)
        // And it renders differently from the unedited photo.
        let image = CIImage(color: CIColor(red: 0.3, green: 0.5, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 48, height: 48))
        let cg = try #require(CIContext().createCGImage(image, from: image.extent))
        let plain = try PhotoEditor.render(cg, edits: PhotoEdits()), edited = try PhotoEditor.render(cg, edits: e)
        #expect(pixels(plain) != pixels(edited))
    }
    @Test func patchesMergeRemoveReplaceAndReportLimits() throws {
        func patch(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
        var e = try AssistantEdits.apply(patch(#"{"advanced": {"glow": {"amount": 40}}}"#), to: PhotoEdits()).edits
        e = try AssistantEdits.apply(patch(#"{"advanced": {"glow": {"softness": 80}}}"#), to: e).edits          // merges
        #expect(e.advanced?.glow?.amount == 40 && e.advanced?.glow?.softness == 80)
        e = try AssistantEdits.apply(patch(#"{"advanced": {"glow": null}}"#), to: e).edits                       // null removes
        #expect(e.advanced?.glow == nil)
        let limited = try AssistantEdits.apply(patch(#"{"exposure": 9, "advanced": {"grain": {"amount": 3}}}"#), to: e)
        #expect(limited.edits.exposure == 4 && limited.adjusted.contains { $0.hasPrefix("exposure") } && limited.adjusted.contains { $0.hasPrefix("advanced.grain.amount") })
        #expect(throws: (any Error).self) { try AssistantEdits.apply(patch(#"{"advanced": {"glowz": {"amount": 1}}}"#), to: e) }        // unknown key
        #expect(throws: (any Error).self) { try AssistantEdits.apply(patch(#"{"advanced": {"toneModel": "regions"}}"#), to: e) }       // kept by OpenStill
        #expect(throws: (any Error).self) { try AssistantEdits.apply(patch(#"{"advanced": {"glow": {"amount": "lots"}}}"#), to: e) }  // wrong type
        #expect(throws: (any Error).self) {                                                                                           // invented file
            try AssistantEdits.apply(patch(#"{"advanced": {"masks": {"Erase": {"kind": "object", "asset": "../../secret.png"}}}}"#), to: e)
        }
        // A brush selection can be painted by value, and a layer's sliders set, in one step.
        let layer = LocalAdjustment(name: "Car")
        let painted = try AssistantEdits.apply(patch("""
        {"advanced": {"localAdjustments": [{"id": "\(layer.id.uuidString)", "name": "Car", "hidden": false,
                                             "settings": {"exposure": 0.4, "temperature": 0.3, "tint": 0.2, "contrast": 0, "highlights": 0, "shadows": 0, "whites": 0, "blacks": 0,
                                                          "saturation": 0, "clarity": 0, "texture": 0, "dehaze": 0, "sharpness": 0, "noise": 0}}],
                      "masks": {"\(layer.maskKey)": {"kind": "brush", "strokes": [{"points": [{"x": 0.4, "y": 0.4}, {"x": 0.6, "y": 0.4}], "radius": 0.05}]}}}}
        """), to: e).edits
        #expect(painted.localAdjustments.first?.settings.tint == 0.2 && painted.advanced?.masks[layer.maskKey]?.strokes.first?.points.count == 2)
    }
    @Test func commandsAreUniqueAndComplete() {
        #expect(Set(AssistantCommands.all.map(\.name)).count == AssistantCommands.all.count)
        #expect(AssistantCommands.all.allSatisfy { !$0.help.isEmpty && ($0.action.isEmpty == ($0.name == "snapshot")) && ($0.action.contains("%@") == ($0.argument != nil) || $0.name == "snapshot") })
    }
    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4 * 16)
        let ctx = CGContext(data: &data, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        return data
    }
}
