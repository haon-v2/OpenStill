import AppKit
import MapKit
import UniformTypeIdentifiers
import OpenStillCore

/// Called with the photos to show in the library and a short description of them.
typealias ShowPhotos = (Set<UUID>, String) -> Void

// MARK: - People

private final class FaceCell: NSCollectionViewItem {
    let preview = NSImageView(), caption = NSTextField(labelWithString: "")
    var faceID: UUID?
    override func loadView() {
        view = NSView(); view.wantsLayer = true; view.layer?.cornerRadius = 8
        preview.imageScaling = .scaleProportionallyUpOrDown; preview.wantsLayer = true; preview.layer?.cornerRadius = 6; preview.layer?.masksToBounds = true
        caption.font = .systemFont(ofSize: 10); caption.textColor = .secondaryLabelColor; caption.alignment = .center; caption.lineBreakMode = .byTruncatingTail
        for v in [preview, caption] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: view.topAnchor, constant: 4), preview.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4), preview.heightAnchor.constraint(equalTo: preview.widthAnchor),
            caption.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 3), caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            caption.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
        ])
    }
    override var isSelected: Bool { didSet { view.layer?.borderWidth = isSelected ? 2 : 0; view.layer?.borderColor = Appearance.accent.cgColor } }
}

/// Faces found in the library's photos, grouped into people. Detection and grouping run on this Mac.
final class PeopleWindow: OutputWindow, NSTableViewDataSource, NSTableViewDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private enum Entry { case person(Person), group(Int, [Face]) }
    var show: ShowPhotos?
    /// Records changed (People keywords); the library refreshes.
    var changedRecords: (() -> Void)?
    private let list = NSTableView(), grid = NSCollectionView()
    private var entries: [Entry] = []
    private var faces: [(face: Face, suggested: Bool)] = []
    private let urls: [UUID: URL]
    private let queue = OperationQueue(), cache = NSCache<NSString, NSImage>()
    private var scanning = false, closed = false
    private lazy var strictness = popup(["Strict", "Normal", "Loose"], selected: 1)
    private var threshold: Float { [0.45, FaceClustering.defaultThreshold, 0.75][max(0, strictness.indexOfSelectedItem)] }
    private var catalog: LibraryCatalog? { EditStorage.records.catalog }

    init(items: [ShootItem]) {
        urls = Dictionary(items.map { ($0.id, $0.url) }, uniquingKeysWith: { a, _ in a })
        let split = NSStackView(); split.spacing = 12; split.alignment = .top
        super.init(title: "People · OpenStill", items: items, size: NSSize(width: 980, height: 640), content: split)
        queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .utility; cache.countLimit = 600
        let column = NSTableColumn(identifier: .init("name")); column.title = "People"; list.addTableColumn(column)
        list.headerView = nil; list.dataSource = self; list.delegate = self; list.rowHeight = 22; list.setAccessibilityLabel("People and groups of faces")
        let listScroll = NSScrollView(); listScroll.documentView = list; listScroll.hasVerticalScroller = true
        listScroll.widthAnchor.constraint(equalToConstant: 220).isActive = true; listScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true
        let flow = NSCollectionViewFlowLayout(); flow.itemSize = NSSize(width: 104, height: 124); flow.minimumInteritemSpacing = 8; flow.minimumLineSpacing = 8
        flow.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        grid.collectionViewLayout = flow; grid.isSelectable = true; grid.allowsMultipleSelection = true; grid.dataSource = self; grid.delegate = self
        grid.register(FaceCell.self, forItemWithIdentifier: .init("face")); grid.backgroundColors = [.clear]; grid.setAccessibilityLabel("Faces")
        let gridScroll = NSScrollView(); gridScroll.documentView = grid; gridScroll.hasVerticalScroller = true; gridScroll.drawsBackground = false
        gridScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true
        split.addArrangedSubview(listScroll); split.addArrangedSubview(gridScroll)
        row("Grouping", strictness)
        button("Find Faces", #selector(scan))
        button("Not This Person", #selector(notThisPerson))
        button("Show Photos", #selector(showPhotos))
        button("Name…", #selector(name), primary: true)
        status.stringValue = "Find Faces looks through the \(items.count) photos shown in the library. Faces are grouped by appearance; name a group and OpenStill suggests more faces of that person."
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowWillClose(_ notification: Notification) { closed = true; queue.cancelAllOperations() }

    override func changed() {
        guard !busy else { return }
        try? catalog?.updateFaceClusters(threshold: threshold); reload()
    }
    private func reload(keeping selection: Int? = nil) {
        guard let catalog else { status.stringValue = "The library catalog isn’t available."; return }
        entries = catalog.people().map { .person($0) } + catalog.unnamedGroups().enumerated().map { .group($0.offset + 1, $0.element) }
        list.reloadData()
        let row = min(selection ?? max(0, list.selectedRow), entries.count - 1)
        if row >= 0 { list.selectRowIndexes([row], byExtendingSelection: false) }
        showSelection()
    }
    private var selectedEntry: Entry? { entries.indices.contains(list.selectedRow) ? entries[list.selectedRow] : nil }
    private func showSelection() {
        switch selectedEntry {
        case .person(let p)?:
            let named = catalog?.faces(person: p.id).map { (face: $0, suggested: false) } ?? []
            let suggested = catalog?.suggestions(for: p.id, threshold: threshold).map { (face: $0.face, suggested: true) } ?? []
            faces = named + suggested
        case .group(_, let members)?: faces = members.map { (face: $0, suggested: false) }
        case nil: faces = []
        }
        grid.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        switch entries[row] {
        case .person(let p): text = "\(p.name) · \(p.photoCount)"
        case .group(let n, let members): text = "Unnamed \(n) · \(members.count) faces"
        }
        let label = NSTextField(labelWithString: text); label.lineBreakMode = .byTruncatingTail
        if case .group = entries[row] { label.textColor = .secondaryLabelColor }
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { showSelection() }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { faces.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: .init("face"), for: indexPath) as! FaceCell
        let entry = faces[indexPath.item], face = entry.face
        cell.faceID = face.id
        cell.caption.stringValue = entry.suggested ? "Suggested" : (urls[face.photoID]?.lastPathComponent ?? catalog?.photo(face.photoID)?.filename ?? "")
        cell.caption.textColor = entry.suggested ? Appearance.accent : .secondaryLabelColor
        cell.view.setAccessibilityLabel((entry.suggested ? "Suggested face in " : "Face in ") + cell.caption.stringValue)
        let key = face.id.uuidString as NSString
        if let image = cache.object(forKey: key) { cell.preview.image = image; return cell }
        cell.preview.image = Appearance.symbol("person.crop.square", size: 28)
        let url = urls[face.photoID] ?? catalog?.photo(face.photoID).map { URL(fileURLWithPath: $0.path) }
        queue.addOperation { [weak self, weak cell] in
            guard let url, let image = Self.thumbnail(url, face.rect) else { return }
            DispatchQueue.main.async { self?.cache.setObject(image, forKey: key); if cell?.faceID == face.id { cell?.preview.image = image } }
        }
        return cell
    }
    /// The face with some margin, from a small rendition of the photo.
    nonisolated static func thumbnail(_ url: URL, _ rect: CGRect) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 1024] as CFDictionary) else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height), side = max(rect.width * w, rect.height * h) * 1.5
        let box = CGRect(x: rect.midX * w - side / 2, y: rect.midY * h - side / 2, width: side, height: side).intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
        guard let crop = image.cropping(to: box) else { return nil }
        return NSImage(cgImage: crop, size: .zero)
    }
    private var selectedFaces: [(face: Face, suggested: Bool)] { grid.selectionIndexPaths.sorted().compactMap { faces.indices.contains($0.item) ? faces[$0.item] : nil } }

    @objc private func scan() {
        guard let catalog, !busy else { return }
        busy = true; scanning = true
        let items = self.items, threshold = self.threshold
        status.stringValue = "Looking for faces…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found = 0, scanned = 0
            for (i, item) in items.enumerated() {
                if self?.closed ?? true { return }
                guard catalog.needsFaceScan(item.id, fingerprint: item.record.contentFingerprint) else { continue }
                let faces = autoreleasepool { FaceDetector.detect(item.url) }
                try? catalog.replaceFaces(for: item.id, fingerprint: item.record.contentFingerprint, faces)
                found += faces.count; scanned += 1
                if i % 5 == 0 { DispatchQueue.main.async { self?.status.stringValue = "Looking for faces… \(i + 1) of \(items.count)" } }
            }
            try? catalog.updateFaceClusters(threshold: threshold)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                self.finish(scanned == 0 ? "All \(items.count) photos were already scanned. \(catalog.faceCount) faces in the library." : "Scanned \(scanned) photos and found \(found) faces.")
                self.reload()
            }
        }
    }
    @objc private func name() {
        guard let catalog, let window else { return }
        var chosen = selectedFaces.map(\.face)
        if chosen.isEmpty, case .group(_, let members)? = selectedEntry { chosen = members }
        if chosen.isEmpty, case .person? = selectedEntry { chosen = faces.filter(\.suggested).map(\.face) }
        guard !chosen.isEmpty else { status.stringValue = "Select faces to name."; return }
        let alert = NSAlert(); alert.messageText = "Who is this?"
        alert.informativeText = "\(chosen.count) face\(chosen.count == 1 ? "" : "s"). The name is added to each photo as a “People” keyword."
        let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 260, height: 26)); field.addItems(withObjectValues: catalog.people().map(\.name)); field.completes = true
        if case .person(let p)? = selectedEntry { field.stringValue = p.name }
        alert.accessoryView = field; alert.addButton(withTitle: "Name"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            do {
                let person = try catalog.person(named: field.stringValue)
                try catalog.assign(chosen.map(\.id), to: person.id)
                self.syncKeywords(Set(chosen.map(\.photoID)))
                try? catalog.updateFaceClusters(threshold: self.threshold)
                self.reload(keeping: catalog.people().firstIndex { $0.id == person.id })
                self.status.stringValue = "Named \(chosen.count) face\(chosen.count == 1 ? "" : "s") \(person.name)."
            } catch { self.status.stringValue = error.localizedDescription }
        }
    }
    @objc private func notThisPerson() {
        guard let catalog, case .person(let p)? = selectedEntry else { status.stringValue = "Choose a person, then select the faces that aren’t them."; return }
        let chosen = selectedFaces.map(\.face); guard !chosen.isEmpty else { status.stringValue = "Select the faces that aren’t \(p.name)."; return }
        do {
            try catalog.reject(chosen.map(\.id), from: p.id)
            syncKeywords(Set(chosen.map(\.photoID))); try? catalog.updateFaceClusters(threshold: threshold)
            reload(); status.stringValue = "\(chosen.count) face\(chosen.count == 1 ? "" : "s") won’t be suggested as \(p.name) again."
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func showPhotos() {
        guard let catalog else { return }
        switch selectedEntry {
        case .person(let p)?: show?(Set(catalog.photos(with: p.id)), p.name)
        case .group(let n, let members)?: show?(Set(members.map(\.photoID)), "Unnamed \(n)")
        case nil: status.stringValue = "Choose a person or group first."
        }
    }
    /// Keeps each photo's "People > Name" keywords matching its named faces.
    private func syncKeywords(_ photos: Set<UUID>) {
        guard let catalog else { return }
        var changed = false
        for id in photos { if (try? PeopleKeywords.sync(id, catalog: catalog, store: EditStorage.records)) != nil { changed = true } }
        if changed { changedRecords?() }
    }
}

// MARK: - Map

private final class PhotoPin: MKPointAnnotation {
    let photoID: UUID
    init(_ id: UUID, _ location: GeoLocation, title: String) {
        photoID = id; super.init()
        coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude); self.title = title
    }
}
/// Accepts photos dragged from the list and reports where they were dropped.
private final class MapDropView: MKMapView {
    var dropped: (([UUID], CLLocationCoordinate2D) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.string]) }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let ids = (sender.draggingPasteboard.readObjects(forClasses: [NSString.self]) as? [String] ?? []).flatMap { $0.split(separator: "\n") }.compactMap { UUID(uuidString: String($0)) }
        guard !ids.isEmpty else { return false }
        dropped?(ids, convert(convert(sender.draggingLocation, from: nil), toCoordinateFrom: self)); return true
    }
}

