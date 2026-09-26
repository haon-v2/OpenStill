import AppKit
import UniformTypeIdentifiers
import OpenStillCore

/// File → Import Photos… (⇧⌘I): copy photos from a camera card or folder into the library, verified by checksum.
/// The source is never changed or deleted.
final class ImportWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var imported: (([URL]) -> Void)?
    private var source: URL?
    private var candidates: [ImportCandidate] = []
    private var destination: URL?
    private var backup: URL?
    private var preset: (name: String, edits: PhotoEdits)?
    private var running = false, cancelled = false, generation = UUID()

    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "Choose a camera card or folder.")
    private let destinationButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let destinationLabel = NSTextField(labelWithString: "Not chosen")
    private let folders = NSComboBox()
    private let names = NSComboBox()
    private let example = NSTextField(labelWithString: "")
    private let backupCheck = NSButton(checkboxWithTitle: "Second copy to", target: nil, action: nil)
    private let backupLabel = NSTextField(labelWithString: "")
    private let skipCheck = NSButton(checkboxWithTitle: "Don’t import photos already in the library", target: nil, action: nil)
    private let metadataPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let keywords = NSTextField(string: "")
    private let developPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let ejectCheck = NSButton(checkboxWithTitle: "Eject the card when done", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private let defaults = UserDefaults.standard

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Import Photos"; window.delegate = self; window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 760, height: 520); window.center(); Appearance.configure(window)
        build(Appearance.panel(in: window))
        restore(); reloadSources()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout
    private func build(_ root: NSView) {
        sourcePopup.target = self; sourcePopup.action = #selector(sourceChanged); sourcePopup.setAccessibilityLabel("Import from")
        let rescan = NSButton(title: "Rescan", target: self, action: #selector(rescan)); rescan.bezelStyle = .rounded
        let all = NSButton(title: "Check all", target: self, action: #selector(checkAll)); all.bezelStyle = .rounded
        let none = NSButton(title: "Uncheck all", target: self, action: #selector(checkNone)); none.bezelStyle = .rounded
        let top = NSStackView(views: [NSTextField(labelWithString: "Import from"), sourcePopup, rescan, NSView(), all, none]); top.spacing = 8
        summary.font = .systemFont(ofSize: 11); summary.textColor = .secondaryLabelColor

        for (id, title, width) in [("use", "", 24.0), ("name", "File", 220), ("date", "Captured", 150), ("size", "Size", 80), ("status", "Status", 150)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.usesAlternatingRowBackgroundColors = true; table.allowsMultipleSelection = true; table.rowHeight = 20
        table.setAccessibilityLabel("Photos to import")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder

        destinationButton.target = self; destinationButton.action = #selector(chooseDestination); destinationButton.bezelStyle = .rounded
        destinationLabel.lineBreakMode = .byTruncatingMiddle
        for combo in [folders, names] { combo.target = self; combo.action = #selector(templateChanged); combo.completes = true }
        folders.addItems(withObjectValues: ImportSettings.folderTemplates.map { $0.isEmpty ? "(directly in the destination)" : $0 }); names.addItems(withObjectValues: ImportSettings.nameTemplates)
        folders.setAccessibilityLabel("Folder template"); names.setAccessibilityLabel("File name template")
        NotificationCenter.default.addObserver(self, selector: #selector(templateChanged), name: NSControl.textDidChangeNotification, object: folders)
        NotificationCenter.default.addObserver(self, selector: #selector(templateChanged), name: NSControl.textDidChangeNotification, object: names)
        example.font = .systemFont(ofSize: 11); example.textColor = .secondaryLabelColor; example.lineBreakMode = .byTruncatingMiddle
        let tokens = NSTextField(wrappingLabelWithString: "Tokens: {yyyy} {MM} {dd} {date} {time} {name} {index} {camera}")
        tokens.font = .systemFont(ofSize: 10); tokens.textColor = .tertiaryLabelColor
        backupCheck.target = self; backupCheck.action = #selector(toggleBackup); backupLabel.lineBreakMode = .byTruncatingMiddle; backupLabel.textColor = .secondaryLabelColor
        skipCheck.state = .on
        metadataPopup.setAccessibilityLabel("Metadata preset"); developPopup.setAccessibilityLabel("Develop preset")
        developPopup.target = self; developPopup.action = #selector(developChanged)
        keywords.placeholderString = "Keywords to add, comma separated"; keywords.setAccessibilityLabel("Keywords")
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1; progress.isHidden = true
        importButton.target = self; importButton.action = #selector(runImport); importButton.bezelStyle = .rounded; importButton.keyEquivalent = "\r"
        let close = NSButton(title: "Close", target: self, action: #selector(closeOrCancel)); close.bezelStyle = .rounded; close.keyEquivalent = "\u{1b}"

        let form = NSGridView(numberOfColumns: 2, rows: 0); form.rowSpacing = 7; form.columnSpacing = 8; form.column(at: 0).xPlacement = .trailing
        form.addRow(with: [NSTextField(labelWithString: "Copy to"), NSStackView(views: [destinationButton, destinationLabel])])
        form.addRow(with: [NSTextField(labelWithString: "Folders"), folders])
        form.addRow(with: [NSTextField(labelWithString: "File names"), names])
        form.addRow(with: [NSView(), example]); form.addRow(with: [NSView(), tokens])
        form.addRow(with: [NSView(), NSStackView(views: [backupCheck, backupLabel])])
        form.addRow(with: [NSView(), skipCheck])
        form.addRow(with: [NSTextField(labelWithString: "Metadata"), metadataPopup])
        form.addRow(with: [NSTextField(labelWithString: "Keywords"), keywords])
        form.addRow(with: [NSTextField(labelWithString: "Develop"), developPopup])
        form.addRow(with: [NSView(), ejectCheck])
        for view in [folders, names, keywords, metadataPopup, developPopup] { view.widthAnchor.constraint(equalToConstant: 280).isActive = true }
        destinationLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true; backupLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true
        example.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true; tokens.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let note = NSTextField(wrappingLabelWithString: "Every copy is read back and checked against the original before it counts as imported. Nothing on the card is changed or deleted.")
        note.font = .systemFont(ofSize: 10); note.textColor = .secondaryLabelColor; note.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let side = NSStackView(views: [form, note]); side.orientation = .vertical; side.alignment = .leading; side.spacing = 12

        let middle = NSStackView(views: [scroll, side]); middle.spacing = 16; middle.alignment = .top
        let buttons = NSStackView(views: [progress, close, importButton]); buttons.spacing = 8
        let stack = NSStackView(views: [top, summary, middle, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor), middle.widthAnchor.constraint(equalTo: stack.widthAnchor), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320), sourcePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            progress.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    // MARK: Settings
    private func restore() {
        destination = defaults.string(forKey: "importDestination").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first?.appendingPathComponent("OpenStill", isDirectory: true)
        backup = defaults.string(forKey: "importBackup").map { URL(fileURLWithPath: $0, isDirectory: true) }
        backupCheck.state = backup != nil && defaults.bool(forKey: "importBackupOn") ? .on : .off
        folders.stringValue = defaults.string(forKey: "importFolders") ?? ImportSettings.folderTemplates[0]
        names.stringValue = defaults.string(forKey: "importNames") ?? ImportSettings.nameTemplates[0]
        ejectCheck.state = defaults.bool(forKey: "importEject") ? .on : .off
        metadataPopup.removeAllItems(); metadataPopup.addItem(withTitle: "None")
        for p in MetadataPresets.load() { metadataPopup.addItem(withTitle: p.name); metadataPopup.lastItem?.representedObject = p.id.uuidString }
        developPopup.removeAllItems(); developPopup.addItem(withTitle: "None"); developPopup.addItem(withTitle: "Choose preset file…")
        refreshLabels()
    }
    private func refreshLabels() {
        destinationLabel.stringValue = destination.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Not chosen"
        backupLabel.stringValue = backup.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "(choose a folder)"
        templateChanged()
    }
    private var folderTemplate: String { folders.stringValue.hasPrefix("(") ? "" : folders.stringValue }
    @objc private func templateChanged() {
        let sample = candidates.first(where: \.include) ?? ImportCandidate(url: URL(fileURLWithPath: "/DCIM/IMG_0001.CR3"), size: 0, captured: Date(), sidecar: nil)
        do {
            let folder = try PhotoImport.expand(folderTemplate, candidate: sample, index: 0, camera: "Camera", folders: true)
            let name = try PhotoImport.expand(names.stringValue, candidate: sample, index: 0, camera: "Camera", folders: false)
            example.stringValue = "Example: " + (folder.isEmpty ? "" : folder + "/") + name + "." + sample.url.pathExtension
            example.textColor = .secondaryLabelColor
        } catch { example.stringValue = "The template makes an invalid name."; example.textColor = .systemRed }
    }
    @objc private func chooseDestination() { chooseFolder("Choose where imported photos are copied") { self.destination = $0; self.defaults.set($0.path, forKey: "importDestination"); self.refreshLabels() } }
    @objc private func toggleBackup() {
        if backupCheck.state == .on && backup == nil {
            chooseFolder("Choose a folder for the second copy, ideally on another drive") { self.backup = $0; self.defaults.set($0.path, forKey: "importBackup"); self.refreshLabels() }
        }
        defaults.set(backupCheck.state == .on, forKey: "importBackupOn")
    }
    @objc private func developChanged() {
        guard developPopup.indexOfSelectedItem == 1, let window else { if developPopup.indexOfSelectedItem == 0 { preset = nil }; return }
        let panel = NSOpenPanel(); panel.title = "Choose a develop preset"; panel.allowedContentTypes = [UTType(filenameExtension: "openstillpreset") ?? .json, .json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url, let edits = try? JSONDecoder().decode(PhotoEdits.self, from: Data(contentsOf: url)) else { self.developPopup.selectItem(at: self.preset == nil ? 0 : 2); return }
            let name = url.deletingPathExtension().lastPathComponent
            self.preset = (name, edits)
            while self.developPopup.numberOfItems > 2 { self.developPopup.removeItem(at: 2) }
            self.developPopup.addItem(withTitle: name); self.developPopup.selectItem(at: 2)
        }
    }
    private func chooseFolder(_ message: String, _ done: @escaping (URL) -> Void) {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.message = message
        panel.beginSheetModal(for: window) { response in if response == .OK, let url = panel.url { done(url) } }
    }

    // MARK: Sources
    private func reloadSources() {
        let volumes = PhotoImport.removableVolumes()
        sourcePopup.removeAllItems()
        for volume in volumes {
            let name = (try? volume.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? volume.lastPathComponent
            sourcePopup.addItem(withTitle: name); sourcePopup.lastItem?.representedObject = volume
            sourcePopup.lastItem?.image = NSWorkspace.shared.icon(forFile: volume.path); sourcePopup.lastItem?.image?.size = NSSize(width: 16, height: 16)
        }
        if let source, !volumes.contains(source) { sourcePopup.addItem(withTitle: source.lastPathComponent); sourcePopup.lastItem?.representedObject = source }
        sourcePopup.menu?.addItem(.separator())
        sourcePopup.addItem(withTitle: "Choose folder…")
        if let source, let index = sourcePopup.itemArray.firstIndex(where: { ($0.representedObject as? URL) == source }) { sourcePopup.selectItem(at: index) }
        else if !volumes.isEmpty { sourcePopup.selectItem(at: 0); scan(volumes[0]) }
        else { sourcePopup.selectItem(at: -1); summary.stringValue = "No camera card found. Insert one, or choose a folder." }
    }
    @objc private func sourceChanged() {
        if let url = sourcePopup.selectedItem?.representedObject as? URL { scan(url); return }
        chooseFolder("Choose a folder to import from") { url in self.source = url; self.reloadSources(); self.scan(url) }
    }
    @objc private func rescan() { reloadSources(); if let source { scan(source) } }
    private var sourceIsVolume: Bool { source.map { PhotoImport.removableVolumes().contains($0) } ?? false }
    private func scan(_ url: URL) {
        source = url; candidates = []; table.reloadData(); importButton.isEnabled = false
        ejectCheck.isEnabled = sourceIsVolume
        summary.stringValue = "Reading \(url.lastPathComponent)…"
        let token = UUID(); generation = token
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = PhotoImport.scan(url) { self?.generation != token }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.candidates = found; self.table.reloadData(); self.updateSummary(); self.templateChanged()
            }
        }
    }
    private func updateSummary() {
        let chosen = candidates.filter(\.include), known = candidates.filter(\.alreadyImported).count
        let bytes = ByteCountFormatter.string(fromByteCount: chosen.reduce(0) { $0 + $1.size }, countStyle: .file)
        summary.stringValue = candidates.isEmpty ? "No photos found." : "\(candidates.count) photos · \(chosen.count) checked (\(bytes))" + (known > 0 ? " · \(known) already in your library" : "")
        importButton.isEnabled = !running && !chosen.isEmpty
    }
    @objc private func checkAll() { for i in candidates.indices where !(skipCheck.state == .on && candidates[i].alreadyImported) { candidates[i].include = true }; table.reloadData(); updateSummary() }
    @objc private func checkNone() { for i in candidates.indices { candidates[i].include = false }; table.reloadData(); updateSummary() }

    // MARK: Table
    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, candidates.indices.contains(row) else { return nil }
        let c = candidates[row]
        if id == "use" {
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRow(_:))); box.tag = row; box.state = c.include ? .on : .off
            box.setAccessibilityLabel("Import \(c.url.lastPathComponent)"); return box
        }
        let text: String
        switch id {
        case "name": text = c.url.lastPathComponent + (c.sidecar != nil ? " + XMP" : "")
        case "date": text = c.captured.formatted(date: .abbreviated, time: .shortened)
        case "size": text = ByteCountFormatter.string(fromByteCount: c.size, countStyle: .file)
        default: text = c.alreadyImported ? "Already in library" : ""
        }
        let label = NSTextField(labelWithString: text); label.lineBreakMode = .byTruncatingMiddle
        if id == "status" { label.textColor = .secondaryLabelColor }
        return label
    }
    @objc private func toggleRow(_ sender: NSButton) {
        // A click on a selected row's box applies to every selected row.
        let rows = table.selectedRowIndexes.contains(sender.tag) ? Array(table.selectedRowIndexes) : [sender.tag]
        for row in rows where candidates.indices.contains(row) { candidates[row].include = sender.state == .on }
        table.reloadData(); updateSummary()
    }

    // MARK: Import
    @objc private func runImport() {
        guard !running, let destination, let window, let first = candidates.first else { return }
        var settings = ImportSettings(destination: destination)
        settings.folderTemplate = folderTemplate; settings.nameTemplate = names.stringValue
        settings.backup = backupCheck.state == .on ? backup : nil
        settings.skipAlreadyImported = skipCheck.state == .on
        var metadata = MetadataPresets.load().first { $0.id.uuidString == metadataPopup.selectedItem?.representedObject as? String }?.metadata ?? IPTCMetadata()
        metadata.keywords += IPTCMetadata.parseKeywords(keywords.stringValue)
        settings.metadata = metadata.sanitized.isEmpty ? nil : metadata.sanitized
        settings.developPreset = preset?.edits; settings.developPresetName = preset?.name
        do { _ = try PhotoImport.expand(settings.folderTemplate, candidate: first, index: 0, camera: "Camera", folders: true); _ = try PhotoImport.expand(settings.nameTemplate, candidate: first, index: 0, camera: "Camera", folders: false) }
        catch { let alert = NSAlert(error: error); alert.beginSheetModal(for: window); return }
        defaults.set(folders.stringValue, forKey: "importFolders"); defaults.set(names.stringValue, forKey: "importNames"); defaults.set(ejectCheck.state == .on, forKey: "importEject")
        running = true; cancelled = false; importButton.isEnabled = false; progress.isHidden = false; progress.doubleValue = 0
        let chosen = candidates, eject = ejectCheck.state == .on && sourceIsVolume ? source : nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = PhotoImport.run(chosen, settings: settings, progress: { done, total in
                DispatchQueue.main.async { self?.progress.doubleValue = total == 0 ? 1 : Double(done) / Double(total); self?.summary.stringValue = "Copying and verifying \(min(done + 1, total)) of \(total)…" }
            }, cancelled: { self?.cancelled ?? true })
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false; self.progress.isHidden = true
                var text = report.summary
                if let eject, report.failed.isEmpty, !report.cancelled {
                    do { try NSWorkspace.shared.unmountAndEjectDevice(at: eject); text += "\n\nThe card was ejected." }
                    catch { text += "\n\nThe card couldn’t be ejected: \(error.localizedDescription)" }
                }
                if !report.imported.isEmpty { self.imported?(report.imported) }
                let alert = NSAlert(); alert.messageText = report.imported.isEmpty ? "Nothing imported" : "Import finished"; alert.informativeText = text
                alert.beginSheetModal(for: window)
                if let source = self.source, eject == nil { self.scan(source) } else { self.candidates = []; self.table.reloadData(); self.updateSummary(); self.reloadSources() }
            }
        }
    }
    @objc private func closeOrCancel() { if running { cancelled = true; summary.stringValue = "Stopping after this photo…" } else { close() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if running { cancelled = true; return false }; return true }
    func windowWillClose(_ notification: Notification) { generation = UUID() }
}
