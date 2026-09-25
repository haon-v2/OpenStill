import AppKit
import OpenStillCore

final class FilmstripItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("photo")
    private let preview = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    var url: URL?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.translatesAutoresizingMaskIntoConstraints = false
        caption.font = .systemFont(ofSize: 10)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle
        caption.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(preview)
        view.addSubview(caption)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            preview.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5),
            preview.heightAnchor.constraint(equalToConstant: 64),
            caption.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 5),
            caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3),
            caption.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3)
        ])
    }
    override var isSelected: Bool { didSet { updateSelection() } }
    private func updateSelection() {
        view.layer?.borderWidth = isSelected ? 1 : 0
        view.layer?.borderColor = Appearance.accent.cgColor
        view.layer?.backgroundColor = isSelected ? Appearance.accent.withAlphaComponent(0.10).cgColor : NSColor.clear.cgColor
    }
    func configure(_ url: URL, store: PhotoStore) {
        self.url = url
        caption.stringValue = url.lastPathComponent
        view.toolTip = url.lastPathComponent
        view.setAccessibilityLabel(url.lastPathComponent)
        preview.imageScaling = .scaleProportionallyDown
        preview.image = Appearance.symbol("photo", size: 26, description: "Loading thumbnail")
        updateSelection()
        store.load(url, thumbnail: true) { [weak self] result in
            guard let self, self.url == url else { return }
            switch result {
            case .success(let photo): self.preview.imageScaling = .scaleProportionallyUpOrDown; self.preview.image = NSImage(cgImage: photo.image, size: .zero)
            case .failure: self.preview.image = Appearance.symbol("exclamationmark.triangle", size: 26, description: "Unreadable image")
            }
        }
    }
}

final class NavigationCollectionView: NSCollectionView {
    private var photos = PhotoSelection()
    var navigate: ((Int) -> Void)?
    var selectionChanged: ((Int?) -> Void)?
    var requestTrash: (() -> Void)?
    var photoMenu: ((Int) -> NSMenu?)?
    func selectSingle(_ index: Int) {
        photos.click(index)
        selectionIndexPaths = [IndexPath(item: index, section: 0)]
    }
    func selectEveryPhoto(count: Int) {
        photos.selectAll(count: count)
        applyPhotoSelection()
    }
    private func applyPhotoSelection() {
        selectionIndexPaths = Set(photos.indices.map { IndexPath(item: $0, section: 0) })
        selectionChanged?(photos.active)
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        guard let index = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self)
        photos.click(index.item, extending: event.modifierFlags.contains(.shift), toggling: event.modifierFlags.contains(.command))
        applyPhotoSelection()
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = indexPathForItem(at: point) else { return nil }
        return photoMenu?(index.item)
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.shift), [123, 124, 125, 126].contains(event.keyCode) {
            photos.extend(by: [123, 126].contains(event.keyCode) ? -1 : 1, count: numberOfItems(inSection: 0))
            applyPhotoSelection()
            return
        }
        switch event.keyCode {
        case 51, 117:
            if !event.isARepeat { requestTrash?() }
        case 123, 126: navigate?(-1)
        case 124, 125: navigate?(1)
        default: super.keyDown(with: event)
        }
    }
}
