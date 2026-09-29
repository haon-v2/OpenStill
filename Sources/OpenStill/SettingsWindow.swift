import AppKit
import Metal
import OpenStillCore

/// The sections of Settings, in sidebar order.
enum SettingsSection: Int, CaseIterable {
    case general, editing, library, autoImport, shortcuts, assistant
    var title: String {
        switch self {
        case .general: return "General"
        case .editing: return "Editing & Performance"
        case .library: return "Library & Catalog"
        case .autoImport: return "Auto Import"
        case .shortcuts: return "Shortcuts"
        case .assistant: return "AI Assistant"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .editing: return "slider.horizontal.3"
        case .library: return "books.vertical"
        case .autoImport: return "tray.and.arrow.down"
        case .shortcuts: return "keyboard"
        case .assistant: return "sparkles"
        }
    }
}

/// OpenStill → Settings… (⌘,): a dark window in the Studio style with a sidebar of sections.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let size = NSSize(width: 700, height: 540)
    private let updates: UpdateController
    private let sidebar = NSStackView()
    private let content = NSView()
    private var pages: [SettingsSection: SettingsPage] = [:]
    private var buttons: [SettingsSidebarButton] = []
    private(set) var section = SettingsSection.general
    /// Called when Auto Import settings are saved, so the running watcher follows them.
    var autoImportSaved: ((AutoImportSettings) -> Void)?

    init(updates: UpdateController) {
        self.updates = updates
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Settings"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua); window.backgroundColor = Studio.chrome
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        show(.general)
        updates.changed = { [weak self] in (self?.pages[.general] as? GeneralSettings)?.refresh() }
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowDidBecomeKey(_ notification: Notification) { pages[section]?.refresh() }

    private func build() {
        guard let root = window?.contentView else { return }
        let side = NSView(); side.wantsLayer = true; side.layer?.backgroundColor = Studio.canvas.cgColor
        let divider = NSView(); divider.wantsLayer = true; divider.layer?.backgroundColor = Studio.hairline.cgColor
        sidebar.orientation = .vertical; sidebar.alignment = .leading; sidebar.spacing = 2
        for section in SettingsSection.allCases {
            let button = SettingsSidebarButton(section: section) { [weak self] in self?.show(section) }
            buttons.append(button); sidebar.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 176).isActive = true
        }
        for v in [side, divider, content, sidebar] { v.translatesAutoresizingMaskIntoConstraints = false }
        root.addSubview(side); root.addSubview(divider); root.addSubview(content); side.addSubview(sidebar)
        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor), side.topAnchor.constraint(equalTo: root.topAnchor),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor), side.widthAnchor.constraint(equalToConstant: 196),
            divider.leadingAnchor.constraint(equalTo: side.trailingAnchor), divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor), divider.widthAnchor.constraint(equalToConstant: 1),
            sidebar.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 10), sidebar.topAnchor.constraint(equalTo: side.topAnchor, constant: 46),
            content.leadingAnchor.constraint(equalTo: divider.trailingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor), content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    private func page(_ section: SettingsSection) -> SettingsPage {
        if let page = pages[section] { return page }
        let page: SettingsPage
        switch section {
        case .general: page = GeneralSettings(updates: updates)
        case .editing: page = EditingSettings()
        case .library: page = LibrarySettings()
        case .autoImport:
            let autoImport = AutoImportSettingsPage()
            autoImport.saved = { [weak self] settings in self?.autoImportSaved?(settings) }
            page = autoImport
        case .shortcuts: page = ShortcutSettings()
        case .assistant: page = AssistantSettings()
        }
        pages[section] = page
        return page
    }

    /// Shows a section, e.g. from File › Catalog Settings… or Library › Auto Import Settings….
    func show(_ section: SettingsSection) {
        self.section = section
        for button in buttons { button.selected = button.section == section }
        content.subviews.forEach { $0.removeFromSuperview() }
        let view = page(section).view
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: content.leadingAnchor), view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                                     view.topAnchor.constraint(equalTo: content.topAnchor), view.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        pages[section]?.refresh()
        window?.title = "Settings · " + section.title
    }
    func open(_ section: SettingsSection) {
        show(section)
        if window?.isVisible != true { window?.center() }
        showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

/// One sidebar row: an icon and a title, with the Studio selection look.
final class SettingsSidebarButton: NSView {
    let section: SettingsSection
    private let action: () -> Void
    private let icon = NSImageView(), label = NSTextField(labelWithString: "")
    private var hovering = false { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true; label.textColor = selected ? Studio.text : Studio.secondary; icon.contentTintColor = selected ? Studio.accent : Studio.secondary; setAccessibilitySelected(selected) } }
    init(section: SettingsSection, action: @escaping () -> Void) {
        self.section = section; self.action = action
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        icon.contentTintColor = Studio.secondary
        label.stringValue = section.title; label.font = .systemFont(ofSize: 13); label.textColor = Studio.secondary
        let row = NSStackView(views: [icon, label]); row.spacing = 9; row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant: 30), icon.widthAnchor.constraint(equalToConstant: 20),
                                     row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), row.centerYAnchor.constraint(equalTo: centerYAnchor)])
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(section.title)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        guard selected || hovering else { return }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        (selected ? Studio.selectedFill : Studio.hoverFill).setFill(); shape.fill()
        if selected { Studio.selectedStroke.setStroke(); shape.lineWidth = 1; shape.stroke() }
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { action() }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}

