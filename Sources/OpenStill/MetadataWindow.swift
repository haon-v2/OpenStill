import AppKit
import OpenStillCore

/// Title, caption, keywords, creator, copyright and location for one or many photos.
/// With one photo the fields show its metadata and Save replaces it. With several, filled-in fields are applied to all of
/// them, keywords are added, and "Remove keywords" takes keywords off.
final class MetadataWindow: NSWindowController, NSWindowDelegate {
    var saved: (([PhotoRecord]) -> Void)?
    private let items: [ShootItem]
    private var fields: [(WritableKeyPath<IPTCMetadata, String>, NSTextField)] = []
    private let keywords = NSTextField(string: "")
    private let removeKeywords = NSTextField(string: "")
    private let presets = NSPopUpButton(frame: .zero, pullsDown: true)
    private let status = NSTextField(wrappingLabelWithString: "")
    private var single: Bool { items.count == 1 }

    init(items: [ShootItem]) {
        self.items = items
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = items.count == 1 ? "Metadata · \(items[0].url.lastPathComponent)" : "Metadata · \(items.count) photos"
        window.delegate = self; window.center(); Appearance.configure(window)
        let root = Appearance.panel(in: window)
        let form = NSGridView(numberOfColumns: 2, rows: 0); form.rowSpacing = 8; form.columnSpacing = 10
        form.column(at: 0).xPlacement = .trailing
        let current = items.count == 1 ? items[0].record.iptc : IPTCMetadata()
        for (title, path, placeholder) in [("Title", \IPTCMetadata.title, "Headline"), ("Caption", \.caption, "Description"), ("Creator", \.creator, "Photographer"),
                                           ("Copyright", \.copyright, "© 2026 Your Name"), ("Location", \.location, "Sublocation"), ("City", \.city, ""), ("State / province", \.state, ""), ("Country", \.country, "")] {
            let field = NSTextField(string: current[keyPath: path]); field.placeholderString = single ? placeholder : "Leave empty to keep each photo’s value"
            field.setAccessibilityLabel(title); field.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
            if path == \IPTCMetadata.caption { field.usesSingleLineMode = false; field.cell?.wraps = true; field.heightAnchor.constraint(equalToConstant: 54).isActive = true }
            fields.append((path, field)); form.addRow(with: [NSTextField(labelWithString: title), field])
        }
        keywords.stringValue = current.keywords.joined(separator: ", ")
        keywords.placeholderString = single ? "Comma separated. Use > for levels: Places > France > Paris" : "Added to every photo. Use > for levels"
        keywords.setAccessibilityLabel("Keywords"); form.addRow(with: [NSTextField(labelWithString: single ? "Keywords" : "Add keywords"), keywords])
        if !single {
            removeKeywords.placeholderString = "Keywords to take off these photos"; removeKeywords.setAccessibilityLabel("Remove keywords")
            form.addRow(with: [NSTextField(labelWithString: "Remove keywords"), removeKeywords])
            let common = Set(items.map { Set($0.record.iptc.keywords) }.reduce(Set(items[0].record.iptc.keywords)) { $0.intersection($1) })
            status.stringValue = common.isEmpty ? "These photos share no keywords." : "Shared keywords: " + common.sorted().joined(separator: ", ")
        }
        if let catalog = EditStorage.records.catalog {
            let known = catalog.keywordCounts().prefix(40).map { "\($0.0) (\($0.1))" }
            keywords.toolTip = known.isEmpty ? nil : "Keywords in your library:\n" + known.joined(separator: "\n")
        }
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        presets.target = self; presets.action = #selector(choosePreset); presets.setAccessibilityLabel("Metadata presets"); reloadPresets()
        let save = NSButton(title: single ? "Save" : "Apply to \(items.count) photos", target: self, action: #selector(saveMetadata)); save.keyEquivalent = "\r"; save.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"; cancel.bezelStyle = .rounded
        let buttons = NSStackView(views: [presets, NSView(), cancel, save]); buttons.spacing = 8
        let note = NSTextField(wrappingLabelWithString: "Stored with OpenStill’s edits; your original files aren’t changed. Exports include it as IPTC when “Keep metadata” is on.")
        note.font = .systemFont(ofSize: 10); note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [form, status, note, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
                                     stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor), note.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }

    private var entered: IPTCMetadata {
        var m = IPTCMetadata()
        for (path, field) in fields { m[keyPath: path] = field.stringValue }
        m.keywords = IPTCMetadata.parseKeywords(keywords.stringValue)
        return m.sanitized
    }
    private func reloadPresets() {
        presets.removeAllItems(); presets.addItem(withTitle: "Presets")
        for preset in MetadataPresets.load() { presets.addItem(withTitle: "Apply “\(preset.name)”"); presets.lastItem?.representedObject = preset.id.uuidString }
        presets.menu?.addItem(.separator())
        presets.addItem(withTitle: "Save fields as preset…"); presets.lastItem?.representedObject = "save"
        if !MetadataPresets.load().isEmpty { presets.addItem(withTitle: "Delete a preset…"); presets.lastItem?.representedObject = "delete" }
    }
    @objc private func choosePreset() {
        guard let choice = presets.selectedItem?.representedObject as? String, let window else { return }
        if choice == "save" {
            let alert = NSAlert(); alert.messageText = "Save metadata preset"; alert.informativeText = "Filled-in fields and keywords are saved. Empty fields stay empty when the preset is applied."
            let name = NSTextField(string: "My copyright"); name.frame = NSRect(x: 0, y: 0, width: 260, height: 24); alert.accessoryView = name
            alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn else { return }
                var all = MetadataPresets.load(); all.append(MetadataPreset(name: name.stringValue.isEmpty ? "Preset" : name.stringValue, metadata: self.entered))
                do { try MetadataPresets.save(all); self.reloadPresets(); self.status.stringValue = "Preset saved." } catch { self.status.stringValue = error.localizedDescription }
            }
        } else if choice == "delete" {
            let alert = NSAlert(); alert.messageText = "Delete a metadata preset"
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false); popup.addItems(withTitles: MetadataPresets.load().map(\.name)); alert.accessoryView = popup
            alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn else { return }
                var all = MetadataPresets.load(); if all.indices.contains(popup.indexOfSelectedItem) { all.remove(at: popup.indexOfSelectedItem) }
                try? MetadataPresets.save(all); self.reloadPresets()
            }
        } else if let preset = MetadataPresets.load().first(where: { $0.id.uuidString == choice }) {
            for (path, field) in fields where !preset.metadata[keyPath: path].isEmpty { field.stringValue = preset.metadata[keyPath: path] }
            let existing = IPTCMetadata.parseKeywords(keywords.stringValue)
            keywords.stringValue = (existing + preset.metadata.keywords.filter { k in !existing.contains { $0.caseInsensitiveCompare(k) == .orderedSame } }).joined(separator: ", ")
            status.stringValue = "Applied “\(preset.name)”. Review, then save."
        }
    }
    @objc private func saveMetadata() {
        let metadata = entered, remove = IPTCMetadata.parseKeywords(removeKeywords.stringValue)
        var updated: [PhotoRecord] = [], failures = 0
        for item in items {
            do { updated.append(try ShootWorkflow.applyMetadata(item.id, metadata, replaceAll: single, removingKeywords: remove)) } catch { failures += 1 }
        }
        saved?(updated)
        if failures > 0 { status.stringValue = "\(failures) photo\(failures == 1 ? "" : "s") couldn’t be updated."; return }
        close()
    }
    @objc private func cancel() { close() }
}
