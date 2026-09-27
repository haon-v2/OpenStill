import AppKit
import OpenStillCore

/// OpenStill → Settings… (⌘,): General (updates and library), Layout, and Shortcuts.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let general: GeneralSettings
    private let tabs = NSTabViewController()

    init(updates: UpdateController) {
        general = GeneralSettings(updates: updates)
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        for (controller, title, symbol) in [(general as NSViewController, "General", "gearshape"), (LayoutSettings(), "Layout", "rectangle.split.3x1"), (ShortcutSettings(), "Shortcuts", "keyboard")] {
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

// MARK: - Layout

/// A clickable card with a small drawing of the layout.
private final class LayoutCard: NSView {
    let layout: WorkspaceLayout
    var chosen: ((WorkspaceLayout) -> Void)?
    var selected = false { didSet { needsDisplay = true; setAccessibilitySelected(selected) } }
    private var hovering = false { didSet { needsDisplay = true } }
    init(_ layout: WorkspaceLayout) {
        self.layout = layout
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 170))
        setAccessibilityRole(.radioButton); setAccessibilityLabel(layout.title + " layout"); setAccessibilityHelp(layout.summary)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 250, height: 170) }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { chosen?(layout) }
    override func accessibilityPerformPress() -> Bool { chosen?(layout); return true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { if event.keyCode == 49 || event.keyCode == 36 { chosen?(layout) } else { super.keyDown(with: event) } }

    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 3, dy: 3)
        let card = NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14)
        NSColor.controlBackgroundColor.withAlphaComponent(0.9).setFill(); card.fill()
        (selected ? Appearance.accent : (hovering ? NSColor.secondaryLabelColor : NSColor.separatorColor)).setStroke()
        card.lineWidth = selected ? 3 : 1; card.stroke()

        // The window: a dark workspace with panels, a photo and a filmstrip.
        let screen = frame.insetBy(dx: 16, dy: 16)
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill(); NSBezierPath(roundedRect: screen, xRadius: 8, yRadius: 8).fill()
        let inner = screen.insetBy(dx: 6, dy: 6)
        let panel = NSColor(calibratedWhite: 0.32, alpha: 1), rail = NSColor(calibratedWhite: 0.24, alpha: 1)
        func box(_ r: NSRect, _ color: NSColor, radius: CGFloat = 3) { color.setFill(); NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill() }
        func photo(_ r: NSRect) {
            NSGradient(colors: [NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.35, alpha: 1), NSColor(calibratedRed: 0.55, green: 0.35, blue: 0.75, alpha: 1), NSColor(calibratedRed: 0.12, green: 0.2, blue: 0.45, alpha: 1)])?
                .draw(in: NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3), angle: -90)
            // A little mountain range and sun.
            NSColor(calibratedWhite: 0.08, alpha: 0.85).setFill()
            let m = NSBezierPath(); m.move(to: NSPoint(x: r.minX, y: r.minY)); m.line(to: NSPoint(x: r.minX + r.width * 0.3, y: r.minY + r.height * 0.45))
            m.line(to: NSPoint(x: r.minX + r.width * 0.5, y: r.minY + r.height * 0.25)); m.line(to: NSPoint(x: r.minX + r.width * 0.72, y: r.minY + r.height * 0.55))
            m.line(to: NSPoint(x: r.maxX, y: r.minY + r.height * 0.2)); m.line(to: NSPoint(x: r.maxX, y: r.minY)); m.close(); m.fill()
            NSColor(calibratedRed: 1, green: 0.9, blue: 0.7, alpha: 0.95).setFill()
            NSBezierPath(ovalIn: NSRect(x: r.minX + r.width * 0.62, y: r.minY + r.height * 0.6, width: r.height * 0.18, height: r.height * 0.18)).fill()
        }
        func strip(_ r: NSRect) {
            box(r, rail)
            let count = 6, gap: CGFloat = 3, w = (r.width - gap * CGFloat(count + 1)) / CGFloat(count)
            for i in 0..<count { box(NSRect(x: r.minX + gap + CGFloat(i) * (w + gap), y: r.minY + 3, width: w, height: r.height - 6), NSColor(calibratedWhite: 0.45 + 0.05 * CGFloat(i % 2), alpha: 1), radius: 2) }
        }
        switch layout {
        case .luminar:
            let railW: CGFloat = 8, toolsW = inner.width * 0.26, stripH = inner.height * 0.18
            box(NSRect(x: inner.minX, y: inner.minY, width: railW, height: inner.height), rail)
            box(NSRect(x: inner.maxX - railW, y: inner.minY, width: railW, height: inner.height), rail)
            let tools = NSRect(x: inner.maxX - railW - 4 - toolsW, y: inner.minY, width: toolsW, height: inner.height); box(tools, panel)
            for i in 0..<5 { box(NSRect(x: tools.minX + 5, y: tools.maxY - 12 - CGFloat(i) * 11, width: tools.width - 10, height: 4), NSColor(calibratedWhite: 0.55, alpha: 1), radius: 2) }
            let photoArea = NSRect(x: inner.minX + railW + 4, y: inner.minY + stripH + 4, width: tools.minX - 4 - (inner.minX + railW + 4), height: inner.height - stripH - 4)
            photo(photoArea)
            strip(NSRect(x: photoArea.minX, y: inner.minY, width: photoArea.width, height: stripH))
        case .lightroom:
            let sideW = inner.width * 0.2, stripH = inner.height * 0.18, barH: CGFloat = 8
            box(NSRect(x: inner.minX, y: inner.maxY - barH, width: inner.width, height: barH), rail, radius: 2)
            let top = inner.maxY - barH - 4, bottom = inner.minY + stripH + 4
            let left = NSRect(x: inner.minX, y: bottom, width: sideW, height: top - bottom), right = NSRect(x: inner.maxX - sideW, y: bottom, width: sideW, height: top - bottom)
            box(left, panel); box(right, panel)
            for i in 0..<4 {
                box(NSRect(x: left.minX + 4, y: left.maxY - 10 - CGFloat(i) * 10, width: left.width * (i % 2 == 0 ? 0.8 : 0.55), height: 4), NSColor(calibratedWhite: 0.55, alpha: 1), radius: 2)
                box(NSRect(x: right.minX + 4, y: right.maxY - 10 - CGFloat(i) * 10, width: right.width - 8, height: 4), NSColor(calibratedWhite: 0.55, alpha: 1), radius: 2)
            }
            photo(NSRect(x: left.maxX + 4, y: bottom, width: right.minX - left.maxX - 8, height: top - bottom))
            strip(NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: stripH))
        }
        if selected {
            let badge = NSRect(x: frame.maxX - 30, y: frame.maxY - 30, width: 22, height: 22)
            Appearance.accent.setFill(); NSBezierPath(ovalIn: badge).fill()
            if let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .bold)) {
                let tinted = NSImage(size: check.size, flipped: false) { r in check.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true }
                tinted.draw(in: NSRect(x: badge.midX - check.size.width / 2, y: badge.midY - check.size.height / 2, width: check.size.width, height: check.size.height))
            }
        }
    }
}

