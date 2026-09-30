import AppKit
import OpenStillCore

/// TEMPORARY for CI: drives the AI assistant's tools in the real app on the opened photo, prints each answer
/// and saves each image beside `OPENSTILL_ASSISTANT_SELFTEST`, then quits.
enum AssistantSelfTest {
    static func runIfRequested(_ viewer: ViewerController) {
        guard let prefix = ProcessInfo.processInfo.environment["OPENSTILL_ASSISTANT_SELFTEST"] else { return }
        var steps: [(String, [String: JSONValue])] = [
            ("preview", ["size": .number(800)]),
            ("add_mask_layer", ["kind": .string("radial"), "name": .string("Center"), "center": .array([.number(0.5), .number(0.5)]), "radius": .number(0.25), "values": .object(["exposure": .number(-1.5)])]),
            ("list_mask_layers", [:]),
            ("update_mask_layer", ["layer_id": .string("Center"), "center": .array([.number(0.3), .number(0.3)]), "values": .object(["saturation": .number(-1)])]),
            ("add_mask_layer", ["kind": .string("linear"), "name": .string("Top"), "from": .array([.number(0.5), .number(0)]), "to": .array([.number(0.5), .number(0.4)]), "values": .object(["exposure": .number(1)])]),
            ("add_mask_layer", ["kind": .string("subject"), "values": .object(["exposure": .number(0.7)])]),
            ("add_mask_layer", ["kind": .string("sky")]),
            ("preview_mask", ["layer_id": .string("Top")]),
            ("update_mask_layer", ["layer_id": .string("Top"), "invert": .bool(true)]),
            ("preview", ["compare": .bool(true), "size": .number(1200)]),
            ("delete_mask_layer", ["layer_id": .string("Center")]),
            ("list_mask_layers", [:]),
        ]
        func next(_ index: Int) {
            guard !steps.isEmpty else { exit(0) }
            let (tool, args) = steps.removeFirst()
            viewer.assistant(tool, args) { result in
                switch result {
                case .failure(let error): print("STEP \(index) \(tool) ERROR \(error.localizedDescription)")
                case .success(var value):
                    if case .object(var o) = value, let data = o["data"]?.string, let bytes = Data(base64Encoded: data) {
                        let file = "\(prefix)-\(index)-\(tool).jpg"
                        try? bytes.write(to: URL(fileURLWithPath: file)); o["data"] = .string("<\(bytes.count) bytes → \(file)>"); value = .object(o)
                    }
                    let text = (try? String(decoding: JSONEncoder().encode(value), as: UTF8.self)) ?? "?"
                    print("STEP \(index) \(tool) OK \(text)")
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
