import AppKit
import CryptoKit
import OpenStillCore

/// A notice over the photo when its original can't be found: where it was, and a way to point to it.
final class MissingOriginalBanner: NSView {
    private let text = NSTextField(wrappingLabelWithString: "")
    var locate: (() -> Void)?
    init() {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 8; layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Original not found") ?? NSImage())
        icon.contentTintColor = .systemOrange
        text.font = .systemFont(ofSize: 12); text.textColor = .white; text.maximumNumberOfLines = 3
        let button = NSButton(title: "Locate…", target: self, action: #selector(locateClicked)); button.controlSize = .small; button.bezelStyle = .rounded
        let row = NSStackView(views: [icon, text, button]); row.alignment = .centerY; row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor), row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     text.widthAnchor.constraint(lessThanOrEqualToConstant: 520)])
        setAccessibilityElement(true); setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ message: String) { text.stringValue = message; setAccessibilityLabel(message); toolTip = message }
    @objc private func locateClicked() { locate?() }
}

extension ViewerController {
    // MARK: The look of recently worked-on photos

    /// Keeps the photo's settled look in the library cache, so it still shows while its drive is away.
    func cacheLook(_ image: CGImage) {
        guard let record = photoRecord, let source = currentSource, FileManager.default.fileExists(atPath: source.path) else { return }
        let edits = (try? JSONEncoder().encode(currentEdits)) ?? Data()
        let revision = record.active.id.uuidString + "-" + SHA256.hash(data: edits).prefix(12).map { String(format: "%02x", $0) }.joined()
        let id = record.id
        DispatchQueue.global(qos: .utility).async {
            guard LibraryCache.revision(of: id) != revision else { return }
            LibraryCache.store(image, for: id, revision: revision)
            if Int.random(in: 0..<25) == 0, let catalog = EditStorage.records.catalog { LibraryCache.prune(keeping: catalog.recent(limit: LibraryCache.limit)) }
        }
    }
    /// Remembers a photo as just opened, for Catalog → Recent.
    func noteRecent() {
        guard let id = photoRecord?.id else { return }
        DispatchQueue.global(qos: .utility).async { EditStorage.records.catalog?.touchRecent(id) }
    }

    // MARK: Missing originals

    /// Whether the original is missing and has no Smart Preview to edit, so only its cached look can be shown.
    func isUnavailable(_ url: URL) -> Bool { !FileManager.default.fileExists(atPath: url.path) && SmartPreviews.stand(in: url) == nil }

    /// Shows the photo's cached look (view only) and says where the original was.
    func showMissingOriginal(_ url: URL) {
        let cached = photoRecord.flatMap { LibraryCache.image(for: $0.id) } ?? photoRecord.flatMap { record in PreviewCache.read(RenderRequest(photo: record, profile: .displayP3, maximumDimension: 420)) }
        if let cached {
            canvas.image = nil; canvas.replaceRenderedImage(cached, pixelSize: CGSize(width: cached.width, height: cached.height)); canvas.message = ""
        } else {
            canvas.message = "\(url.lastPathComponent) can’t be found, and there’s no cached preview of it yet."
        }
        info.update(currentEdits, document: editDocument, enabled: false)
        showMissingBanner(for: url, cached: cached != nil)
    }
    func showMissingBanner(for url: URL, cached: Bool, smartPreview: Bool = false) {
        let banner = missingBanner ?? {
            let b = MissingOriginalBanner(); b.translatesAutoresizingMaskIntoConstraints = false; canvas.addSubview(b)
            NSLayoutConstraint.activate([b.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 12), b.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
                                         b.widthAnchor.constraint(lessThanOrEqualTo: canvas.widthAnchor, constant: -32)])
            missingBanner = b; return b
        }()
        banner.locate = { [weak self] in self?.locateOriginal(url) }
        let place = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        let when = photoRecord.flatMap { LibraryCache.date(of: $0.id) }.map { " from " + DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? ""
        let detail = smartPreview ? "Editing its Smart Preview; your edits apply to the original when it’s back."
            : cached ? "Showing the cached preview\(when). Connect the drive or card to edit it." : "Connect the drive or card, or locate the file."
        banner.show("The original isn’t available: \(place)/\(url.lastPathComponent). \(detail)")
        banner.isHidden = false
    }
    func hideMissingBanner() { missingBanner?.isHidden = true }