private final class LayoutSettings: NSViewController {
    private var cards: [LayoutCard] = []
    override func loadView() {
        title = "Layout"
        let intro = note("Choose how OpenStill arranges its panels. Your photos, edits and shortcuts stay the same; switch any time, also from View → Lightroom Classic Layout (⌃⌘1) or Luminar Neo Layout (⌃⌘2).")
        intro.widthAnchor.constraint(equalToConstant: 540).isActive = true
        let row = NSStackView(); row.spacing = 18; row.alignment = .top
        for layout in [WorkspaceLayout.luminar, .lightroom] {
            let card = LayoutCard(layout); card.chosen = { [weak self] in self?.choose($0) }; cards.append(card)
            let name = NSTextField(labelWithString: layout.title); name.font = .systemFont(ofSize: 13, weight: .semibold)
            let summary = note(layout.summary); summary.widthAnchor.constraint(equalToConstant: 250).isActive = true
            let column = NSStackView(views: [card, name, summary]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 6
            row.addArrangedSubview(column)
        }
        let stack = NSStackView(views: [heading("Workspace layout"), intro, row])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 26, right: 24); stack.setCustomSpacing(20, after: intro)
        view = stack
        preferredContentSize = stack.fittingSize
        refresh()
        NotificationCenter.default.addObserver(forName: .workspaceLayoutChanged, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }
    private func choose(_ layout: WorkspaceLayout) {
        guard layout != WorkspaceLayout.current else { return }
        WorkspaceLayout.current = layout
        NotificationCenter.default.post(name: .workspaceLayoutChanged, object: nil)
    }
    private func refresh() { for card in cards { card.selected = card.layout == WorkspaceLayout.current } }
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
    private static let groupOrder = ["App", "File", "Edit", "View", "Window", "Library grid", "Photo and filmstrip"]

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
