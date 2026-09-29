import AppKit
import CoreImage
import OpenStillCore
import UniformTypeIdentifiers

final class ViewerController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate, NSMenuItemValidation, NSToolbarDelegate, NSToolbarItemValidation {
    private let store = PhotoStore()
    let canvas = PhotoCanvas()
    let info = EditorPanel()
    let collection = NavigationCollectionView()
    let filmstrip = NSScrollView()
    let center = NSView()
    let libraryHost = NSView()
    let librarySidebar = LibrarySidebar()
    let shelf = LRFill(Studio.chrome)
    let workspaceContent = LRFill(Studio.chrome)
    // The Studio window: tool rail, tool options bar, status line, one resizable panel, photo tabs in the toolbar.
    let rail = ToolRail()
    let optionsBar = ToolOptionsBar()
    let statusBar = StudioStatusBar()
    let rightPanel = LRFill(Studio.chrome)
    let resizeEdge = PanelResizeEdge()
    let libraryTabsBar = StudioBar(edge: .bottom)
    let libraryTabs = StudioSegments(["Folders", "Collections", "Info"])
    let modeSwitch = StudioSegments(["Library", "Develop"], selected: 1)
    let tabStrip = PhotoTabStrip()
    let identityPlate = IdentityPlate()
    var studio = StudioLayout.load()
    var tool = StudioTool.adjust
    var photoTabs = OpenPhotoTabs()
    var studioConstraints: [NSLayoutConstraint] = []
    var panelWidth: NSLayoutConstraint?
    var lights = LightsOut.normal
    var libraryInspectorToken = UUID()
    var studioPanels: [String: StudioPanel] = [:]
    /// The floating Info panel's contents and the Navigator, when shown.
    let floatingInfo = InfoPanel()
    weak var navigatorView: LRNavigator?
    /// The options bar is rebuilt only when what it shows changes, so a slider in it is never replaced mid-drag.
    var optionsSignature = ""
    var optionsRefresh: [() -> Void] = []
    var libraryBrowser: ShootWindow?
    // Library tools: Auto Import, the Reference view and their windows.
    let autoImportMonitor = AutoImportMonitor()
    var autoImportWindow: AutoImportWindow?
    var referenceWindow: ReferenceWindow?
    // Workflow: the second display window and Auto Sync.
    var secondaryWindow: SecondaryDisplayWindow?
    var autoSync = false
    var workspaceKeyMonitor: Any?
    var libraryURLs: [URL] = []
    var folderURL: URL?
    /// The collection the library shows, when opened from the sidebar's Collections.
    var openCollection: PhotoCollection?
    private var smartCollectionWindow: SmartCollectionWindow?
    var isLibrary = false
    private var toolbarItems: [String: NSToolbarItem] = [:]
    private var shareWindow: NSWindow?
    var exportPanel: ExportPanel?
    var shootCatalog:[URL]=[]
    let welcome = NSStackView()
    private let spinner = NSProgressIndicator()
    var urls: [URL] = []
    var selected = 0
    private var generation = UUID()
    private var catalogGeneration = UUID()
    var metadata: PhotoMetadata?
    var renderedPhoto: DecodedPhoto?
    private var trashInProgress = false
    var editDocument = EditDocument(fingerprint: "")
    var currentEdits = PhotoEdits()
    /// The last photo's settings, for Lightroom's Previous button.
    var previousEdits: PhotoEdits?
    /// Targeted adjustment in progress: what's being changed, the edits it started from, and what was sampled.
    var targetState: (kind: String, base: PhotoEdits, luminance: Double, hue: Double)?
    /// Visualize Spots overlay and its sensitivity (0 finds only strong spots … 1 finds faint ones).
    var spotsVisible = false
    var spotThreshold = 0.7
    var eyeKind = EyeFixKind.redEye
    /// The targeted adjustment chosen, waiting for a press on the photo ("curve", "hue", "saturation" or "luminance").
    var pendingTarget: String?
    var preparedSource: URL?
    var photoRecord: PhotoRecord?
    var editToken = UUID()
    var lastSunPreviewAt: TimeInterval = 0
    /// Render scheduling (see `renderEdits`): one render at a time, the newest edits next.
    var renderInFlight = false, renderQueued = false, queuedInteractive = true, renderGeneration = UUID()
    var detailWork: DispatchWorkItem?
    let renderQueue = DispatchQueue(label: "OpenStill.screenRender", qos: .userInteractive)
    /// Pixel sizes of AI-edited base images, so they are read from disk once.
    var baseSizes: [String: CGSize] = [:]
    let editQueue = DispatchQueue(label: "OpenStill.render", qos: .userInitiated)
    let localAI = LocalAI()
    var comparing = false
    var splitCompare = false
    var showClipping = false
    var compareToken = UUID()
    var aiPreparing = false
    var maskSession = MaskEditingSession()
    var retouchSession = RetouchSession()
    var activeMaskKey: String? { maskSession.tool }
    var maskVisible = false
    var maskRadius = 0.025
    var maskSoftness = 0.3
    var maskStrength = 1.0
    var maskSubtract = false
    var maskToken = UUID()
    /// Mask overlays render on their own queue; only the newest request runs.
    let maskOverlayGate = LUTPreviewGeneration(), histogramGate = LUTPreviewGeneration()
    let maskQueue = DispatchQueue(label: "OpenStill.maskOverlay", qos: .userInitiated)
    var histogramToken = UUID()
    let histogramQueue = DispatchQueue(label:"OpenStill.histogram",qos:.utility)