/// Photos with a location on a map. Drag photos from the list onto the map, or drag a pin, to set where they were taken.
final class MapWindow: OutputWindow, MKMapViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var show: ShowPhotos?
    var changedRecords: (() -> Void)?
    private let map = MapDropView(frame: NSRect(x: 0, y: 0, width: 640, height: 460))
    private let list = NSTableView()
    private var library: [ShootItem]
    private var unplaced: [ShootItem] = []

    init(items: [ShootItem]) {
        library = items
        let split = NSStackView(); split.spacing = 12; split.alignment = .top
        super.init(title: "Map · OpenStill", items: items, size: NSSize(width: 1040, height: 660), content: split)
        let column = NSTableColumn(identifier: .init("name")); column.title = "Without a location"; list.addTableColumn(column)
        list.dataSource = self; list.delegate = self; list.allowsMultipleSelection = true; list.rowHeight = 20
        list.setDraggingSourceOperationMask(.copy, forLocal: true); list.setAccessibilityLabel("Photos without a location. Drag onto the map to place them.")
        let scroll = NSScrollView(); scroll.documentView = list; scroll.hasVerticalScroller = true
        scroll.widthAnchor.constraint(equalToConstant: 220).isActive = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
        map.delegate = self; map.showsZoomControls = true; map.showsCompass = true; map.setAccessibilityLabel("Map of photo locations")
        map.heightAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true; map.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
        map.dropped = { [weak self] ids, coordinate in self?.place(ids, at: GeoLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) }
        split.addArrangedSubview(scroll); split.addArrangedSubview(map)
        button("Import GPX Track…", #selector(importGPX))
        button("Place Selected at Map Centre", #selector(placeAtCentre))
        button("Show Photos in View", #selector(showVisible), primary: true)
        reload(fit: true)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func location(_ item: ShootItem) -> GeoLocation? {
        item.record.geotag ?? item.facts.flatMap { f in f.latitude.flatMap { lat in f.longitude.flatMap { GeoLocation(latitude: lat, longitude: $0).valid } } }
    }
    private func reload(fit: Bool = false) {
        map.removeAnnotations(map.annotations)
        var pins: [PhotoPin] = []
        for item in library { if let g = location(item) { pins.append(PhotoPin(item.id, g, title: item.url.lastPathComponent)) } }
        map.addAnnotations(pins)
        unplaced = library.filter { location($0) == nil }
        list.reloadData()
        if fit, !pins.isEmpty { map.showAnnotations(pins, animated: false) }
        status.stringValue = "\(pins.count) of \(library.count) photos have a location. Drag photos from the list onto the map, or drag a pin to move it. The map comes from Apple Maps, so viewing it downloads map tiles."
    }
    private func place(_ ids: [UUID], at location: GeoLocation) {
        guard let g = location.valid else { return }
        var placed = 0
        for id in ids {
            guard let updated = try? EditStorage.records.update(id, { $0.geotag = g }) else { continue }
            if let i = library.firstIndex(where: { $0.id == id }) { library[i].record = updated }
            placed += 1
        }
        reload(); changedRecords?()
        status.stringValue = "Placed \(placed) photo\(placed == 1 ? "" : "s") at \(String(format: "%.5f, %.5f", g.latitude, g.longitude))."
    }
    @objc private func placeAtCentre() {
        let ids = list.selectedRowIndexes.compactMap { unplaced.indices.contains($0) ? unplaced[$0].id : nil }
        guard !ids.isEmpty else { status.stringValue = "Select photos in the list first."; return }
        place(ids, at: GeoLocation(latitude: map.centerCoordinate.latitude, longitude: map.centerCoordinate.longitude))
    }
    @objc private func showVisible() {
        let ids = Set(map.annotations(in: map.visibleMapRect).compactMap { ($0 as? PhotoPin)?.photoID })
        guard !ids.isEmpty else { status.stringValue = "No photos in this part of the map."; return }
        show?(ids, "Map area")
    }
    @objc private func importGPX() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "gpx") ?? .xml, .xml]; panel.message = "Choose a GPX track from a phone, watch or GPS logger."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { self.match(try GPXTrack.read(url), name: url.lastPathComponent) } catch { self.status.stringValue = error.localizedDescription }
        }
    }
    /// Asks for the camera's time zone and clock error, then places photos whose capture time falls on the track.
    private func match(_ track: GPXTrack, name: String) {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "Match photos to \(name)"
        alert.informativeText = "Photos are placed where the track was at their capture time. Photos that record their own time zone use it; for the others, choose the time zone the camera’s clock was set to."
        let zone = NSPopUpButton(); let here = TimeZone.current.secondsFromGMT()
        let offsets = stride(from: -12 * 3600, through: 14 * 3600, by: 1800).map { $0 }
        for o in offsets { zone.addItem(withTitle: "UTC" + (o < 0 ? "−" : "+") + String(format: "%d:%02d", abs(o) / 3600, abs(o) % 3600 / 60) + (o == here ? " (this Mac)" : "")) }
        zone.selectItem(at: offsets.firstIndex(of: here) ?? 24)
        let correction = NSTextField(string: "0"); correction.placeholderString = "minutes"
        let replace = NSButton(checkboxWithTitle: "Replace locations photos already have", target: nil, action: nil)
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Camera time zone"), zone], [NSTextField(labelWithString: "Camera clock was fast by"), NSStackView(views: [correction, NSTextField(labelWithString: "minutes")])], [NSView(), replace]])
        grid.frame = NSRect(x: 0, y: 0, width: 420, height: 96); alert.accessoryView = grid
        alert.addButton(withTitle: "Match"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let offset = TimeInterval(offsets[max(0, zone.indexOfSelectedItem)]), fast = (Double(correction.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 0) * 60
            let targets = self.library.filter { replace.state == .on || self.location($0) == nil }
            self.busy = true; self.status.stringValue = "Reading capture times…"
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let times = targets.compactMap { item in CaptureTime.read(item.url).map { (id: item.id, time: $0) } }
                let matches = track.match(times, assumedOffset: offset, clockCorrection: -fast)
                var placed: [UUID: PhotoRecord] = [:]
                for (id, g) in matches { if let r = try? EditStorage.records.update(id, { $0.geotag = g }) { placed[id] = r } }
                DispatchQueue.main.async {
                    guard let self else { return }
                    for (id, r) in placed { if let i = self.library.firstIndex(where: { $0.id == id }) { self.library[i].record = r } }
                    self.reload(fit: !placed.isEmpty); self.changedRecords?()
                    let missed = targets.count - placed.count
                    self.finish("Placed \(placed.count) of \(targets.count) photos." + (missed > 0 ? " \(missed) were taken outside the track’s time (or have no capture time)." : ""))
                }
            }
        }
    }
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard annotation is PhotoPin else { return nil }
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: "photo") as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "photo")
        view.annotation = annotation; view.isDraggable = true; view.canShowCallout = true; view.clusteringIdentifier = "photos"
        view.glyphImage = NSImage(systemSymbolName: "photo", accessibilityDescription: nil); view.markerTintColor = Appearance.accent
        return view
    }
    func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
        guard newState == .ending, let pin = view.annotation as? PhotoPin else { return }
        place([pin.photoID], at: GeoLocation(latitude: pin.coordinate.latitude, longitude: pin.coordinate.longitude))
    }
    func numberOfRows(in tableView: NSTableView) -> Int { unplaced.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: unplaced[row].url.lastPathComponent); label.lineBreakMode = .byTruncatingMiddle; return label
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        unplaced.indices.contains(row) ? unplaced[row].id.uuidString as NSString : nil
    }
}

