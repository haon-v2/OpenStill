import AppKit
import OpenStillCore

/// TEMPORARY diagnostics for CI: runs a few steps in the Studio window, captures it, then quits.
enum LayoutDump {
    /// TEMPORARY TIMING: printed only while the harness runs.
    static let tracing = ProcessInfo.processInfo.environment["OPENSTILL_LAYOUT_DUMP"] != nil
    static func trace(_ text: @autoclosure () -> String) { if tracing { print("TRACE " + text()); fflush(stdout) } }
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
            let others = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.frame.width > 120 && $0.frame.height > 80 }
            func visible(_ v: NSView) -> Bool { var x: NSView? = v; while let c = x { if c.isHidden { return false }; x = c.superview }; return true }
            func list(_ v: NSView) {
                if visible(v), v.frame.width > 0, v is ToolOptionsBar || v is ToolRail || v is StudioStatusBar || v is PhotoTabStrip {
                    print("VIEW \(type(of: v)) \(NSStringFromRect(v.convert(v.bounds, to: nil)))")
                }
                v.subviews.forEach(list)
            }
            list(root); fflush(stdout)
            for (suffix, target) in [("", window)] + others.enumerated().map({ ("-other\($0.offset)", $0.element) }) {
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
        case "action":
            // A menu command: the viewer's own, otherwise whatever the key window's responder chain handles.
            let selector = Selector(arg)
            if !NSApp.sendAction(selector, to: viewer.responds(to: selector) ? viewer : nil, from: nil) { print("ACTION not handled \(arg)") }
        case "people": viewer.withLibrary { $0.showPeople() }
        case "timeline": viewer.withLibrary { $0.showTimeline() }
        default: print("unknown step \(step)")
        }
    }

    /// Drags a Develop slider for about 1.5 s the way the slider reports a drag (live values, then the release) and counts
    /// the frames the canvas shows meanwhile.
    private static func drag(slider title: String, viewer: ViewerController, window: NSWindow?) {
        guard let window, let root = window.contentView else { return }
        var found: ContinuousSlider?
        func find(_ v: NSView) { if found == nil, let s = v as? ContinuousSlider, s.accessibilityLabel() == title, !s.isHiddenOrHasHiddenAncestor { found = s }; v.subviews.forEach(find) }
        find(root)
        guard let slider = found else { print("DRAG no slider \(title)"); fflush(stdout); return }
        var frames = Set<ObjectIdentifier>(), last = viewer.canvas.image.map(ObjectIdentifier.init)
        let sampler = Timer(timeInterval: 0.008, repeats: true) { _ in
            if let image = viewer.canvas.image { let id = ObjectIdentifier(image); if id != last { frames.insert(id); last = id } }
        }
        RunLoop.main.add(sampler, forMode: .common)
        let start = Date(), from = slider.doubleValue, span = (slider.maxValue - slider.minValue) * 0.3
        for i in 1...45 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.033) {
                let value = from + span * Double(i) / 45
                let t = Date(); slider.doubleValue = value; slider.changed?(value, false)
                trace("tick main \(String(format: "%.1f", Date().timeIntervalSince(t)*1000)) ms")
                if i == 45 {
                    let during = frames.count
                    slider.changed?(value, true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        sampler.invalidate()
                        print("DRAG \(title): \(during) frames shown during a \(String(format: "%.2f", Date().timeIntervalSince(start))) s drag of 45 steps; \(frames.count) including the release; value now \(String(format: "%.2f", slider.doubleValue))"); fflush(stdout)
                    }
                }
            }
        }
    }
}
