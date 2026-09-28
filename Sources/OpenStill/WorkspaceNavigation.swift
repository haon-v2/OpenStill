import AppKit
import OpenStillCore

/// Compact native navigation for the library and editing sides of the workspace.
final class WorkspaceRail: GlassChrome {
    var choose: ((String) -> Void)?
    private var buttons: [String: ToolbarIconButton] = [:]
    init(items: [(String, String, String)]) {
        super.init(frame: .zero)
        cornerRadius = 16
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        for (id, title, symbol) in items {
            let button = ToolbarIconButton(title: title, target: self, action: #selector(clicked(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.image = Appearance.symbol(symbol, description: title)
            button.isBordered = false; button.imagePosition = .imageOnly; button.setButtonType(.toggle)
            button.toolTip = title; button.setAccessibilityLabel(title)
            button.widthAnchor.constraint(equalToConstant: 36).isActive = true
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
            buttons[id] = button; stack.addArrangedSubview(button)
        }
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10), stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
    func select(_ id: String?) {
        for (key, button) in buttons { button.state = key == id ? .on : .off; button.needsDisplay = true }
    }
    @objc private func clicked(_ sender: NSButton) { if let id = sender.identifier?.rawValue { choose?(id) } }
}

private final class LibraryStack: NSStackView { override var isFlipped: Bool { true } }
final class LibrarySidebar: GlassChrome {
    var open: ((URL) -> Void)?
    var browse: (() -> Void)?
    var filter: ((Int) -> Void)?
    var subfoldersChanged: ((Bool) -> Void)?
    var openCollection: ((PhotoCollection) -> Void)?
    var newSmartCollection: (() -> Void)?
    /// Lightroom layout: Publish Services opens the publish window.
    var publish: (() -> Void)?
    /// Lightroom Classic's Catalog, Folders, Collections and Publish Services sections instead of the Luminar list.
    var lightroom = false {
        didSet {
            guard lightroom != oldValue else { return }
            flatColor = lightroom ? LRColors.panel : nil
            stack.edgeInsets = lightroom ? NSEdgeInsets() : NSEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
            stack.spacing = lightroom ? 0 : 10
            reloadCollections()
            if lightroom { reloadFolders() }
        }
    }
    private let stack = LibraryStack()
    private var folder: URL?
    private var count = 0
    private var shownCollection: UUID?
    private var collections: [PhotoCollection] = []
    static let subfoldersKey = "OpenStillIncludeSubfolders"
    static var includeSubfolders: Bool { UserDefaults.standard.bool(forKey: subfoldersKey) }
    private var recent: [URL] = UserDefaults.standard.stringArray(forKey: "OpenStillRecentFolders")?.map { URL(fileURLWithPath: $0) } ?? []
    override init(frame: NSRect) {
        super.init(frame: frame)
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(scroll)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = stack
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor), scroll.topAnchor.constraint(equalTo: contentView.topAnchor), scroll.bottomAnchor.constraint(equalTo: contentView.bottomAnchor), stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        update(folder: nil, count: 0)
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Rebuilds the list after collections change, keeping the current folder or collection.
    func reloadCollections() { update(folder: folder, count: count, collection: shownCollection) }
    func update(folder: URL?, count: Int, collection: UUID? = nil) {
        if let folder, folder != self.folder {
            recent.removeAll { $0 == folder }; recent.insert(folder, at: 0); recent = Array(recent.prefix(8))
            UserDefaults.standard.set(recent.map(\.path), forKey: "OpenStillRecentFolders")
        }
        let reload = lightroom && folder != nil && folder != self.folder
        self.folder = folder; self.count = count; shownCollection = collection
        if reload { reloadFolders() }
        collections = EditStorage.records.catalog?.collections() ?? []
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        if lightroom { buildLightroom(collection: collection); return }
        heading("Local", size: 19)
        label("Your photos, on this Mac.")
        let openButton = button("Open folder…", symbol: "folder.badge.plus", action: #selector(openFolder)); Appearance.primary(openButton)
        let current = collections.first { $0.id == collection }
        heading(current == nil ? "Current Folder" : "Current Collection")
        label(current?.name ?? folder?.lastPathComponent ?? "No folder open", emphasized: true)
        if let folder, current == nil { label(folder.path); button("Show in Finder", symbol: "arrow.up.forward.square", action: #selector(reveal)) }
        let subfolders = NSButton(checkboxWithTitle: "Include subfolders", target: self, action: #selector(toggleSubfolders(_:)))
        subfolders.state = Self.includeSubfolders ? .on : .off; subfolders.font = .systemFont(ofSize: 11); add(subfolders)
        button("All photos · \(count)", symbol: "photo.on.rectangle", action: #selector(filterPhotos(_:)), tag: 0)
        button("Picks", symbol: "flag", action: #selector(filterPhotos(_:)), tag: 1)
        button("Rejected", symbol: "flag.slash", action: #selector(filterPhotos(_:)), tag: 2)
        heading("Collections")
        for (index, c) in collections.enumerated() {
            let b = button(c.name, symbol: c.isSmart ? "gearshape" : "rectangle.stack", action: #selector(chooseCollection(_:)), tag: index)
            b.state = c.id == collection ? .on : .off
            let menu = NSMenu()
            for (title, action) in [("Rename…", #selector(renameCollection(_:))), ("Delete…", #selector(deleteCollection(_:)))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.tag = index; menu.addItem(item)
            }
            b.menu = menu; b.toolTip = (c.isSmart ? "Smart collection" : "Collection") + " · Control-click to rename or delete"
        }
        if collections.isEmpty { label("Select photos, then choose Actions → Add to collection.") }
        button("New smart collection…", symbol: "plus.rectangle.on.rectangle", action: #selector(createSmartCollection))
        heading("Recent Folders")
        for (index, url) in recent.enumerated() {
            let b = button(url.lastPathComponent, symbol: "folder", action: #selector(openRecent(_:)), tag: index)
            b.toolTip = url.path
        }
        if recent.isEmpty { label("Folders you open appear here.") }
        Appearance.applyAccent(in: contentView)
    }
    private func add(_ view: NSView) { stack.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
    private func heading(_ text: String, size: CGFloat = 11) {
        let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: size, weight: .semibold)
        label.textColor = size > 11 ? .labelColor : .secondaryLabelColor
        if let previous = stack.arrangedSubviews.last { stack.setCustomSpacing(22, after: previous) }
        add(label)
    }
    private func label(_ text: String, emphasized: Bool = false) {
        let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: 11, weight: emphasized ? .medium : .regular)
        label.textColor = emphasized ? .labelColor : .secondaryLabelColor; label.maximumNumberOfLines = 3; label.lineBreakMode = .byTruncatingMiddle
        add(label)
    }
    @discardableResult private func button(_ title: String, symbol: String, action: Selector, tag: Int = 0) -> NSButton {
        let button = NSButton(title: title, target: self, action: action); button.tag = tag
        button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 12); button.image = Appearance.symbol(symbol, size: 13)
        button.imagePosition = .imageLeading; button.lineBreakMode = .byTruncatingMiddle; add(button); return button
    }
    @objc private func openFolder() { browse?() }
    @objc private func reveal() { if let folder { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path) } }
    @objc private func filterPhotos(_ sender: NSButton) { filter?(sender.tag) }
    @objc private func toggleSubfolders(_ sender: NSButton) { UserDefaults.standard.set(sender.state == .on, forKey: Self.subfoldersKey); subfoldersChanged?(sender.state == .on) }
    @objc private func chooseCollection(_ sender: NSButton) { guard collections.indices.contains(sender.tag) else { return }; openCollection?(collections[sender.tag]) }
    @objc private func createSmartCollection() { newSmartCollection?() }
    @objc private func renameCollection(_ sender: NSMenuItem) {
        guard collections.indices.contains(sender.tag), let window else { return }
        let c = collections[sender.tag], alert = NSAlert(); alert.messageText = "Rename collection"
        let field = NSTextField(string: c.name); field.frame = NSRect(x: 0, y: 0, width: 260, height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            try? EditStorage.records.catalog?.renameCollection(c.id, to: field.stringValue); self?.reloadCollections()
        }
    }
    @objc private func deleteCollection(_ sender: NSMenuItem) {
        guard collections.indices.contains(sender.tag), let window else { return }
        let c = collections[sender.tag], alert = NSAlert(); alert.messageText = "Delete “\(c.name)”?"
        alert.informativeText = "Only the collection is removed. The photos, their edits and the files stay."
        alert.addButton(withTitle: "Delete collection"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            try? EditStorage.records.catalog?.deleteCollection(c.id)
            if self?.shownCollection == c.id { self?.shownCollection = nil }
            self?.reloadCollections()
        }
    }
    // MARK: Lightroom Classic sections
    private func buildLightroom(collection: UUID?) {
        func section(_ title: String, open: Bool = true, _ fill: (LRSection) -> Void) {
            let s = LRSection(title, module: .library, side: .left, open: open); s.body.spacing = 0
            s.body.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
            fill(s); stack.addArrangedSubview(s); s.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let current = collections.first { $0.id == collection }
        section("Catalog") { s in
            s.add(row("All Photographs", count: count, action: #selector(filterPhotos(_:)), tag: 0))
            s.add(row("Picks", action: #selector(filterPhotos(_:)), tag: 1))
            s.add(row("Rejected", action: #selector(filterPhotos(_:)), tag: 2))
        }
        section("Folders") { s in
            if volumes.isEmpty {
                // Nothing in the catalog yet: the open folder and recent folders.
                if let folder {
                    let r = row(folder.lastPathComponent, count: current == nil ? count : nil, action: #selector(reveal), selected: current == nil, symbol: "folder.fill")
                    r.toolTip = folder.path + " · Click to show in Finder"; s.add(r)
                }
                for (index, url) in recent.enumerated() where url != folder {
                    let r = row(url.lastPathComponent, action: #selector(openRecent(_:)), tag: index, symbol: "folder"); r.toolTip = url.path; s.add(r)
                }
            }
            for volume in volumes {
                let r = folderRow(volume.name, path: volume.path, count: volume.count, indent: 0, hasChildren: !volume.folders.isEmpty,
                                  symbol: volume.path == "/" ? "internaldrive" : "externaldrive", dimmed: !volume.online, selected: false, in: s)
                r.toolTip = volume.online ? volume.path : volume.path + " · Not connected"
                if expanded(volume.path, default: true) { for node in volume.folders { addFolder(node, indent: 1, online: volume.online, collection: current, in: s) } }
            }
            let subfolders = NSButton(checkboxWithTitle: "Include Subfolders", target: self, action: #selector(toggleSubfolders(_:)))
            subfolders.state = Self.includeSubfolders ? .on : .off; subfolders.font = .systemFont(ofSize: 11); subfolders.controlSize = .small
            let holder = NSStackView(views: [subfolders]); holder.edgeInsets = NSEdgeInsets(top: 4, left: 26, bottom: 2, right: 8); s.add(holder)
            s.add(row("Add Folder…", action: #selector(openFolder), symbol: "plus"))
        }
        section("Collections") { s in
            for (index, c) in collections.enumerated() {
                let r = row(c.name, action: #selector(chooseCollection(_:)), tag: index, selected: c.id == collection, symbol: c.isSmart ? "gearshape" : "rectangle.stack")
                let menu = NSMenu()
                for (title, action) in [("Rename…", #selector(renameCollection(_:))), ("Delete…", #selector(deleteCollection(_:)))] {
                    let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.tag = index; menu.addItem(item)
                }
                r.menu = menu; r.toolTip = (c.isSmart ? "Smart collection" : "Collection") + " · Control-click to rename or delete"; s.add(r)
            }
            s.add(row("Create Smart Collection…", action: #selector(createSmartCollection), symbol: "plus"))
        }
        section("Publish Services") { s in s.add(row("Set Up Publishing…", action: #selector(publishServices), symbol: "square.and.arrow.up")) }
    }
    // MARK: Folders tree

    /// Show in Finder, Import into this folder, or Synchronize Folder, from a folder's right-click menu.
    var folderCommand: ((String, URL) -> Void)?
    private var volumes: [FolderVolume] = []
    private var folderLoad = UUID()
    private static let expandedKey = "OpenStillExpandedFolders", collapsedKey = "OpenStillCollapsedFolders"
    /// Reads the catalog's folders in the background, then redraws the panel.
    func reloadFolders() {
        let token = UUID(); folderLoad = token
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let volumes = FolderTree.volumes(EditStorage.records.catalog?.photoPaths() ?? [])
            DispatchQueue.main.async {
                guard let self, self.folderLoad == token else { return }
                self.volumes = volumes; if self.lightroom { self.reloadCollections() }
            }
        }
    }
    /// Drives start expanded, folders collapsed; either remembers what you last did.
    private func expanded(_ path: String, default open: Bool) -> Bool {
        let d = UserDefaults.standard
        return open ? !(d.stringArray(forKey: Self.collapsedKey) ?? []).contains(path) : (d.stringArray(forKey: Self.expandedKey) ?? []).contains(path)
    }
    private func setExpanded(_ path: String, _ value: Bool, default open: Bool) {
        let d = UserDefaults.standard, key = open ? Self.collapsedKey : Self.expandedKey
        var list = Set(d.stringArray(forKey: key) ?? [])
        if value == open { list.remove(path) } else { list.insert(path) }
        d.set(Array(list), forKey: key); reloadCollections()
    }
    private func addFolder(_ node: FolderNode, indent: Int, online: Bool, collection: PhotoCollection?, in s: LRSection) {
        let open = expanded(node.path, default: false)
        let r = folderRow(node.name, path: node.path, count: node.count, indent: indent, hasChildren: !node.children.isEmpty, symbol: open && !node.children.isEmpty ? "folder" : "folder.fill",
                          dimmed: !online, selected: collection == nil && folder?.standardizedFileURL.path == node.path, in: s)
        r.toolTip = node.path
        if open { for child in node.children { addFolder(child, indent: indent + 1, online: online, collection: collection, in: s) } }
    }
    @discardableResult private func folderRow(_ title: String, path: String, count: Int, indent: Int, hasChildren: Bool, symbol: String, dimmed: Bool, selected: Bool, in s: LRSection) -> LRListRow {
        let isVolume = indent == 0
        let open = expanded(path, default: isVolume)
        let r = LRListRow(title: title, count: count, symbol: symbol, selected: selected, indent: indent, disclosure: hasChildren ? open : nil, dimmed: dimmed)
        r.target = self; r.action = #selector(chooseFolder(_:)); r.identifier = .init(path)
        r.setAccessibilityLabel("\(title), \(count) photos" + (dimmed ? ", not connected" : ""))
        r.toggled = { [weak self] in self?.setExpanded(path, !open, default: isVolume) }
        let menu = NSMenu(), url = URL(fileURLWithPath: path, isDirectory: true)
        let items: [(String, String)] = [("Show in Finder", "finder"), ("Import to This Folder…", "import"), ("Synchronize Folder", "sync")]
        for (title, id) in items {
            let item = ActionMenuItem(title) { [weak self] in self?.folderCommand?(id, url) }
            item.isEnabled = !dimmed; menu.addItem(item)
        }
        if hasChildren {
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem(open ? "Collapse" : "Expand") { [weak self] in self?.setExpanded(path, !open, default: isVolume) })
        }
        menu.autoenablesItems = false
        r.menu = menu
        s.add(r)
        return r
    }
    @objc private func chooseFolder(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        guard FileManager.default.fileExists(atPath: path) else { NSSound.beep(); return }
        open?(URL(fileURLWithPath: path, isDirectory: true))
    }

    /// A flat Lightroom list row: icon, name, and a count on the right.
    private func row(_ title: String, count: Int? = nil, action: Selector, tag: Int = 0, selected: Bool = false, symbol: String? = nil) -> NSButton {
        let b = LRListRow(title: title, count: count, symbol: symbol, selected: selected)
        b.target = self; b.action = action; b.tag = tag; b.setAccessibilityLabel(count.map { "\(title), \($0) photos" } ?? title)
        return b
    }
    @objc private func publishServices() { publish?() }
    @objc private func openRecent(_ sender: NSButton) { guard recent.indices.contains(sender.tag) else { return }; open?(recent[sender.tag]) }
}

/// A row in Lightroom's left panel lists: highlighted when it's the current source.
/// Folder rows are indented by depth and have a disclosure triangle when they hold subfolders.
final class LRListRow: NSButton {
    private let label: String, count: Int?, symbol: String?, selected: Bool
    private let indent: Int, disclosure: Bool?, dimmed: Bool
    /// Clicking the triangle expands or collapses the row instead of choosing it.
    var toggled: (() -> Void)?
    init(title: String, count: Int?, symbol: String?, selected: Bool, indent: Int = 0, disclosure: Bool? = nil, dimmed: Bool = false) {
        label = title; self.count = count; self.symbol = symbol; self.selected = selected
        self.indent = indent; self.disclosure = disclosure; self.dimmed = dimmed
        super.init(frame: .zero)
        self.title = title; isBordered = false; heightAnchor.constraint(equalToConstant: 22).isActive = true
        if let disclosure { setAccessibilityExpanded(disclosure) }
    }
    required init?(coder: NSCoder) { fatalError() }
    private var start: CGFloat { 26 + CGFloat(indent) * 12 }
    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        if disclosure != nil, let toggled, x < start, x > start - 18 { toggled(); return }
        super.mouseDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        if selected || isHighlighted { NSColor(calibratedWhite: selected ? 0.34 : 0.28, alpha: 1).setFill(); bounds.fill() }
        var x = start
        let fraction: CGFloat = dimmed ? 0.35 : 0.7
        if let disclosure {
            let t = NSBezierPath(), cx = start - 9, cy = bounds.midY
            if disclosure { t.move(to: NSPoint(x: cx - 4, y: cy - 2)); t.line(to: NSPoint(x: cx + 4, y: cy - 2)); t.line(to: NSPoint(x: cx, y: cy + 3)) }
            else { t.move(to: NSPoint(x: cx - 2, y: cy - 4)); t.line(to: NSPoint(x: cx - 2, y: cy + 4)); t.line(to: NSPoint(x: cx + 3, y: cy)) }
            t.close(); LRColors.dim.setFill(); t.fill()
        }
        if let symbol, let image = Appearance.symbol(symbol, size: 11) {
            image.draw(in: NSRect(x: x, y: (bounds.height - 12) / 2, width: 13, height: 12), from: .zero, operation: .sourceOver, fraction: fraction, respectFlipped: true, hints: nil); x += 20
        }
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingMiddle
        let color = dimmed ? LRColors.dim : (selected ? LRColors.bright : LRColors.text)
        (label as NSString).draw(in: NSRect(x: x, y: (bounds.height - 15) / 2, width: bounds.width - x - 50, height: 15), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color, .paragraphStyle: style])
        if let count {
            let text = "\(count)" as NSString, attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: LRColors.dim]
            text.draw(at: NSPoint(x: bounds.width - 12 - text.size(withAttributes: attrs).width, y: (bounds.height - 13) / 2), withAttributes: attrs)
        }
    }
}
