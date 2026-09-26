import AppKit
import OpenStillCore
import UniformTypeIdentifiers

final class ViewerController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate, NSMenuItemValidation, NSToolbarDelegate, NSToolbarItemValidation {
    private let store = PhotoStore()
    let canvas = PhotoCanvas()
    let info = EditorPanel()
    private let collection = NavigationCollectionView()
    private let filmstrip = NSScrollView()
    private let center = NSView()
    private let libraryHost = NSView()
    private let librarySidebar = LibrarySidebar()
    private let leftRail = WorkspaceRail(items: [("folders", "Local folders", "folder"), ("library", "Photo library", "square.grid.2x2"), ("photo", "Edit photograph", "photo"), ("open", "Open photos", "plus")])
    private let rightRail = WorkspaceRail(items: [("edit", "Edit", "slider.horizontal.3"), ("crop", "Crop and rotate", "crop"), ("retouch", "Retouch", "bandage"), ("mask", "Mask current tool", "circle.dashed"), ("presets", "Presets and LUTs", "square.stack"), ("history", "Edit history", "clock.arrow.circlepath"), ("info", "Camera and lens info", "info.circle")])
    private let workspaceMode = NSSegmentedControl(labels: ["Library", "Edit"], trackingMode: .selectOne, target: nil, action: nil)
    private let shelf = Appearance.glass()
    private var libraryBrowser: ShootWindow?
    private var libraryURLs: [URL] = []
    private var folderURL: URL?
    /// The collection the library shows, when opened from the sidebar's Collections.
    private var openCollection: PhotoCollection?
    private var smartCollectionWindow: SmartCollectionWindow?
    private var isLibrary = false
    private var foldersVisible = false
    private var centerToFolders: NSLayoutConstraint!
    private var centerToRail: NSLayoutConstraint!
    private var centerToShelf: NSLayoutConstraint!
    private var centerToFooter: NSLayoutConstraint!

    private let status = NSTextField(labelWithString: "A little space for your photographs.")
    private let hint = NSTextField(labelWithString: "")
    private let zoom = NSSegmentedControl(labels: ["Fit", "100%"], trackingMode: .selectOne, target: nil, action: nil)
    private var toolbarItems: [String: NSToolbarItem] = [:]
    private var shareWindow: NSWindow?
    var exportPanel: ExportPanel?
    var shootWindow: ShootWindow?
    var shootCatalog:[URL]=[]
    private let welcome = NSStackView()
    private let spinner = NSProgressIndicator()
    private var canvasToInspector: NSLayoutConstraint!
    private var canvasToEdge: NSLayoutConstraint!
    var urls: [URL] = []
    var selected = 0
    private var generation = UUID()
    private var catalogGeneration = UUID()
    private var metadata: PhotoMetadata?
    var renderedPhoto: DecodedPhoto?
    private var infoVisible = true
    private var trashInProgress = false
    var editDocument = EditDocument(fingerprint: "")
    var currentEdits = PhotoEdits()
    var photoRecord: PhotoRecord?
    var editToken = UUID()
    var lastSunPreviewAt: TimeInterval = 0
    var editWork: DispatchWorkItem?
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
    var histogramToken = UUID()
    let histogramQueue = DispatchQueue(label:"OpenStill.histogram",qos:.utility)

    override func loadView() {
        view = Appearance.workspace()
        setupLayout()
        configureEditing()
        workspaceMode.target = self; workspaceMode.action = #selector(workspaceChanged(_:)); workspaceMode.selectedSegment = 1
        workspaceMode.selectedSegmentBezelColor = Appearance.accent; workspaceMode.setAccessibilityLabel("Workspace")
        leftRail.choose = { [weak self] id in
            guard let self else { return }
            switch id {
            case "folders": self.foldersVisible.toggle(); self.updateWorkspaceLayout()
            case "library": self.showLibrary()
            case "photo": self.showEditor()
            default: self.openPanel()
            }
        }
        rightRail.choose = { [weak self] id in self?.showEditingSection(id) }
        info.sectionChanged = { [weak self] index in self?.rightRail.select(["edit", "presets", "history", "info"][index]) }
        librarySidebar.browse = { [weak self] in self?.openPanel() }
        librarySidebar.open = { [weak self] url in self?.open([url]) }
        librarySidebar.filter = { [weak self] index in self?.showLibrary(); self?.libraryBrowser?.setFlagFilter(index) }
        librarySidebar.subfoldersChanged = { [weak self] _ in if let self, let folder = self.folderURL, self.openCollection == nil { self.open([folder]) } }
        librarySidebar.openCollection = { [weak self] collection in self?.open(collection: collection) }
        librarySidebar.newSmartCollection = { [weak self] in
            guard let self else { return }
            let window = SmartCollectionWindow(); self.smartCollectionWindow = window
            window.created = { [weak self] collection in self?.librarySidebar.reloadCollections(); self?.open(collection: collection) }
            window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
        }
        leftRail.select("photo"); rightRail.select("edit")

        canvas.navigate = { [weak self] step in self?.advance(step) }
        canvas.toggleZoom = { [weak self] in self?.toggleZoom() }
        canvas.zoomChanged = { [weak self] in self?.updateControls() }
        canvas.openURLs = { [weak self] urls in self?.open(urls) }
        canvas.escape = { [weak self] in self?.escapeView() }
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
        updateControls()
    }