// MARK: - Timeline

/// Photos by year, month and day of capture.
final class TimelineWindow: OutputWindow, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var show: ShowPhotos?
    private final class Node {
        let title: String, photos: [UUID], children: [Node]
        init(_ title: String, _ photos: [UUID], _ children: [Node] = []) { self.title = title; self.photos = photos; self.children = children }
    }
    private let outline = NSOutlineView()
    private var roots: [Node] = []
    init(items: [ShootItem]) {
        let scroll = NSScrollView()
        super.init(title: "Timeline · OpenStill", items: items, size: NSSize(width: 520, height: 620), content: scroll)
        let column = NSTableColumn(identifier: .init("date")); column.title = "Date"; outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.headerView = nil; outline.dataSource = self; outline.delegate = self; outline.rowHeight = 22; outline.target = self; outline.doubleAction = #selector(showSelected)
        outline.setAccessibilityLabel("Photos by year, month and day")
        scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
        let timeline = Timeline(items.map { item in (id: item.id, captured: item.facts?.captured ?? (item.captured == .distantPast ? nil : item.captured)) })
        roots = timeline.years.map { y in
            Node("\(y.year) · \(y.count)", y.photos, y.months.map { m in
                Node(Timeline.title(year: m.year, month: m.month) + " · \(m.count)", m.photos, m.days.map { d in Node(Timeline.title(d) + " · \(d.photos.count)", d.photos) })
            })
        }
        if !timeline.undated.isEmpty { roots.append(Node("No capture date · \(timeline.undated.count)", timeline.undated)) }
        outline.reloadData(); if let first = roots.first { outline.expandItem(first) }
        button("Show Photos", #selector(showSelected), primary: true)
        status.stringValue = "Double-click a year, month or day to show its photos in the library."
    }
    required init?(coder: NSCoder) { fatalError() }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? Node)?.children[index] ?? roots[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? Node)?.children.isEmpty ?? true) }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        NSTextField(labelWithString: (item as? Node)?.title ?? "")
    }
    @objc private func showSelected() {
        guard let node = outline.item(atRow: outline.selectedRow) as? Node else { status.stringValue = "Choose a year, month or day."; return }
        show?(Set(node.photos), node.title.components(separatedBy: " · ").first ?? node.title)
    }
}
