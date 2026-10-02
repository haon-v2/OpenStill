import AppKit
import OpenStillCore

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, symbol: String? = nil, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
        if let symbol { image = Appearance.symbol(symbol) }
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func runAction() { run() }
}

/// The right-click menu for photos, the same in the library grid, the filmstrip and on the photo:
/// open in Develop, Open With, Edit In, Show in Finder, Show in Folder, rating, flag, label, Share and Move to Trash.
extension ViewerController {
    func photoContextMenu(for urls: [URL]) -> NSMenu {
        let menu = NSMenu()
        let many = urls.count > 1, first = urls[0]
        if isLibrary { menu.addItem(ActionMenuItem("Open in Develop", symbol: "slider.horizontal.3") { [weak self] in self?.showEditor() }) }

        // Open With: the apps macOS offers for this kind of file, default first, plus any app you pick.
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: ""); let apps = NSMenu()
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: first)
        var offered = NSWorkspace.shared.urlsForApplications(toOpen: first).filter { $0.lastPathComponent != "OpenStill.app" }
        if let defaultApp, let i = offered.firstIndex(of: defaultApp) { offered.insert(offered.remove(at: i), at: 0) }
        for app in offered.prefix(20) {
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            let item = ActionMenuItem(app == defaultApp ? name + " (default)" : name) { Self.open(urls.map(VirtualCopy.file), with: app) }
            item.image = NSWorkspace.shared.icon(forFile: app.path); item.image?.size = NSSize(width: 16, height: 16)
            apps.addItem(item)
        }
        if !offered.isEmpty { apps.addItem(.separator()) }
        apps.addItem(ActionMenuItem("Other…") { [weak self] in self?.chooseAppToOpen(urls) })
        openWith.submenu = apps; menu.addItem(openWith)

        // Edit In: a 16-bit TIFF with your edits, stacked with the original (Photo → Edit In).
        let editIn = NSMenuItem(title: "Edit In", action: nil, keyEquivalent: ""); let editors = NSMenu()
        if let app = EditIn.load().appPath {
            let name = ((app as NSString).lastPathComponent as NSString).deletingPathExtension
            editors.addItem(ActionMenuItem("Edit in \(name)…") { [weak self] in self?.editInApp() })
        }
        editors.addItem(ActionMenuItem("Choose App…") { [weak self] in self?.editInOtherApp() })
        editIn.submenu = editors; menu.addItem(editIn)

        menu.addItem(ActionMenuItem(many ? "Create Virtual Copies" : "Create Virtual Copy", symbol: "plus.square.on.square") { [weak self] in self?.createVirtualCopy() })
        menu.addItem(.separator())
        let files = urls.map(VirtualCopy.file)
        menu.addItem(ActionMenuItem("Show in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting(files) })
        let folder = first.deletingLastPathComponent()
        menu.addItem(ActionMenuItem("Show in Folder “\(folder.lastPathComponent)”", symbol: "folder.badge.gearshape") { [weak self] in self?.showFolder(of: first) })

        menu.addItem(.separator())
        let rating = NSMenuItem(title: "Set Rating", action: nil, keyEquivalent: ""); let stars = NSMenu()
        for n in 0...5 { stars.addItem(ActionMenuItem(n == 0 ? "None" : String(repeating: "★", count: n)) { [weak self] in self?.mark(urls, rating: n) }) }
        rating.submenu = stars; menu.addItem(rating)
        let flag = NSMenuItem(title: "Set Flag", action: nil, keyEquivalent: ""); let flags = NSMenu()
        for (title, value) in [("Pick", PhotoFlag.pick), ("Reject", .reject), ("Unflagged", .none)] { flags.addItem(ActionMenuItem(title) { [weak self] in self?.mark(urls, flag: value) }) }
        flag.submenu = flags; menu.addItem(flag)
        let label = NSMenuItem(title: "Set Color Label", action: nil, keyEquivalent: ""); let labels = NSMenu()
        for value in ColorLabel.allCases { labels.addItem(ActionMenuItem(value.title) { [weak self] in self?.mark(urls, label: value) }) }
        label.submenu = labels; menu.addItem(label)

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(many ? "Share \(urls.count) Photos…" : "Share Photo…", symbol: "square.and.arrow.up") { [weak self] in self?.sharePhoto() })
        let allCopies = urls.allSatisfy(VirtualCopy.isCopy)
        menu.addItem(ActionMenuItem(allCopies ? (many ? "Remove \(urls.count) Virtual Copies…" : "Remove Virtual Copy…") : many ? "Move \(urls.count) Photos to Trash…" : "Move to Trash…", symbol: "trash") { [weak self] in
            guard let self else { return }
            if self.isLibrary, let items = self.libraryBrowser?.selectedItems { self.trashLibraryPhotos(items) } else { self.trashPhoto() }
        })
        return menu
    }

    private static func open(_ urls: [URL], with app: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
    private func chooseAppToOpen(_ urls: [URL]) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose an app to open " + (urls.count == 1 ? "this photo" : "these \(urls.count) photos") + " with. The original files are opened."
        panel.beginSheetModal(for: window) { response in if response == .OK, let app = panel.url { Self.open(urls, with: app) } }
    }
    /// Jumps the library to the folder a photo is in, with that photo selected.
    func showFolder(of url: URL) {
        open([url.deletingLastPathComponent()])
        showLibrary()
        withLibrary { browser in browser.select(url: url) }
    }
    private func mark(_ urls: [URL], rating: Int? = nil, flag: PhotoFlag? = nil, label: ColorLabel? = nil) {
        do {
            for url in urls {
                let record = try EditStorage.records.record(for: url)
                let updated = try ShootWorkflow.mark(record.id, rating: rating, flag: flag, label: label)
                if photoRecord?.id == updated.id { photoRecord = updated }
            }
            refreshLibrary(); updateControls()
        } catch { info.status(error.localizedDescription) }
    }
}
