import AppKit
import OpenStillCore

// MARK: - Book

/// The Book module: pages of one, two or four photos with captions, laid out automatically and changed page by page, saved as a PDF.
final class BookWindow: OutputWindow {
    private var document = BookEngine.load()
    private let pages = NSStackView(), preview = NSImageView(), pageLabel = NSTextField(labelWithString: "")
    private lazy var paper = popup(BookDocument.papers.map(\.name))
    private lazy var template = popup(BookTemplate.allCases.map(\.title))
    private var selected = 0
    private var thumbnails: [UUID: CGImage] = [:]
    private let queue = OperationQueue()
    private var byID: [UUID: ShootItem] { Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

    init(items: [ShootItem]) {
        let side = NSStackView(); side.orientation = .vertical; side.spacing = 6
        super.init(title: "Book · OpenStill", items: items, size: NSSize(width: 1040, height: 700), content: side)
        queue.maxConcurrentOperationCount = 2
        preview.imageScaling = .scaleProportionallyUpOrDown; preview.wantsLayer = true; preview.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        preview.widthAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true; preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true
        preview.setAccessibilityLabel("Preview of the selected page")
        pageLabel.font = .systemFont(ofSize: 11); pageLabel.textColor = .secondaryLabelColor
        side.addArrangedSubview(preview); side.addArrangedSubview(pageLabel)
        pages.orientation = .vertical; pages.alignment = .leading; pages.spacing = 8
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = FlippedStack(); document.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(pages); pages.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([pages.topAnchor.constraint(equalTo: document.topAnchor), pages.leadingAnchor.constraint(equalTo: document.leadingAnchor), pages.trailingAnchor.constraint(equalTo: document.trailingAnchor), pages.bottomAnchor.constraint(equalTo: document.bottomAnchor)])
        scroll.documentView = document; document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 470).isActive = true; scroll.heightAnchor.constraint(equalToConstant: 420).isActive = true
        row("Page size", paper); row("Layout", template)
        let auto = NSButton(title: "Auto Layout", target: self, action: #selector(autoLayout)); auto.bezelStyle = .rounded
        let add = NSButton(title: "Add page", target: self, action: #selector(addPage)); add.bezelStyle = .rounded
        let actions = NSStackView(views: [auto, add]); actions.spacing = 8
        row("", actions); row("Pages", scroll)
        button("Save PDF…", #selector(savePDF), primary: true)
        paper.selectItem(at: BookDocument.papers.firstIndex { $0.name == self.document.paper.name } ?? 0)
        let known = Set(items.map(\.id))
        if self.document.pages.isEmpty || !self.document.pages.flatMap({ $0.photos.compactMap { $0 } }).allSatisfy(known.contains) { self.document.pages = BookEngine.autoLayout(items.map(\.id), template: .single) }
        status.stringValue = "\(items.count) photo\(items.count == 1 ? "" : "s"). Auto Layout fills pages in order; choose a photo for any spot to change it. The book is saved as a PDF on this Mac."
        loadThumbnails(); rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func changed() {
        document.paper = BookDocument.papers[max(0, paper.indexOfSelectedItem)]
        save(); refreshPreview()
    }
    private func save() { try? BookEngine.save(document) }
    @objc private func autoLayout() {
        document.pages = BookEngine.autoLayout(items.map(\.id), template: BookTemplate.allCases[max(0, template.indexOfSelectedItem)])
        selected = 0; save(); rebuild()
    }
    @objc private func addPage() { document.pages.append(BookPage(template: BookTemplate.allCases[max(0, template.indexOfSelectedItem)])); selected = document.pages.count - 1; save(); rebuild() }
    /// One row per page: its layout, a photo menu per spot, the caption, and move / remove.
    private func rebuild() {
        pages.arrangedSubviews.forEach { pages.removeArrangedSubview($0); $0.removeFromSuperview() }
        let names = items.map(\.url.lastPathComponent)
        for (index, page) in document.pages.enumerated() {
            let title = NSButton(title: "Page \(index + 1)", target: self, action: #selector(selectPage(_:))); title.tag = index; title.bezelStyle = .rounded; title.controlSize = .small
            if index == selected { title.state = .on; title.setButtonType(.pushOnPushOff) }
            let layout = NSPopUpButton(); layout.controlSize = .small; layout.addItems(withTitles: BookTemplate.allCases.map(\.title))
            layout.selectItem(at: BookTemplate.allCases.firstIndex(of: page.template) ?? 0); layout.tag = index; layout.target = self; layout.action = #selector(pageTemplate(_:))
            var slots: [NSView] = []
            for (slot, id) in page.photos.enumerated() {
                let pick = NSPopUpButton(); pick.controlSize = .small; pick.addItem(withTitle: "Empty"); pick.addItems(withTitles: names)
                pick.selectItem(at: id.flatMap { id in items.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0)
                pick.tag = index * 10 + slot; pick.target = self; pick.action = #selector(pagePhoto(_:)); pick.setAccessibilityLabel("Page \(index + 1) photo \(slot + 1)")
                pick.widthAnchor.constraint(lessThanOrEqualToConstant: 140).isActive = true; slots.append(pick)
            }
            let caption = NSTextField(string: page.caption); caption.placeholderString = "Caption"; caption.controlSize = .small; caption.tag = index
            caption.target = self; caption.action = #selector(pageCaption(_:)); caption.widthAnchor.constraint(equalToConstant: 150).isActive = true
            let up = NSButton(title: "↑", target: self, action: #selector(movePage(_:))); up.tag = index * 2; up.bezelStyle = .rounded; up.controlSize = .small; up.setAccessibilityLabel("Move page \(index + 1) up")
            let down = NSButton(title: "↓", target: self, action: #selector(movePage(_:))); down.tag = index * 2 + 1; down.bezelStyle = .rounded; down.controlSize = .small; down.setAccessibilityLabel("Move page \(index + 1) down")
            let remove = NSButton(title: "✕", target: self, action: #selector(removePage(_:))); remove.tag = index; remove.bezelStyle = .rounded; remove.controlSize = .small; remove.setAccessibilityLabel("Remove page \(index + 1)")
            let top = NSStackView(views: [title, layout, caption, up, down, remove]); top.spacing = 4
            let photos = NSStackView(views: slots); photos.spacing = 4
            let block = NSStackView(views: [top, photos]); block.orientation = .vertical; block.alignment = .leading; block.spacing = 4
            pages.addArrangedSubview(block)
        }
        refreshPreview()
    }
    @objc private func selectPage(_ sender: NSButton) { selected = sender.tag; rebuild() }
    @objc private func pageTemplate(_ sender: NSPopUpButton) {
        guard document.pages.indices.contains(sender.tag) else { return }
        let old = document.pages[sender.tag]
        document.pages[sender.tag] = BookPage(template: BookTemplate.allCases[max(0, sender.indexOfSelectedItem)], photos: old.photos)
        document.pages[sender.tag].caption = old.caption; selected = sender.tag; save(); rebuild()
    }
    @objc private func pagePhoto(_ sender: NSPopUpButton) {
        let page = sender.tag / 10, slot = sender.tag % 10
        guard document.pages.indices.contains(page), document.pages[page].photos.indices.contains(slot) else { return }
        document.pages[page].photos[slot] = sender.indexOfSelectedItem == 0 ? nil : items[sender.indexOfSelectedItem - 1].id
        selected = page; save(); refreshPreview()
    }
    @objc private func pageCaption(_ sender: NSTextField) {
        guard document.pages.indices.contains(sender.tag) else { return }
        document.pages[sender.tag].caption = sender.stringValue; selected = sender.tag; save(); refreshPreview()
    }
    @objc private func movePage(_ sender: NSButton) {
        let index = sender.tag / 2, target = index + (sender.tag % 2 == 0 ? -1 : 1)
        guard document.pages.indices.contains(index), document.pages.indices.contains(target) else { return }
        document.pages.swapAt(index, target); selected = target; save(); rebuild()
    }
    @objc private func removePage(_ sender: NSButton) {
        guard document.pages.indices.contains(sender.tag) else { return }
        document.pages.remove(at: sender.tag); selected = max(0, min(selected, document.pages.count - 1)); save(); rebuild()
    }
    /// Small renders for the page preview.
    private func loadThumbnails() {
        for item in items {
            let request = RenderRequest(photo: item.record, profile: .displayP3, maximumDimension: 420)
            queue.addOperation { [weak self] in
                let image = PreviewCache.read(request) ?? (try? ModernRenderer.display(ModernRenderer.render(source: item.url, recipe: item.record.active.recipe.sdr, maximumDimension: 420)))
                DispatchQueue.main.async { guard let self, let image else { return }; self.thumbnails[item.id] = image; self.refreshPreview() }
            }
        }
    }
    private func refreshPreview() {
        pageLabel.stringValue = document.pages.isEmpty ? "No pages" : "Page \(selected + 1) of \(document.pages.count) · \(document.paper.name)"
        guard document.pages.indices.contains(selected) else { preview.image = nil; return }
        let page = document.pages[selected], size = NSSize(width: document.paper.width, height: document.paper.height)
        preview.image = NSImage(size: size, flipped: false) { [document, thumbnails] rect in
            NSColor.white.setFill(); rect.fill()
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            let cells = BookEngine.cells(page.template, document: document, caption: !page.caption.isEmpty)
            for (cell, id) in zip(cells, page.photos) {
                guard let id, let image = thumbnails[id] else { NSColor(white: 0.9, alpha: 1).setFill(); cell.fill(); continue }
                context.saveGState(); context.clip(to: cell)
                context.draw(image, in: BookEngine.fill(CGSize(width: image.width, height: image.height), in: cell)); context.restoreGState()
            }
            if !page.caption.isEmpty {
                let text = NSAttributedString(string: page.caption, attributes: [.font: NSFont(name: "Helvetica", size: 11) ?? .systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.2, alpha: 1)])
                text.draw(at: NSPoint(x: (rect.width - text.size().width) / 2, y: document.margin))
            }
            return true
        }
    }
    @objc private func savePDF() {
        guard let window, !document.pages.isEmpty else { status.stringValue = "Add pages first."; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = document.title + ".pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.busy = true; self.status.stringValue = "Rendering the book…"
            let document = self.document, lookup = self.byID
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { () -> Int in
                    var images: [UUID: CGImage] = [:]
                    // About 300 dpi for the largest spot on the page.
                    let edge = Int(max(document.paper.width, document.paper.height) / 72 * 300)
                    for id in Set(document.pages.flatMap { $0.photos.compactMap { $0 } }) {
                        guard let item = lookup[id] else { continue }
                        images[id] = try autoreleasepool { try ModernRenderer.display(ModernRenderer.render(source: item.url, recipe: item.record.active.recipe.sdr, maximumDimension: edge), profile: .sRGB) }
                    }
                    try BookEngine.pdf(document, images: images, to: url)
                    return document.pages.count
                }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let n): self?.finish("Saved a \(n)-page PDF. Your photos and edits are unchanged."); NSWorkspace.shared.activateFileViewerSelecting([url])
                    case .failure(let error): self?.finish(error.localizedDescription)
                    }
                }
            }
        }
    }
    func windowWillClose(_ notification: Notification) { queue.cancelAllOperations() }
}
private final class FlippedStack: NSView { override var isFlipped: Bool { true } }

// MARK: - Second display

/// A second window (on another screen when there is one) that follows the main window's selection, like Lightroom's Secondary Display.
final class SecondaryDisplayWindow: NSWindowController, NSWindowDelegate {
    private let stage = LibraryStage()
    private let mode = NSSegmentedControl(labels: ["Loupe", "Compare", "Survey"], trackingMode: .selectOne, target: nil, action: nil)
    private var items: [ShootItem] = []
    var closed: (() -> Void)?
    init() {
        let screen = NSScreen.screens.count > 1 ? NSScreen.screens[1] : NSScreen.main
        let frame = screen?.visibleFrame.insetBy(dx: 40, dy: 40) ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Secondary Display · OpenStill"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let root = NSView(); root.wantsLayer = true; root.layer?.backgroundColor = LRColors.canvas.cgColor; window.contentView = root
        mode.selectedSegment = 0; mode.target = self; mode.action = #selector(modeChanged); mode.controlSize = .small; mode.setAccessibilityLabel("Secondary display view")
        for v in [stage, mode] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            mode.topAnchor.constraint(equalTo: root.topAnchor, constant: 8), mode.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stage.topAnchor.constraint(equalTo: mode.bottomAnchor, constant: 8), stage.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: root.trailingAnchor), stage.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        if let screen { window.setFrame(frame, display: false); if NSScreen.screens.count > 1 { window.setFrameOrigin(screen.visibleFrame.origin) } }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func modeChanged() { show(items, force: true) }
    /// Shows the main window's selection.
    func show(_ selection: [ShootItem], force: Bool = false) {
        guard force || selection.map(\.id) != items.map(\.id) else { return }
        items = selection
        let m: LibraryViewMode = [LibraryViewMode.loupe, .compare, .survey][max(0, mode.selectedSegment)]
        stage.show(m == .loupe ? Array(selection.prefix(1)) : selection, mode: m, active: selection.first?.id)
    }
    func windowWillClose(_ notification: Notification) { stage.stop(); closed?() }
}
