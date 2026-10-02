import AppKit
import OpenStillCore

/// Virtual copies (Photo → Create Virtual Copy, ⌘'): another thumbnail of the same file with its own edits and rating.
extension ViewerController {
    /// The photos the command applies to: the Library selection, or the photo in Develop.
    private var chosenForCopy: [URL] {
        if isLibrary { return libraryBrowser?.selectedItems.map(\.url) ?? [] }
        return urls.indices.contains(selected) ? [urls[selected]] : []
    }
    @objc func createVirtualCopy() {
        flushPendingSave()
        let sources = chosenForCopy
        guard !sources.isEmpty else { NSSound.beep(); return }
        var made: [(after: URL, copy: URL)] = []
        for url in sources {
            guard let record = try? EditStorage.record(url), let copy = try? VirtualCopy.create(of: record) else { continue }
            made.append((url, copy.listURL))
        }
        guard !made.isEmpty else { statusBar.show("Couldn’t create a virtual copy.", busy: false); return }
        // Each copy goes after its original's last copy, so it shows beside it.
        func insert(_ list: inout [URL]) {
            for (after, copy) in made {
                let file = VirtualCopy.file(after).path
                guard let start = list.firstIndex(where: { $0.path == file }) else { continue }
                var end = start
                while end + 1 < list.count, list[end + 1].path == file { end += 1 }
                list.insert(copy, at: end + 1)
            }
        }
        insert(&urls); if !shootCatalog.isEmpty { insert(&shootCatalog) }
        libraryURLs = []
        collection.reloadData()
        if isLibrary { refreshLibrary() } else if let first = made.first, let index = urls.firstIndex(of: first.copy) { select(index) }
        statusBar.show(made.count == 1 ? "Created a virtual copy. It has its own edits, rating and flag; the file is shared." : "Created \(made.count) virtual copies.", busy: false)
    }
    /// Delete on virtual copies removes them from the library; the file and the original stay. Returns true when it handled the request.
    func removeVirtualCopies(_ list: [URL]) -> Bool {
        let copies = list.filter(VirtualCopy.isCopy)
        guard !copies.isEmpty else { return false }
        guard let window = view.window, window.attachedSheet == nil else { return true }
        let alert = NSAlert()
        let names = copies.compactMap { try? EditStorage.record($0) }.map { "\($0.copyName ?? "Virtual copy") of \(URL(fileURLWithPath: $0.sourcePath).lastPathComponent)" }
        alert.messageText = copies.count == 1 ? "Remove “\(names.first ?? "virtual copy")”?" : "Remove \(copies.count) virtual copies?"
        alert.informativeText = "Only the virtual cop\(copies.count == 1 ? "y and its edits are" : "ies and their edits are") removed. The photo file and the original stay as they are."
            + (copies.count < list.count ? "\n\nOriginals in the selection aren’t moved to the Trash by this; delete them separately." : "")
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: copies.count == 1 ? "Remove Copy" : "Remove Copies")
        alert.buttons[0].keyEquivalent = "\u{1b}"; alert.buttons[1].keyEquivalent = "\r"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn else { return }
            for url in copies { if let id = VirtualCopy.id(in: url) { try? VirtualCopy.remove(id) } }
            let gone = Set(copies)
            let current = self.urls.indices.contains(self.selected) ? self.urls[self.selected] : nil
            self.urls.removeAll { gone.contains($0) }; self.shootCatalog.removeAll { gone.contains($0) }; self.libraryURLs = []
            self.selected = min(self.selected, max(0, self.urls.count - 1))
            self.collection.reloadData()
            if self.isLibrary { self.refreshLibrary() } else if current.map(gone.contains) == true, !self.urls.isEmpty { self.select(self.selected) }
            self.updateControls()
            self.statusBar.show("Removed \(copies.count) virtual cop\(copies.count == 1 ? "y" : "ies").", busy: false)
        }
        return true
    }
    /// When an original goes to the Trash, its virtual copies leave the library with it.
    func removeCopies(ofTrashed files: [URL]) {
        guard let catalog = EditStorage.records.catalog else { return }
        for file in files where !VirtualCopy.isCopy(file) {
            guard let id = catalog.recordID(path: file.standardizedFileURL.path) else { continue }
            for copy in catalog.virtualCopies(of: id) { try? VirtualCopy.remove(copy) }
        }
        let paths = Set(files.map(\.path))
        urls.removeAll { VirtualCopy.isCopy($0) && paths.contains($0.path) }
        shootCatalog.removeAll { VirtualCopy.isCopy($0) && paths.contains($0.path) }
    }
    /// The name shown under a thumbnail: the file name, plus the copy's name for a virtual copy.
    static func displayName(_ url: URL, record: PhotoRecord?) -> String {
        guard VirtualCopy.isCopy(url) else { return url.lastPathComponent }
        return url.lastPathComponent + " · " + (record?.copyName ?? "Copy")
    }

    /// Synchronize Folder: photos in the catalog whose files were deleted outside OpenStill (the folder itself is there).
    /// OpenStill lists them and asks before taking them out of the library; their edits are kept on disk.
    func offerToRemoveDeleted(in folder: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let catalog = EditStorage.records.catalog else { return }
            let gone = catalog.photosMissing(under: folder.standardizedFileURL.path)
            guard !gone.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, let window = self.view.window, window.attachedSheet == nil else { return }
                let names = gone.filter { $0.masterID == nil }.map(\.filename)
                let alert = NSAlert()
                alert.messageText = "\(names.count) photo\(names.count == 1 ? " is" : "s are") no longer in “\(folder.lastPathComponent)”"
                alert.informativeText = "These files were deleted or moved outside OpenStill:\n" + names.prefix(12).joined(separator: "\n") + (names.count > 12 ? "\n…" : "")
                    + "\n\nRemove them from the library? Their edits stay saved, so they come back if the files do."
                alert.addButton(withTitle: "Remove from Library"); alert.addButton(withTitle: "Keep")
                alert.beginSheetModal(for: window) { [weak self] response in
                    guard response == .alertFirstButtonReturn else { return }
                    try? RemovedPhotos.remove(gone)
                    let paths = Set(gone.map(\.path))
                    self?.urls.removeAll { paths.contains($0.path) }; self?.shootCatalog.removeAll { paths.contains($0.path) }
                    self?.libraryURLs = []; self?.collection.reloadData(); self?.refreshLibrary(); self?.librarySidebar.reloadFolders()
                    self?.statusBar.show("Removed \(names.count) deleted photo\(names.count == 1 ? "" : "s") from the library.", busy: false)
                }
            }
        }
    }
}
