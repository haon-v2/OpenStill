import AppKit
import CoreImage
import OpenStillCore

/// The Studio window: tool rail, tool options bar, the photo, one resizable panel, the status line,
/// photo tabs in the toolbar and floating panels for Presets, History, Info and the Navigator.
extension ViewerController {
    // MARK: Setup
    func setupStudio() {
        rail.choose = { [weak self] id in self?.railChosen(id) }
        resizeEdge.dragged = { [weak self] dx in
            guard let self else { return }
            self.studio.panelWidth = StudioLayout.clamp(self.studio.panelWidth + Double(dx))
            self.panelWidth?.constant = CGFloat(self.studio.panelWidth)
        }
        resizeEdge.finished = { [weak self] in self?.studio.save() }
        libraryTabs.selected = studio.libraryTab
        libraryTabs.changed = { [weak self] index in guard let self else { return }; self.studio.libraryTab = index; self.studio.save(); self.layoutStudio() }
        libraryTabs.setAccessibilityLabel("Library panel")
        libraryTabsBar.addSubview(libraryTabs)
        NSLayoutConstraint.activate([libraryTabs.centerXAnchor.constraint(equalTo: libraryTabsBar.centerXAnchor), libraryTabs.centerYAnchor.constraint(equalTo: libraryTabsBar.centerYAnchor)])
        tabStrip.choose = { [weak self] path in self?.openTab(path) }
        tabStrip.close = { [weak self] path in self?.closeTab(path) }
        tabStrip.closeOthers = { [weak self] path in
            guard let self else { return }
            for other in self.photoTabs.paths where other != path { self.photoTabs.close(other) }
            self.saveTabs(); self.openTab(path)
        }
        photoTabs = OpenPhotoTabs.load(root: EditStorage.root)
        photoTabs.prune { FileManager.default.fileExists(atPath: $0) }
        tabStrip.show(photoTabs)
        info.statusChanged = { [weak self] text, busy in self?.statusBar.show(text, busy: busy) }
        canvas.backdrop = Studio.canvas
        canvas.viewportChanged = { [weak self] in self?.navigatorView?.needsDisplay = true; self?.updateStudioInfo(); self?.viewportSettled() }
        librarySidebar.publish = { [weak self] in self?.withLibrary { $0.openPublish() } }
        info.showModule(.develop)
        Shortcuts.workspace = { [weak self] id in self?.handleWorkspaceKey(id) ?? false }
        // Workspace keys (G, D, R, Q, L, T, Tab…) work wherever focus is in this window, except while typing in a text field.
        if workspaceKeyMonitor == nil {
            workspaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.view.window, event.window === window, window.attachedSheet == nil,
                      !(window.firstResponder is NSText) else { return event }
                return Shortcuts.performWorkspace(event) ? nil : event
            }
        }
        layoutStudio()
    }

    // MARK: Arrangement
    /// Places the bars and panels, leaving out the ones that are hidden. Hidden bars take no space, so the photo grows.
    func layoutStudio() {
        NSLayoutConstraint.deactivate(studioConstraints)
        let content = workspaceContent
        let showRail = !studio.railHidden, showPanel = !studio.panelHidden, showOptions = !studio.optionsBarHidden, showFilm = studio.filmstripShown
        rail.isHidden = !showRail; optionsBar.isHidden = !showOptions
        rightPanel.isHidden = !showPanel; resizeEdge.isHidden = !showPanel; shelf.isHidden = !showFilm
        canvas.isHidden = isLibrary; canvas.photoBackdrop.isHidden = isLibrary; libraryHost.isHidden = !isLibrary
        // The right panel: Develop's adjustments, or the Library's Folders · Collections · Info.
        let tab = studio.libraryTab
        libraryTabsBar.isHidden = !isLibrary
        librarySidebar.isHidden = !(isLibrary && tab < 2)
        info.isHidden = isLibrary && tab < 2
        if isLibrary, tab < 2 { librarySidebar.page = tab }
        libraryTabs.selected = tab
        modeSwitch.selected = isLibrary ? 0 : 1
        let width = rightPanel.widthAnchor.constraint(equalToConstant: showPanel ? CGFloat(studio.panelWidth) : 0)
        panelWidth = width
        studioConstraints = [
            optionsBar.topAnchor.constraint(equalTo: content.topAnchor), optionsBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            optionsBar.trailingAnchor.constraint(equalTo: content.trailingAnchor), optionsBar.heightAnchor.constraint(equalToConstant: showOptions ? Studio.optionsBarHeight : 0),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor), statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor), statusBar.heightAnchor.constraint(equalToConstant: Studio.statusBarHeight),
            shelf.bottomAnchor.constraint(equalTo: statusBar.topAnchor), shelf.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            shelf.trailingAnchor.constraint(equalTo: content.trailingAnchor), shelf.heightAnchor.constraint(equalToConstant: showFilm ? Studio.filmstripHeight : 0),
            rail.leadingAnchor.constraint(equalTo: content.leadingAnchor), rail.topAnchor.constraint(equalTo: optionsBar.bottomAnchor),
            rail.bottomAnchor.constraint(equalTo: shelf.topAnchor), rail.widthAnchor.constraint(equalToConstant: showRail ? Studio.railWidth : 0),
            rightPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor), rightPanel.topAnchor.constraint(equalTo: optionsBar.bottomAnchor),
            rightPanel.bottomAnchor.constraint(equalTo: shelf.topAnchor), width,
            resizeEdge.trailingAnchor.constraint(equalTo: rightPanel.leadingAnchor), resizeEdge.topAnchor.constraint(equalTo: rightPanel.topAnchor),
            resizeEdge.bottomAnchor.constraint(equalTo: rightPanel.bottomAnchor), resizeEdge.widthAnchor.constraint(equalToConstant: showPanel ? 8 : 0),
            center.leadingAnchor.constraint(equalTo: rail.trailingAnchor), center.trailingAnchor.constraint(equalTo: resizeEdge.leadingAnchor, constant: showPanel ? 7 : 0),
            center.topAnchor.constraint(equalTo: optionsBar.bottomAnchor), center.bottomAnchor.constraint(equalTo: shelf.topAnchor),
            libraryTabsBar.topAnchor.constraint(equalTo: rightPanel.topAnchor), libraryTabsBar.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor),
            libraryTabsBar.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor), libraryTabsBar.heightAnchor.constraint(equalToConstant: isLibrary ? Studio.optionsBarHeight : 0),
            info.topAnchor.constraint(equalTo: libraryTabsBar.bottomAnchor), info.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor),
            info.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor), info.bottomAnchor.constraint(equalTo: rightPanel.bottomAnchor),
            librarySidebar.topAnchor.constraint(equalTo: libraryTabsBar.bottomAnchor), librarySidebar.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor),
            librarySidebar.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor), librarySidebar.bottomAnchor.constraint(equalTo: rightPanel.bottomAnchor),
        ]
        NSLayoutConstraint.activate(studioConstraints)
        applyLights()
        updateStudioBars()
    }

    /// Lights Out (L): dims the bars and panels, then turns them off, leaving the photo.
    func applyLights() {
        let opacity = CGFloat(lights.chromeOpacity)
        for v in [rail, optionsBar, rightPanel, resizeEdge, shelf, statusBar] as [NSView] { v.alphaValue = opacity }
        canvas.backdrop = [Studio.canvas, NSColor(calibratedWhite: 0.04, alpha: 1), .black][lights.rawValue]
        workspaceContent.color = lights == .normal ? Studio.chrome : .black
    }

    // MARK: Tools
    /// Develop's rail: the tools, then Before / After and Clipping at the bottom. The Library's: its views and the Painter.
    private var railItems: (top: [ToolRail.Item], bottom: [ToolRail.Item]) {
        func key(_ id: String?) -> String { id.flatMap { Shortcuts.map.combo(for: $0)?.display }.map { " (\($0))" } ?? "" }
        if isLibrary {
            return ([ToolRail.Item(id: "lib.grid", symbol: "square.grid.2x2", label: "Grid" + key("workspace.grid")),
                     ToolRail.Item(id: "lib.loupe", symbol: "photo", label: "Loupe" + key("library.loupe")),
                     ToolRail.Item(id: "lib.compare", symbol: "rectangle.split.2x1", label: "Compare" + key("library.compare")),
                     ToolRail.Item(id: "lib.survey", symbol: "square.grid.3x2", label: "Survey" + key("library.survey")),
                     ToolRail.Item(id: "lib.painter", symbol: "paintbrush.pointed", label: "Painter" + key("workspace.painter"))],
                    [ToolRail.Item(id: "lib.people", symbol: "person.2", label: "People"),
                     ToolRail.Item(id: "lib.map", symbol: "map", label: "Map"),
                     ToolRail.Item(id: "lib.timeline", symbol: "calendar", label: "Timeline")])
        }
        let tools = StudioTool.allCases.map { ToolRail.Item(id: $0.rawValue, symbol: $0.symbol, label: $0.title + key($0.shortcutID)) }
        return (tools, [ToolRail.Item(id: "view.split", symbol: "rectangle.lefthalf.inset.filled", label: "Before / After" + key("editor.split")),
                        ToolRail.Item(id: "view.clipping", symbol: "exclamationmark.triangle", label: "Clipping" + key("editor.clipping"))])
    }
    private func railChosen(_ id: String) {
        if let t = StudioTool(rawValue: id) { selectTool(t); return }
        switch id {
        case "view.split": editingCommand("compareSplit")
        case "view.clipping": editingCommand("toggleClipping")
        case "lib.grid": libraryBrowser?.setViewMode(.grid)
        case "lib.loupe": libraryBrowser?.setViewMode(.loupe)
        case "lib.compare": libraryBrowser?.setViewMode(.compare)
        case "lib.survey": libraryBrowser?.setViewMode(.survey)
        case "lib.painter": libraryBrowser?.togglePainter()
        case "lib.people": withLibrary { $0.showPeople() }
        case "lib.map": chooseModule(.map)
        case "lib.timeline": withLibrary { $0.showTimeline() }
        default: break
        }
        updateStudioBars()
    }
    /// Picks a Develop tool. Picking the open tool again closes it (back to Adjust); Return or Done does the same.
    func selectTool(_ next: StudioTool) {
        if isLibrary { if next == .adjust { return }; showEditor() }
        if next != .adjust, next == tool { finishToolAndClose(); return }
        if next.needsPhoto, renderedPhoto == nil { info.status("Open a photo first."); NSSound.beep(); return }
        leave(tool)
        tool = next
        if studio.panelHidden, next == .masking { studio.panelHidden = false; studio.save(); layoutStudio() }
        info.showToolPanel(next == .masking ? "masking" : nil)
        switch next {
        case .adjust: break
        case .crop: editingCommand("crop")
        case .remove: editingCommand("retouchPaint")
        case .redEye: editingCommand(eyeKind == .petEye ? "eye:petEye" : "eye:redEye")
        case .masking: if let id = currentEdits.localAdjustments.last?.id, info.selectedMaskLayer == nil { editingCommand("maskLayer:select:\(id.uuidString)") }
        case .whiteBalance: editingCommand("whiteBalance")
        case .targeted: editingCommand("tat:" + (pendingTarget ?? "curve"))
        }
        updateStudioBars()
        view.window?.makeFirstResponder(canvas)
    }
    /// Leaving a tool: a drawn crop is applied (as Lightroom's Done does); anything half-done on the photo stops.
    private func leave(_ previous: StudioTool) {
        switch previous {
        case .adjust: break
        case .crop: if canvas.tool == .crop { finishCrop() }
        case .masking: finishMaskEditing()
        case .remove, .redEye, .whiteBalance, .targeted: if canvas.tool != .browse { canvas.clearTool() }
        }
    }
    func studioCommand(_ name: String) { editingCommand(name); updateStudioBars() }

    // MARK: Bars
    /// Refreshes the rail, the options bar, the status line and the tabs after anything changes.
    func updateStudioBars() {
        // White balance and targeted adjustment end on the photo; follow them back to Adjust.
        if !isLibrary, tool == .whiteBalance, canvas.tool != .whiteBalance { tool = .adjust }
        let items = railItems
        if rail.mode != (isLibrary ? 1 : 2) { rail.setItems(top: items.top, bottom: items.bottom); rail.mode = isLibrary ? 1 : 2 }
        if isLibrary {
            let mode = libraryBrowser?.viewMode ?? .grid
            rail.show(selected: ["lib.grid", "lib.loupe", "lib.compare", "lib.survey"][mode.rawValue], on: libraryBrowser?.painterOn == true ? ["lib.painter"] : [])
        } else {
            var on = Set<String>()
            if splitCompare { on.insert("view.split") }; if showClipping { on.insert("view.clipping") }
            rail.show(selected: tool.rawValue, on: on)
            rail.setEnabled(renderedPhoto != nil, for: Set(StudioTool.allCases.filter(\.needsPhoto).map(\.rawValue) + ["view.split", "view.clipping"]))
        }
        showOptions()
        statusBar.setHint(isLibrary ? ShootWindow.hintText() : tool.hint)
        updateStudioInfo()
        updateTabs()
        if let panel = studioPanels["info"], panel.isVisible { floatingInfo.show(metadata, rendering: renderedPhoto?.description) }
    }
    /// Zoom, size and file on the status line's left.
    func updateStudioInfo() {
        if isLibrary {
            let shown = libraryBrowser?.visibleURLs.count ?? 0, chosen = libraryBrowser?.selectedItems.count ?? 0
            let source = openCollection?.name ?? folderURL?.lastPathComponent ?? "No folder open"
            statusBar.setInfo("\(source)  ·  \(shown) photo\(shown == 1 ? "" : "s")" + (chosen > 0 ? "  ·  \(chosen) selected" : ""))
            return
        }
        guard !urls.isEmpty, urls.indices.contains(selected) else { statusBar.setInfo("Ready when you are"); return }
        var parts = [canvas.image == nil ? "—" : (canvas.isFit ? "Fit" : "\(canvas.zoomPercent)%")]
        if let m = metadata, m.dimensions.contains("×") { parts.append(m.dimensions + " px") }
        parts.append(urls[selected].lastPathComponent)
        if let r = photoRecord, r.rating > 0 { parts.append(String(repeating: "★", count: r.rating)) }
        parts.append("\(selected + 1) of \(urls.count)")
        statusBar.setInfo(parts.joined(separator: "  ·  "))
    }

    /// The tool options bar: the current tool's settings, or the Library's views and filters.
    private func showOptions() {
        let enabled = renderedPhoto != nil
        // Rebuild only when what the bar shows changes; otherwise refresh its values (never mid-drag).
        let signature = isLibrary ? "library|\(libraryBrowser.map { ObjectIdentifier($0).hashValue } ?? 0)"
            : [tool.rawValue, "\(enabled)", "\(comparing)", "\(splitCompare)", "\(spotsVisible)", "\(maskVisible)", eyeKind == .petEye ? "pet" : "red",
               retouchSession.mode == .clone ? "clone" : "heal", "\(currentEdits.localAdjustments.count)", pendingTarget ?? ""].joined(separator: "|")
        if signature == optionsSignature {
            if NSEvent.pressedMouseButtons == 0 { optionsRefresh.forEach { $0() } }
            return
        }
        optionsSignature = signature; optionsRefresh = []
        if isLibrary {
            guard let browser = libraryBrowser else { optionsBar.show(title: "Library", controls: []); return }
            optionsBar.show(title: "Library", controls: browser.optionsControls, actions: browser.optionsActions)
            return
        }
        let done = Studio.button("Done", primary: true) { [weak self] in self?.finishToolAndClose() }
        switch tool {
        case .adjust:
            let auto = Studio.button("Auto") { [weak self] in self?.studioCommand("autoTone") }
            auto.toolTip = "Auto tone: sets exposure, contrast, highlights, shadows, whites, blacks and vibrance"
            let before = Studio.button("Before / After") { [weak self] in self?.studioCommand("compareSplit") }
            before.toolTip = "Split before and after (Y) · \\ shows the original"
            let previous = Studio.button("Previous") { [weak self] in self?.studioCommand("previousSettings") }
            previous.toolTip = "Copy the last photo's settings (not its crop, retouching, lens or transform)"
            let reset = Studio.button("Reset") { [weak self] in self?.studioCommand("reset") }
            for b in [auto, before, previous, reset] { b.isEnabled = enabled }
            before.title = splitCompare ? "Hide Before / After" : "Before / After"
            optionsBar.show(title: "Adjust", controls: [auto, before], actions: [previous, reset])
        case .crop:
            let presets = info.cropPresets
            presets.compact = true
            let angle = StudioValue("Angle", range: -20...20, value: currentEdits.straighten, reset: 0, decimals: 1, unit: "°")
            angle.changed = { [weak self] v, final in self?.editValue(\.straighten, v, final: final, title: "Straighten") }
            optionsRefresh.append { [weak self, weak angle] in if let self { angle?.value = self.currentEdits.straighten } }
            let straighten = Studio.button("Auto") { [weak self] in self?.studioCommand("autoStraighten") }
            straighten.toolTip = "Straighten from the lines in the photo"
            let horizon = Studio.button("Horizon") { [weak self] in self?.studioCommand("horizon") }
            horizon.toolTip = "Level the horizon (on-device AI)"
            let rotate = StudioIconButton(symbol: "rotate.right", label: "Rotate clockwise", side: 28) { [weak self] in self?.studioCommand("rotate"); self?.editingCommand("crop") }
            let flip = StudioIconButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", label: "Flip horizontally", side: 28) { [weak self] in self?.studioCommand("flip"); self?.editingCommand("crop") }
            let reset = Studio.button("Reset") { [weak self] in self?.studioCommand("resetCrop"); self?.editingCommand("crop") }
            let cancel = Studio.button("Cancel") { [weak self] in self?.canvas.clearTool(); self?.closeTool() }
            optionsBar.show(title: "Crop", controls: [presets, Studio.separator(), angle, straighten, horizon, rotate, flip], actions: [reset, cancel, done])
        case .remove:
            let mode = StudioSegments(["Heal", "Clone"], selected: retouchSession.mode == .clone ? 1 : 0)
            mode.changed = { [weak self] i in guard let self else { return }; var s = self.retouchSession; s.mode = i == 1 ? .clone : .heal; self.updateRetouchSettings(s) }
            let size = StudioValue("Size", range: 0.005...0.15, value: retouchSession.radius, reset: 0.025, decimals: 3, sliderWidth: 80)
            size.changed = { [weak self] v, _ in guard let self else { return }; var s = self.retouchSession; s.radius = v; self.updateRetouchSettings(s) }
            let feather = StudioValue("Feather", range: 0...1, value: retouchSession.feather, reset: 0.5, sliderWidth: 70)
            feather.changed = { [weak self] v, _ in guard let self else { return }; var s = self.retouchSession; s.feather = v; self.updateRetouchSettings(s) }
            let opacity = StudioValue("Opacity", range: 0...1, value: retouchSession.opacity, reset: 1, sliderWidth: 70)
            opacity.changed = { [weak self] v, _ in guard let self else { return }; var s = self.retouchSession; s.opacity = v; self.updateRetouchSettings(s) }
            let source = Studio.button("Source") { [weak self] in self?.studioCommand("retouchSource") }
            source.toolTip = "Pick a clean source point (or Option-click on the photo)"
            let ai = Studio.button("Remove with AI") { [weak self] in self?.studioCommand("ai:erase") }
            ai.toolTip = "Select the area with Masking first; on-device AI fills it"
            let spots = Studio.button(spotsVisible ? "Hide Spots" : "Visualize Spots") { [weak self] in self?.studioCommand("spots:toggle") }
            let undo = Studio.button("Undo Stroke") { [weak self] in self?.studioCommand("retouchRemoveLast") }
            optionsBar.show(title: "Remove", controls: [mode, size, feather, opacity, Studio.separator(), source, ai, spots], actions: [undo, done])
        case .redEye:
            let kind = StudioSegments(["Red Eye", "Pet Eye"], selected: eyeKind == .petEye ? 1 : 0)
            kind.changed = { [weak self] i in self?.studioCommand(i == 1 ? "eye:petEye" : "eye:redEye") }
            let pupil = StudioValue("Pupil", range: 0.2...1, value: currentEdits.eyePupil, reset: 0.6)
            pupil.changed = { [weak self] v, final in self?.editValue(\.eyePupil, v, final: final, title: "Pupil size") }
            optionsRefresh.append { [weak self, weak pupil] in if let self { pupil?.value = self.currentEdits.eyePupil } }
            let darken = StudioValue("Darken", range: 0...1, value: currentEdits.eyeDarken, reset: 0.6)
            darken.changed = { [weak self] v, final in self?.editValue(\.eyeDarken, v, final: final, title: "Darken") }
            optionsRefresh.append { [weak self, weak darken] in if let self { darken?.value = self.currentEdits.eyeDarken } }
            let catchlight = NSButton(checkboxWithTitle: "Catchlight", target: nil, action: nil)
            catchlight.font = Studio.controlFont; catchlight.state = currentEdits.eyeCatchlight ? .on : .off
            catchlight.target = self; catchlight.action = #selector(toggleCatchlight(_:))
            catchlight.isEnabled = eyeKind == .petEye
            let clear = Studio.button("Clear All") { [weak self] in self?.studioCommand("eye:clear") }
            let undo = Studio.button("Undo Eye") { [weak self] in self?.studioCommand("eye:removeLast") }
            optionsBar.show(title: "Red Eye", controls: [kind, pupil, darken, catchlight], actions: [clear, undo, done])
        case .masking:
            let menu = NSPopUpButton(frame: .zero, pullsDown: true)
            menu.addItem(withTitle: "New Mask")
            for (title, kind) in MaskLayersPanel.kinds {
                let item = ActionMenuItem(title) { [weak self] in self?.studioCommand("maskLayer:new:" + kind) }
                menu.menu?.addItem(item)
            }
            menu.controlSize = .small; menu.font = Studio.controlFont; menu.setAccessibilityLabel("Create a new mask"); menu.isEnabled = enabled
            let count = currentEdits.localAdjustments.count
            let note = Studio.label(count == 0 ? "No masks yet: pick one to start" : "\(count) mask\(count == 1 ? "" : "s") · pick one in the panel to edit it")
            let overlay = Studio.button(maskVisible ? "Hide Overlay" : "Show Overlay") { [weak self] in
                guard let self, let id = self.info.selectedMaskLayer else { return }
                self.studioCommand("maskLayer:show:\(id.uuidString)")
            }
            overlay.toolTip = "Show the selected mask as a red overlay (O)"
            optionsBar.show(title: "Masking", controls: [menu, note], actions: [overlay, done])
        case .whiteBalance:
            let asShot = Studio.button("As Shot") { [weak self] in self?.studioCommand("resetWhiteBalance"); self?.closeTool() }
            let cancel = Studio.button("Cancel") { [weak self] in self?.canvas.clearTool(); self?.closeTool() }
            optionsBar.show(title: "White Balance", controls: [Studio.label("Click something in the photo that should be neutral gray.")], actions: [asShot, cancel])
        case .targeted:
            let kinds = ["curve", "hue", "saturation", "luminance"]
            let choice = StudioSegments(["Tone Curve", "Hue", "Saturation", "Luminance"], selected: kinds.firstIndex(of: pendingTarget ?? "curve") ?? 0)
            choice.changed = { [weak self] i in self?.studioCommand("tat:" + kinds[i]) }
            optionsBar.show(title: "Targeted", controls: [choice, Studio.label("Drag up or down on the photo")], actions: [done])
        }
    }
    @objc private func toggleCatchlight(_ sender: NSButton) {
        var edits = currentEdits; edits.eyeCatchlight = sender.state == .on
        changeEdits(edits, title: "Pet eye catchlight", commit: true)
    }
    /// A value from the options bar: live while dragging, one undo step when let go.
    private func editValue(_ path: WritableKeyPath<PhotoEdits, Double>, _ value: Double, final: Bool, title: String) {
        var edits = currentEdits; edits[keyPath: path] = value
        changeEdits(edits, title: title, commit: final)
    }

    // MARK: Photo tabs
    /// The photo just opened in Develop gets a tab (or its tab becomes active).
    func updateTabs() {
        guard !isLibrary, urls.indices.contains(selected) else { tabStrip.show(photoTabs); return }
        let path = urls[selected].path
        let edited = currentEdits != PhotoEdits()
        if photoTabs.active != path || !photoTabs.paths.contains(path) { photoTabs.open(path, edited: edited); saveTabs() }
        else if photoTabs.edited.contains(path) != edited { photoTabs.setEdited(path, edited); saveTabs() }
        tabStrip.show(photoTabs)
    }
    private func saveTabs() { photoTabs.save(root: EditStorage.root) }
    private func openTab(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { closeTab(path); info.status("That photo has moved or was deleted."); return }
        if let index = urls.firstIndex(where: { $0.path == path }) {
            if isLibrary { showEditor() }
            select(index)
        } else {
            open([URL(fileURLWithPath: path)])
            if isLibrary { showEditor() }
        }
    }
    private func closeTab(_ path: String) {
        let wasActive = photoTabs.active == path
        let next = photoTabs.close(path); saveTabs()
        tabStrip.show(photoTabs)
        guard wasActive else { return }
        if let next { openTab(next) } else { showLibrary() }
    }

    // MARK: Panels
    @objc func togglePresetsPanel() { toggleFloatingPanel("presets") }
    @objc func toggleHistoryPanel() { toggleFloatingPanel("history") }
    @objc func toggleNavigatorPanel() { toggleFloatingPanel("navigator") }
    /// Opens or closes one of the floating panels beside the editor.
    func toggleFloatingPanel(_ id: String) {
        if let panel = studioPanels[id], panel.isVisible { panel.close(); if id == "presets" { info.setLUTPreviewsActive(false) }; return }
        let panel = studioPanels[id] ?? makePanel(id)
        studioPanels[id] = panel
        if id == "info" { floatingInfo.show(metadata, rendering: renderedPhoto?.description) }
        if id == "presets" {
            // LUT thumbnails render only while this panel is open, from the current edit.
            panel.closed = { [weak self] in self?.info.setLUTPreviewsActive(false) }
            if let photo = renderedPhoto { info.setLUTPhoto(photo.preview, edits: currentEdits, source: photo.sourceImage, url: currentSource, recipe: photoRecord?.active.recipe) }
            info.setLUTPreviewsActive(true)
        }
        panel.show(beside: view.window)
    }
    private func makePanel(_ id: String) -> StudioPanel {
        switch id {
        case "presets": return StudioPanel(name: id, title: "Presets & LUTs", content: info.presetsColumn, size: NSSize(width: 300, height: 560))
        case "history": return StudioPanel(name: id, title: "History", content: info.historyColumn, size: NSSize(width: 280, height: 520))
        case "info": return StudioPanel(name: id, title: "Info", content: floatingInfo, size: NSSize(width: 300, height: 480))
        default:
            let navigator = LRNavigator(); navigator.canvas = canvas; navigatorView = navigator
            let links = LRZoomLinks()
            links.choose = { [weak self] index in
                guard let self else { return }
                switch index { case 0: self.fitPhoto(); case 1: self.nativePhoto(); default: self.canvas.native = true; self.canvas.scale(by: 2); self.updateControls() }
            }
            let stack = NSStackView(views: [navigator, links]); stack.orientation = .vertical; stack.spacing = 8
            stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 12, right: 12)
            navigator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            return StudioPanel(name: id, title: "Navigator", content: stack, size: NSSize(width: 260, height: 230))
        }
    }

    // MARK: Show / hide
    @objc func toggleFilmstripPanel() { studio.filmstripShown.toggle(); studio.save(); layoutStudio() }
    @objc func toggleRightPanel() { studio.panelHidden.toggle(); studio.save(); layoutStudio() }
    @objc func toggleToolRail() { studio.railHidden.toggle(); studio.save(); layoutStudio() }
    @objc func toggleOptionsBar() { studio.optionsBarHidden.toggle(); studio.save(); layoutStudio() }
    @objc func showMapModule() { chooseModule(.map) }
    @objc func showSlideshowModule() { chooseModule(.slideshow) }
    @objc func showPrintModule() { chooseModule(.print) }
    @objc func showWebModule() { chooseModule(.web) }

    func chooseModule(_ module: LightroomModule) {
        switch module {
        case .library: showLibrary()
        case .develop: showEditor()
        default:
            guard !urls.isEmpty || !shootCatalog.isEmpty else { info.status("Open a folder of photos first."); NSSound.beep(); return }
            withLibrary { $0.openModule(module) }
        }
    }
    /// Runs `action` on the library once it has read its photos, creating it if needed.
    func withLibrary(attempt: Int = 0, _ action: @escaping (ShootWindow) -> Void) {
        if libraryBrowser == nil { refreshLibrary() }
        guard let browser = libraryBrowser else { return }
        if browser.visibleURLs.isEmpty, attempt < 15 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.withLibrary(attempt: attempt + 1, action) }
            return
        }
        action(browser)
    }

    // MARK: Keys
    /// The single keys that work anywhere in the window: G, D, A, R, Q, Shift-W, W, H, Shift-P, L, T, Tab, Shift-Tab, K.
    func handleWorkspaceKey(_ id: String) -> Bool {
        guard view.window?.isKeyWindow == true, view.window?.attachedSheet == nil else { return false }
        switch id {
        case "workspace.grid": if isLibrary { libraryBrowser?.setViewMode(.grid) }; showLibrary()
        case "workspace.develop": if isLibrary { showEditor() }
        case "workspace.adjust": selectTool(.adjust)
        case "workspace.crop": selectTool(.crop)
        case "workspace.remove": selectTool(.remove)
        case "workspace.masking": selectTool(.masking)
        case "workspace.whiteBalance": guard !isLibrary else { return false }; selectTool(.whiteBalance)
        case "workspace.history": guard !isLibrary else { return false }; toggleHistoryPanel()
        case "workspace.presets": guard !isLibrary else { return false }; togglePresetsPanel()
        case "workspace.painter": guard isLibrary else { return false }; libraryBrowser?.togglePainter(); updateStudioBars()
        case "workspace.lightsOut": lights = lights.next; applyLights()
        case "workspace.toolbar": toggleOptionsBar()
        case "workspace.sidePanels": studio.toggleSidePanels(); studio.save(); layoutStudio()
        case "workspace.allPanels": studio.toggleAllChrome(); studio.save(); layoutStudio()
        default: return false
        }
        return true
    }

    /// Commands from the panels' buttons (Sync, Copy / Paste settings…).
    func lightroomCommand(_ name: String) {
        switch name {
        case "lr:metadata", "lr:syncMetadata": withLibrary { $0.openMetadataEditor() }
        case "lr:syncSettings": withLibrary { $0.syncSettings() }
        case "lr:copy", "lr:paste":
            guard let url = currentSource else { info.status("Open a photo first."); return }
            withLibrary { [weak self] browser in self?.info.status(name == "lr:copy" ? browser.copySettings(from: url) : browser.pasteSettings(to: url)) }
        default: break
        }
    }

    /// The Library's Info tab follows the grid selection: its histogram (from the saved preview), keywords and metadata.
    func updateLibraryInspector() {
        guard isLibrary else { return }
        updateLibraryPanels(); updateSecondaryDisplay()
        defer { updateStudioBars() }
        guard let item = libraryBrowser?.selectedItems.first else { info.showKeywords(nil); info.show(nil); info.updateHistogram(nil, sensor: nil); return }
        info.showKeywords(item.record.metadata?.keywords ?? [])
        if let index = urls.firstIndex(of: item.url) { collection.selectSingle(index); collection.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .centeredHorizontally) }
        let token = UUID(); libraryInspectorToken = token
        let request = RenderRequest(photo: item.record, profile: .displayP3, maximumDimension: 420)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let metadata = PhotoMetadata.read(item.url)
            let histogram = PreviewCache.read(request).map { PhotoHistogram.measure(CIImage(cgImage: $0)) }
            DispatchQueue.main.async {
                guard let self, self.libraryInspectorToken == token, self.isLibrary else { return }
                self.info.show(metadata); self.info.updateHistogram(histogram, sensor: nil)
            }
        }
    }
}
