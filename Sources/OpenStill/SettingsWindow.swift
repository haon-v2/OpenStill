import AppKit
import OpenStillCore

/// OpenStill → Settings… (⌘,): General (updates and library) and Shortcuts.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let general: GeneralSettings
    private let tabs = NSTabViewController()

    init(updates: UpdateController) {
        general = GeneralSettings(updates: updates)
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        for (controller, title, symbol) in [(general as NSViewController, "General", "gearshape"), (ShortcutSettings(), "Shortcuts", "keyboard")] {
            let item = NSTabViewItem(viewController: controller)
            item.label = title; item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]; window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        super.init(window: window)
        window.delegate = self
        updates.changed = { [weak self] in self?.general.refresh() }
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowDidBecomeKey(_ notification: Notification) { general.refresh() }
    /// Opens straight to a tab, e.g. from the Layout menu.
    func show(tab index: Int) { tabs.selectedTabViewItemIndex = index; showWindow(nil) }
}

private func note(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor; return label
}
private func heading(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 15, weight: .semibold); return label
}

// MARK: - General

private final class GeneralSettings: NSViewController {
    private let updates: UpdateController
    private let version = NSTextField(labelWithString: "")
    private let method = note("")
    private let automatic = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
    private let lastChecked = NSTextField(labelWithString: "")
    private let checkNow = NSButton(title: "Check Now", target: nil, action: nil)
    private let releases = NSButton(title: "View All Releases", target: nil, action: nil)
    private let writeXMP = NSButton(checkboxWithTitle: "Write metadata to XMP sidecars automatically", target: nil, action: nil)
    init(updates: UpdateController) { self.updates = updates; super.init(nibName: nil, bundle: nil); title = "General" }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        version.font = .systemFont(ofSize: 12)
        automatic.target = self; automatic.action = #selector(toggleAutomatic)
        automatic.setAccessibilityHelp("Checks once a day and tells you when a newer OpenStill is available")
        lastChecked.font = .systemFont(ofSize: 11); lastChecked.textColor = .secondaryLabelColor
        for button in [checkNow, releases] { button.bezelStyle = .rounded; button.target = self }
        checkNow.action = #selector(check); releases.action = #selector(openReleases)
        let buttons = NSStackView(views: [checkNow, releases]); buttons.spacing = 8
        let privacy = note("Only OpenStill's public release list on GitHub is requested. Nothing about you or your photos is sent.")
        writeXMP.target = self; writeXMP.action = #selector(toggleXMP)
        let xmpNote = note("When you change a rating, flag, label, keywords or other metadata, OpenStill also writes it to a .xmp file next to the photo, where Lightroom, Bridge and other apps can read it. Other information already in the file is kept. Your photos themselves are never changed.")
        let stack = NSStackView(views: [heading("Updates"), version, method, automatic, lastChecked, buttons, privacy, heading("Library"), writeXMP, xmpNote])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.setCustomSpacing(16, after: method); stack.setCustomSpacing(16, after: buttons); stack.setCustomSpacing(24, after: privacy)
        for label in [method, privacy, xmpNote] { label.widthAnchor.constraint(equalToConstant: 452).isActive = true }
        view = stack
        preferredContentSize = stack.fittingSize
        refresh()
    }
    func refresh() {
        guard isViewLoaded else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String, build = info["CFBundleVersion"] as? String
        version.stringValue = short.map { "OpenStill \($0)" + (build.map { " (build \($0))" } ?? "") } ?? "OpenStill development build"
        method.stringValue = updates.usesSparkle
            ? "Updates download, are checked against OpenStill's signing key, and install from here. OpenStill relaunches when done."
            : "This build finds new releases on GitHub and opens the download page; you replace OpenStill in Applications yourself."
        automatic.state = updates.automaticChecks ? .on : .off
        lastChecked.stringValue = updates.lastChecked.map { "Last checked " + $0.formatted(.relative(presentation: .named)) } ?? "Not checked yet"
        checkNow.isEnabled = !updates.isChecking
        writeXMP.state = XMPSidecar.autoWrite ? .on : .off
    }
    @objc private func toggleXMP() { UserDefaults.standard.set(writeXMP.state == .on, forKey: XMPSidecar.autoWriteKey) }
    @objc private func toggleAutomatic() { updates.automaticChecks = automatic.state == .on; refresh() }
    @objc private func check() { updates.checkForUpdates(self); refresh() }
    @objc private func openReleases() { NSWorkspace.shared.open(UpdateCheck.releasesPage) }
}

// MARK: - Shortcuts