// MARK: - Page building

/// A Settings page: a title, then groups of rows (label left, control right) separated by hairlines. It scrolls when taller than the window.
class SettingsPage: NSViewController {
    static let width: CGFloat = 503 - 2 * Studio.inset - 8
    let stack = NSStackView()
    init(title: String) { super.init(nibName: nil, bundle: nil); self.title = title }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 44, left: Studio.inset + 4, bottom: 24, right: Studio.inset + 4)
        let heading = NSTextField(labelWithString: title ?? ""); heading.font = .systemFont(ofSize: 20, weight: .semibold); heading.textColor = Studio.text
        stack.addArrangedSubview(heading); stack.setCustomSpacing(14, after: heading)
        build()
        let document = FlippedView(); document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        let scroll = NSScrollView(); scroll.documentView = document; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: document.topAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
                                     document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        view = scroll
    }
    /// Adds the page's groups.
    func build() {}
    /// Reloads values shown on the page.
    func refresh() {}

    /// A group: an optional small title, rows with hairlines between them, and an optional note under it.
    func group(_ title: String?, _ rows: [NSView], note text: String? = nil) {
        if let title {
            let label = NSTextField(labelWithString: title.uppercased()); label.font = .systemFont(ofSize: 11, weight: .semibold); label.textColor = Studio.tertiary
            stack.addArrangedSubview(label); stack.setCustomSpacing(6, after: label)
        }
        for (i, row) in rows.enumerated() {
            if i > 0 { let line = hairline(); stack.addArrangedSubview(line) }
            stack.addArrangedSubview(row); row.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        }
        var last: NSView = rows.last ?? stack.arrangedSubviews.last!
        if let text {
            let label = settingsNote(text); stack.setCustomSpacing(6, after: last); stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalToConstant: Self.width).isActive = true; last = label
        }
        stack.setCustomSpacing(26, after: last)
    }
    func hairline() -> NSView {
        let line = NSView(); line.wantsLayer = true; line.layer?.backgroundColor = Studio.hairline.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([line.heightAnchor.constraint(equalToConstant: 1), line.widthAnchor.constraint(equalToConstant: Self.width)])
        return line
    }
    /// A row: the label (with an optional explanation under it) on the left and the controls on the right.
    func row(_ title: String, _ controls: [NSView], detail: String? = nil) -> NSView {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 13); label.textColor = Studio.text
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        var left: NSView = label
        if let detail {
            let small = settingsNote(detail); small.preferredMaxLayoutWidth = 220
            let column = NSStackView(views: [label, small]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 2
            small.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
            left = column
        }
        let right = NSStackView(views: controls); right.spacing = 8
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = NSStackView(views: [left, spacer, right]); line.alignment = .centerY; line.edgeInsets = NSEdgeInsets(top: 9, left: 0, bottom: 9, right: 0)
        return line
    }
    func value(_ text: String = "") -> NSTextField {
        let field = NSTextField(labelWithString: text); field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); field.textColor = Studio.secondary
        field.lineBreakMode = .byTruncatingMiddle; field.alignment = .right
        return field
    }
    func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; b.controlSize = .regular; return b
    }
    func toggle(_ action: Selector, label: String) -> NSSwitch {
        let s = NSSwitch(); s.target = self; s.action = action; s.controlSize = .small; s.setAccessibilityLabel(label); return s
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

func settingsNote(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: 11); label.textColor = Studio.secondary; return label
}

