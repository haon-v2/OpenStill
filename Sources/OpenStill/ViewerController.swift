import AppKit
import CoreImage
import OpenStillCore
import UniformTypeIdentifiers

final class ViewerController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate, NSMenuItemValidation, NSToolbarDelegate, NSToolbarItemValidation {
    private let store = PhotoStore()
    let canvas = PhotoCanvas()
    let info = EditorPanel()
    let collection = NavigationCollectionView()
    private let filmstrip = NSScrollView()
    private let center = NSView()
    private let libraryHost = NSView()
    private let librarySidebar = LibrarySidebar()
    private let leftRail = WorkspaceRail(items: [("folders", "Local folders", "folder"), ("library", "Photo library", "square.grid.2x2"), ("photo", "Edit photograph", "photo"), ("open", "Open photos", "plus")])
    private let rightRail = WorkspaceRail(items: [("edit", "Edit", "slider.horizontal.3"), ("crop", "Crop and rotate", "crop"), ("retouch", "Retouch", "bandage"), ("mask", "Mask current tool", "circle.dashed"), ("presets", "Presets and LUTs", "square.stack"), ("history", "Edit history", "clock.arrow.circlepath"), ("info", "Camera and lens info", "info.circle")])
    private let workspaceMode = NSSegmentedControl(labels: ["Library", "Edit"], trackingMode: .selectOne, target: nil, action: nil)
    private let shelf = Appearance.glass()
    private let workspaceContent = LRFill(.clear)
    private let footer = NSStackView()
    var layoutMode = WorkspaceLayout.current
    private var luminarConstraints: [NSLayoutConstraint] = []
    private var sidebarWidth: NSLayoutConstraint!
    private var infoWidth: NSLayoutConstraint!
    private var shelfHeight: NSLayoutConstraint!
    // Lightroom Classic layout: module picker, Navigator, filmstrip bar, toolbar and the edge triangles.
    let modulePicker = LRModulePicker()
    private let navigator = LRNavigator()
    private let zoomLinks = LRZoomLinks()
    private lazy var navigatorSection = LRSection("Navigator", module: .library, side: .left, open: true, accessory: zoomLinks)
    private let navigatorBox = LRFill(LRColors.panel)
    private let libraryButtons = LRPanelColumn()
    private let filmstripBar = LRFilmstripBar()
    private let developToolbar = LRDevelopToolbar()
    private let edges = Dictionary(uniqueKeysWithValues: PanelEdge.allCases.map { ($0, LREdgeToggle($0)) })
    private var lightroomConstraints: [NSLayoutConstraint] = []
    private var lights = LightsOut.normal
    private var libraryInspectorToken = UUID()
    private var lrPanels: LightroomPanels { LightroomState.shared.panels }
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
    private var openCollection: PhotoCollection?
    private var smartCollectionWindow: SmartCollectionWindow?
    var isLibrary = false
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
        applyLayout(layoutMode)
        updateControls()
    }

    private func setupLayout() {
        let content = workspaceContent
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
        let lightroomViews: [NSView] = [modulePicker, navigatorBox, libraryButtons, info.leftDevelopColumn, filmstripBar, developToolbar] + PanelEdge.allCases.compactMap { edges[$0] }
        for child in [leftRail, librarySidebar, center, info, rightRail, shelf] + lightroomViews {
            child.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(child)
        }
        lightroomViews.forEach { $0.isHidden = true }
        for child in [canvas.hdrBackdrop, canvas, libraryHost] {
            child.translatesAutoresizingMaskIntoConstraints = false; center.addSubview(child)
            NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo:center.leadingAnchor),child.trailingAnchor.constraint(equalTo:center.trailingAnchor),child.topAnchor.constraint(equalTo:center.topAnchor),child.bottomAnchor.constraint(equalTo:center.bottomAnchor)])
        }
        canvas.appearance = NSAppearance(named: .darkAqua)
        for child in [canvas.hdrBackdrop, canvas, libraryHost] { child.wantsLayer = true; child.layer?.cornerRadius = 16; child.layer?.masksToBounds = true }
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
        for view in [status, NSView(), hint] { footer.addArrangedSubview(view) }
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
        sidebarWidth = librarySidebar.widthAnchor.constraint(equalToConstant: 216)
        infoWidth = info.widthAnchor.constraint(equalToConstant: 320)
        shelfHeight = shelf.heightAnchor.constraint(equalToConstant: 112)
        // EZ Layout: rails at both edges, glass panels, the filmstrip under the photo only.
        luminarConstraints = [
            center.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            librarySidebar.topAnchor.constraint(equalTo: center.topAnchor), info.topAnchor.constraint(equalTo: center.topAnchor),
            librarySidebar.leadingAnchor.constraint(equalTo: leftRail.trailingAnchor, constant: 10), librarySidebar.bottomAnchor.constraint(equalTo: shelf.bottomAnchor),
            info.trailingAnchor.constraint(equalTo: rightRail.leadingAnchor, constant: -10), info.bottomAnchor.constraint(equalTo: shelf.bottomAnchor),
            shelf.leadingAnchor.constraint(equalTo: center.leadingAnchor), shelf.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            shelf.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            leftRail.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10), leftRail.widthAnchor.constraint(equalToConstant: 48),
            leftRail.topAnchor.constraint(equalTo: center.topAnchor), leftRail.bottomAnchor.constraint(equalTo: shelf.bottomAnchor),
            rightRail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10), rightRail.widthAnchor.constraint(equalToConstant: 48),
            rightRail.topAnchor.constraint(equalTo: center.topAnchor), rightRail.bottomAnchor.constraint(equalTo: shelf.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8), footer.heightAnchor.constraint(equalToConstant: 18),
        ]
        NSLayoutConstraint.activate([
            sidebarWidth, infoWidth, shelfHeight,
            filmstrip.leadingAnchor.constraint(equalTo: shelf.contentView.leadingAnchor, constant: 4), filmstrip.trailingAnchor.constraint(equalTo: shelf.contentView.trailingAnchor, constant: -4),
            filmstrip.topAnchor.constraint(equalTo: shelf.contentView.topAnchor), filmstrip.bottomAnchor.constraint(equalTo: shelf.contentView.bottomAnchor),
        ])
        setupWelcome()
        setupLightroomChrome()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: canvas.centerYAnchor, constant: 48)
        ])
        NotificationCenter.default.addObserver(forName: .workspaceLayoutChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyLayout(WorkspaceLayout.current) }
        }
    }

    // MARK: Layout (Lightroom Classic or EZ Layout)
    @objc func useLightroomLayout() { WorkspaceLayout.current = .lightroom; NotificationCenter.default.post(name: .workspaceLayoutChanged, object: nil) }
    @objc func useLuminarLayout() { WorkspaceLayout.current = .luminar; NotificationCenter.default.post(name: .workspaceLayoutChanged, object: nil) }
    func applyLayout(_ layout: WorkspaceLayout) {
        layoutMode = layout
        let lr = layout == .lightroom
        if !lr { lights = .normal }
        // Lightroom Classic: flat dark-gray panels with square corners. EZ Layout: soft glass.
        view.window?.appearance = lr ? NSAppearance(named: .darkAqua) : nil
        view.window?.toolbar?.isVisible = !lr
        workspaceContent.color = lr ? LRColors.backdrop : .clear
        shelf.flatColor = lr ? LRColors.strip : nil
        librarySidebar.lightroom = lr
        for chrome in [librarySidebar, info, shelf] as [GlassChrome] { chrome.cornerRadius = lr ? 0 : 22 }
        for child in [canvas.hdrBackdrop, canvas, libraryHost] { child.layer?.cornerRadius = lr ? 0 : 16 }
        canvas.backdrop = lr ? LRColors.canvas : NSColor(calibratedWhite: 0.055, alpha: 1)
        libraryHost.layer?.backgroundColor = (lr ? LRColors.canvas : NSColor.windowBackgroundColor).cgColor
        workspaceMode.setLabel(layout.modeNames.library, forSegment: 0); workspaceMode.setLabel(layout.modeNames.edit, forSegment: 1)
        workspaceMode.sizeToFit()
        info.setLightroom(lr ? (isLibrary ? .library : .develop) : nil)
        if !lr { info.showTab(isLibrary ? 3 : info.selectedTab) }
        updateWorkspaceLayout()
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
        // Lightroom Classic has no toolbar; its module picker takes that place.
        toolbar.isVisible = layoutMode != .lightroom
        window.appearance = layoutMode == .lightroom ? NSAppearance(named: .darkAqua) : nil
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
                self.canvas.image = photo.image
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
                guard let preview = try? RawDecoder.cameraPreview(url), let image = try? ModernRenderer.display(preview) else { return }
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
        defer { updateLightroomBars() }
        let hasPhotos = !urls.isEmpty
        let selectionCount = selectedURLs.count
        toolbarItems["share"]?.toolTip = "Share \(selectionCount) selected photo\(selectionCount == 1 ? "" : "s") (⇧⌘S)"
        // The Lightroom library's Metadata panel follows the grid selection instead.
        if !(layoutMode == .lightroom && isLibrary) { info.show(metadata, rendering: renderedPhoto?.description) }
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
        if layoutMode == .lightroom { info.setLightroom(.library) }
        refreshLibrary(); updateWorkspaceLayout(); updateControls(); updateLibraryInspector()
        withLibrary { $0.focus() }
    }
    @objc func showEditor() {
        let selectedItem = isLibrary ? libraryBrowser?.selectedItems.first : nil
        let wasLibrary = isLibrary
        isLibrary = false; foldersVisible = false
        if layoutMode == .lightroom {
            info.setLightroom(.develop)
            // The library showed the selected photo's metadata and histogram; show this photo's again.
            if wasLibrary { info.show(metadata, rendering: renderedPhoto?.description); if renderedPhoto != nil { renderEdits() } }
        }
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
        let lr = layoutMode == .lightroom
        let lightroomViews: [NSView] = [modulePicker, navigatorBox, libraryButtons, info.leftDevelopColumn, filmstripBar, developToolbar] + PanelEdge.allCases.compactMap { edges[$0] }
        // Deactivate every alternative first, preventing transient constraint conflicts.
        NSLayoutConstraint.deactivate([canvasToInspector, canvasToEdge, centerToFolders, centerToRail, centerToShelf, centerToFooter] + luminarConstraints + lightroomConstraints)
        lightroomConstraints = []
        canvas.isHidden = isLibrary; canvas.hdrBackdrop.isHidden = isLibrary; libraryHost.isHidden = !isLibrary
        workspaceMode.selectedSegment = isLibrary ? 0 : 1
        if lr { layoutLightroom(); return }
        lightroomViews.forEach { $0.isHidden = true }
        footer.isHidden = false; leftRail.isHidden = false; rightRail.isHidden = false
        for v in [librarySidebar, info, shelf, center] as [NSView] { v.alphaValue = 1 }
        let inspector = infoVisible && !isLibrary
        info.isHidden = !inspector
        librarySidebar.isHidden = !foldersVisible
        shelf.isHidden = isLibrary
        sidebarWidth.constant = 216; infoWidth.constant = 320; shelfHeight.constant = 112
        let trailing: NSLayoutConstraint = inspector ? canvasToInspector : canvasToEdge
        let leading: NSLayoutConstraint = foldersVisible ? centerToFolders : centerToRail
        let bottom: NSLayoutConstraint = isLibrary ? centerToFooter : centerToShelf
        NSLayoutConstraint.activate(luminarConstraints + [trailing, leading, bottom])
        leftRail.select(isLibrary ? "library" : "photo")
        if isLibrary { rightRail.select(nil) }
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
        let browser = ShootWindow(urls:catalog,embedded:true,selectedURL:currentSource);libraryBrowser=browser;libraryURLs=catalog
        browser.collection = openCollection
        browser.collectionsChanged = { [weak self] in self?.librarySidebar.reloadCollections() }
        let content=browser.browserView;content.translatesAutoresizingMaskIntoConstraints=false;libraryHost.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo:libraryHost.leadingAnchor),content.trailingAnchor.constraint(equalTo:libraryHost.trailingAnchor),content.topAnchor.constraint(equalTo:libraryHost.topAnchor),content.bottomAnchor.constraint(equalTo:libraryHost.bottomAnchor)])
        browser.edit = { [weak self] _,_ in
            guard let self else { return };self.showEditor()
        }
        browser.selectionChanged = { [weak self] in self?.updateControls(); self?.updateLibraryInspector() }
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
        if canvas.tool != .browse || (layoutMode == .lightroom && info.lightroomToolOpen != nil) {
            finishMaskEditing(); canvas.clearTool(); closeLightroomTool()
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
        if menuItem.action == #selector(useLightroomLayout) { menuItem.state = layoutMode == .lightroom ? .on : .off; return true }
        if menuItem.action == #selector(useLuminarLayout) { menuItem.state = layoutMode == .luminar ? .on : .off; return true }
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
        guard let index = indexPaths.map(\.item).sorted().last else { return }
        // In the Lightroom library the filmstrip selects in the grid, as Lightroom's does.
        if isLibrary, layoutMode == .lightroom, urls.indices.contains(index) { libraryBrowser?.select(url: urls[index]); return }
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

// MARK: - Lightroom Classic layout

extension ViewerController {
    fileprivate var lightroomChrome: [NSView] { [modulePicker, navigatorBox, librarySidebar, libraryButtons, info.leftDevelopColumn, info, shelf, filmstripBar, developToolbar] + PanelEdge.allCases.compactMap { edges[$0] } }

    func setupLightroomChrome() {
        navigator.canvas = canvas
        navigatorSection.add(navigator)
        navigatorSection.toggled = { [weak self] in self?.updateWorkspaceLayout() }
        navigatorSection.translatesAutoresizingMaskIntoConstraints = false; navigatorBox.addSubview(navigatorSection)
        NSLayoutConstraint.activate([navigatorSection.topAnchor.constraint(equalTo: navigatorBox.topAnchor), navigatorSection.leadingAnchor.constraint(equalTo: navigatorBox.leadingAnchor),
                                     navigatorSection.trailingAnchor.constraint(equalTo: navigatorBox.trailingAnchor), navigatorSection.bottomAnchor.constraint(equalTo: navigatorBox.bottomAnchor)])
        zoomLinks.choose = { [weak self] index in
            guard let self else { return }
            switch index { case 0: self.fitPhoto(); case 1: self.nativePhoto(); default: self.canvas.native = true; self.canvas.scale(by: 2); self.updateControls() }
        }
        libraryButtons.setButtons([("Import…", { [weak self] in self?.importPhotos() }), ("Export…", { [weak self] in self?.exportPhoto() })])
        libraryButtons.note.isHidden = true
        modulePicker.choose = { [weak self] module in self?.chooseModule(module) }
        for (edge, toggle) in edges { toggle.toggled = { [weak self] in self?.togglePanel(edge) } }
        filmstripBar.grid = { [weak self] in self?.showLibrary() }
        filmstripBar.step = { [weak self] step in guard let self else { return }; if self.isLibrary { self.showEditor() }; self.advance(step) }
        developToolbar.command = { [weak self] name in self?.editingCommand(name); self?.updateLightroomBars() }
        info.lightroomTool = { [weak self] id in self?.lightroomToolChanged(id) }
        librarySidebar.publish = { [weak self] in self?.withLibrary { $0.openPublish() } }
        canvas.viewportChanged = { [weak self] in self?.navigator.needsDisplay = true }
        Shortcuts.workspace = { [weak self] id in self?.handleWorkspaceKey(id) ?? false }
        // Workspace keys (G, D, R, Q, L, T, Tab…) work wherever focus is in this window, except while typing in a text field.
        // Before, only the photo, filmstrip and grid handled them, so after G hid the focused photo, D and G went nowhere.
        if workspaceKeyMonitor == nil {
            workspaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.view.window, event.window === window, window.attachedSheet == nil,
                      !(window.firstResponder is NSText) else { return event }
                return Shortcuts.performWorkspace(event) ? nil : event
            }
        }
    }

    /// Lightroom Classic's arrangement, with the panels the person has shown or hidden.
    fileprivate func layoutLightroom() {
        let panels = lrPanels, g: CGFloat = 10, content = workspaceContent
        let top = panels.isVisible(.top), left = panels.isVisible(.left), right = panels.isVisible(.right), bottom = panels.isVisible(.bottom)
        let toolbar = !isLibrary && !panels.toolbarHidden
        footer.isHidden = true; leftRail.isHidden = true; rightRail.isHidden = true
        for (edge, toggle) in edges { toggle.isHidden = false; toggle.shown = panels.isVisible(edge) }
        modulePicker.isHidden = !top; modulePicker.current = isLibrary ? .library : .develop
        navigatorBox.isHidden = !left
        librarySidebar.isHidden = !(left && isLibrary); libraryButtons.isHidden = !(left && isLibrary)
        info.leftDevelopColumn.isHidden = !(left && !isLibrary)
        info.isHidden = !right
        shelf.isHidden = !bottom; filmstripBar.isHidden = !bottom
        developToolbar.isHidden = !toolbar
        sidebarWidth.constant = 250; infoWidth.constant = 300; shelfHeight.constant = bottom ? 92 : 0
        guard let topEdge = edges[.top], let bottomEdge = edges[.bottom], let leftEdge = edges[.left], let rightEdge = edges[.right] else { return }
        let develop = info.leftDevelopColumn
        lightroomConstraints = [
            topEdge.topAnchor.constraint(equalTo: content.topAnchor), topEdge.leadingAnchor.constraint(equalTo: content.leadingAnchor), topEdge.trailingAnchor.constraint(equalTo: content.trailingAnchor), topEdge.heightAnchor.constraint(equalToConstant: g),
            modulePicker.topAnchor.constraint(equalTo: topEdge.bottomAnchor), modulePicker.leadingAnchor.constraint(equalTo: content.leadingAnchor), modulePicker.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            modulePicker.heightAnchor.constraint(equalToConstant: top ? 44 : 0),
            bottomEdge.bottomAnchor.constraint(equalTo: content.bottomAnchor), bottomEdge.leadingAnchor.constraint(equalTo: content.leadingAnchor), bottomEdge.trailingAnchor.constraint(equalTo: content.trailingAnchor), bottomEdge.heightAnchor.constraint(equalToConstant: g),
            shelf.bottomAnchor.constraint(equalTo: bottomEdge.topAnchor), shelf.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: g), shelf.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -g),
            filmstripBar.bottomAnchor.constraint(equalTo: shelf.topAnchor), filmstripBar.leadingAnchor.constraint(equalTo: shelf.leadingAnchor), filmstripBar.trailingAnchor.constraint(equalTo: shelf.trailingAnchor),
            filmstripBar.heightAnchor.constraint(equalToConstant: bottom ? 24 : 0),
            leftEdge.leadingAnchor.constraint(equalTo: content.leadingAnchor), leftEdge.widthAnchor.constraint(equalToConstant: g), leftEdge.topAnchor.constraint(equalTo: modulePicker.bottomAnchor), leftEdge.bottomAnchor.constraint(equalTo: filmstripBar.topAnchor),
            rightEdge.trailingAnchor.constraint(equalTo: content.trailingAnchor), rightEdge.widthAnchor.constraint(equalToConstant: g), rightEdge.topAnchor.constraint(equalTo: modulePicker.bottomAnchor), rightEdge.bottomAnchor.constraint(equalTo: filmstripBar.topAnchor),
            navigatorBox.leadingAnchor.constraint(equalTo: leftEdge.trailingAnchor), navigatorBox.topAnchor.constraint(equalTo: modulePicker.bottomAnchor), navigatorBox.widthAnchor.constraint(equalToConstant: 250),
            // The Navigator keeps its own height (header, 160-point preview and padding) so the panel below gets the rest.
            navigatorBox.heightAnchor.constraint(equalToConstant: navigatorSection.isOpen ? 210 : 28),
            librarySidebar.leadingAnchor.constraint(equalTo: navigatorBox.leadingAnchor), librarySidebar.topAnchor.constraint(equalTo: navigatorBox.bottomAnchor), librarySidebar.bottomAnchor.constraint(equalTo: libraryButtons.topAnchor),
            libraryButtons.leadingAnchor.constraint(equalTo: navigatorBox.leadingAnchor), libraryButtons.widthAnchor.constraint(equalToConstant: 250), libraryButtons.bottomAnchor.constraint(equalTo: filmstripBar.topAnchor), libraryButtons.heightAnchor.constraint(equalToConstant: 40),
            develop.leadingAnchor.constraint(equalTo: navigatorBox.leadingAnchor), develop.widthAnchor.constraint(equalToConstant: 250), develop.topAnchor.constraint(equalTo: navigatorBox.bottomAnchor), develop.bottomAnchor.constraint(equalTo: filmstripBar.topAnchor),
            info.trailingAnchor.constraint(equalTo: rightEdge.leadingAnchor), info.topAnchor.constraint(equalTo: modulePicker.bottomAnchor), info.bottomAnchor.constraint(equalTo: filmstripBar.topAnchor),
            center.topAnchor.constraint(equalTo: modulePicker.bottomAnchor),
            center.leadingAnchor.constraint(equalTo: left ? navigatorBox.trailingAnchor : leftEdge.trailingAnchor),
            center.trailingAnchor.constraint(equalTo: right ? info.leadingAnchor : rightEdge.leadingAnchor),
            center.bottomAnchor.constraint(equalTo: developToolbar.topAnchor),
            developToolbar.leadingAnchor.constraint(equalTo: center.leadingAnchor), developToolbar.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            developToolbar.bottomAnchor.constraint(equalTo: filmstripBar.topAnchor), developToolbar.heightAnchor.constraint(equalToConstant: toolbar ? 30 : 0),
        ]
        NSLayoutConstraint.activate(lightroomConstraints)
        applyLights()
        updateLightroomBars()
    }

    /// Lights Out (L): dims the panels, then turns them off, leaving the photo.
    fileprivate func applyLights() {
        let lr = layoutMode == .lightroom
        let level = lr ? lights : .normal
        for v in lightroomChrome where v !== info && v !== shelf && v !== librarySidebar { v.alphaValue = level.chromeOpacity }
        for v in [info, shelf, librarySidebar] as [NSView] { v.alphaValue = lr ? level.chromeOpacity : 1 }
        guard lr else { return }
        workspaceContent.color = level == .normal ? LRColors.backdrop : .black
        canvas.backdrop = [LRColors.canvas, NSColor(calibratedWhite: 0.05, alpha: 1), .black][level.rawValue]
    }

    /// Shows or hides a panel (the edge triangles and F5–F8). In the Luminar layout the side panels map to the folders and inspector.
    fileprivate func togglePanel(_ edge: PanelEdge) {
        if layoutMode == .lightroom { LightroomState.shared.update { $0.toggle(edge) }; updateWorkspaceLayout(); return }
        switch edge {
        case .left: foldersVisible.toggle(); updateWorkspaceLayout()
        case .right: toggleInspector()
        default: break
        }
    }
    @objc func toggleModulePicker() { togglePanel(.top) }
    @objc func toggleFilmstripPanel() { togglePanel(.bottom) }
    @objc func toggleLeftPanel() { togglePanel(.left) }
    @objc func toggleRightPanel() { togglePanel(.right) }
    @objc func showMapModule() { chooseModule(.map) }
    @objc func showSlideshowModule() { chooseModule(.slideshow) }
    @objc func showPrintModule() { chooseModule(.print) }
    @objc func showWebModule() { chooseModule(.web) }

    fileprivate func chooseModule(_ module: LightroomModule) {
        switch module {
        case .library: showLibrary()
        case .develop: showEditor()
        default:
            guard !urls.isEmpty || !shootCatalog.isEmpty else { info.status("Open a folder of photos first."); NSSound.beep(); return }
            withLibrary { $0.openModule(module) }
        }
    }
    /// Runs `action` on the library once it has read its photos, creating it if needed.
    func withLibrary(attempt: Int = 0, _ action: @escaping (ShootWindow) -> Void) {
        if libraryBrowser == nil { refreshLibrary() }
        guard let browser = libraryBrowser else { return }
        if browser.visibleURLs.isEmpty, attempt < 15 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.withLibrary(attempt: attempt + 1, action) }
            return
        }
        action(browser)
    }

    /// Lightroom's single keys: G, D, R, Q, Shift-W, L, T, Tab and Shift-Tab.
    fileprivate func handleWorkspaceKey(_ id: String) -> Bool {
        guard view.window?.isKeyWindow == true, view.window?.attachedSheet == nil else { return false }
        let lr = layoutMode == .lightroom
        switch id {
        case "workspace.grid": if isLibrary { libraryBrowser?.setViewMode(.grid) }; showLibrary()
        case "workspace.develop": if isLibrary { showEditor() }
        case "workspace.crop": openTool("crop")
        case "workspace.remove": openTool("remove")
        case "workspace.masking": openTool("masking")
        case "workspace.lightsOut":
            guard lr else { return false }
            lights = lights.next; applyLights()
        case "workspace.toolbar":
            guard lr else { return false }
            LightroomState.shared.update { $0.toolbarHidden.toggle() }; updateWorkspaceLayout()
        case "workspace.sidePanels", "workspace.allPanels":
            if lr {
                let all = id == "workspace.allPanels"
                LightroomState.shared.update { panels in if all { panels.toggleAllPanels() } else { panels.toggleSidePanels() } }
                updateWorkspaceLayout()
            }
            else { toggleInspector() }
        default: return false
        }
        return true
    }
    /// Crop, Remove or Masking: the Lightroom tool strip, or the matching tool in the Luminar panel.
    fileprivate func openTool(_ id: String) {
        if isLibrary { showEditor() }
        guard layoutMode == .lightroom else {
            infoVisible = true; updateWorkspaceLayout()
            switch id { case "crop": info.openTool("Crop & rotate"); case "remove": info.openTool("Retouch"); default: info.openCurrentMask() }
            return
        }
        if !lrPanels.isVisible(.right) { LightroomState.shared.update { $0.hidden.remove(.right) }; updateWorkspaceLayout() }
        let next = info.lightroomToolOpen == id ? nil : id
        info.showLightroomTool(next); lightroomToolChanged(next)
    }
    /// Choosing Crop starts the crop overlay; closing it applies the crop, as Lightroom's Done does.
    fileprivate func lightroomToolChanged(_ id: String?) {
        if id == "redeye" { editingCommand("eye:redEye"); return }
        if canvas.tool == .eyeFix { canvas.clearTool() }
        if id == "crop" { editingCommand("crop") }
        else if canvas.tool == .crop { editingCommand("applyCrop") }
    }

    /// Commands from the Lightroom panels' buttons.
    func lightroomCommand(_ name: String) {
        switch name {
        case "lr:metadata", "lr:syncMetadata": withLibrary { $0.openMetadataEditor() }
        case "lr:syncSettings": withLibrary { $0.syncSettings() }
        case "lr:copy", "lr:paste":
            guard let url = currentSource else { info.status("Open a photo first."); return }
            withLibrary { [weak self] browser in self?.info.status(name == "lr:copy" ? browser.copySettings(from: url) : browser.pasteSettings(to: url)) }
        default: break
        }
    }

    /// The Library's right panel follows the grid selection: its histogram (from the saved preview), keywords and metadata.
    func updateLibraryInspector() {
        guard layoutMode == .lightroom, isLibrary else { return }
        updateLibraryPanels(); updateSecondaryDisplay()
        guard let item = libraryBrowser?.selectedItems.first else { info.showKeywords(nil); info.show(nil); info.updateHistogram(nil, sensor: nil); return }
        info.showKeywords(item.record.metadata?.keywords ?? [])
        if let index = urls.firstIndex(of: item.url) { collection.selectSingle(index); collection.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .centeredHorizontally) }
        let token = UUID(); libraryInspectorToken = token
        let request = RenderRequest(photo: item.record, profile: .displayP3, maximumDimension: 420)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let metadata = PhotoMetadata.read(item.url)
            let histogram = PreviewCache.read(request).map { PhotoHistogram.measure(CIImage(cgImage: $0)) }
            DispatchQueue.main.async {
                guard let self, self.libraryInspectorToken == token, self.isLibrary else { return }
                self.info.show(metadata); self.info.updateHistogram(histogram, sensor: nil)
            }
        }
        updateLightroomBars()
    }

    /// The filmstrip's source line, the Develop toolbar and the Navigator.
    func updateLightroomBars() {
        guard layoutMode == .lightroom else { return }
        let chosen = isLibrary ? (libraryBrowser?.selectedItems.map(\.url) ?? []) : collection.selectionIndexPaths.map(\.item).sorted().filter { urls.indices.contains($0) }.map { urls[$0] }
        let count = isLibrary ? (libraryBrowser?.visibleURLs.count ?? urls.count) : urls.count
        filmstripBar.show(source: openCollection == nil ? "Folder" : "Collection", name: openCollection?.name ?? folderURL?.lastPathComponent ?? "No folder open",
                          count: count, selected: chosen.count, file: chosen.first?.lastPathComponent)
        developToolbar.show(split: splitCompare, clipping: showClipping, zoom: canvas.image == nil ? "" : (canvas.isFit ? "Fit" : "\(canvas.zoomPercent)%"))
        zoomLinks.selected = canvas.isFit ? 0 : [100: 1, 200: 2][canvas.zoomPercent] ?? -1
        navigator.needsDisplay = true
    }
}

extension Notification.Name {
    /// Settings or the View menu switched between the Lightroom Classic and EZ layouts.
    static let workspaceLayoutChanged = Notification.Name("OpenStillWorkspaceLayoutChanged")
}
