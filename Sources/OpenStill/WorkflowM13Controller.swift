import AppKit
import OpenStillCore

/// Workflow tools: Edit In, Smart Previews, catalog backup and export, the second display, Auto Sync, adaptive presets, Book and the identity plate.
extension ViewerController {
    /// The photos a command works on: the library selection, or the photo being developed.
    private func chosenItems() -> [ShootItem] {
        if isLibrary { return libraryBrowser?.selectedItems ?? [] }
        guard let url = currentSource, let record = photoRecord else { return [] }
        return [ShootItem(url: url, record: record, captured: .distantPast)]
    }

    // MARK: Edit In
    @objc func editInApp() {
        let settings = EditIn.load()
        if settings.appPath == nil { editInOtherApp(); return }
        editIn(settings)
    }
    @objc func editInOtherApp() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose the app to edit photos in, such as Photoshop or Affinity Photo. OpenStill sends it a 16-bit TIFF with your edits."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let app = panel.url else { return }
            var settings = EditIn.load(); settings.appPath = app.path; try? EditIn.save(settings)
            self?.editIn(settings)
        }
    }
    private func editIn(_ settings: EditInSettings) {
        guard let item = chosenItems().first else { info.status("Select a photo to edit in another app."); return }
        let appName = settings.appPath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? "the default app"
        info.status("Preparing a copy for \(appName)…", busy: true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try EditIn.prepare(item, settings: settings) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let url):
                    self.addMergedPhoto(url)
                    let open = NSWorkspace.OpenConfiguration()
                    if let app = settings.appPath { NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: app), configuration: open) { _, error in if let error { DispatchQueue.main.async { self.info.status(error.localizedDescription) } } } }
                    else { NSWorkspace.shared.open(url) }
                    self.info.status("Opened \(url.lastPathComponent) in \(appName). It's stacked with the original; save it there and it updates here.")
                case .failure(let error): self.info.status(error.localizedDescription)
                }
            }
        }
    }

    // MARK: Smart Previews
    @objc func buildSmartPreviews() {
        let items = chosenItems().filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard !items.isEmpty else { info.status("Select photos whose originals are connected."); return }
        info.status("Building \(items.count) Smart Preview\(items.count == 1 ? "" : "s")…", busy: true)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var built = 0, failed = 0
            for item in items { do { try autoreleasepool { _ = try SmartPreviews.build(item.url, record: item.record) }; built += 1 } catch { failed += 1 } }
            let size = ByteCountFormatter.string(fromByteCount: SmartPreviews.diskUsage(), countStyle: .file)
            DispatchQueue.main.async { self?.info.status("Built \(built) Smart Preview\(built == 1 ? "" : "s")" + (failed > 0 ? " · \(failed) failed" : "") + ". They use \(size). Photos with one can be edited while their drive is disconnected.") }
        }
    }
    @objc func discardSmartPreviews() {
        let items = chosenItems(); guard !items.isEmpty else { return }
        items.forEach { SmartPreviews.remove($0.record) }
        info.status("Discarded Smart Previews for \(items.count) photo\(items.count == 1 ? "" : "s").")
    }

    // MARK: Catalog
    @objc func backUpCatalogNow() {
        info.status("Backing up the catalog…", busy: true)
        let settings = CatalogBackup.load()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try CatalogBackup.run(into: settings.folder, keep: settings.keep) }
            DispatchQueue.main.async {
                switch result {
                case .success(let url): var s = settings; s.last = Date(); try? CatalogBackup.save(s); self?.info.status("Backed up to \(url.lastPathComponent)."); NSWorkspace.shared.activateFileViewerSelecting([url])
                case .failure(let error): self?.info.status("Backup failed: " + error.localizedDescription)
                }
            }
        }
    }
    /// Called when the app quits: backs up when the schedule says it's time.
    func backupIfDue() {
        var settings = CatalogBackup.load()
        guard CatalogBackup.isDue(settings) else { return }
        if (try? CatalogBackup.run(into: settings.folder, keep: settings.keep)) != nil { settings.last = Date(); try? CatalogBackup.save(settings) }
    }
    @objc func catalogSettings() {
        guard let window = view.window else { return }
        var settings = CatalogBackup.load()
        let alert = NSAlert(); alert.messageText = "Catalog Settings"
        alert.informativeText = "Catalog: \(EditStorage.root.path)\nBackups: \((settings.folder ?? CatalogBackup.defaultFolder()).path)" + (settings.last.map { "\nLast backup: " + DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "")
        let frequency = NSPopUpButton(); frequency.addItems(withTitles: BackupFrequency.allCases.map(\.title)); frequency.selectItem(at: BackupFrequency.allCases.firstIndex(of: settings.frequency) ?? 0)
        let keep = NSTextField(string: "\(settings.keep)"); keep.widthAnchor.constraint(equalToConstant: 50).isActive = true
        let keepRow = NSStackView(views: [NSTextField(labelWithString: "Keep"), keep, NSTextField(labelWithString: "backups")]); keepRow.spacing = 6
        let move = NSButton(checkboxWithTitle: "Use a different catalog folder (takes effect after relaunch)…", target: nil, action: nil)
        let stack = NSStackView(views: [NSTextField(labelWithString: "Back up the catalog:"), frequency, keepRow, move]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 120); alert.accessoryView = stack
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            settings.frequency = BackupFrequency.allCases[max(0, frequency.indexOfSelectedItem)]; settings.keep = max(1, min(100, Int(keep.stringValue) ?? 5))
            try? CatalogBackup.save(settings)
            if move.state == .on { self?.chooseCatalogFolder() }
        }
    }
    private func chooseCatalogFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "Choose a folder for the catalog. An empty folder starts a new catalog; a folder with an OpenStill catalog opens it."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        CatalogLocation.choose(folder)
        let alert = NSAlert(); alert.messageText = "Relaunch OpenStill to use this catalog"; alert.informativeText = folder.path; alert.runModal()
    }
    @objc func exportAsCatalog() {
        let items = isLibrary ? (libraryBrowser?.selectedItems ?? []) : chosenItems()
        guard !items.isEmpty, let window = view.window else { info.status("Select the photos to export as a catalog."); return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Exported Photos." + CatalogExport.fileExtension
        let originals = NSButton(checkboxWithTitle: "Include the original photos", target: nil, action: nil); panel.accessoryView = originals
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.info.status("Exporting \(items.count) photos as a catalog…", busy: true)
            let include = originals.state == .on
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try CatalogExport.export(items, to: url, includeOriginals: include) }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let r): self?.info.status("Exported \(r.exported) photo\(r.exported == 1 ? "" : "s")" + (r.failed.isEmpty ? "." : " · \(r.failed.count) failed: " + r.failed.prefix(2).joined(separator: "; "))); NSWorkspace.shared.activateFileViewerSelecting([url])
                    case .failure(let error): self?.info.status(error.localizedDescription)
                    }
                }
            }
        }
    }
    @objc func importCatalog() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose an exported OpenStill catalog (.\(CatalogExport.fileExtension))."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            let result = CatalogExport.importCatalog(folder)
            self?.info.status("Imported \(result.imported.count) photo\(result.imported.count == 1 ? "" : "s")" + (result.failed.isEmpty ? "." : " · \(result.failed.count) couldn’t be imported (open their originals first)."))
        }
    }

    // MARK: Second display
    @objc func toggleSecondaryDisplay() {
        if let window = secondaryWindow { window.close(); secondaryWindow = nil; return }
        let window = SecondaryDisplayWindow(); secondaryWindow = window
        window.closed = { [weak self] in self?.secondaryWindow = nil }
        window.showWindow(nil); updateSecondaryDisplay()
    }
    func updateSecondaryDisplay() {
        guard let window = secondaryWindow else { return }
        if isLibrary { window.show(libraryBrowser?.selectedItems ?? []); return }
        guard urls.indices.contains(selected), let item = try? ShootItem.read(urls[selected]) else { return }
        window.show([item])
    }

    // MARK: Auto Sync
    @objc func toggleAutoSync() {
        autoSync.toggle()
        info.status(autoSync ? "Auto Sync on: changes to this photo also go to the other photos selected in the filmstrip." : "Auto Sync off.")
    }
    /// Copies just the settings that changed to the other photos selected in the filmstrip.
    func autoSyncChange(from before: PhotoEdits, to after: PhotoEdits, title: String) {
        let others = collection.selectionIndexPaths.map(\.item).filter { $0 != selected && urls.indices.contains($0) }.map { urls[$0] }
        guard !others.isEmpty, !AutoSync.changedGroups(from: before, to: after).isEmpty else { return }
        var synced = 0
        for url in others {
            guard let record = try? EditStorage.record(url) else { continue }
            _ = try? EditStorage.records.update(record.id) { r in
                var document = r.active.document
                let next = AutoSync.apply(from: before, to: after, onto: document.current)
                guard next != document.current else { return }
                document.commit(next, title: "Auto Sync · " + title); r.updateDocument(document); synced += 1
            }
        }
        if synced > 0 { info.status("Auto Sync: \(title) on \(synced) more photo\(synced == 1 ? "" : "s").") }
    }

    // MARK: Adaptive presets
    @objc func applyAdaptivePreset(_ sender: NSMenuItem) {
        guard AdaptivePresets.all.indices.contains(sender.tag) else { return }
        let preset = AdaptivePresets.all[sender.tag]
        guard !isLibrary, let original = renderedPhoto?.image, let source = currentSource, !aiPreparing, !localAI.isRunning else { info.status("Open a photo in Develop to apply an adaptive preset."); return }
        let edits = currentEdits
        if preset.target == .sky {
            guard LocalAI.ready else { info.status("Sky presets use on-device AI. Choose Set up on-device AI first."); return }
            do {
                let input = try EditStorage.newAsset(), output = try EditStorage.newAsset()
                try PhotoEditor.write(try aiBaseImage(edits, original: original, maximum: 3072), to: input)
                info.status("Finding the sky with on-device AI…", busy: true)
                localAI.run(tool: "skymask", arguments: ["--input", input.path, "--output", output.path], status: { [weak self] text in self?.info.status(text, busy: true) }) { [weak self] result in
                    try? FileManager.default.removeItem(at: input)
                    guard let self, self.currentSource == source else { return }
                    switch result {
                    case .success: self.changeEdits(AdaptivePresets.apply(preset, to: self.currentEdits, maskAsset: output.lastPathComponent), title: preset.name, commit: true); self.info.status("\(preset.name) applied to the sky.")
                    case .failure(let error): try? FileManager.default.removeItem(at: output); self.info.status(error.localizedDescription)
                    }
                }
            } catch { info.status(error.localizedDescription) }
            return
        }
        aiPreparing = true; info.status("Finding the subject on this Mac…", busy: true)
        editQueue.async { [weak self] in
            let result = Result { () -> String in
                guard let self else { throw EditError.render }
                return try self.saveMask(AIMasks.subject(try self.aiBaseImage(edits, original: original)))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.aiPreparing = false
                guard self.currentSource == source else { return }
                switch result {
                case .success(let asset): self.changeEdits(AdaptivePresets.apply(preset, to: self.currentEdits, maskAsset: asset), title: preset.name, commit: true); self.info.status("\(preset.name) applied. Its masks are in each tool's Masking tab.")
                case .failure(let error): self.info.status(error.localizedDescription)
                }
            }
        }
    }

    // MARK: Book and identity plate
    @objc func showBookModule() {
        guard !urls.isEmpty || !shootCatalog.isEmpty else { info.status("Open a folder of photos first."); NSSound.beep(); return }
        withLibrary { $0.openModule(.book) }
    }
    @objc func editIdentityPlate() {
        guard let window = view.window else { return }
        let alert = NSAlert(); alert.messageText = "Identity Plate"
        alert.informativeText = "Your name or studio in the top-left of the Lightroom layout, or a logo image. Leave it empty for “OpenStill”."
        let text = NSTextField(string: UserDefaults.standard.string(forKey: IdentityPlate.textKey) ?? ""); text.placeholderString = "OpenStill"
        text.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        // Logos made or imported in the logo designer (Export → Watermark) can be used here too.
        let logos = Watermarks.library(), saved = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        saved.addItem(withTitle: logos.isEmpty ? "No saved logos yet" : "Saved logo…"); saved.addItems(withTitles: logos.map(\.name)); saved.isEnabled = !logos.isEmpty
        saved.setAccessibilityLabel("Saved logo for the identity plate")
        let accessory = NSStackView(views: [text, saved]); accessory.orientation = .vertical; accessory.alignment = .leading; accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 300, height: 58); alert.accessoryView = accessory
        alert.addButton(withTitle: "Use Text"); alert.addButton(withTitle: "Choose Logo…"); alert.addButton(withTitle: "Use Saved Logo"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                UserDefaults.standard.set(text.stringValue, forKey: IdentityPlate.textKey); UserDefaults.standard.removeObject(forKey: IdentityPlate.imageKey)
                self.identityPlate.refresh()
            case .alertSecondButtonReturn:
                let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .tiff, .pdf]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                // Keep a private copy so the logo survives the original moving.
                let copy = EditStorage.root.appendingPathComponent("IdentityPlate." + url.pathExtension)
                try? FileManager.default.createDirectory(at: EditStorage.root, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: copy); try? FileManager.default.copyItem(at: url, to: copy)
                UserDefaults.standard.set(copy.path, forKey: IdentityPlate.imageKey); self.identityPlate.refresh()
            case .alertThirdButtonReturn:
                guard saved.indexOfSelectedItem > 0, logos.indices.contains(saved.indexOfSelectedItem - 1) else { return }
                let logo = logos[saved.indexOfSelectedItem - 1]
                do {
                    let image = try logo.design.map { try LogoRenderer.vector($0).raster(maximum: 600) } ?? ModernRenderer.display(Watermarks.image(EditStorage.asset(logo.asset), maximum: 600))
                    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
                    let copy = EditStorage.root.appendingPathComponent("IdentityPlate.png")
                    try FileManager.default.createDirectory(at: EditStorage.root, withIntermediateDirectories: true)
                    try png.write(to: copy, options: .atomic)
                    UserDefaults.standard.set(copy.path, forKey: IdentityPlate.imageKey); self.identityPlate.refresh()
                } catch { NSSound.beep() }
            default: break
            }
        }
    }
}