/// A keycap-style button. Click it, then press the new keys.
private final class ShortcutRecorder: NSView {
    var combo: KeyCombo? { didSet { needsDisplay = true; updateAccessibility() } }
    var customized = false { didSet { needsDisplay = true } }
    /// The new keys (nil = remove). Return false to reject them (the recorder shakes).
    var recorded: ((KeyCombo?) -> Bool)?
    var commandTitle = ""
    private var recording = false { didSet { needsDisplay = true; updateAccessibility() } }
    private var liveModifiers: NSEvent.ModifierFlags = []
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { recording = true; window?.makeFirstResponder(self) }
    override func accessibilityPerformPress() -> Bool { recording = true; window?.makeFirstResponder(self); return true }
    override func resignFirstResponder() -> Bool { recording = false; liveModifiers = []; return super.resignFirstResponder() }
    private func updateAccessibility() {
        setAccessibilityRole(.button)
        setAccessibilityLabel("Shortcut for \(commandTitle)")
        setAccessibilityValue(recording ? "Recording. Press the new keys, Delete to remove, Escape to cancel." : (combo?.spoken ?? "None"))
    }
    override func flagsChanged(with event: NSEvent) { if recording { liveModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control]); needsDisplay = true } else { super.flagsChanged(with: event) } }
    // Menu shortcuts arrive here before keyDown; capture them instead of running the command.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        capture(event); return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording else {
            if event.keyCode == 49 || event.keyCode == 36 { recording = true } else { super.keyDown(with: event) }
            return
        }
        capture(event)
    }
    private func capture(_ event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
        if plain && event.keyCode == 53 { stop(); return }                                       // Esc cancels
        if plain && (event.keyCode == 51 || event.keyCode == 117) { if recorded?(nil) == true { stop() }; return }  // Delete removes
        guard let combo = Shortcuts.combo(from: event) else { return }
        if recorded?(combo) == true { stop() } else { shake() }
    }
    private func stop() { recording = false; liveModifiers = []; window?.makeFirstResponder(nil) }
    private func shake() {
        guard let layer else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -6, 6, -4, 4, 0]; animation.duration = 0.3
        layer.add(animation, forKey: "shake")
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let cap = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        // A keycap: light face, a darker lip at the bottom.
        (recording ? Appearance.accent.withAlphaComponent(0.14) : NSColor.controlBackgroundColor).setFill(); cap.fill()
        let lip = NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 3), xRadius: 2, yRadius: 2)
        NSColor.separatorColor.withAlphaComponent(recording ? 0 : 0.6).setFill(); lip.fill()
        (recording ? Appearance.accent : NSColor.separatorColor).setStroke(); cap.lineWidth = recording ? 2 : 1; cap.stroke()
        let text: String, color: NSColor, font: NSFont
        if recording {
            var mods = ""
            if liveModifiers.contains(.control) { mods += "⌃" }; if liveModifiers.contains(.option) { mods += "⌥" }
            if liveModifiers.contains(.shift) { mods += "⇧" }; if liveModifiers.contains(.command) { mods += "⌘" }
            text = mods.isEmpty ? "Type shortcut…" : mods; color = Appearance.accent; font = .systemFont(ofSize: 12, weight: .medium)
        } else if let combo {
            text = combo.display; color = .labelColor; font = .monospacedSystemFont(ofSize: 12, weight: customized ? .semibold : .regular)
        } else { text = "Add shortcut"; color = .tertiaryLabelColor; font = .systemFont(ofSize: 12) }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + 1), withAttributes: attributes)
    }
}