    override func loadView() {
        view = Appearance.workspace()
        setupLayout()
        configureEditing()
        librarySidebar.browse = { [weak self] in self?.openPanel() }
        librarySidebar.open = { [weak self] url in self?.open([url]) }
        librarySidebar.folderCommand = { [weak self] id, url in self?.folderCommand(id, url) }
        librarySidebar.filter = { [weak self] index in self?.showLibrary(); self?.libraryBrowser?.setFlagFilter(index) }
        librarySidebar.subfoldersChanged = { [weak self] _ in if let self, let folder = self.folderURL, self.openCollection == nil { self.open([folder]) } }
        librarySidebar.openCollection = { [weak self] collection in self?.open(collection: collection) }
        librarySidebar.newSmartCollection = { [weak self] in
            guard let self else { return }
            let window = SmartCollectionWindow(); self.smartCollectionWindow = window
            window.created = { [weak self] collection in self?.librarySidebar.reloadCollections(); self?.open(collection: collection) }
            window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
        }

        canvas.navigate = { [weak self] step in self?.advance(step) }
        canvas.toggleZoom = { [weak self] in self?.toggleZoom() }
        canvas.zoomChanged = { [weak self] in self?.updateControls() }
        canvas.openURLs = { [weak self] urls in self?.open(urls) }
        canvas.escape = { [weak self] in self?.escapeView() }
        canvas.confirm = { [weak self] in self?.finishToolAndClose() }
        collection.navigate = canvas.navigate
        collection.selectionChanged = { [weak self] index in
            guard let self else { return }
            if let index { self.select(index, preservingSelection: true) }
            else { self.updateControls() }
        }
        canvas.requestTrash = { [weak self] in self?.trashPhoto() }
        collection.requestTrash = canvas.requestTrash
        canvas.photoMenu = { [weak self] in self?.makePhotoMenu() }
        collection.photoMenu = { [weak self] index in
            guard let self, !self.trashInProgress else { return nil }
            self.select(index, preservingSelection: self.collection.selectionIndexPaths.contains(IndexPath(item: index, section: 0)))
            return self.makePhotoMenu()
        }
        setupStudio()
        updateControls()
    }

