import AppKit
import OpenStillCore

/// TEMPORARY diagnostics for CI: dumps the window's views and a snapshot, then quits.
enum LayoutDump {
    static func runIfRequested(window: NSWindow?) {
        guard let path = ProcessInfo.processInfo.environment["OPENSTILL_LAYOUT_DUMP"] else { return }
        if ProcessInfo.processInfo.environment["OPENSTILL_DUMP_MODULE"] == "library" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { (window?.contentViewController as? ViewerController)?.showLibrary() }
            // Library view mode and filter bar, after the grid has read its photos.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                guard let viewer = window?.contentViewController as? ViewerController, let browser = viewer.libraryBrowser else { return }
                browser.selectAllPhotos()
                if ProcessInfo.processInfo.environment["OPENSTILL_DUMP_FILTERBAR"] != nil { browser.toggleFilterBar() }
                switch ProcessInfo.processInfo.environment["OPENSTILL_DUMP_VIEW"] {
                case "loupe": browser.setViewMode(.loupe)
                case "compare": browser.setViewMode(.compare)
                case "survey": browser.setViewMode(.survey)
                default: break
                }
            }
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
        // Develop actions, one every half second: "tool:masking", "new:radial", "return", "escape", "command:<name>".
        if let steps = ProcessInfo.processInfo.environment["OPENSTILL_DUMP_ACTIONS"], !steps.isEmpty {
            for (i, step) in steps.split(separator: ";").map(String.init).enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 9 + Double(i) * 0.8) {
                    guard let viewer = window?.contentViewController as? ViewerController else { return }
                    if step.hasPrefix("tool:") { let id = String(step.dropFirst(5)); viewer.info.showLightroomTool(id); if id == "crop" { viewer.editingCommand("crop") } }
                    else if step.hasPrefix("new:") { viewer.editingCommand("maskLayer:new:" + step.dropFirst(4)) }
                    else if step == "return" { viewer.finishToolAndClose() }
                    else if step == "escape" { viewer.canvas.escape?() }
                    else if step.hasPrefix("command:") { viewer.editingCommand(String(step.dropFirst(8))) }
                    else if step.hasPrefix("luminar:") { viewer.info.openTool(String(step.dropFirst(8))) }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
            guard let window, let root = window.contentView else { exit(2) }
            var out = "window \(window.frame) appearance \(window.effectiveAppearance.name.rawValue)\n"
            func walk(_ v: NSView, _ depth: Int) {
                let f = v.convert(v.bounds, to: nil)
                let bg = v.layer?.backgroundColor.map { "\($0)" } ?? "-"
                out += String(repeating: "  ", count: depth) + "\(type(of: v)) frame=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) hidden=\(v.isHidden) alpha=\(v.alphaValue) layer=\(v.wantsLayer) bg=\(bg.prefix(60))\n"
                if depth < 9 { for s in v.subviews { walk(s, depth + 1) } }
            }
            walk(root, 0)
            if let viewer = window.contentViewController as? ViewerController {
                var bodies: [NSView] = [], headers: [NSButton] = []
                for child in Mirror(reflecting: viewer.info).children {
                    if child.label == "toolBodies" { bodies = child.value as? [NSView] ?? [] }
                    if child.label == "headers" { headers = child.value as? [NSButton] ?? [] }
                }
                let open = zip(headers, bodies).filter { !$0.1.isHidden }.map { $0.0.title }
                let masking = viewer.info.lightroomToolOpen ?? "none"
                print("STATE \(path): open tools \(open), lightroom drawer \(masking), canvas tool \(viewer.canvas.tool), layers \(viewer.currentEdits.localAdjustments.map(\.name))"); fflush(stdout)
            }
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
