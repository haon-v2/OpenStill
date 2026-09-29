import AppKit
import OpenStillCore

/// TEMPORARY diagnostics for CI: runs a few steps in the Studio window, captures it, then quits.
enum LayoutDump {
    static func runIfRequested(window: NSWindow?) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["OPENSTILL_LAYOUT_DUMP"] else { return }
        let steps = (env["OPENSTILL_DUMP_ACTIONS"] ?? "").split(separator: ";").map(String.init)
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6 + Double(i) * 1.2) {
                guard let viewer = window?.contentViewController as? ViewerController else { return }
                run(step, viewer: viewer, window: window)
                print("STEP \(step) → tool=\(viewer.tool.rawValue) library=\(viewer.isLibrary)"); fflush(stdout)
            }
        }
        let extra = steps.contains { $0.hasPrefix("keys") || $0.hasPrefix("drag") } ? 7.0 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 8 + Double(steps.count) * 1.2 + extra) {
            guard let window, let root = window.contentView else { exit(2) }
            let panel = NSApp.windows.first { $0 is NSPanel && $0.isVisible }
            func visible(_ v: NSView) -> Bool { var x: NSView? = v; while let c = x { if c.isHidden { return false }; x = c.superview }; return true }
            func list(_ v: NSView) {
                if visible(v), v.frame.width > 0, v is ToolOptionsBar || v is ToolRail || v is StudioStatusBar || v is PhotoTabStrip {
                    print("VIEW \(type(of: v)) \(NSStringFromRect(v.convert(v.bounds, to: nil)))")
                }
                v.subviews.forEach(list)
            }
            list(root); fflush(stdout)
            for (suffix, target) in [("", Optional(window)), ("-panel", panel)] {
                guard let target else { continue }
                let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", String(target.windowNumber), path + suffix + "-capture.png"]
                try? capture.run(); capture.waitUntilExit()
            }
            exit(0)
        }
    }

    private static func run(_ step: String, viewer: ViewerController, window: NSWindow?) {
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "size": let w = CGFloat(Double(arg) ?? 1240); window?.setFrame(NSRect(x: 0, y: 0, width: w, height: 820), display: true)
        case "tool": if let t = StudioTool(rawValue: arg) { viewer.selectTool(t) }
        case "library": viewer.showLibrary()
        case "develop": viewer.showEditor()
        case "libtab": viewer.libraryTabs.selected = Int(arg) ?? 0; viewer.libraryTabs.changed?(Int(arg) ?? 0)
        case "view": viewer.withLibrary { $0.setViewMode(arg == "compare" ? .compare : arg == "loupe" ? .loupe : arg == "survey" ? .survey : .grid) }
        case "selectall": viewer.withLibrary { $0.selectAllPhotos() }
        case "filmstrip": viewer.toggleFilmstripPanel()
        case "panel": viewer.toggleFloatingPanel(arg)
        case "command": viewer.editingCommand(arg); viewer.updateStudioBars()
        case "key": _ = viewer.handleWorkspaceKey(arg)
        case "keys":
            // Real key events through the window, so the monitor and responder chain are exercised.
            for (i, k) in arg.split(separator: ",").map(String.init).enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.4) {
                    let shift = k.hasPrefix("^"), name = shift ? String(k.dropFirst()) : k
                    let (chars, code): (String, UInt16) = switch name {
                    case "return": ("\r", 36)
                    case "esc": ("\u{1b}", 53)
                    case "tab": ("\t", 48)
                    default: (name, [ "g": 5, "d": 2, "r": 15, "q": 12, "w": 13, "a": 0, "l": 37, "t": 17, "e": 14 ][name] ?? 0)
                    }
                    let flags: NSEvent.ModifierFlags = shift ? [.shift] : []
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil, characters: shift ? chars.uppercased() : chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                            NSApp.sendEvent(e)
                        }
                    }
                    print("KEY \(k) → tool=\(viewer.tool.rawValue) library=\(viewer.isLibrary) optionsBarHidden=\(viewer.studio.optionsBarHidden) panelHidden=\(viewer.studio.panelHidden)"); fflush(stdout)
                }
            }
        case "status": viewer.info.status("Rendering preview…", busy: true)
        case "drag": drag(slider: arg, viewer: viewer, window: window)
        case "zoom": viewer.canvas.native = true
        default: print("unknown step \(step)")
        }
    }

    /// Drags a Develop slider with real mouse events over about 1.5 s and counts the frames the canvas shows meanwhile.
    private static func drag(slider title: String, viewer: ViewerController, window: NSWindow?) {
        guard let window, let root = window.contentView else { return }
        var found: NSSlider?
        func find(_ v: NSView) { if found == nil, let s = v as? NSSlider, s.accessibilityLabel() == title, !s.isHiddenOrHasHiddenAncestor, s.isEnabled { found = s }; v.subviews.forEach(find) }
        find(root)
        guard let slider = found else { print("DRAG no slider \(title)"); fflush(stdout); return }
        slider.scrollToVisible(slider.bounds)
        let knobStart = slider.convert(CGPoint(x: slider.bounds.width * CGFloat((slider.doubleValue - slider.minValue) / (slider.maxValue - slider.minValue)), y: slider.bounds.midY), to: nil)
        let number = window.windowNumber
        var frames = Set<ObjectIdentifier>(), last = viewer.canvas.image.map(ObjectIdentifier.init)
        let sampler = Timer(timeInterval: 0.008, repeats: true) { _ in
            if let image = viewer.canvas.image { let id = ObjectIdentifier(image); if id != last { frames.insert(id); last = id } }
        }
        RunLoop.main.add(sampler, forMode: .common)
        let start = Date()
        func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: knobStart.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        // The slider's tracking loop reads queued events, so the drag is posted from another thread while it runs.
        DispatchQueue.global().async {
            for i in 1...45 {
                Thread.sleep(forTimeInterval: 0.033)
                let x = knobStart.x + CGFloat(i) * 2.2 * (i % 2 == 0 ? 1 : 1)
                if let e = event(.leftMouseDragged, x) { NSApp.postEvent(e, atStart: false) }
            }
            Thread.sleep(forTimeInterval: 0.05)
            if let e = event(.leftMouseUp, knobStart.x + 99) { NSApp.postEvent(e, atStart: false) }
        }
        if let down = event(.leftMouseDown, knobStart.x) { NSApp.sendEvent(down) }
        let during = frames.count
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            sampler.invalidate()
            print("DRAG \(title): \(during) frames shown while dragging for \(String(format: "%.2f", Date().timeIntervalSince(start))) s; value now \(String(format: "%.2f", slider.doubleValue))"); fflush(stdout)
        }
    }
}
