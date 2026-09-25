import AppKit

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
    private let stack = LibraryStack()
    private var folder: URL?
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
    func update(folder: URL?, count: Int) {
        if let folder, folder != self.folder {
            recent.removeAll { $0 == folder }; recent.insert(folder, at: 0); recent = Array(recent.prefix(8))
            UserDefaults.standard.set(recent.map(\.path), forKey: "OpenStillRecentFolders")
        }
        self.folder = folder
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        heading("Local", size: 19)
        label("Your photos, on this Mac.")
        let add = button("Open folder…", symbol: "folder.badge.plus", action: #selector(openFolder)); Appearance.primary(add)
        heading("Current Folder")
        label(folder?.lastPathComponent ?? "No folder open", emphasized: true)
        if let folder { label(folder.path); button("Show in Finder", symbol: "arrow.up.forward.square", action: #selector(reveal)) }
        button("All photos · \(count)", symbol: "photo.on.rectangle", action: #selector(filterPhotos(_:)), tag: 0)
        button("Picks", symbol: "flag", action: #selector(filterPhotos(_:)), tag: 1)
        button("Rejected", symbol: "flag.slash", action: #selector(filterPhotos(_:)), tag: 2)
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
    @objc private func openRecent(_ sender: NSButton) { guard recent.indices.contains(sender.tag) else { return }; open?(recent[sender.tag]) }
}
