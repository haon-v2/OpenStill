import AppKit
import OpenStillCore

/// TEMPORARY for CI: drives the AI assistant's tools in the real app on the opened photo, prints each answer
/// and saves each image beside `OPENSTILL_ASSISTANT_SELFTEST`, then quits.
enum AssistantSelfTest {
    static func runIfRequested(_ viewer: ViewerController) {
        guard let prefix = ProcessInfo.processInfo.environment["OPENSTILL_ASSISTANT_SELFTEST"] else { return }
        func j(_ text: String) -> JSONValue { (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null }
        var steps: [(String, [String: JSONValue])] = [
            ("edit_reference", [:]),
            ("get_edits", [:]),
            ("edit", ["patch": j("""
            {"exposure": 0.2, "highlights": -0.4,
             "advanced": {"glow": {"amount": 55, "mode": "orton", "softness": 60}, "grain": {"amount": 0.35, "size": 0.4},
                          "pointColors": [{"hue": 0.62, "saturation": 0.6, "lightness": 0.55, "hueShift": 0.3, "saturationShift": 0.5, "lightnessShift": -0.3, "range": 0.7}],
                          "colorGrading": {"highlights": {"hue": 40, "saturation": 0.35}, "shadows": {"hue": 210, "saturation": 0.3}},
                          "curves": {"parametric": {"shadows": -0.4, "highlights": 0.3}},
                          "localAdjustments": [{"id": "6B1F3C44-2A6E-4C1B-9B7E-0D5F1B0B2A11", "name": "Warm stripe", "settings": {"temperature": 0.6, "tint": 0.4, "exposure": 0.5}}],
                          "masks": {"Mask-6B1F3C44-2A6E-4C1B-9B7E-0D5F1B0B2A11": {"kind": "brush", "feather": 0.4,
                                     "strokes": [{"points": [{"x": 0.1, "y": 0.5}, {"x": 0.9, "y": 0.5}], "radius": 0.08}]}}}}
            """)]),
            ("preview", ["compare": .bool(true), "size": .number(1200)]),
            ("preview_mask", ["layer_id": .string("Warm stripe")]),
            ("edit", ["patch": j(#"{"advanced": {"glowz": {"amount": 1}}}"#)]),
            ("edit", ["patch": j(#"{"exposure": 12}"#)]),
            ("run_command", ["name": .string("snapshot"), "argument": .string("AI look")]),
            ("run_command", ["name": .string("auto_tone")]),
            ("run_command", ["name": .string("upright"), "argument": .string("auto")]),
            ("run_command", ["name": .string("undo")]),
            ("list_presets", [:]),
            ("_open_second", [:]),
            ("list_photos", [:]),
        ]
        func next(_ index: Int) {
            guard !steps.isEmpty else { exit(0) }
            let (tool, args) = steps.removeFirst()
            if tool == "_open_second" {
                // The catalog lists photos once they've been opened: open the second sample, then come back.
                viewer.select(1)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { viewer.select(0); DispatchQueue.main.asyncAfter(deadline: .now() + 4) { next(index + 1) } }
                return
            }
            viewer.assistant(tool, args) { result in
                switch result {
                case .failure(let error): print("STEP \(index) \(tool) ERROR \(error.localizedDescription)")
                case .success(var value):
                    if case .object(var o) = value, let data = o["data"]?.string, let bytes = Data(base64Encoded: data) {
                        let file = "\(prefix)-\(index)-\(tool).jpg"
                        try? bytes.write(to: URL(fileURLWithPath: file)); o["data"] = .string("<\(bytes.count) bytes → \(file)>"); value = .object(o)
                    }
                    var text = (try? String(decoding: JSONEncoder().encode(value), as: UTF8.self)) ?? "?"
                    if text.count > 1500 { text = String(text.prefix(1500)) + "… (\(text.count) chars)" }
                    print("STEP \(index) \(tool) OK \(text)")
                    if tool == "list_photos", case .object(let o) = value, case .array(let photos)? = o["photos"] {
                        let ids = photos.compactMap { p -> String? in if case .object(let x) = p { return x["id"]?.string }; return nil }
                        if let other = ids.first(where: { $0 != viewer.photoRecord?.id.uuidString }) {
                            steps.append(("copy_edits", ["to_photo_ids": .array([.string(other)]), "sections": .array(["glow", "grain", "color", "grading"].map(JSONValue.string))]))
                            steps.append(("get_edits", ["photo_id": .string(other)]))
                        }
                    }
                }
                fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { next(index + 1) }
            }
        }
        func start(_ tries: Int) {
            if viewer.renderedPhoto != nil || tries == 0 { viewer.showEditor(); DispatchQueue.main.asyncAfter(deadline: .now() + 2) { next(1) }; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { start(tries - 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { start(60) }
    }
}
