import AppKit
import OpenStillCore

/// TEMPORARY diagnostics for CI: dumps the window's views and a snapshot, then quits.
enum LayoutDump {
    static func runIfRequested(window: NSWindow?) {
        guard let path = ProcessInfo.processInfo.environment["OPENSTILL_LAYOUT_DUMP"] else { return }
        if ProcessInfo.processInfo.environment["OPENSTILL_DUMP_MODULE"] == "library" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { (window?.contentViewController as? ViewerController)?.showLibrary() }
        }
        if let open = ProcessInfo.processInfo.environment["OPENSTILL_DUMP_OPEN"] {
            let titles = Set(open.split(separator: ",").map(String.init))
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard let root = window?.contentView else { return }
                window?.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 1500), display: true)
                var sections: [LRSection] = []
                func find(_ v: NSView) { if let s = v as? LRSection { sections.append(s) }; v.subviews.forEach(find) }
                find(root)
                LightroomState.shared.update { panels in for s in sections { panels.expanded[s.key] = titles.contains(s.title) } }
                for s in sections { s.refresh() }
                root.layoutSubtreeIfNeeded()
                // Bring the last opened section on the right fully into view.
                if let target = sections.last(where: { titles.contains($0.title) && $0.side == .right }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { target.scrollToVisible(target.bounds) }
                }
                if let tool = ProcessInfo.processInfo.environment["OPENSTILL_DUMP_TOOL"] { (window?.contentViewController as? ViewerController)?.editingCommand(tool) }
                root.needsLayout = true
            }
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
