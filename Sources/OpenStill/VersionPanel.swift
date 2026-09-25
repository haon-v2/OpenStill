import AppKit
import OpenStillCore

final class VersionPanel: NSStackView {
    var command: ((String)->Void)?
    private let versions = NSPopUpButton(frame:.zero, pullsDown:false)
    private let source = NSSegmentedControl(labels:["Camera Look", "RAW"], trackingMode:.selectOne, target:nil, action:nil)
    private let recovery=NSPopUpButton()
    private let detail = NSTextField(wrappingLabelWithString:"")
    private let more = NSPopUpButton(frame:.zero, pullsDown:true)
    override init(frame:NSRect) {
        super.init(frame:frame); orientation = .vertical; alignment = .leading; spacing = 8
        versions.target = self; versions.action = #selector(chooseVersion); versions.setAccessibilityLabel("Edit version")
        more.addItems(withTitles:["Version options…", "Create named version…", "Rename version…", "Upgrade renderer", "Delete version…", "Export portable edits…", "Import portable edits…"])
        more.target = self; more.action = #selector(versionAction)
        source.target = self; source.action = #selector(chooseSource); source.setAccessibilityLabel("Source rendering")
        recovery.addItems(withTitles:["Highlights: Clip","Highlights: Unclipped","Highlights: Blend"]+(3...9).map{"Highlights: Rebuild \($0)"});recovery.target=self;recovery.action = #selector(chooseRecovery);recovery.setAccessibilityLabel("RAW highlight recovery")
        detail.font = .systemFont(ofSize:10); detail.textColor = .secondaryLabelColor
        for view in [versions, source, recovery, more, detail] { addArrangedSubview(view); view.widthAnchor.constraint(equalTo:widthAnchor).isActive = true }
        update(nil, raw:false)
    }
    required init?(coder:NSCoder) { fatalError() }
    func update(_ record: PhotoRecord?, raw:Bool) {
        versions.removeAllItems()
        if let record {
            for version in record.versions {
                versions.addItem(withTitle:version.name)
                versions.lastItem?.representedObject = version.id.uuidString
            }
            versions.selectItem(at: record.versions.firstIndex(where: { $0.id == record.activeVersionID }) ?? 0)
            source.selectedSegment = record.active.sourceMode == .raw ? 1 : 0
            recovery.selectItem(at:record.active.recipe.raw.sanitized.highlightRecovery)
            detail.stringValue = record.active.renderer == .legacy ? "Legacy rendering · Original appearance preserved" : "High precision · Local, nondestructive edits"
        } else { detail.stringValue = "Open a photograph to begin" }
        versions.isEnabled = record != nil; more.isEnabled = record != nil; source.isEnabled = record != nil; source.isHidden = !raw;recovery.isHidden = record?.active.sourceMode != .raw
    }
    @objc private func chooseRecovery(){command?("recovery:"+String(recovery.indexOfSelectedItem))}
    @objc private func chooseVersion() { if let id = versions.selectedItem?.representedObject as? String { command?("version:" + id) } }
    @objc private func chooseSource() { command?(source.selectedSegment == 1 ? "source:raw" : "source:cameraLook") }
    @objc private func versionAction() {
        let names = ["", "new", "rename", "upgrade", "delete", "exportPackage", "importPackage"]
        guard names.indices.contains(more.indexOfSelectedItem), more.indexOfSelectedItem > 0 else { return }
        command?("version:" + names[more.indexOfSelectedItem])
    }
}

extension ViewerController {
    func versionCommand(_ command:String) {
        guard var record = photoRecord, let window = view.window, !localAI.isRunning, !aiPreparing else { return }
        if command == "version:exportPackage"{exportEditPackage();return}
        if command == "version:importPackage"{importEditPackage();return}
        finishMaskEditing()
        if command == "version:new" || command == "version:rename" {
            let alert = NSAlert(); alert.messageText = command == "version:new" ? "Create edit version" : "Rename edit version"
            alert.informativeText = "Versions stay saved on this Mac until you delete them."
            let field = NSTextField(string:command == "version:new" ? "Alternative" : record.active.name)
            field.frame = NSRect(x:0,y:0,width:280,height:24); field.setAccessibilityLabel("Version name"); alert.accessoryView = field
            alert.addButton(withTitle:"Save"); alert.addButton(withTitle:"Cancel")
            let id = record.id
            alert.beginSheetModal(for:window) { [weak self] response in
                guard let self, self.photoRecord?.id == id, response == .alertFirstButtonReturn else { return }
                let name = field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                if command == "version:new" { record.duplicateVersion(named:name) }
                else if let i = record.versions.firstIndex(where: { $0.id == record.activeVersionID }) { record.versions[i].name = name }
                self.saveVersionRecord(record)
            }
            return
        }
        if command == "version:delete" {
            guard record.versions.count > 1 else { info.status("Keep at least one edit version."); return }
            let alert = NSAlert(); alert.messageText = "Delete \(record.active.name)?"; alert.informativeText = "Other versions and the original photo will remain."
            alert.addButton(withTitle:"Delete version"); alert.addButton(withTitle:"Cancel")
            let id = record.id
            alert.beginSheetModal(for:window) { [weak self] response in
                guard let self, self.photoRecord?.id == id, response == .alertFirstButtonReturn else { return }
                record.versions.removeAll { $0.id == record.activeVersionID }; record.activeVersionID = record.versions[0].id
                self.saveVersionRecord(record)
            }
            return
        }
        if command == "version:upgrade" { record.upgrade() }
        else if command.hasPrefix("source:"), let mode = SourceMode(rawValue:String(command.dropFirst(7))) { record.switchSource(to:mode) }
        else if let id = UUID(uuidString:String(command.dropFirst(8))), record.versions.contains(where: { $0.id == id }) { record.activeVersionID = id }
        else { return }
        saveVersionRecord(record)
    }
    private func saveVersionRecord(_ record:PhotoRecord) {
        do { try EditStorage.records.update(record.id) { saved in var replacement=record;replacement.rating=saved.rating;replacement.flag=saved.flag;saved=replacement }; select(selected, preservingSelection:true);shootWindow?.refresh() }
        catch { info.status(error.localizedDescription) }
    }
}
