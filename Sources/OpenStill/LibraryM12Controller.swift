import AppKit
import OpenStillCore

/// The Library's Lightroom tools in the main window: Quick Develop, keywords, stacks, rename, Auto Import and the Reference view.
extension ViewerController {
    /// Commands from the Library panels ("lib:…").
    func libraryCommand(_ name: String) {
        let parts = name.split(separator: ":", maxSplits: 3).map(String.init)
        guard parts.count >= 2 else { return }
        switch parts[1] {
        case "qd":
            guard parts.count >= 3, let step = Self.quickDevelopStep(parts.dropFirst(2).joined(separator: ":")) else { return }
            withLibrary { $0.quickDevelop(step) }
        case "keyword":
            guard parts.count == 4 else { return }
            let keyword = parts[3]
            switch parts[2] {
            case "add": withLibrary { $0.setKeyword(keyword, on: true) }
            case "remove": withLibrary { $0.setKeyword(keyword, on: false) }
            case "toggle": withLibrary { $0.toggleKeyword(keyword) }
            case "filter": withLibrary { $0.filterKeyword(keyword) }
            default: break
            }
        default: break
        }
    }
    /// "exposure:0.333", "wb:daylight", "auto" or "reset".
    static func quickDevelopStep(_ text: String) -> QuickDevelopStep? {
        let bits = text.split(separator: ":").map(String.init)
        guard let key = bits.first else { return nil }
        if key == "auto" { return .autoTone }
        if key == "reset" { return .resetAll }
        if key == "wb", bits.count == 2 { return WhiteBalancePreset(rawValue: bits[1]).map { .whiteBalance($0) } }
        guard bits.count == 2, let v = Double(bits[1]), v.isFinite else { return nil }
        switch key {
        case "exposure": return .exposure(v)
        case "contrast": return .contrast(v)
        case "highlights": return .highlights(v)
        case "shadows": return .shadows(v)
        case "whites": return .whites(v)
        case "blacks": return .blacks(v)
        case "clarity": return .clarity(v)
        case "vibrance": return .vibrance(v)
        case "saturation": return .saturation(v)
        case "temperature": return .temperature(v)
        case "tint": return .tint(v)
        default: return nil
        }
    }
    /// Quick Develop, Keywording and the Keyword List follow the grid selection.
    func updateLibraryPanels() {
        guard layoutMode == .lightroom, isLibrary, let browser = libraryBrowser else { return }
        let selected = browser.selectedItems
        info.quickDevelopPanel.setEnabled(!selected.isEmpty)
        let catalog = EditStorage.records.catalog
        let counts = catalog?.keywordCounts() ?? []
        let states = browser.keywordStates()
        info.keywordListPanel.update(counts: counts, states: states, enabled: !selected.isEmpty)
        let applied = Set(states.filter { $0.value == .on }.map(\.key))
        let own = selected.first?.record.iptc.keywords ?? []
        info.keywordSetPanel.update(applied: applied, suggestions: catalog?.keywordSuggestions(for: own) ?? [], enabled: !selected.isEmpty)
        info.showKeywords(selected.first.map { $0.record.iptc.keywords })
    }
    /// Renamed files: the folder's photo list and the open photo follow the new names.
    func followRenames(_ moves: [URL: URL]) {
        guard !moves.isEmpty else { return }
        func moved(_ url: URL) -> URL { moves[url.standardizedFileURL] ?? moves[url] ?? url }
        urls = urls.map(moved); shootCatalog = shootCatalog.map(moved); libraryURLs = libraryURLs.map(moved)
        collection.reloadData(); updateControls()
    }
    /// Photos brought in by Auto Import join the open folder when they landed in it.
    func addAutoImported(_ imported: [URL], report: ImportReport) {
        let folder = folderURL?.standardizedFileURL.path
        var added = 0
        for url in imported where folder != nil && url.standardizedFileURL.path.hasPrefix(folder! + "/") && !urls.contains(url) {
            urls.append(url); if !shootCatalog.isEmpty { shootCatalog.append(url) }; added += 1
        }
        if added > 0 { collection.reloadData(); refreshLibrary(); updateControls() }
        info.status("Auto Import: \(report.imported.count) photo\(report.imported.count == 1 ? "" : "s") added" + (report.failed.isEmpty ? "." : " · \(report.failed.count) failed"))
    }
    func startAutoImport() {
        autoImportMonitor.imported = { [weak self] urls, report in self?.addAutoImported(urls, report: report) }
        autoImportMonitor.start(AutoImport.load())
    }

    // MARK: Library menu
    private func library(_ action: @escaping (ShootWindow) -> Void) {
        if !isLibrary { showLibrary() }
        withLibrary(action)
    }
    @objc func groupIntoStack() { library { $0.groupIntoStack() } }
    @objc func unstackPhotos() { library { $0.unstackSelected() } }
    @objc func toggleStack() { library { $0.toggleStacks() } }
    @objc func moveToStackTop() { library { $0.moveToStackTop() } }
    @objc func autoStackPhotos() { library { $0.autoStack() } }
    @objc func renamePhotos() { library { $0.renameSelected() } }
    @objc func undoRename() { library { $0.undoRename() } }
    @objc func toggleLibraryFilterBar() { library { $0.toggleFilterBar() } }
    @objc func showLoupeView() { library { $0.setViewMode(.loupe) } }
    @objc func showCompareView() { library { $0.setViewMode(.compare) } }
    @objc func showSurveyView() { library { $0.setViewMode(.survey) } }
    @objc func showAutoImportSettings() {
        let window = autoImportWindow ?? AutoImportWindow(); autoImportWindow = window
        window.saved = { [weak self] settings in self?.autoImportMonitor.start(settings) }
        window.showWindow(nil); window.window?.center(); window.window?.makeKeyAndOrderFront(nil)
    }
    /// Reference View: the photo being edited (or the one selected in the library) is kept in its own window for comparison.
    @objc func showReferenceView() {
        let window = referenceWindow ?? ReferenceWindow(); referenceWindow = window
        window.useCurrent = { [weak self] in self?.setReferencePhoto() }
        window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
        setReferencePhoto()
    }
    private func setReferencePhoto() {
        if isLibrary, let item = libraryBrowser?.selectedItems.first { referenceWindow?.show(item); return }
        guard let url = currentSource, let record = photoRecord else { info.status("Open a photo to use as the reference."); return }
        referenceWindow?.show(ShootItem(url: url, record: record, captured: Date.distantPast))
    }
}
