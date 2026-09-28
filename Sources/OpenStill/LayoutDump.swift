import AppKit
import OpenStillCore

/// TEMPORARY diagnostics for CI: opens a screen, captures the window, then quits.
enum LayoutDump {
    static func runIfRequested(window: NSWindow?) {
        guard let path = ProcessInfo.processInfo.environment["OPENSTILL_LAYOUT_DUMP"] else { return }
        let env = ProcessInfo.processInfo.environment
        if env["OPENSTILL_DUMP_MODULE"] == "library" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { (window?.contentViewController as? ViewerController)?.showLibrary() }
        }
        if let open = env["OPENSTILL_DUMP_OPEN"] {
            let titles = Set(open.split(separator: ",").map(String.init))
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard let root = window?.contentView else { return }
                window?.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 1500), display: true)
                var sections: [LRSection] = []
                func find(_ v: NSView) { if let s = v as? LRSection { sections.append(s) }; v.subviews.forEach(find) }
                find(root)
                if !titles.isEmpty { LightroomState.shared.update { panels in for s in sections where s.side == .right { panels.expanded[s.key] = titles.contains(s.title) } } }
                for s in sections { s.refresh() }
                root.layoutSubtreeIfNeeded()
                if let target = sections.last(where: { titles.contains($0.title) && $0.side == .right }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { target.scrollToVisible(target.bounds) }
                }
                print("SECTIONS " + sections.filter { $0.side == .right }.map { "\($0.title)\($0.isOpen ? "*" : "")" }.joined(separator: ", ")); fflush(stdout)
            }
        }
        // "folders" rereads the Folders panel; "import:<mode>" opens the import window in that mode.
        if let steps = env["OPENSTILL_DUMP_ACTIONS"], !steps.isEmpty {
            for (i, step) in steps.split(separator: ";").map(String.init).enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 8 + Double(i) * 1.5) {
                    guard let viewer = window?.contentViewController as? ViewerController else { return }
                    if step == "folders" {
                        for child in Mirror(reflecting: viewer).children where child.label == "librarySidebar" { (child.value as? LibrarySidebar)?.reloadFolders() }
                    } else if step.hasPrefix("import:") {
                        viewer.importPhotos()
                        let wanted = String(step.dropFirst(7))
                        guard let importWindow = NSApp.windows.first(where: { $0.title == "Import Photos" }) else { return }
                        importWindow.setFrame(NSRect(x: 40, y: 40, width: 1000, height: 680), display: true)
                        func walk(_ v: NSView) {
                            if let modes = v as? NSSegmentedControl, modes.segmentCount == 3, modes.label(forSegment: 0) == "Copy" {
                                modes.selectedSegment = ["copy", "move", "add"].firstIndex(of: wanted) ?? 0; _ = modes.sendAction(modes.action, to: modes.target)
                            }
                            v.subviews.forEach(walk)
                        }
                        if let root = importWindow.contentView { walk(root) }
                    } else if step.hasPrefix("tool:") { viewer.info.showLightroomTool(String(step.dropFirst(5))) }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 16) {
            let target = NSApp.windows.first(where: { $0.title == "Import Photos" && $0.isVisible }) ?? window
            guard let target, let root = target.contentView else { exit(2) }
            func visible(_ v: NSView) -> Bool { var x: NSView? = v; while let c = x { if c.isHidden { return false }; x = c.superview }; return true }
            func list(_ v: NSView) {
                if visible(v), let b = v as? LRListRow { print("ROW \(path) \(b.title) x=\(Int(b.convert(b.bounds, to: nil).minX))") }
                if visible(v), let field = v as? NSTextField, target.title == "Import Photos", !field.stringValue.isEmpty { print("TEXT \(path) “\(field.stringValue.prefix(90))”") }
                v.subviews.forEach(list)
            }
            list(root); fflush(stdout)
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(target.windowNumber), path + "-capture.png"]
            try? capture.run(); capture.waitUntilExit()
            if let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".png"))
            }
            exit(0)
        }
    }
}
