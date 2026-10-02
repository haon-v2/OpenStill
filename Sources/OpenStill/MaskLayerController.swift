import AppKit
import OpenStillCore

/// Mask layers, finishing and closing tools with Return, and moving library photos to the Trash.
extension ViewerController {
    // MARK: Return and Escape
    /// Return anywhere in Develop: finish the tool (apply a crop, end mask painting, stop red eye) and close its panel.
    override func keyDown(with event: NSEvent) {
        if !isLibrary, Shortcuts.command(for: event, in: .editor) == "editor.done", view.window?.attachedSheet == nil { finishToolAndClose(); return }
        if !isLibrary, Shortcuts.command(for: event, in: .editor) == "editor.escape", tool != .adjust {
            finishMaskEditing(); canvas.clearTool(); closeTool(); return
        }
        super.keyDown(with: event)
    }
    /// Return or Done: finishes the tool (applies the crop, ends mask painting) and goes back to Adjust.
    func finishToolAndClose() {
        guard !isLibrary else { return }
        let open = tool != .adjust
        let active = canvas.tool != .browse
        switch canvas.tool {
        case .crop: finishCrop()
        case .browse: break
        default: finishMaskEditing(); canvas.clearTool()
        }
        guard open || active else { return }
        closeTool()
        info.status("Done. Edits are saved on this Mac.")
    }
    /// Leaves the current tool for Adjust without applying anything more.
    func closeTool() {
        if canvas.tool == .crop { finishCrop() }
        if canvas.tool == .eyeFix || canvas.tool == .whiteBalance || canvas.tool == .targeted { canvas.clearTool() }
        guard tool != .adjust else { return }
        tool = .adjust
        info.showToolPanel(nil)
        updateStudioBars()
    }

    /// Applies a drawn crop; with no frame drawn (or the whole photo) it just leaves Crop.
    func finishCrop() {
        if let rect = canvas.cropSelection, rect.width > 0.01, rect.height > 0.01, rect.width < 0.999 || rect.height < 0.999 { editingCommand("applyCrop") }
        if canvas.tool == .crop { canvas.clearTool() }
    }

    // MARK: Mask layers
    func maskLayerCommand(_ name: String) {
        let parts = name.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, currentSource != nil, renderedPhoto != nil else { return }
        switch parts[1] {
        case "new": newMaskLayer(kind: parts[2])
        case "select":
            guard let id = UUID(uuidString: parts[2]), let layer = currentEdits.localAdjustments.first(where: { $0.id == id }) else { return }
            info.selectMaskLayer(id)
            maskCommand("mask:\(layer.maskKey):componentChanged")
        default:
            guard let id = UUID(uuidString: parts[2]), let layer = currentEdits.localAdjustments.first(where: { $0.id == id }) else { return }
            var edits = currentEdits
            switch parts[1] {
            case "duplicate":
                guard let copy = edits.duplicateLocalAdjustment(id) else { return }
                changeEdits(edits, title: "Duplicate " + layer.name, commit: true); info.selectMaskLayer(copy.id)
            case "invert": maskCommand("mask:\(layer.maskKey):invert")
            case "show": maskCommand("mask:\(layer.maskKey):show")
            case "delete":
                finishMaskEditing(); edits.removeLocalAdjustment(id)
                changeEdits(edits, title: "Delete " + layer.name, commit: true)
            default: break
            }
        }
    }
    /// A new mask layer, then straight into selecting its area.
    private func newMaskLayer(kind: String) {
        let title = MaskLayersPanel.kinds.first { $0.1 == kind }?.0.replacingOccurrences(of: "Select ", with: "") ?? "Mask"
        var edits = currentEdits
        let count = edits.localAdjustments.filter { $0.name.hasPrefix(title) }.count
        let layer = edits.addLocalAdjustment(named: count == 0 ? title : "\(title) \(count + 1)")
        let key = layer.maskKey
        var component: MaskComponent?
        if kind == "colorRange" || kind == "luminanceRange" {
            var selection = AdjustmentMask(kind: kind); selection.range = RangeSelection(); selection.feather = 0
            var root = AdjustmentMask(kind: "stack"); root.components = []
            let c = MaskComponent(name: title, selection: selection); root.updateComponent(c); edits.setMask(root, for: key); component = c
        }
        finishMaskEditing()
        changeEdits(edits, title: "New mask · " + layer.name, commit: true)
        info.selectMaskLayer(layer.id)
        if let component { info.selectMaskComponent(key: key, id: component.id); maskCommand("mask:\(key):sampleRange"); return }
        maskCommand("mask:\(key):\(kind)")
    }

    // MARK: Library: Delete moves the selected photos to the Trash
    func trashLibraryPhotos(_ items: [ShootItem]) {
        guard !items.isEmpty, let window = view.window, window.attachedSheet == nil else { return }
        // Virtual copies are removed from the library, never trashed (they share the original's file).
        if removeVirtualCopies(items.map(\.url)) { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = items.count == 1 ? "Move “\(items[0].url.lastPathComponent)” to Trash?" : "Move \(items.count) photos to Trash?"
        alert.informativeText = "The original files move to your Mac’s Trash, where you can recover them. Sidecar and paired files stay in place."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Move to Trash")
        alert.buttons[0].keyEquivalent = "\u{1b}"; alert.buttons[1].keyEquivalent = "\r"; alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn else { return }
            let urls = items.map(\.url)
            DispatchQueue.global(qos: .userInitiated).async {
                var moved: [URL] = [], failed = 0
                // The system Trash only; never a permanent delete.
                for url in urls { if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { moved.append(url) } else { failed += 1 } }
                DispatchQueue.main.async {
                    self.removeCopies(ofTrashed: moved)
                    let gone = Set(moved)
                    self.urls.removeAll { gone.contains($0) }; self.shootCatalog.removeAll { gone.contains($0) }; self.libraryURLs = []
                    self.selected = min(self.selected, max(0, self.urls.count - 1))
                    self.collection.reloadData(); self.refreshLibrary(); self.updateControls()
                    self.info.status("Moved \(moved.count) photo\(moved.count == 1 ? "" : "s") to Trash" + (failed > 0 ? " · \(failed) couldn’t be moved" : "."))
                }
            }
        }
    }
}
