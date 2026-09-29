import AppKit
import OpenStillCore

/// TEMPORARY diagnostics for CI: drives the Presets & LUTs browser, captures the windows, then quits.
enum LayoutDump {
    static func runIfRequested(window: NSWindow?) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["OPENSTILL_LAYOUT_DUMP"] else { return }
        let steps = (env["OPENSTILL_DUMP_ACTIONS"] ?? "").split(separator: ";").map(String.init)
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6 + Double(i) * 1.5) {
                guard let viewer = window?.contentViewController as? ViewerController else { return }
                run(step, viewer: viewer, window: window)
                print("STEP \(step)"); fflush(stdout)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12 + Double(steps.count) * 1.5) {
            guard let window else { exit(2) }
            if let browser = browser() { print("LOOKS " + browser.harnessSummary()); fflush(stdout) }
            let others = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.frame.width > 120 && $0.frame.height > 80 }
            for (suffix, target) in [("", window)] + others.enumerated().map({ ("-other\($0.offset)", $0.element) }) {
                let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", String(target.windowNumber), path + suffix + "-capture.png"]
                try? capture.run(); capture.waitUntilExit()
            }
            exit(0)
        }
    }
    private static func browser() -> LookBrowserView? {
        var found: LookBrowserView?
        func find(_ v: NSView) { if found == nil, let b = v as? LookBrowserView { found = b }; v.subviews.forEach(find) }
        for w in NSApp.windows { if let root = w.contentView { find(root) } }
        return found
    }
    private static func run(_ step: String, viewer: ViewerController, window: NSWindow?) {
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "develop": viewer.showEditor()
        case "panel": viewer.toggleFloatingPanel(arg)
        case "skymask":
            // CI has no on-device AI: stand in for its sky selection with the upper part of the frame, softly edged.
            let size = viewer.editSourceSize(), w = Int(size.width), h = Int(size.height), fraction = Double(arg) ?? 0.47
            let gradient = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: CGFloat(Double(h) * (1 - fraction) - Double(h) * 0.01)), "inputPoint1": CIVector(x: 0, y: CGFloat(Double(h) * (1 - fraction) + Double(h) * 0.01)),
                                                                          "inputColor0": CIColor.black, "inputColor1": CIColor.white])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            if let cg = CIContext().createCGImage(gradient, from: gradient.extent), let url = try? EditStorage.newAsset() {
                try? PhotoEditor.write(cg, to: url)
                var mask = AdjustmentMask(kind: "object"); mask.asset = url.lastPathComponent; mask.feather = 0
                var edits = viewer.currentEdits; edits.setMask(mask, for: PhotoEdits.skyMaskKey)
                viewer.changeEdits(edits, title: "Test sky selection", commit: true)
            }
        case "size":
            let s = arg.split(separator: "x").compactMap { Double($0) }
            for w in NSApp.windows where w.title == "Presets & LUTs" { w.setContentSize(NSSize(width: s[0], height: s[1])) }
        case "looks":
            let started = Date()
            browser()?.harness(arg)
            print("LOOKS \(arg) took \(String(format: "%.1f", Date().timeIntervalSince(started) * 1000)) ms"); fflush(stdout)
        default: print("unknown step \(step)")
        }
    }
}
