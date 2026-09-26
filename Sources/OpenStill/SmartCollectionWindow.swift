import AppKit
import OpenStillCore

/// Builds a smart collection: a name, "all" or "any", and up to six rules.
final class SmartCollectionWindow: NSWindowController, NSWindowDelegate {
    var created: ((PhotoCollection) -> Void)?
    private let name = NSTextField(string: "Five stars")
    private let match = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rowsStack = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var rows: [(NSPopUpButton, NSPopUpButton, NSComboBox)] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "New Smart Collection"; window.delegate = self; window.center(); Appearance.configure(window)
        let root = Appearance.panel(in: window)
        name.setAccessibilityLabel("Collection name")
        match.addItems(withTitles: ["Match all rules", "Match any rule"]); match.setAccessibilityLabel("Rule matching")
        rowsStack.orientation = .vertical; rowsStack.alignment = .leading; rowsStack.spacing = 8
        let add = NSButton(title: "Add rule", target: self, action: #selector(addRow)); add.bezelStyle = .rounded
        let remove = NSButton(title: "Remove last rule", target: self, action: #selector(removeRow)); remove.bezelStyle = .rounded
        let create = NSButton(title: "Create", target: self, action: #selector(createCollection)); create.keyEquivalent = "\r"; create.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"; cancel.bezelStyle = .rounded
        let help = NSTextField(wrappingLabelWithString: "Smart collections search every photo in the catalog and update themselves. Dates are YYYY-MM-DD. Flags: pick, reject, none. Labels: red, yellow, green, blue, purple, none.")
        help.font = .systemFont(ofSize: 10); help.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 11); status.textColor = .systemRed
        let header = NSStackView(views: [NSTextField(labelWithString: "Name"), name, match]); header.spacing = 8
        let buttons = NSStackView(views: [add, remove, NSView(), cancel, create]); buttons.spacing = 8
        let stack = NSStackView(views: [header, rowsStack, help, status, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
                                     name.widthAnchor.constraint(equalToConstant: 240), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor), help.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        addRow()
        rows[0].0.selectItem(at: SmartRule.Field.allCases.firstIndex(of: .rating) ?? 0); fieldChanged(rows[0].0); rows[0].2.stringValue = "5"
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func addRow() {
        guard rows.count < 6 else { return }
        let field = NSPopUpButton(frame: .zero, pullsDown: false); field.addItems(withTitles: SmartRule.Field.allCases.map(\.title))
        let operation = NSPopUpButton(frame: .zero, pullsDown: false)
        let value = NSComboBox(); value.widthAnchor.constraint(equalToConstant: 180).isActive = true
        field.tag = rows.count; field.target = self; field.action = #selector(fieldChanged(_:))
        field.setAccessibilityLabel("Rule \(rows.count + 1) field"); operation.setAccessibilityLabel("Rule \(rows.count + 1) condition"); value.setAccessibilityLabel("Rule \(rows.count + 1) value")
        rows.append((field, operation, value))
        let row = NSStackView(views: [field, operation, value]); row.spacing = 8; rowsStack.addArrangedSubview(row)
        field.selectItem(at: SmartRule.Field.allCases.firstIndex(of: .keyword) ?? 0); fieldChanged(field)
    }
    @objc private func removeRow() {
        guard rows.count > 1, let last = rowsStack.arrangedSubviews.last else { return }
        rows.removeLast(); rowsStack.removeArrangedSubview(last); last.removeFromSuperview()
    }
    @objc private func fieldChanged(_ sender: NSPopUpButton) {
        guard rows.indices.contains(sender.tag) else { return }
        let field = SmartRule.Field.allCases[max(0, sender.indexOfSelectedItem)], (_, operation, value) = rows[sender.tag]
        operation.removeAllItems(); operation.addItems(withTitles: SmartRule.operations(for: field).map(\.1))
        value.removeAllItems(); value.addItems(withObjectValues: SmartRule.choices(for: field)); value.stringValue = SmartRule.choices(for: field).first ?? ""
        value.isEnabled = field != .edited
        value.placeholderString = field == .captured ? "2026-09-25" : (field == .rating ? "0–5" : (field == .iso ? "e.g. 3200" : "Text"))
    }
    @objc private func createCollection() {
        var rules: [SmartRule] = []
        for (index, (fieldPopup, operationPopup, value)) in rows.enumerated() {
            let field = SmartRule.Field.allCases[max(0, fieldPopup.indexOfSelectedItem)]
            let operations = SmartRule.operations(for: field)
            let operation = operations[min(operations.count - 1, max(0, operationPopup.indexOfSelectedItem))].0
            guard let rule = SmartRule.make(field, operation, value: value.stringValue) else { status.stringValue = "Rule \(index + 1): enter a valid \(field.title.lowercased()) value."; return }
            rules.append(rule)
        }
        guard let catalog = EditStorage.records.catalog else { status.stringValue = "The library catalog isn’t available."; return }
        do {
            let collection = try catalog.createCollection(name: name.stringValue, smart: SmartRules(matchAll: match.indexOfSelectedItem == 0, rules: rules))
            created?(collection); close()
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func cancel() { close() }
}