// MARK: - General

private final class GeneralSettings: SettingsPage {
    private let updates: UpdateController
    private let version = NSTextField(labelWithString: "")
    private lazy var automatic = toggle(#selector(toggleAutomatic), label: "Check for updates automatically")
    private let lastChecked = NSTextField(labelWithString: "")
    private lazy var checkNow = button("Check Now", #selector(check))
    private let method = settingsNote("")
    init(updates: UpdateController) { self.updates = updates; super.init(title: SettingsSection.general.title) }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        version.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); version.textColor = Studio.secondary
        lastChecked.font = .systemFont(ofSize: 11); lastChecked.textColor = Studio.secondary
        group("Updates", [
            row("Version", [version]),
            row("Check automatically", [automatic], detail: "Once a day, OpenStill looks for a newer version."),
            row("Check now", [lastChecked, checkNow]),
            row("All releases", [button("View on GitHub", #selector(openReleases))]),
        ], note: "Only OpenStill's public release list on GitHub is requested. Nothing about you or your photos is sent.")
        stack.addArrangedSubview(method); method.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
    }
    override func refresh() {
        guard isViewLoaded else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String, build = info["CFBundleVersion"] as? String
        version.stringValue = short.map { "OpenStill \($0)" + (build.map { " (\($0))" } ?? "") } ?? "Development build"
        method.stringValue = updates.usesSparkle
            ? "Updates download, are checked against OpenStill's signing key, and install from here. OpenStill relaunches when done."
            : "This build finds new releases on GitHub and opens the download page; you replace OpenStill in Applications yourself."
        automatic.state = updates.automaticChecks ? .on : .off
        lastChecked.stringValue = updates.lastChecked.map { "Last checked " + $0.formatted(.relative(presentation: .named)) } ?? "Not checked yet"
        checkNow.isEnabled = !updates.isChecking
    }
    @objc private func toggleAutomatic() { updates.automaticChecks = automatic.state == .on; refresh() }
    @objc private func check() { updates.checkForUpdates(self); refresh() }
    @objc private func openReleases() { NSWorkspace.shared.open(UpdateCheck.releasesPage) }
}

// MARK: - Editing & Performance

private final class EditingSettings: SettingsPage {
    static let cacheSizes: [Int64] = [2, 5, 10, 20, 50].map { Int64($0) << 30 }
    private let cacheSize = NSPopUpButton()
    private let cacheUsed = NSTextField(labelWithString: "")
    private lazy var clear = button("Clear Cache", #selector(clearCache))
    init() { super.init(title: SettingsSection.editing.title) }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        cacheSize.addItems(withTitles: Self.cacheSizes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
        cacheSize.target = self; cacheSize.action = #selector(sizeChanged); cacheSize.setAccessibilityLabel("Render cache size")
        cacheUsed.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); cacheUsed.textColor = Studio.secondary
        group("Render cache", [
            row("Maximum size", [cacheSize]),
            row("In use", [cacheUsed, clear]),
        ], note: "A screen-sized copy of each RAW photo you open, like Lightroom's Camera Raw cache, so going back to a photo doesn't decode the RAW again. The oldest copies are removed past the size limit. Clearing it never touches your photos or edits.")
        let gpu = value(MTLCreateSystemDefaultDevice()?.name ?? "None found")
        let hdr = value(PhotoBackdrop.hdrAvailable ? "Available on this display" : "Not available on this display")
        group("Graphics", [
            row("GPU", [gpu]),
            row("HDR editing", [hdr]),
        ], note: "Develop renders on the GPU at the size shown on screen, then in full detail where you zoom in. The photo follows sliders while you drag them.")
    }
    override func refresh() {
        guard isViewLoaded else { return }
        let limit = RenderCache.limitBytes
        cacheSize.selectItem(at: Self.cacheSizes.firstIndex { $0 >= limit } ?? Self.cacheSizes.count - 1)
        cacheUsed.stringValue = "Measuring…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let used = RenderCache.diskUsage()
            DispatchQueue.main.async { self?.cacheUsed.stringValue = ByteCountFormatter.string(fromByteCount: used, countStyle: .file) }
        }
    }
    @objc private func sizeChanged() { RenderCache.limitBytes = Self.cacheSizes[max(0, cacheSize.indexOfSelectedItem)]; refresh() }
    @objc private func clearCache() {
        clear.isEnabled = false
        DispatchQueue.global(qos: .utility).async { [weak self] in
            RenderCache.clear()
            DispatchQueue.main.async { self?.clear.isEnabled = true; self?.refresh() }
        }
    }
}

// MARK: - Library & Catalog

private final class LibrarySettings: SettingsPage {
    private lazy var writeXMP = toggle(#selector(toggleXMP), label: "Write metadata to XMP sidecars")
    private let location = NSTextField(labelWithString: "")
    private let frequency = NSPopUpButton()
    private let keep = NSStepper(), keepLabel = NSTextField(labelWithString: "")
    private let lastBackup = NSTextField(labelWithString: "")
    private lazy var backUpNow = button("Back Up Now", #selector(backUp))
    private var backup = CatalogBackup.load()
    init() { super.init(title: SettingsSection.library.title) }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        group("Metadata", [row("Write XMP sidecars", [writeXMP], detail: "Ratings, flags, labels and keywords are also saved in a .xmp file next to each photo, where Lightroom and Bridge can read them. Your photos themselves are never changed.")])
        for f in [location, keepLabel, lastBackup] { f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); f.textColor = Studio.secondary }
        location.lineBreakMode = .byTruncatingMiddle; location.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        group("Catalog", [
            row("Location", [location, button("Show", #selector(showCatalog)), button("Change…", #selector(changeCatalog))]),
        ], note: "The catalog keeps your edits, ratings, collections and previews. Choosing an empty folder starts a new catalog; a folder with an OpenStill catalog opens it. OpenStill relaunches to switch.")
        frequency.addItems(withTitles: BackupFrequency.allCases.map(\.title)); frequency.target = self; frequency.action = #selector(backupChanged)
        frequency.setAccessibilityLabel("Back up the catalog")
        keep.minValue = 1; keep.maxValue = 100; keep.increment = 1; keep.target = self; keep.action = #selector(backupChanged)
        keep.setAccessibilityLabel("Backups to keep")
        lastBackup.font = .systemFont(ofSize: 11)
        group("Backups", [
            row("Back up", [frequency]),
            row("Keep", [keepLabel, keep]),
            row("Last backup", [lastBackup, backUpNow]),
        ], note: "Backups are zipped copies of the catalog in \(CatalogBackup.defaultFolder().path).")
    }
    override func refresh() {
        guard isViewLoaded else { return }
        writeXMP.state = XMPSidecar.autoWrite ? .on : .off
        location.stringValue = (EditStorage.root.path as NSString).abbreviatingWithTildeInPath
        location.toolTip = EditStorage.root.path
        backup = CatalogBackup.load()
        frequency.selectItem(at: BackupFrequency.allCases.firstIndex(of: backup.frequency) ?? 0)
        keep.integerValue = backup.keep; keepLabel.stringValue = "\(backup.keep) backup\(backup.keep == 1 ? "" : "s")"
        lastBackup.stringValue = backup.last.map { $0.formatted(.relative(presentation: .named)) } ?? "Never"
    }
    @objc private func toggleXMP() { UserDefaults.standard.set(writeXMP.state == .on, forKey: XMPSidecar.autoWriteKey) }
    @objc private func backupChanged() {
        backup.frequency = BackupFrequency.allCases[max(0, frequency.indexOfSelectedItem)]
        backup.keep = max(1, min(100, keep.integerValue))
        try? CatalogBackup.save(backup)
        refresh()
    }
    @objc private func backUp() {
        backUpNow.isEnabled = false; lastBackup.stringValue = "Backing up…"
        let settings = backup
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try CatalogBackup.run(into: settings.folder, keep: settings.keep) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.backUpNow.isEnabled = true
                switch result {
                case .success:
                    var saved = CatalogBackup.load(); saved.last = Date(); try? CatalogBackup.save(saved); self.refresh()
                case .failure(let error): self.lastBackup.stringValue = error.localizedDescription
                }
            }
        }
    }
    @objc private func showCatalog() { NSWorkspace.shared.activateFileViewerSelecting([EditStorage.root]) }
    @objc private func changeCatalog() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "Choose a folder for the catalog. An empty folder starts a new catalog; a folder with an OpenStill catalog opens it."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let folder = panel.url else { return }
            CatalogLocation.choose(folder)
            let alert = NSAlert(); alert.messageText = "Relaunch OpenStill to use this catalog"; alert.informativeText = folder.path
            alert.beginSheetModal(for: window)
        }
    }
}

// MARK: - Auto Import

private final class AutoImportSettingsPage: SettingsPage {
    var saved: ((AutoImportSettings) -> Void)?
    private var settings = AutoImport.load()
    private lazy var enabled = toggle(#selector(changed), label: "Auto Import")
    private let watched = NSTextField(labelWithString: ""), destination = NSTextField(labelWithString: "")
    private let folders = NSPopUpButton(), mode = NSPopUpButton(), keywords = NSTextField()
    private let status = NSTextField(labelWithString: "")
    init() { super.init(title: SettingsSection.autoImport.title) }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        for f in [watched, destination] { f.lineBreakMode = .byTruncatingMiddle; f.font = .systemFont(ofSize: 12); f.textColor = Studio.secondary; f.widthAnchor.constraint(lessThanOrEqualToConstant: 190).isActive = true }
        folders.addItems(withTitles: ImportSettings.folderTemplates.map { $0.isEmpty ? "No subfolders" : $0 })
        mode.addItems(withTitles: ["Move into the library", "Copy (leave the originals)"])
        for c in [folders, mode] as [NSControl] { c.target = self; c.action = #selector(changed) }
        keywords.placeholderString = "Optional, separated by commas"; keywords.target = self; keywords.action = #selector(changed)
        keywords.widthAnchor.constraint(equalToConstant: 220).isActive = true; keywords.setAccessibilityLabel("Keywords to add")
        status.font = .systemFont(ofSize: 11); status.textColor = Studio.secondary
        group(nil, [row("Auto Import", [status, enabled], detail: "Photos saved into the watched folder, for example by tethering software, are added to the library while OpenStill is open.")])
        group("Folders", [
            row("Watched folder", [watched, button("Choose…", #selector(pickWatched))]),
            row("Destination", [destination, button("Choose…", #selector(pickDestination))]),
            row("Subfolders", [folders]),
            row("Files", [mode]),
        ])
        group("When importing", [row("Add keywords", [keywords])], note: "Nothing leaves this Mac.")
    }
    override func refresh() {
        guard isViewLoaded else { return }
        settings = AutoImport.load()
        enabled.state = settings.enabled ? .on : .off
        watched.stringValue = settings.watched.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Not chosen"
        destination.stringValue = settings.destination.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Not chosen"
        folders.selectItem(at: ImportSettings.folderTemplates.firstIndex(of: settings.folderTemplate) ?? 0)
        mode.selectItem(at: settings.move ? 0 : 1); keywords.stringValue = settings.metadata?.keywords.joined(separator: ", ") ?? ""
        showStatus()
    }
    private func showStatus() {
        status.stringValue = !settings.enabled ? "Off" : settings.isReady ? "Watching \(settings.watched?.lastPathComponent ?? "")" : "Choose both folders"
        status.textColor = settings.enabled && !settings.isReady ? .systemOrange : Studio.secondary
    }
    /// Every change is saved at once, and the watcher restarts with it.
    @objc private func changed() {
        settings.enabled = enabled.state == .on
        settings.folderTemplate = ImportSettings.folderTemplates[max(0, folders.indexOfSelectedItem)]; settings.move = mode.indexOfSelectedItem == 0
        let words = IPTCMetadata.parseKeywords(keywords.stringValue)
        if words.isEmpty { settings.metadata = nil } else { var m = settings.metadata ?? IPTCMetadata(); m.keywords = words; settings.metadata = m }
        do { try AutoImport.save(settings); saved?(settings); showStatus() }
        catch { status.stringValue = error.localizedDescription; status.textColor = .systemRed }
    }
    private func choose(_ done: @escaping (URL) -> Void) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { if $0 == .OK, let url = panel.url { done(url) } }
    }
    @objc private func pickWatched() { choose { [weak self] url in self?.settings.watched = url; self?.watched.stringValue = (url.path as NSString).abbreviatingWithTildeInPath; self?.changed() } }
    @objc private func pickDestination() { choose { [weak self] url in self?.settings.destination = url; self?.destination.stringValue = (url.path as NSString).abbreviatingWithTildeInPath; self?.changed() } }
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

private final class ShortcutSettings: SettingsPage, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Row { case group(String), command(ShortcutCommand) }
    private let table = NSTableView()
    private let search = NSSearchField()
    private let status = settingsNote("")
    private var rows: [Row] = []
    private static let groupOrder = ["App", "File", "Edit", "View", "Window", "Workspace", "Library grid", "Photo and filmstrip"]
    init() { super.init(title: SettingsSection.shortcuts.title) }
    required init?(coder: NSCoder) { fatalError() }

    // The shortcut list scrolls on its own, so this page doesn't use the scrolling page layout.
    override func loadView() {
        let heading = NSTextField(labelWithString: title ?? ""); heading.font = .systemFont(ofSize: 20, weight: .semibold); heading.textColor = Studio.text
        search.placeholderString = "Search commands or keys, e.g. “export” or “⌘E”"; search.delegate = self
        search.setAccessibilityLabel("Search shortcuts")
        let column = NSTableColumn(identifier: .init("row")); column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.headerView = nil; table.dataSource = self; table.delegate = self; table.rowHeight = 34; table.selectionHighlightStyle = .none
        table.style = .plain; table.backgroundColor = .clear; table.usesAlternatingRowBackgroundColors = false; table.intercellSpacing = NSSize(width: 0, height: 0)
        table.gridStyleMask = []; table.setAccessibilityLabel("Keyboard shortcuts")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder; scroll.drawsBackground = false
        let restore = NSButton(title: "Restore All Defaults", target: self, action: #selector(restoreAll)); restore.bezelStyle = .rounded
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [status, spacer, restore]); footer.spacing = 8
        let intro = settingsNote("Click a shortcut, then press the new keys. Delete removes a shortcut; Escape cancels. Library and photo keys can be single keys; menu shortcuts need ⌘, ⌃ or ⌥ (or a function key).")
        let stack = NSStackView(views: [heading, intro, search, hairline(), scroll, hairline(), footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 44, left: Studio.inset + 4, bottom: 16, right: Studio.inset + 4)
        stack.setCustomSpacing(14, after: heading); stack.setCustomSpacing(0, after: scroll)
        for v in [intro, search, scroll, footer] as [NSView] { v.widthAnchor.constraint(equalToConstant: Self.width).isActive = true }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        view = stack
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
            let label = NSTextField(labelWithString: name.uppercased()); label.font = .systemFont(ofSize: 11, weight: .semibold); label.textColor = Studio.tertiary
            return label
        case .command(let command):
            let title = NSTextField(labelWithString: command.title); title.lineBreakMode = .byTruncatingTail; title.font = .systemFont(ofSize: 13); title.textColor = Studio.text
            let recorder = ShortcutRecorder(); recorder.commandTitle = command.title
            recorder.combo = Shortcuts.map.combo(for: command.id); recorder.customized = Shortcuts.map.isCustomized(command.id)
            recorder.recorded = { [weak self] combo in self?.assign(combo, to: command) ?? false }
            let reset = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.backward.circle.fill", accessibilityDescription: "Reset \(command.title) to its default")!, target: self, action: #selector(resetOne(_:)))
            reset.isBordered = false; reset.contentTintColor = .secondaryLabelColor; reset.identifier = .init(command.id)
            reset.toolTip = "Back to " + (command.defaultCombo?.display ?? "no shortcut"); reset.isHidden = !Shortcuts.map.isCustomized(command.id)
            let line = NSStackView(views: [title, NSView(), recorder, reset]); line.spacing = 10; line.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 2)
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