private final class ShortcutSettings: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Row { case group(String), command(ShortcutCommand) }
    private let table = NSTableView()
    private let search = NSSearchField()
    private let status = note("")
    private var rows: [Row] = []
    private static let groupOrder = ["App", "File", "Edit", "View", "Window", "Workspace", "Library grid", "Photo and filmstrip"]

    override func loadView() {
        title = "Shortcuts"
        search.placeholderString = "Search commands or keys, e.g. “export” or “⌘E”"; search.delegate = self
        search.setAccessibilityLabel("Search shortcuts")
        let column = NSTableColumn(identifier: .init("row")); column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.headerView = nil; table.dataSource = self; table.delegate = self; table.rowHeight = 34; table.selectionHighlightStyle = .none
        table.style = .inset; table.usesAlternatingRowBackgroundColors = false; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.setAccessibilityLabel("Keyboard shortcuts")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder; scroll.drawsBackground = false
        scroll.heightAnchor.constraint(equalToConstant: 400).isActive = true
        let restore = NSButton(title: "Restore All Defaults", target: self, action: #selector(restoreAll)); restore.bezelStyle = .rounded
        let footer = NSStackView(views: [status, NSView(), restore]); footer.spacing = 8
        let intro = note("Click a shortcut, then press the new keys. Delete removes a shortcut; Escape cancels. Library and photo keys can be single keys; menu shortcuts need ⌘, ⌃ or ⌥ (or a function key).")
        let stack = NSStackView(views: [heading("Keyboard shortcuts"), intro, search, scroll, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 18, right: 24)
        for v in [intro, search, scroll, footer] as [NSView] { v.widthAnchor.constraint(equalToConstant: 560).isActive = true }
        view = stack
        preferredContentSize = stack.fittingSize
        reload()
        NotificationCenter.default.addObserver(forName: Shortcuts.changedNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.table.reloadData() } }
    }
    func controlTextDidChange(_ obj: Notification) { reload() }
    private func reload() {
        let matches = Shortcuts.map.search(search.stringValue)
        let groups = Dictionary(grouping: matches, by: \.group)
        let order = Self.groupOrder + groups.keys.filter { !Self.groupOrder.contains($0) }.sorted()
        rows = order.flatMap { name -> [Row] in groups[name].map { [.group(name)] + $0.map { .command($0) } } ?? [] }
        table.reloadData()
        status.stringValue = matches.isEmpty ? "No commands match “\(search.stringValue)”." : "\(Shortcuts.map.commands.filter { Shortcuts.map.isCustomized($0.id) }.count) changed from the defaults."
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { if case .group = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if case .group = rows[row] { return 28 }; return 34 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let name):
            let label = NSTextField(labelWithString: name.uppercased()); label.font = .systemFont(ofSize: 11, weight: .semibold); label.textColor = .secondaryLabelColor
            return label
        case .command(let command):
            let title = NSTextField(labelWithString: command.title); title.lineBreakMode = .byTruncatingTail; title.font = .systemFont(ofSize: 13)
            let recorder = ShortcutRecorder(); recorder.commandTitle = command.title
            recorder.combo = Shortcuts.map.combo(for: command.id); recorder.customized = Shortcuts.map.isCustomized(command.id)
            recorder.recorded = { [weak self] combo in self?.assign(combo, to: command) ?? false }
            let reset = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.backward.circle.fill", accessibilityDescription: "Reset \(command.title) to its default")!, target: self, action: #selector(resetOne(_:)))
            reset.isBordered = false; reset.contentTintColor = .secondaryLabelColor; reset.identifier = .init(command.id)
            reset.toolTip = "Back to " + (command.defaultCombo?.display ?? "no shortcut"); reset.isHidden = !Shortcuts.map.isCustomized(command.id)
            let line = NSStackView(views: [title, NSView(), recorder, reset]); line.spacing = 10; line.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
            reset.widthAnchor.constraint(equalToConstant: 18).isActive = true
            return line
        }
    }
    /// Checks the keys, asks before taking them from another command, and saves.
    private func assign(_ combo: KeyCombo?, to command: ShortcutCommand) -> Bool {
        guard let combo else { Shortcuts.map.set(nil, for: command.id); reload(); return true }
        // Function keys, arrows and the like can stand alone; letters, digits, Space, Return, Tab and Escape can't.
        if command.scope == .menu, !combo.hasModifier, !combo.isSpecial || ["space", "return", "tab", "escape"].contains(combo.key) {
            status.stringValue = "Menu shortcuts need ⌘, ⌃ or ⌥ so they don't get in the way of typing."
            return false
        }
        let clashes = Shortcuts.map.conflicts(for: combo, assigningTo: command.id)
        if let other = clashes.first, let window = view.window {
            let alert = NSAlert(); alert.messageText = "\(combo.display) is already used by “\(other.title)”."
            alert.informativeText = "Use it for “\(command.title)” instead? “\(other.title)” will have no shortcut until you give it one."
            alert.addButton(withTitle: "Use for \(command.title)"); alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                Shortcuts.map.set(combo, for: command.id); self?.reload()
                self?.status.stringValue = "\(command.title) is now \(combo.display). \(other.title) has no shortcut."
            }
            return true
        }
        Shortcuts.map.set(combo, for: command.id); reload()
        status.stringValue = "\(command.title) is now \(combo.display)."
        return true
    }
    @objc private func resetOne(_ sender: NSButton) { if let id = sender.identifier?.rawValue { Shortcuts.map.reset(id); reload() } }
    @objc private func restoreAll() {
        guard let window = view.window else { return }
        let alert = NSAlert(); alert.messageText = "Restore every shortcut to its default?"; alert.informativeText = "Shortcuts you changed or removed come back as they were."
        alert.addButton(withTitle: "Restore Defaults"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in if response == .alertFirstButtonReturn { Shortcuts.map.resetAll(); self?.reload() } }
    }
}