    /// Locate…: points the catalog to the file's new place. Other missing photos from the same folder that are in the
    /// chosen file's folder are relinked with it.
    func locateOriginal(_ url: URL) {
        guard let window = view.window, let record = photoRecord else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Find “\(url.lastPathComponent)”"; panel.prompt = "Locate"
        let start = url.deletingLastPathComponent()
        panel.directoryURL = FileManager.default.fileExists(atPath: start.path) ? start : FileManager.default.homeDirectoryForCurrentUser
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let chosen = panel.url else { return }
            self?.statusBar.show("Checking \(chosen.lastPathComponent)…", busy: true)
            DispatchQueue.global(qos: .userInitiated).async {
                let same = (try? PhotoRecordStore.contentHash(chosen)) == record.contentFingerprint
                var moves: [RelinkPlan.Move] = []
                if same, let catalog = EditStorage.records.catalog {
                    moves = [RelinkPlan.Move(id: record.id, from: url.path, to: chosen.standardizedFileURL.path)]
                    let others = LibraryRelocator.plan(from: url.deletingLastPathComponent().path, to: chosen.deletingLastPathComponent().standardizedFileURL.path, locations: catalog.locations())
                    moves += others.filter { $0.id != record.id }
                }
                let moved = same ? LibraryRelocator.apply(moves) : 0
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard same else {
                        let alert = NSAlert(); alert.messageText = "That’s a different photo"
                        alert.informativeText = "“\(chosen.lastPathComponent)” doesn’t have the same contents as the original, so it wasn’t linked."
                        alert.beginSheetModal(for: window); self.statusBar.show("", busy: false); return
                    }
                    self.statusBar.show("Relinked \(moved) photo\(moved == 1 ? "" : "s").", busy: false)
                    self.photosRelinked(moves)
                }
            }
        }
    }

    /// Find Missing Folder…: choose where a folder went; its photos relink to the same files there.
    func findMissingFolder(_ folder: URL) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Where is “\(folder.lastPathComponent)” now?"; panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let chosen = panel.url, let catalog = EditStorage.records.catalog else { return }
            self?.statusBar.show("Looking for the photos of “\(folder.lastPathComponent)”…", busy: true)
            DispatchQueue.global(qos: .userInitiated).async {
                let moves = LibraryRelocator.plan(from: folder.standardizedFileURL.path, to: chosen.standardizedFileURL.path, locations: catalog.locations())
                let moved = LibraryRelocator.apply(moves)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if moved == 0 {
                        self.statusBar.show("", busy: false)
                        let alert = NSAlert(); alert.messageText = "No photos found there"
                        alert.informativeText = "None of the missing photos from “\(folder.lastPathComponent)” are in “\(chosen.lastPathComponent)” with the same names and sizes."
                        alert.beginSheetModal(for: window); return
                    }
                    self.statusBar.show("Found “\(folder.lastPathComponent)”: \(moved) photo\(moved == 1 ? "" : "s") relinked.", busy: false)
                    self.photosRelinked(moves)
                }
            }
        }
    }

    // MARK: Drives and cards coming and going

    /// Watches for drives and cards being connected; their photos relink to wherever the drive mounted.
    func startWatchingVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didRenameVolumeNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                self?.relinkVolumes(at: [url.standardizedFileURL.path])
            })
        }
        volumeObservers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            self?.librarySidebar.reloadFolders()
        })
        // Drives connected while OpenStill was closed.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            EditStorage.records.catalog?.recordMissingLocations()
            DispatchQueue.main.async { self?.relinkVolumes(at: nil) }
        }
    }
    /// Relinks the catalog's photos on these mounted drives (all drives when nil).
    func relinkVolumes(at roots: [String]?) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let catalog = EditStorage.records.catalog else { return }
            let volumes = MountedVolume.all().filter { roots?.contains($0.root) ?? true }
            // Only photos whose file is missing can move; checking once keeps this quick on large catalogs.
            let locations = catalog.locations().filter { !FileManager.default.fileExists(atPath: $0.path) }
            guard !locations.isEmpty else { DispatchQueue.main.async { self?.librarySidebar.reloadFolders() }; return }
            var automatic: [RelinkPlan.Move] = [], questions: [(MountedVolume, RelinkPlan)] = []
            for volume in volumes {
                let plan = LibraryRelocator.plan(for: volume, locations: locations)
                automatic += plan.automatic
                if !plan.suggested.isEmpty { questions.append((volume, plan)) }
            }
            let moved = LibraryRelocator.apply(automatic)
            DispatchQueue.main.async {
                guard let self else { return }
                if moved > 0 {
                    let names = Set(volumes.filter { v in automatic.contains { v.relative($0.to) != nil } }.map(\.name)).sorted().joined(separator: ", ")
                    self.statusBar.show("Reconnected “\(names)”: \(moved) photo\(moved == 1 ? "" : "s") relinked.", busy: false)
                    self.photosRelinked(automatic)
                } else { self.librarySidebar.reloadFolders() }
                for (volume, plan) in questions { self.askToRelink(volume, plan) }
            }
        }
    }
    private func askToRelink(_ volume: MountedVolume, _ plan: RelinkPlan) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Photos from “\(plan.suggestedFrom ?? "another drive")” found on “\(volume.name)”"
        alert.informativeText = "\(plan.suggested.count) photos in the library are missing, and files with the same names, places and sizes are on “\(volume.name)”. Relink them there?"
        alert.addButton(withTitle: "Relink \(plan.suggested.count) Photos"); alert.addButton(withTitle: "Not Now")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let moved = LibraryRelocator.apply(plan.suggested)
                DispatchQueue.main.async { self?.statusBar.show("Relinked \(moved) photos to “\(volume.name)”.", busy: false); self?.photosRelinked(plan.suggested) }
            }
        }
    }
    /// After relinking: open lists point to the new paths, the Folders panel and grid redraw, and a missing photo on screen opens.
    func photosRelinked(_ moves: [RelinkPlan.Move]) {
        guard !moves.isEmpty else { return }
        let map = Dictionary(moves.map { (URL(fileURLWithPath: $0.from).standardizedFileURL, URL(fileURLWithPath: $0.to)) }, uniquingKeysWith: { a, _ in a })
        func moved(_ url: URL) -> URL { map[url.standardizedFileURL] ?? url }
        let wasShowing = currentSource.map { map[$0.standardizedFileURL] != nil } ?? false
        urls = urls.map(moved); shootCatalog = shootCatalog.map(moved)
        photoTabs.rename(Dictionary(moves.map { ($0.from, $0.to) }, uniquingKeysWith: { a, _ in a })); photoTabs.save(root: EditStorage.root); tabStrip.show(photoTabs)
        if folderURL.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? false, let first = moves.first {
            folderURL = URL(fileURLWithPath: first.to).deletingLastPathComponent()
        }
        librarySidebar.reloadFolders()
        collection.reloadData()
        if isLibrary { libraryURLs = []; refreshLibrary() }
        if wasShowing && !isLibrary { hideMissingBanner(); select(selected, preservingSelection: true) }
    }

    // MARK: Catalog → Recent

    /// The photos you worked on most recently, newest first, including ones whose drive isn't connected.
    func openRecentPhotos() {
        guard let catalog = EditStorage.records.catalog else { return }
        let ids = catalog.recent(limit: LibraryCache.limit)
        let byID = Dictionary(catalog.photos(ids: Set(ids)).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let files = ids.compactMap { byID[$0] }.map { URL(fileURLWithPath: $0.path) }
        open(files, collection: PhotoCollection(id: Self.recentCollectionID, name: "Recent", smart: nil), keepOrder: true)
        showLibrary()
    }
    static let recentCollectionID = UUID(uuidString: "00000000-0000-0000-0000-00000000E0E0")!

    /// Opening a folder whose drive isn't connected: its photos come from the catalog and show their cached looks.
    func openOfflineFolder(_ folder: URL) {
        guard let catalog = EditStorage.records.catalog else { return }
        let files = catalog.photoPaths(under: folder.standardizedFileURL.path).map { URL(fileURLWithPath: $0) }
        open(files, collection: PhotoCollection(id: Self.offlineCollectionID, name: folder.lastPathComponent + " (not connected)", smart: nil))
        showLibrary()
    }
    static let offlineCollectionID = UUID(uuidString: "00000000-0000-0000-0000-00000000E0E1")!
}