    private func setupLayout() {
        let content = NSView()
        let surface: NSView
        if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView()
            container.spacing = 0
            container.contentView = content
            surface = container
        } else { surface = content }
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor), surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), surface.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        for child in [leftRail, librarySidebar, center, info, rightRail, shelf] {
            child.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(child)
        }
        for child in [canvas, libraryHost] {
            child.translatesAutoresizingMaskIntoConstraints = false; center.addSubview(child)
            NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo:center.leadingAnchor),child.trailingAnchor.constraint(equalTo:center.trailingAnchor),child.topAnchor.constraint(equalTo:center.topAnchor),child.bottomAnchor.constraint(equalTo:center.bottomAnchor)])
        }
        canvas.appearance = NSAppearance(named: .darkAqua)
        for child in [canvas, libraryHost] { child.wantsLayer = true; child.layer?.cornerRadius = 16; child.layer?.masksToBounds = true }
        libraryHost.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        libraryHost.isHidden = true; librarySidebar.isHidden = true
        zoom.selectedSegment = 0
        zoom.target = self
        zoom.action = #selector(zoomChanged)
        zoom.toolTip = "Fit (⌘0) or original pixels (⌘1)"
        zoom.setAccessibilityLabel("Photo zoom")
        zoom.selectedSegmentBezelColor = Appearance.accent
        let flow = NSCollectionViewFlowLayout()
        flow.scrollDirection = .horizontal
        flow.itemSize = NSSize(width: 102, height: 91)
        flow.minimumInteritemSpacing = 12
        flow.minimumLineSpacing = 12
        flow.sectionInset = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
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
        shelf.contentView.addSubview(filmstrip)
        let footer = NSStackView(views: [status, NSView(), hint])
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.spacing = 8
        for label in [status, hint] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.addSubview(footer)
        canvasToInspector = center.trailingAnchor.constraint(equalTo: info.leadingAnchor, constant: -10)
        canvasToEdge = center.trailingAnchor.constraint(equalTo: rightRail.leadingAnchor, constant: -10)
        centerToFolders = center.leadingAnchor.constraint(equalTo: librarySidebar.trailingAnchor, constant: 10)
        centerToRail = center.leadingAnchor.constraint(equalTo: leftRail.trailingAnchor, constant: 10)
        centerToShelf = center.bottomAnchor.constraint(equalTo: shelf.topAnchor, constant: -10)
        centerToFooter = center.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10)
        NSLayoutConstraint.activate([
            leftRail.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10), leftRail.widthAnchor.constraint(equalToConstant: 48),
            leftRail.topAnchor.constraint(equalTo: center.topAnchor), leftRail.bottomAnchor.constraint(equalTo: shelf.bottomAnchor),
            librarySidebar.leadingAnchor.constraint(equalTo: leftRail.trailingAnchor, constant: 10), librarySidebar.widthAnchor.constraint(equalToConstant: 216),
            librarySidebar.topAnchor.constraint(equalTo: center.topAnchor), librarySidebar.bottomAnchor.constraint(equalTo: shelf.bottomAnchor),
            centerToRail, center.topAnchor.constraint(equalTo: content.topAnchor, constant: 10), canvasToInspector, centerToShelf,
            info.trailingAnchor.constraint(equalTo: rightRail.leadingAnchor, constant: -10), info.topAnchor.constraint(equalTo: center.topAnchor),
            info.bottomAnchor.constraint(equalTo: shelf.bottomAnchor), info.widthAnchor.constraint(equalToConstant: 320),
            rightRail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10), rightRail.widthAnchor.constraint(equalToConstant: 48),
            rightRail.topAnchor.constraint(equalTo: center.topAnchor), rightRail.bottomAnchor.constraint(equalTo: shelf.bottomAnchor),
            shelf.leadingAnchor.constraint(equalTo: center.leadingAnchor), shelf.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            shelf.heightAnchor.constraint(equalToConstant: 112), shelf.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            filmstrip.leadingAnchor.constraint(equalTo: shelf.contentView.leadingAnchor, constant: 4), filmstrip.trailingAnchor.constraint(equalTo: shelf.contentView.trailingAnchor, constant: -4),
            filmstrip.topAnchor.constraint(equalTo: shelf.contentView.topAnchor), filmstrip.bottomAnchor.constraint(equalTo: shelf.contentView.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8), footer.heightAnchor.constraint(equalToConstant: 18)
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

    private func setupWelcome() {
        welcome.orientation = .vertical
        welcome.alignment = .centerX
        welcome.spacing = 16
        welcome.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)!)
        icon.contentTintColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 46, weight: .ultraLight)
        let title = NSTextField(labelWithString: "Your photos. A clearer view.")
        title.font = .systemFont(ofSize: 21, weight: .medium)
        let subtitle = NSTextField(labelWithString: "Drop a photo or folder here to begin.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let button = NSButton(title: "Open photos…", target: self, action: #selector(openPanel))
        button.bezelStyle = .rounded
        button.controlSize = .large
        Appearance.primary(button)
        let help = NSTextField(labelWithString: "← → to browse · Pinch or scroll to zoom")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .tertiaryLabelColor
        for item in [icon, title, subtitle, button, help] { welcome.addArrangedSubview(item) }
        welcome.setCustomSpacing(24, after: subtitle)
        welcome.setCustomSpacing(28, after: button)
        canvas.addSubview(welcome)
        NSLayoutConstraint.activate([
            welcome.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            welcome.centerYAnchor.constraint(equalTo: canvas.centerYAnchor)
        ])
    }

    func installToolbar(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "OpenStill.MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        updateControls()
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let leading = ["open", "previous", "next"].map { NSToolbarItem.Identifier($0) }
        let trailing = ["workspace", "zoom", "share", "export", "inspector"].map { NSToolbarItem.Identifier($0) }
        return leading + [.flexibleSpace] + trailing
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        let definitions: [String: (String, String, Selector)] = [
            "open": ("Open photos", "folder", #selector(openPanel)),
            "previous": ("Previous photo", "chevron.left", #selector(previousPhoto)),
            "next": ("Next photo", "chevron.right", #selector(nextPhoto)),
            "shoot": ("Shoot grid", "square.grid.2x2", #selector(showShoot)),
            "share": ("Share photos", "square.and.arrow.up", #selector(sharePhoto)),
            "export": ("Export", "square.and.arrow.up.on.square", #selector(exportPhoto)),
            "inspector": ("Show or hide inspector", "sidebar.right", #selector(toggleInspector))
        ]
        if id.rawValue == "workspace" {
            item.label = "Workspace"; item.view = workspaceMode
        } else if id.rawValue == "zoom" {
            item.label = "Zoom"; item.view = zoom
        } else if let (label, symbol, action) = definitions[id.rawValue] {
            item.label = label; item.toolTip = label
            item.image = Appearance.symbol(symbol, size: 16, description: label)
            item.target = self; item.action = action; item.isBordered = true
            if #available(macOS 26.0, *) {
                item.isNavigational = ["previous", "next"].contains(id.rawValue)
                if id.rawValue == "export" { item.style = .prominent; item.backgroundTintColor = Appearance.accent }
            }
        } else { return nil }
        toolbarItems[id.rawValue] = item
        return item
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier.rawValue {
        case "previous": return !isLibrary && !urls.isEmpty && selected > 0
        case "next": return !isLibrary && !urls.isEmpty && selected < urls.count - 1
        case "share": return !selectedURLs.isEmpty && view.window?.attachedSheet == nil
        case "export": return isLibrary ? !(libraryBrowser?.selectedItems.isEmpty ?? true) : renderedPhoto != nil && !localAI.isRunning && !aiPreparing
        case "shoot": return !urls.isEmpty
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
        urls = [];shootCatalog=[];shootWindow?.close();shootWindow=nil
        libraryBrowser?.stopBrowsing(); libraryBrowser?.browserView.removeFromSuperview(); libraryBrowser=nil; libraryURLs=[]; folderURL=nil; openCollection=libraryCollection
        librarySidebar.update(folder:nil,count:0)
        selected = 0
        metadata = nil
        renderedPhoto = nil
        info.show(nil)
        info.setLUTPhoto(nil,edits:PhotoEdits())
        localAI.cancel(); aiPreparing = false; editWork?.cancel(); editToken = UUID(); canvas.clearTool()
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
                self.canvas.image = photo.image
                self.canvas.message = ""
                self.info.update(self.currentEdits, document: self.editDocument, enabled: true)
                self.renderEdits()
            case .failure(let error): self.canvas.message = "Couldn’t display \(url.lastPathComponent).\n\(error.localizedDescription)\nUse the arrow keys to continue browsing."
            }
            self.updateControls()
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
        info.show(metadata, rendering: renderedPhoto?.description)
        view.window?.title = isLibrary ? (openCollection?.name ?? folderURL?.lastPathComponent ?? "Local Library") : (hasPhotos ? urls[selected].lastPathComponent : "OpenStill")
        var subtitle = hasPhotos ? "\(selected + 1) of \(urls.count)" : "Photo editor"
        if hasPhotos, selectionCount != 1 { subtitle += " · \(selectionCount) selected" }
        view.window?.subtitle = isLibrary ? "Local library · \(shootCatalog.count) photos" : subtitle
        view.window?.toolbar?.validateVisibleItems()
        zoom.isEnabled = !isLibrary && canvas.image != nil
        zoom.selectedSegment = canvas.isFit ? 0 : (canvas.native ? 1 : -1)
        status.stringValue = metadata.map { "\($0.dimensions.contains("×") ? "\($0.dimensions) px  ·  " : "")\($0.format)  ·  \($0.fileSize)" } ?? (hasPhotos ? "Reading photo…" : "A little space for your photographs.")
        if let photo = renderedPhoto, photo.rendering != .original {
            status.stringValue = photo.description
            status.toolTip = "100% shows one pixel of this displayed image per physical screen pixel. Embedded previews may be smaller than the RAW sensor image."
        } else { status.toolTip = nil }
        if isLibrary {
            status.stringValue = "\(libraryBrowser?.visibleURLs.count ?? 0) photos · \(selectionCount) selected"
            status.toolTip = nil
            hint.stringValue = "Double-click to edit · 0–5 to rate · P to pick"
            return
        }
        hint.stringValue = hasPhotos ? "\(canvas.isFit ? "Fit" : "\(canvas.zoomPercent)%") · ⌘-click or Shift-click to select photos" : ""
    }
    var libraryExportItems: [ShootItem]? { isLibrary ? (libraryBrowser?.selectedItems ?? []) : nil }
    private var selectedURLs: [URL] {
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
    @objc private func zoomChanged() { canvas.native = zoom.selectedSegment == 1; updateControls(); view.window?.makeFirstResponder(canvas) }
    private func toggleZoom() { canvas.native = canvas.isFit; updateControls() }
    @objc func zoomIn() { canvas.scale(by: 1.25) }
    @objc func zoomOut() { canvas.scale(by: 0.8) }
    @objc func toggleInfo() {
        if isLibrary { showEditor() }
        if !info.isHidden && info.selectedTab == 3 { infoVisible = false }
        else { infoVisible = true; info.showTab(3) }
        updateInspectorVisibility()
    }
    @objc private func toggleInspector() {
        if isLibrary { showEditor(); infoVisible=true } else { infoVisible.toggle() }
        updateInspectorVisibility()
    }
    private func updateInspectorVisibility() {
        if !infoVisible { finishMaskEditing() }
        updateWorkspaceLayout()
        toolbarItems["inspector"]?.toolTip = infoVisible ? "Hide inspector" : "Show inspector"
    }
    @objc private func workspaceChanged(_ sender:NSSegmentedControl) { sender.selectedSegment == 0 ? showLibrary() : showEditor() }
    @objc func showLibrary() {
        finishMaskEditing(); canvas.clearTool()
        isLibrary = true; foldersVisible = true
        refreshLibrary(); updateWorkspaceLayout(); updateControls()
    }
    @objc func showEditor() {
        let selectedItem = isLibrary ? libraryBrowser?.selectedItems.first : nil
        isLibrary = false; foldersVisible = false
        updateWorkspaceLayout(); updateControls()
        if let selectedItem, let browser=libraryBrowser {showShootSelection(filtered:browser.visibleURLs,url:selectedItem.url)}
        rightRail.select(["edit","presets","history","info"][info.selectedTab])
        view.window?.makeFirstResponder(canvas)
    }
    private func showEditingSection(_ id:String) {
        showEditor(); infoVisible = true; updateWorkspaceLayout()
        switch id {
        case "crop": info.openTool("Crop & rotate")
        case "retouch": info.openTool("Retouch")
        case "mask": info.openCurrentMask()
        case "presets": info.showTab(1)
        case "history": info.showTab(2)
        case "info": info.showTab(3)
        default: info.showTab(0)
        }
        rightRail.select(id)
    }
    private func updateWorkspaceLayout() {
        let inspector = infoVisible && !isLibrary
        info.isHidden = !inspector; librarySidebar.isHidden = !foldersVisible
        canvas.isHidden = isLibrary; libraryHost.isHidden = !isLibrary; shelf.isHidden = isLibrary
        // Deactivate alternatives first, preventing transient constraint conflicts.
        NSLayoutConstraint.deactivate([canvasToInspector,canvasToEdge,centerToFolders,centerToRail,centerToShelf,centerToFooter])
        NSLayoutConstraint.activate([inspector ? canvasToInspector : canvasToEdge, foldersVisible ? centerToFolders : centerToRail, isLibrary ? centerToFooter : centerToShelf])
        workspaceMode.selectedSegment = isLibrary ? 0 : 1
        leftRail.select(isLibrary ? "library" : "photo")
        if isLibrary { rightRail.select(nil) }
    }
    private func refreshLibrary() {
        let catalog = shootCatalog.isEmpty ? urls : shootCatalog
        if libraryURLs == catalog, let browser = libraryBrowser { browser.refresh(); return }
        libraryBrowser?.stopBrowsing();libraryBrowser?.browserView.removeFromSuperview()
        let browser = ShootWindow(urls:catalog,embedded:true,selectedURL:currentSource);libraryBrowser=browser;libraryURLs=catalog
        browser.collection = openCollection
        browser.collectionsChanged = { [weak self] in self?.librarySidebar.reloadCollections() }
        let content=browser.browserView;content.translatesAutoresizingMaskIntoConstraints=false;libraryHost.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo:libraryHost.leadingAnchor),content.trailingAnchor.constraint(equalTo:libraryHost.trailingAnchor),content.topAnchor.constraint(equalTo:libraryHost.topAnchor),content.bottomAnchor.constraint(equalTo:libraryHost.bottomAnchor)])
        browser.edit = { [weak self] _,_ in
            guard let self else { return };self.showEditor()
        }
        browser.selectionChanged = { [weak self] in self?.updateControls() }
        browser.recordsChanged = { [weak self] in
            guard let self,let id=self.photoRecord?.id,let latest=try? EditStorage.records.read(id) else{return}
            let changed=self.photoRecord?.active.revision != latest.active.revision || self.photoRecord?.activeVersionID != latest.activeVersionID
            self.photoRecord=latest
            if changed {self.editDocument=latest.active.document;self.currentEdits=latest.active.document.current;self.info.update(self.currentEdits,document:self.editDocument,enabled:true);self.renderEdits()}
        }
    }
    @objc func toggleFullscreen() { view.window?.toggleFullScreen(nil) }
    private func escapeView() {
        if canvas.tool != .browse { finishMaskEditing(); canvas.clearTool(); info.status("Tool cancelled. Edits are saved on this Mac."); return }
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
        let menu = NSMenu()
        let share = NSMenuItem(title: selectedURLs.count > 1 ? "Share \(selectedURLs.count) Photos…" : "Share Photo…", action: #selector(sharePhoto), keyEquivalent: "")
        share.target = self
        menu.addItem(share)
        let item = NSMenuItem(title: selectedURLs.count > 1 ? "Move to Trash (select one photo)" : "Move to Trash…", action: #selector(trashPhoto), keyEquivalent: "")
        item.target = self
        item.image = Appearance.symbol("trash")
        menu.addItem(item)
        return menu
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
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
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
        status.stringValue = "Moved \(url.lastPathComponent) to Trash"
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
        if let index = indexPaths.map(\.item).sorted().last { select(index, preservingSelection: true) }
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
