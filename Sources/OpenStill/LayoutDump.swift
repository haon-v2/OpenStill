import AppKit
import OpenStillCore

/// TEMPORARY diagnostics for CI: checks which way the Temp and Tint tracks and the photo go, then quits.
enum LayoutDump {
    static func runIfRequested(window: NSWindow?) {
        guard let path = ProcessInfo.processInfo.environment["OPENSTILL_LAYOUT_DUMP"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            guard let viewer = window?.contentViewController as? ViewerController, let root = window?.contentView else { exit(2) }
            viewer.showEditor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                for title in ["Temp", "Tint"] {
                    guard let slider = find(title, in: root) else { print("WB no slider \(title)"); continue }
                    print("WB \(title) track left=\(sample(slider, left: true)) right=\(sample(slider, left: false)) value=\(slider.doubleValue) range=\(slider.minValue)…\(slider.maxValue)")
                    crop(slider, to: path + "-\(title)")
                }
                let mode = ProcessInfo.processInfo.environment["OPENSTILL_WB_MODE"] ?? "plain"
                if mode == "legacy" {
                    // An edit saved before the white balance fix: Temp already moved, direction not yet corrected.
                    var e = viewer.currentEdits; e.temperature = 7500; e.usesCorrectedWhiteBalance = false
                    viewer.currentEdits = e; viewer.info.update(e, document: viewer.editDocument, enabled: true); viewer.renderEdits()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    print("WB [\(mode)] photo before \(mean(viewer.canvas.image)) temp=\(viewer.currentEdits.temperature) corrected=\(viewer.currentEdits.usesCorrectedWhiteBalance)"); fflush(stdout)
                    if mode == "ticks" { tickDrag(viewer, root, path: path) }
                    else { step(viewer, root, [("Temp", 9500), ("Temp", 3500), ("Temp", 6500), ("Tint", 80), ("Tint", -80), ("Tint", 0)], path: path) }
                }
            }
        }
    }
    private static func step(_ viewer: ViewerController, _ root: NSView, _ moves: [(String, Double)], path: String) {
        guard let (title, value) = moves.first else {
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(root.window!.windowNumber), path + "-capture.png"]
            try? capture.run(); capture.waitUntilExit(); exit(0)
        }
        find(title, in: root)?.changed?(value, true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            print("WB photo after \(title)=\(value): \(mean(viewer.canvas.image)) usesCorrected=\(viewer.currentEdits.usesCorrectedWhiteBalance)"); fflush(stdout)
            step(viewer, root, Array(moves.dropFirst()), path: path)
        }
    }
    /// A drag as the slider reports it: values while the mouse moves (final false), then the release, which repeats
    /// the last value (final true). Starts from a photo that has never had its white balance changed.
    private static func tickDrag(_ viewer: ViewerController, _ root: NSView, path: String) {
        guard let slider = find("Temp", in: root) else { exit(3) }
        let fresh = PhotoEdits()
        viewer.currentEdits = fresh; viewer.info.update(fresh, document: viewer.editDocument, enabled: true); viewer.renderEdits()
        func drag(_ values: [Double], then: @escaping () -> Void) {
            for (i, v) in values.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(i) * 0.1) { slider.doubleValue = v; slider.changed?(v, false) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(values.count) * 0.1) {
                print("WB [ticks] while dragging to \(Int(values.last!)): \(mean(viewer.canvas.image)) corrected=\(viewer.currentEdits.usesCorrectedWhiteBalance)"); fflush(stdout)
                slider.changed?(values.last!, true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    print("WB [ticks] after release at \(Int(values.last!)): \(mean(viewer.canvas.image)) corrected=\(viewer.currentEdits.usesCorrectedWhiteBalance) saved=\(viewer.editDocument.current.usesCorrectedWhiteBalance)"); fflush(stdout)
                    then()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            print("WB [ticks] fresh photo: \(mean(viewer.canvas.image)) temp=\(viewer.currentEdits.temperature) corrected=\(viewer.currentEdits.usesCorrectedWhiteBalance)"); fflush(stdout)
            drag(stride(from: 6700.0, through: 9500, by: 400).map { $0 } + [9500]) {
                drag(stride(from: 9100.0, through: 3500, by: -400).map { $0 } + [3500]) { step(viewer, root, [], path: path) }
            }
        }
    }
    private static func find(_ title: String, in root: NSView) -> ContinuousSlider? {
        var found: ContinuousSlider?
        func walk(_ v: NSView) { if found == nil, let s = v as? ContinuousSlider, s.accessibilityLabel() == title, !s.isHiddenOrHasHiddenAncestor { found = s }; v.subviews.forEach(walk) }
        walk(root); return found
    }
    private static func sample(_ view: NSView, left: Bool) -> String {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "?" }
        view.cacheDisplay(in: view.bounds, to: rep)
        let x = left ? 3 : rep.pixelsWide - 4
        var best = "?", bestSat = -1.0
        for y in 0..<rep.pixelsHigh {   // the most colorful pixel in that column is the track
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let sat = max(c.redComponent, c.greenComponent, c.blueComponent) - min(c.redComponent, c.greenComponent, c.blueComponent)
            if sat > bestSat { bestSat = sat; best = String(format: "r%.2f g%.2f b%.2f", c.redComponent, c.greenComponent, c.blueComponent) }
        }
        return best
    }
    private static func crop(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + "-capture.png"))
    }
    private static func mean(_ image: CGImage?) -> String {
        guard let image, let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "no image" }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self); var s = [0.0, 0, 0]
        for i in 0..<1024 { for c in 0..<3 { s[c] += Double(p[i*4+c]) } }
        return String(format: "R %.1f G %.1f B %.1f", s[0]/1024, s[1]/1024, s[2]/1024)
    }
}
