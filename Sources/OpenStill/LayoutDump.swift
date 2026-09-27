import AppKit
import OpenStillCore

/// TEMPORARY diagnostics for CI: dumps the window's views and a snapshot, then quits.
enum LayoutDump {
    static func runIfRequested(window: NSWindow?) {
        guard let path = ProcessInfo.processInfo.environment["OPENSTILL_LAYOUT_DUMP"] else { return }
        if ProcessInfo.processInfo.environment["OPENSTILL_DUMP_MODULE"] == "library" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { (window?.contentViewController as? ViewerController)?.showLibrary() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard let window, let root = window.contentView else { exit(2) }
            var out = "window \(window.frame) appearance \(window.effectiveAppearance.name.rawValue)\n"
            func walk(_ v: NSView, _ depth: Int) {
                let f = v.convert(v.bounds, to: nil)
                let bg = v.layer?.backgroundColor.map { "\($0)" } ?? "-"
                out += String(repeating: "  ", count: depth) + "\(type(of: v)) frame=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) hidden=\(v.isHidden) alpha=\(v.alphaValue) layer=\(v.wantsLayer) bg=\(bg.prefix(60))\n"
                if depth < 9 { for s in v.subviews { walk(s, depth + 1) } }
            }
            walk(root, 0)
            let h = root.bounds.height, w = root.bounds.width
            for (name, p) in [("center", NSPoint(x: w/2, y: h/2)), ("top", NSPoint(x: w/2, y: h - 40)), ("left", NSPoint(x: 120, y: h/2)), ("right", NSPoint(x: w - 120, y: h/2)), ("bottom", NSPoint(x: w/2, y: 60))] {
                out += "hit \(name) \(p): \(root.hitTest(p).map { "\(type(of: $0))" } ?? "nil")\n"
            }
            try? out.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
            if let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".png"))
            }
            exit(0)
        }
    }
}