    private func setupLayout() {
        let content = workspaceContent
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor), content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), content.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        for child in [rail, optionsBar, center, resizeEdge, rightPanel, shelf, statusBar] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(child)
        }
        for child in [libraryTabsBar, info, librarySidebar] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false; rightPanel.addSubview(child)
        }
        for child in [canvas.photoBackdrop, canvas, libraryHost] {
            child.translatesAutoresizingMaskIntoConstraints = false; center.addSubview(child)
            NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo:center.leadingAnchor),child.trailingAnchor.constraint(equalTo:center.trailingAnchor),child.topAnchor.constraint(equalTo:center.topAnchor),child.bottomAnchor.constraint(equalTo:center.bottomAnchor)])
        }
        canvas.appearance = NSAppearance(named: .darkAqua)
        libraryHost.wantsLayer = true; libraryHost.layer?.backgroundColor = Studio.canvas.cgColor
        libraryHost.isHidden = true; librarySidebar.isHidden = true
        let flow = NSCollectionViewFlowLayout()
        flow.scrollDirection = .horizontal
        flow.itemSize = NSSize(width: 102, height: 91)
        flow.minimumInteritemSpacing = 12
        flow.minimumLineSpacing = 12
        flow.sectionInset = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        collection.collectionViewLayout = flow
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.dataSource = self
        collection.delegate = self
        collection.backgroundColors = [.clear]
        collection.register(FilmstripItem.self, forItemWithIdentifier: FilmstripItem.identifier)
        filmstrip.documentView = collection
        filmstrip.hasHorizontalScroller = true
        filmstrip.hasVerticalScroller = false
        filmstrip.autohidesScrollers = true
        filmstrip.drawsBackground = false
        filmstrip.translatesAutoresizingMaskIntoConstraints = false
        shelf.addSubview(filmstrip)
        NSLayoutConstraint.activate([
            filmstrip.leadingAnchor.constraint(equalTo: shelf.leadingAnchor, constant: 4), filmstrip.trailingAnchor.constraint(equalTo: shelf.trailingAnchor, constant: -4),
            filmstrip.topAnchor.constraint(equalTo: shelf.topAnchor, constant: 1), filmstrip.bottomAnchor.constraint(equalTo: shelf.bottomAnchor),
        ])
        setupWelcome()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: canvas.centerYAnchor, constant: 48)
        ])
    }

    /// The empty canvas: a quiet invitation to open or import, and the folders used last.
    private func setupWelcome() {
        welcome.orientation = .vertical
        welcome.alignment = .centerX
        welcome.spacing = 14
        welcome.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)!)
        icon.contentTintColor = Studio.tertiary
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .ultraLight)
        let title = Studio.label("Your photographs, developed on this Mac.", font: .systemFont(ofSize: 20, weight: .semibold), color: Studio.text)
        let subtitle = Studio.label("Open a folder to browse it, or drop photos anywhere in this window.", font: .systemFont(ofSize: 13))
        let open = Studio.button("Open Folder…", primary: true) { [weak self] in self?.openPanel() }
        let importButton = Studio.button("Import Photos…") { [weak self] in self?.importPhotos() }
        let buttons = NSStackView(views: [importButton, open]); buttons.spacing = 10
        for item in [icon, title, subtitle, buttons] as [NSView] { welcome.addArrangedSubview(item) }
        welcome.setCustomSpacing(8, after: title)
        welcome.setCustomSpacing(24, after: subtitle)
        let recent = (UserDefaults.standard.stringArray(forKey: "OpenStillRecentFolders") ?? []).prefix(4).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !recent.isEmpty {
            let label = Studio.label("Recent", font: .systemFont(ofSize: 11, weight: .semibold), color: Studio.tertiary)
            let row = NSStackView(); row.spacing = 8
            for url in recent { row.addArrangedSubview(Studio.button(url.lastPathComponent) { [weak self] in self?.open([url]); self?.showLibrary() }) }
            welcome.addArrangedSubview(label); welcome.addArrangedSubview(row)
            welcome.setCustomSpacing(30, after: buttons); welcome.setCustomSpacing(8, after: label)
        }
        let foot = Studio.label("Edits are kept on this Mac. Originals are never changed.", font: .systemFont(ofSize: 11), color: Studio.tertiary)
        welcome.addArrangedSubview(foot); welcome.setCustomSpacing(34, after: welcome.arrangedSubviews[welcome.arrangedSubviews.count - 2])
        canvas.addSubview(welcome)
        NSLayoutConstraint.activate([
            welcome.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            welcome.centerYAnchor.constraint(equalTo: canvas.centerYAnchor, constant: -12),
            welcome.widthAnchor.constraint(lessThanOrEqualTo: canvas.widthAnchor, constant: -48)
        ])
    }

    // MARK: Toolbar: identity plate, Library | Develop, photo tabs, zoom, Presets, History, Share, Export
    func installToolbar(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "OpenStill.StudioToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Studio.chrome; window.isOpaque = true
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitTabStrip() }
        }
        fitTabStrip()
        updateControls()
    }
    /// The tabs get the toolbar's free width; past that they scroll.
    func fitTabStrip() { tabStrip.setAvailableWidth((view.window?.frame.width ?? 1240) - 700) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ["plate", "mode", "tabs"].map { NSToolbarItem.Identifier($0) } + [.flexibleSpace]
            + ["fit", "actual", "zoomGroup", "presets", "history", "share", "export"].map { NSToolbarItem.Identifier($0) }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        let symbols: [String: (String, String, Selector)] = [
            "presets": ("Presets & LUTs (⇧P)", "square.stack", #selector(togglePresetsPanel)),
            "history": ("History, Snapshots & Versions (H)", "clock.arrow.circlepath", #selector(toggleHistoryPanel)),
            "share": ("Share photos", "square.and.arrow.up", #selector(sharePhoto)),
        ]
        switch id.rawValue {
        case "plate": item.view = identityPlate; item.label = "OpenStill"
        case "mode":
            item.view = modeSwitch; item.label = "Library or Develop"
            modeSwitch.changed = { [weak self] index in index == 0 ? self?.showLibrary() : self?.showEditor() }
            modeSwitch.setAccessibilityLabel("Library or Develop (G / D)")
        case "tabs": item.view = tabStrip; item.label = "Open photos"
        case "fit", "actual":
            let fit = id.rawValue == "fit"
            let button = Studio.button(fit ? "Fit" : "100%") { [weak self] in fit ? self?.fitPhoto() : self?.nativePhoto() }
            button.toolTip = fit ? "Fit the photo in the window (⌘0)" : "Actual pixels (⌘1)"
            item.view = button; item.label = fit ? "Fit" : "100%"
        case "zoomGroup":
            let out = StudioIconButton(symbol: "minus.magnifyingglass", label: "Zoom out (⌘−)", side: 28) { [weak self] in self?.zoomOut() }
            let zin = StudioIconButton(symbol: "plus.magnifyingglass", label: "Zoom in (⌘+)", side: 28) { [weak self] in self?.zoomIn() }
            for b in [out, zin] { b.symbolSize = 14 }
            let group = NSStackView(views: [out, zin]); group.spacing = 2
            item.view = group; item.label = "Zoom"
        case "export":
            let button = Studio.button("Export", primary: true) { [weak self] in self?.exportPhoto() }
            button.toolTip = "Export the selected photos (⇧⌘E)"
            item.view = button; item.label = "Export"
        default:
            guard let (label, symbol, action) = symbols[id.rawValue] else { return nil }
            item.label = label; item.toolTip = label
            item.image = Appearance.symbol(symbol, size: 15, description: label)
            item.target = self; item.action = action; item.isBordered = true
        }
        toolbarItems[id.rawValue] = item
        return item
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier.rawValue {
        case "share": return !selectedURLs.isEmpty && view.window?.attachedSheet == nil
        case "presets", "history": return !isLibrary
        default: return true
        }
    }

    @objc func openPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open photos"
        panel.message = "Choose a folder, or a photo to browse its folder."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.open(panel.urls) }
        }
    }

    /// Shows a collection's photos in the library. Photos whose files have moved or been deleted are left out.
    func open(collection: PhotoCollection) {
        guard let catalog = EditStorage.records.catalog else { return }
        let files = catalog.members(of: collection).map { URL(fileURLWithPath: $0.path) }
        open(files, collection: collection)
        showLibrary()
    }
    func open(_ inputs: [URL], collection libraryCollection: PhotoCollection? = nil) {
        _ = view
        let token = UUID()
        catalogGeneration = token
        // Invalidate work for the previous folder before scanning the new one.
        generation = UUID()
        store.reset()
        urls = [];shootCatalog=[]
        libraryBrowser?.stopBrowsing(); libraryBrowser?.browserView.removeFromSuperview(); libraryBrowser=nil; libraryURLs=[]; folderURL=nil; openCollection=libraryCollection
        librarySidebar.update(folder:nil,count:0)
        selected = 0
        metadata = nil
        renderedPhoto = nil
        info.show(nil)
        info.setLUTPhoto(nil,edits:PhotoEdits())
        localAI.cancel(); aiPreparing = false; cancelRenders(); editToken = UUID(); canvas.clearTool()
        info.update(PhotoEdits(), document: nil, enabled: false)
        collection.reloadData()
        updateControls()
        welcome.isHidden = true
        canvas.image = nil
        canvas.message = "Reading photos…"
        spinner.startAnimation(nil)
        let subfolders = LibrarySidebar.includeSubfolders
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try libraryCollection == nil ? PhotoCatalog.open(inputs, includeSubfolders: subfolders) : PhotoCatalog.files(inputs) }
            DispatchQueue.main.async {
                guard let self, self.catalogGeneration == token else { return }
                self.spinner.stopAnimation(nil)
                switch result {
                case .success(let catalog):
                    self.urls = catalog.urls;self.shootCatalog=catalog.urls
                    self.folderURL = catalog.folder
                    self.librarySidebar.update(folder:catalog.folder,count:catalog.urls.count,collection:libraryCollection?.id)
                    if self.isLibrary { self.refreshLibrary() }

                    self.selected = catalog.selectedIndex
                    self.view.window?.title = libraryCollection.map { "\($0.name) — OpenStill" } ?? catalog.folder.map { "\($0.lastPathComponent) — OpenStill" } ?? "OpenStill"
                    self.collection.reloadData()
                    if catalog.urls.isEmpty {
                        self.canvas.message = libraryCollection == nil ? "No supported photos in this folder.\nOpen another folder or drop in a photo." : "No photos in this collection yet."
                        self.metadata = nil
                        self.info.show(nil)
                        self.updateControls()
                    } else { self.select(catalog.selectedIndex) }
                case .failure(let error):
                    self.urls = []
                    self.collection.reloadData()
                    self.metadata = nil
                    self.info.show(nil)
                    self.canvas.message = "Couldn’t open these photos.\n\(error.localizedDescription)"
                    self.updateControls()
                }
            }
        }
    }

    func showShootSelection(filtered:[URL],url:URL) {
        guard let index=filtered.firstIndex(of:url)else{return}
        urls=filtered;collection.reloadData();select(index);view.window?.makeKeyAndOrderFront(nil)
    }
    func select(_ index: Int, preservingSelection: Bool = false) {
        guard urls.indices.contains(index) else { return }
        selected = index
        defer { updateSecondaryDisplay() }
        if !preservingSelection {
            collection.selectSingle(index)
        }
        let token = UUID()
        generation = token
        let url = urls[index]
        prepareEditor(for: url)
        canvas.image = nil
        canvas.message = "Loading photo…"
        canvas.setAccessibilityValue(url.lastPathComponent)
        metadata = nil
        renderedPhoto = nil
        info.show(nil)
        spinner.startAnimation(nil)
        updateControls()
        if !preservingSelection {
            collection.scrollToItems(at: collection.selectionIndexPaths, scrollPosition: .centeredHorizontally)
            view.window?.makeFirstResponder(canvas)
        }
        store.cancelImageRequests()
        store.load(url, version: photoRecord?.active) { [weak self] result in
            guard let self, self.generation == token else { return }
            self.spinner.stopAnimation(nil)
            switch result {
            case .success(let photo):
                self.renderedPhoto = photo
                self.canvas.image = nil; self.canvas.replaceRenderedImage(photo.preview, pixelSize:photo.pixelSize)
                self.canvas.message = ""
                self.info.update(self.currentEdits, document: self.editDocument, enabled: true)
                self.renderEdits()
            case .failure(let error): self.canvas.message = "Couldn’t display \(url.lastPathComponent).\n\(error.localizedDescription)\nUse the arrow keys to continue browsing."
            }
            self.updateControls()
        }
        // RAW files can take a moment to develop (Fuji X-Trans most of all): show the camera's own preview meanwhile.
        if RawDecoder.isRAW(url) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let preview = try? RawDecoder.cameraPreview(url), let image = try? ModernRenderer.screenImage(preview) else { return }
                DispatchQueue.main.async {
                    guard let self, self.generation == token, self.renderedPhoto == nil else { return }
                    self.canvas.image = image; self.canvas.message = ""
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let metadata = PhotoMetadata.read(url)
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.metadata = metadata
                self.info.show(metadata, rendering: self.renderedPhoto?.description)
                self.updateControls()
            }
        }
    }

    func updateControls() {
        let hasPhotos = !urls.isEmpty
        let selectionCount = selectedURLs.count
        toolbarItems["share"]?.toolTip = "Share \(selectionCount) selected photo\(selectionCount == 1 ? "" : "s") (⇧⌘S)"
        // The library's Info tab follows the grid selection instead.
        if !isLibrary { info.show(metadata, rendering: renderedPhoto?.description) }
        view.window?.title = isLibrary ? (openCollection?.name ?? folderURL?.lastPathComponent ?? "Library") : (hasPhotos ? urls[selected].lastPathComponent : "OpenStill")
        view.window?.toolbar?.validateVisibleItems()
        let canExport = isLibrary ? !(libraryBrowser?.selectedItems.isEmpty ?? true) : renderedPhoto != nil && !localAI.isRunning && !aiPreparing
        (toolbarItems["export"]?.view as? NSButton)?.isEnabled = canExport
        for id in ["fit", "actual"] { (toolbarItems[id]?.view as? NSButton)?.isEnabled = !isLibrary && canvas.image != nil }
        updateStudioBars()
    }
    var libraryExportItems: [ShootItem]? { isLibrary ? (libraryBrowser?.selectedItems ?? []) : nil }
    var selectedURLs: [URL] {
        if isLibrary { return libraryBrowser?.selectedItems.map(\.url) ?? [] }
        return collection.selectionIndexPaths.map(\.item).sorted().filter { urls.indices.contains($0) }.map { urls[$0] }
    }
    @objc func selectAllPhotos() {
        guard NSApp.keyWindow === view.window, view.window?.attachedSheet == nil else { return }
        if isLibrary {libraryBrowser?.selectAllPhotos();return}
        collection.selectEveryPhoto(count: urls.count)
        updateControls()
    }
    func advance(_ step: Int) { select(selected + step) }
    @objc func previousPhoto() { advance(-1) }
    @objc func nextPhoto() { advance(1) }
    @objc func fitPhoto() { canvas.native = false; updateControls() }
    @objc func nativePhoto() { canvas.native = true; updateControls() }
    private func toggleZoom() { canvas.native = canvas.isFit; updateControls() }
    @objc func zoomIn() { canvas.scale(by: 1.25) }
    @objc func zoomOut() { canvas.scale(by: 0.8) }
    /// ⌘I: shows the photo's camera and lens details (the Library's Info tab, or the Info panel beside the photo).
    @objc func toggleInfo() {
        if isLibrary { studio.libraryTab = 2; studio.save(); layoutStudio(); return }
        toggleFloatingPanel("info")
    }
    /// View › Tools.
    @objc func chooseToolFromMenu(_ sender: NSMenuItem) { if let raw = sender.representedObject as? String, let t = StudioTool(rawValue: raw) { selectTool(t) } }
    @objc func showLibrary() {
        finishMaskEditing(); canvas.clearTool()
        if tool != .adjust { tool = .adjust; info.showToolPanel(nil) }
        isLibrary = true
        info.setLightroom(.library)
        refreshLibrary(); layoutStudio(); updateControls(); updateLibraryInspector()
        withLibrary { $0.focus() }
    }
    @objc func showEditor() {
        let selectedItem = isLibrary ? libraryBrowser?.selectedItems.first : nil
        let wasLibrary = isLibrary
        isLibrary = false
        info.setLightroom(.develop)
        // The library showed the selected photo's metadata and histogram; show this photo's again.
        if wasLibrary { info.show(metadata, rendering: renderedPhoto?.description); if renderedPhoto != nil { renderEdits() } }
        layoutStudio(); updateControls()
        if let selectedItem, let browser=libraryBrowser {showShootSelection(filtered:browser.visibleURLs,url:selectedItem.url)}
        view.window?.makeFirstResponder(canvas)
    }
    /// A merged photo (HDR, panorama, focus stack) joins the open folder's photos.
    func addMergedPhoto(_ url: URL) {
        guard !urls.contains(url) else { return }
        urls.append(url); if !shootCatalog.isEmpty { shootCatalog.append(url) }
        collection.reloadData(); refreshLibrary(); updateControls()
    }
    func refreshLibrary() {
        let catalog = shootCatalog.isEmpty ? urls : shootCatalog
        if libraryURLs == catalog, let browser = libraryBrowser { browser.refresh(); return }
        libraryBrowser?.stopBrowsing();libraryBrowser?.browserView.removeFromSuperview()
        let browser = ShootWindow(urls:catalog,selectedURL:currentSource);libraryBrowser=browser;libraryURLs=catalog
        browser.collection = openCollection
        browser.collectionsChanged = { [weak self] in self?.librarySidebar.reloadCollections() }
        let content=browser.browserView;content.translatesAutoresizingMaskIntoConstraints=false;libraryHost.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo:libraryHost.leadingAnchor),content.trailingAnchor.constraint(equalTo:libraryHost.trailingAnchor),content.topAnchor.constraint(equalTo:libraryHost.topAnchor),content.bottomAnchor.constraint(equalTo:libraryHost.bottomAnchor)])
        browser.edit = { [weak self] _,_ in
            guard let self else { return };self.showEditor()
        }
        browser.selectionChanged = { [weak self] in self?.updateControls(); self?.updateLibraryInspector() }
        browser.messageChanged = { [weak self] text in if !text.isEmpty { self?.statusBar.show(text, busy: false) } }
        optionsSignature = ""
        browser.merged = { [weak self] url in self?.addMergedPhoto(url) }
        browser.renamed = { [weak self] moves in self?.followRenames(moves) }
        browser.keywordsChanged = { [weak self] in self?.updateLibraryPanels() }
        browser.keywordSetKey = { [weak self] i in self?.info.keywordSetPanel.applySetKeyword(i) }
        browser.trashRequested = { [weak self] items in self?.trashLibraryPhotos(items) }
        browser.contextMenu = { [weak self] in self?.makePhotoMenu() }
        browser.recordsChanged = { [weak self] in
            guard let self,let id=self.photoRecord?.id,let latest=try? EditStorage.records.read(id) else{return}
            let changed=self.photoRecord?.active.revision != latest.active.revision || self.photoRecord?.activeVersionID != latest.activeVersionID
            self.photoRecord=latest
            if changed {self.editDocument=latest.active.document;self.currentEdits=latest.active.document.current;self.info.update(self.currentEdits,document:self.editDocument,enabled:true);self.renderEdits()}
        }
    }
    @objc func toggleFullscreen() { view.window?.toggleFullScreen(nil) }
    private var photoImport: ImportWindow?
    @objc func importPhotos() {
        let window = photoImport ?? ImportWindow(); photoImport = window
        window.imported = { [weak self] urls in guard let self, !urls.isEmpty else { return }; self.open(urls); self.showLibrary() }
        window.showFolder = { [weak self] folder in self?.open([folder]); self?.showLibrary() }
        window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
    }
    /// Folders panel → Import to This Folder…
    func importPhotosInto(_ folder: URL) { importPhotos(); photoImport?.importInto(folder) }
    /// Folders panel right-click: Show in Finder, Import to This Folder…, Synchronize Folder.
    func folderCommand(_ id: String, _ folder: URL) {
        switch id {
        case "finder": NSWorkspace.shared.activateFileViewerSelecting([folder])
        case "import": importPhotosInto(folder)
        case "sync":
            // Re-reads the folder: new photos join the library and the counts are refreshed.
            open([folder]); showLibrary()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.librarySidebar.reloadFolders() }
        default: break
        }
    }
    private var tether: TetherWindow?
    @objc func tetheredCapture() {
        let window = tether ?? TetherWindow(); tether = window
        window.shotArrived = { [weak self] url in self?.showTetheredShot(url) }
        window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
    }
    /// A new tethered shot opens in the editor: added to the open session folder, or the folder is opened first.
    private func showTetheredShot(_ url: URL) {
        if urls.contains(url) || folderURL?.standardizedFileURL.path == url.deletingLastPathComponent().standardizedFileURL.path {
            addMergedPhoto(url)
            if let index = urls.firstIndex(of: url) { if isLibrary { showEditor() }; select(index) }
        } else {
            open([url]); showEditor()
        }
    }
    private var lightroomImport: LightroomImportWindow?
    @objc func importLightroomCatalog() {
        let window = lightroomImport ?? LightroomImportWindow(); lightroomImport = window
        window.completed = { [weak self] in guard let self else { return }; self.librarySidebar.reloadCollections(); self.libraryBrowser?.refresh() }
        window.showFolder = { [weak self] folder in self?.open([folder]); self?.showLibrary() }
        window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
    }
    private func escapeView() {
        if canvas.tool != .browse || tool != .adjust {
            finishMaskEditing(); canvas.clearTool(); closeTool()
            info.status("Tool cancelled. Edits are saved on this Mac."); return
        }
        if view.window?.styleMask.contains(.fullScreen) == true { toggleFullscreen() }
        else { fitPhoto() }
    }
    @objc func revealPhoto() {
        guard urls.indices.contains(selected) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([urls[selected]])
    }
    private var canTrashPhoto: Bool {
        !isLibrary && urls.indices.contains(selected) && selectedURLs.count == 1 && selectedURLs.first == urls[selected] && !trashInProgress && view.window?.attachedSheet == nil
            && NSApp.keyWindow === view.window
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(trashPhoto) { return canTrashPhoto }
        if menuItem.action == #selector(sharePhoto) { return !selectedURLs.isEmpty && NSApp.keyWindow === view.window && view.window?.attachedSheet == nil }
        if menuItem.action == #selector(selectAllPhotos) { return !urls.isEmpty && NSApp.keyWindow === view.window && view.window?.attachedSheet == nil }
        return true
    }
    private func makePhotoMenu() -> NSMenu? {
        guard !selectedURLs.isEmpty, !trashInProgress, view.window?.attachedSheet == nil else { return nil }
        return photoContextMenu(for: selectedURLs)
    }

    @objc func trashPhoto() {
        guard canTrashPhoto, let window = view.window else { return }
        let url = urls[selected]
        let catalogToken = catalogGeneration
        trashInProgress = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move “\(url.lastPathComponent)” to Trash?"
        alert.informativeText = "This moves the original photo from its current location to your Mac’s Trash. You can recover it from Trash.\n\n\(url.deletingLastPathComponent().path)\n\nOnly this file will be moved; paired photos and sidecar files stay in place."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Move to Trash")
        // Delete, then Return, moves the photo to the Trash (recoverable); Escape cancels.
        alert.buttons[0].keyEquivalent = "\u{1b}"
        alert.buttons[1].keyEquivalent = "\r"
        alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertSecondButtonReturn, self.catalogGeneration == catalogToken else {
                self.trashInProgress = false
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result {
                    // Use the system Trash on the source volume. Never fall back to permanent deletion.
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
                DispatchQueue.main.async {
                    self.trashInProgress = false
                    switch result {
                    case .success:
                        self.removeTrashedPhoto(url)
                    case .failure(let error):
                        let failure = NSAlert()
                        failure.alertStyle = .warning
                        failure.messageText = "Couldn’t move “\(url.lastPathComponent)” to Trash"
                        failure.informativeText = "OpenStill did not permanently delete the photo. The device may be read-only or may not support Trash.\n\n\(error.localizedDescription)"
                        failure.addButton(withTitle: "OK")
                        if window.attachedSheet == nil { failure.beginSheetModal(for: window) }
                    }
                }
            }
        }
    }
    private func removeTrashedPhoto(_ url: URL) {
        guard let index = urls.firstIndex(of: url) else { return }
        let current = urls.indices.contains(selected) ? urls[selected] : nil
        generation = UUID()
        store.reset()
        shareWindow?.close()
        urls.remove(at: index)
        selected = min(selected, max(0, urls.count - 1))
        collection.reloadData()
        if !urls.isEmpty {
            // Keep another photo selected if the user navigated while the disk operation finished.
            select(current.flatMap { urls.firstIndex(of: $0) } ?? min(index, urls.count - 1))
        } else {
            spinner.stopAnimation(nil)
            canvas.image = nil
            canvas.setAccessibilityValue("")
            canvas.message = "No photos left in this selection.\nOpen another folder or drop in a photo."
            metadata = nil
            renderedPhoto = nil
            collection.selectionIndexPaths = []
            updateControls()
        }
        statusBar.show("Moved \(url.lastPathComponent) to Trash", busy: false)
    }
    @objc func sharePhoto() {
        let sources = selectedURLs
        guard !sources.isEmpty else { return }
        shareWindow?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 690),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Share — OpenStill"
        Appearance.configure(panel)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary]
        let edits = Dictionary(uniqueKeysWithValues: sources.map { ($0, $0 == urls[selected] ? currentEdits : EditStorage.load($0).current) })
        panel.contentViewController = ShareController(sources: sources, image: sources.contains(urls[selected]) ? canvas.image : nil, edits: edits)
        panel.center()
        shareWindow = panel
        panel.makeKeyAndOrderFront(nil)
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { urls.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FilmstripItem.identifier, for: indexPath) as! FilmstripItem
        item.configure(urls[indexPath.item], store: store)
        return item
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.map(\.item).sorted().last else { return }
        // In the Lightroom library the filmstrip selects in the grid, as Lightroom's does.
        if isLibrary, urls.indices.contains(index) { libraryBrowser?.select(url: urls[index]); return }
        select(index, preservingSelection: true)
    }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let remaining = self.collection.selectionIndexPaths.map(\.item).sorted()
            if !remaining.contains(self.selected), let index = remaining.first { self.select(index, preservingSelection: true) }
            else { self.updateControls() }
        }
    }
}
