import AppKit
import AVFoundation
import PDFKit
import UniformTypeIdentifiers
import OpenStillCore

/// Shared scaffolding for the output windows: a form on the left, content on the right, buttons and status at the bottom.
class OutputWindow: NSWindowController, NSWindowDelegate {
    let items: [ShootItem]
    let status = NSTextField(wrappingLabelWithString: "")
    let form = NSGridView()
    let buttons = NSStackView()
    let progress = NSProgressIndicator()
    var busy = false { didSet { progress.isHidden = !busy; for case let control as NSControl in buttons.arrangedSubviews { control.isEnabled = !busy } } }
    init(title: String, items: [ShootItem], size: NSSize, content: NSView? = nil) {
        self.items = items
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = title; window.delegate = self; window.isReleasedWhenClosed = false; window.center(); Appearance.configure(window)
        let root = Appearance.panel(in: window)
        form.rowSpacing = 10; form.columnSpacing = 10
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 3
        progress.style = .spinning; progress.controlSize = .small; progress.isHidden = true
        buttons.spacing = 8; buttons.insertArrangedSubview(progress, at: 0); buttons.insertArrangedSubview(NSView(), at: 1)
        let left = NSStackView(views: [form]); left.orientation = .vertical; left.alignment = .leading
        let body = NSStackView(views: content.map { [left, $0] } ?? [left]); body.spacing = 18; body.alignment = .top
        let stack = NSStackView(views: [body, status, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        if let content { content.setContentHuggingPriority(.defaultLow, for: .horizontal); content.setContentHuggingPriority(.defaultLow, for: .vertical) }
    }
    required init?(coder: NSCoder) { fatalError() }
    func row(_ title: String, _ control: NSView) {
        let label = NSTextField(labelWithString: title); label.alignment = .right
        form.addRow(with: [label, control]); (control as? NSControl)?.setAccessibilityLabel(title)
    }
    func popup(_ titles: [String], selected: Int = 0) -> NSPopUpButton {
        let p = NSPopUpButton(); p.addItems(withTitles: titles); p.selectItem(at: selected); p.target = self; p.action = #selector(changed); return p
    }
    func checkbox(_ title: String, _ on: Bool) -> NSButton { let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(changed)); b.state = on ? .on : .off; return b }
    @discardableResult func button(_ title: String, _ action: Selector, primary: Bool = false) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded
        if primary { Appearance.primary(b); b.keyEquivalent = "\r" }
        buttons.addArrangedSubview(b); return b
    }
    @objc func changed() {}
    /// The edited photos, rendered for output (SDR rendition).
    nonisolated static func render(_ item: ShootItem) throws -> CIImage { try ModernRenderer.render(source: item.url, recipe: item.record.active.recipe.sdr) }
    func finish(_ message: String) { busy = false; status.stringValue = message }
}

// MARK: Print

final class PrintWindow: OutputWindow {
    private var layout = PrintLayout()
    private let preview = NSImageView(), pageLabel = NSTextField(labelWithString: "")
    private lazy var style = popup(PrintStyle.allCases.map(\.title))
    private lazy var paper = popup(PaperSize.all.map(\.name))
    private lazy var landscape = checkbox("Landscape", false)
    private let rows = NSTextField(string: "2"), columns = NSTextField(string: "2")
    private lazy var margin = popup(["No margins", "¼ inch", "½ inch", "¾ inch", "1 inch"], selected: 2)
    private lazy var caption = popup(PrintCaption.allCases.map(\.title))
    private lazy var sharpening = popup(PrintSharpening.allCases.map(\.title), selected: 2)
    private lazy var resolution = popup(["180 dpi", "240 dpi", "300 dpi", "360 dpi"], selected: 2)
    private let profileName = NSTextField(labelWithString: "sRGB (let the printer driver manage color)")
    private var previewToken = UUID()

    init(items: [ShootItem]) {
        let side = NSStackView(); side.orientation = .vertical; side.spacing = 6
        super.init(title: "Print · OpenStill", items: items, size: NSSize(width: 900, height: 640), content: side)
        preview.imageScaling = .scaleProportionallyUpOrDown; preview.wantsLayer = true; preview.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        preview.setAccessibilityLabel("Preview of the first page")
        pageLabel.font = .systemFont(ofSize: 11); pageLabel.textColor = .secondaryLabelColor
        side.addArrangedSubview(preview); side.addArrangedSubview(pageLabel)
        preview.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true; preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true
        for field in [rows, columns] { field.target = self; field.action = #selector(changed); field.widthAnchor.constraint(equalToConstant: 44).isActive = true }
        let grid = NSStackView(views: [rows, NSTextField(labelWithString: "rows ×"), columns, NSTextField(labelWithString: "columns")]); grid.spacing = 4
        row("Layout", style); row("Paper", paper); row("", landscape); row("Grid", grid); row("Margins", margin); row("Captions", caption)
        row("Print sharpening", sharpening); row("Resolution", resolution)
        let choose = NSButton(title: "Printer profile…", target: self, action: #selector(chooseProfile)); choose.bezelStyle = .rounded
        profileName.font = .systemFont(ofSize: 11); profileName.lineBreakMode = .byTruncatingMiddle
        row("Color", choose); row("", profileName)
        button("Save as JPEG…", #selector(saveJPEG)); button("Save as PDF…", #selector(savePDF)); button("Print…", #selector(printPages), primary: true)
        status.stringValue = "\(items.count) photo\(items.count == 1 ? "" : "s"). Sharpening is added for print only; your edits are unchanged."
        changed()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func changed() {
        layout.style = PrintStyle.allCases[max(0, style.indexOfSelectedItem)]
        layout.paper = PaperSize.all[max(0, paper.indexOfSelectedItem)]
        layout.landscape = landscape.state == .on
        layout.rows = Int(rows.stringValue) ?? 2; layout.columns = Int(columns.stringValue) ?? 2
        rows.isEnabled = layout.style == .grid; columns.isEnabled = layout.style == .grid
        layout.margin = [0, 18, 36, 54, 72][max(0, margin.indexOfSelectedItem)]
        layout.caption = PrintCaption.allCases[max(0, caption.indexOfSelectedItem)]
        layout.sharpening = PrintSharpening.allCases[max(0, sharpening.indexOfSelectedItem)]
        layout.dpi = [180, 240, 300, 360][max(0, resolution.indexOfSelectedItem)]
        layout = layout.sanitized
        let pages = PrintLayoutEngine.pages(count: items.count, layout: layout).count
        pageLabel.stringValue = "\(pages) page\(pages == 1 ? "" : "s") · \(layout.paper.name)\(layout.landscape ? ", landscape" : "")"
        renderPreview()
    }
    nonisolated private func printItems(_ indices: [Int]? = nil) throws -> [PrintItem] {
        let items = self.items
        return try (indices ?? Array(items.indices)).map { i in
            PrintItem(image: try Self.render(items[i]), filename: items[i].url.lastPathComponent, title: items[i].record.iptc.title)
        }
    }
    private func renderPreview() {
        let token = UUID(); previewToken = token
        let layout = layout, first = PrintLayoutEngine.pages(count: items.count, layout: layout).first ?? []
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = Result { () -> CGImage in
                let photos = try self.printItems(first)
                return try PrintLayoutEngine.pageImage(Array(photos.indices), items: photos, layout: layout, dpi: 60)
            }
            DispatchQueue.main.async {
                guard self.previewToken == token else { return }
                switch result {
                case .success(let page): self.preview.image = NSImage(cgImage: page, size: .zero)
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
            }
        }
    }
    @objc private func chooseProfile() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "icc") ?? .data, UTType(filenameExtension: "icm") ?? .data]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { self.layout.profileAsset = try SoftProof.importProfile(url); self.profileName.stringValue = url.lastPathComponent + " (RGB profiles convert; others print as sRGB)" }
            catch { self.status.stringValue = error.localizedDescription }
        }
    }
    private func work(_ message: String, _ job: @escaping ([PrintItem]) throws -> String) {
        busy = true; status.stringValue = message
        let items = self.items
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = Result { try job(try self.printItems(Array(items.indices))) }
            DispatchQueue.main.async {
                switch result { case .success(let text): self.finish(text); case .failure(let error): self.finish(error.localizedDescription) }
            }
        }
    }
    @objc private func savePDF() {
        guard let window else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = "Print.pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let layout = self.layout
            self.work("Rendering pages…") { photos in try PrintLayoutEngine.pdf(photos, layout: layout, to: url); return "Saved \(url.lastPathComponent)." }
        }
    }
    @objc private func saveJPEG() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Save Pages Here"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let folder = panel.url else { return }
            let layout = self.layout
            self.work("Rendering pages…") { photos in
                let files = try PrintLayoutEngine.jpegs(photos, layout: layout, to: folder)
                return "Saved \(files.count) page\(files.count == 1 ? "" : "s") as JPEG at \(layout.dpi) dpi."
            }
        }
    }
    @objc private func printPages() {
        let pdf = FileManager.default.temporaryDirectory.appendingPathComponent("OpenStill-print-\(UUID().uuidString).pdf"), layout = self.layout
        work("Rendering pages…") { photos in try PrintLayoutEngine.pdf(photos, layout: layout, to: pdf); return "" }
        // Print once the PDF exists.
        func waitAndPrint() {
            if busy { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: waitAndPrint); return }
            guard let window, let document = PDFDocument(url: pdf) else { return }
            let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
            info.paperSize = layout.pageSize; info.orientation = layout.landscape ? .landscape : .portrait
            info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
            guard let operation = document.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false) else { status.stringValue = "This Mac couldn’t start printing."; return }
            operation.showsPrintPanel = true; operation.showsProgressPanel = true
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            status.stringValue = "Sent to the print dialog. Choose your printer and paper there; set the driver to “No color adjustment” when using a printer profile."
        }
        waitAndPrint()
    }
}

// MARK: Web gallery

final class GalleryWindow: OutputWindow {
    private let titleField = NSTextField(string: "Gallery"), subtitle = NSTextField(string: "")
    private lazy var theme = popup(["Dark", "Light"])
    private lazy var size = popup(["1024 px", "2048 px", "3000 px"], selected: 1)
    private lazy var captions = checkbox("Show titles and captions", true)
    private lazy var metadata = checkbox("Keep camera and copyright details (never location)", false)
    private lazy var watermark = popup(["No watermark"] + Watermarks.library().map(\.name))

    init(items: [ShootItem]) {
        super.init(title: "Web Gallery · OpenStill", items: items, size: NSSize(width: 560, height: 420))
        for field in [titleField, subtitle] { field.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        subtitle.placeholderString = "Optional line under the title"
        row("Title", titleField); row("Subtitle", subtitle); row("Theme", theme); row("Photo size", size); row("", captions); row("", metadata); row("Watermark", watermark)
        button("Create Gallery…", #selector(create), primary: true)
        status.stringValue = "Writes a folder with index.html, your photos and thumbnails for \(items.count) photo\(items.count == 1 ? "" : "s"). Upload the folder to any web host; OpenStill doesn’t upload anything."
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func create() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Create Gallery Here"
        panel.message = "Choose an empty folder (or an earlier gallery to update)."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let folder = panel.url else { return }
            var settings = WebGallerySettings()
            settings.title = self.titleField.stringValue; settings.subtitle = self.subtitle.stringValue; settings.dark = self.theme.indexOfSelectedItem == 0
            settings.imageEdge = [1024, 2048, 3000][max(0, self.size.indexOfSelectedItem)]; settings.showCaptions = self.captions.state == .on; settings.keepMetadata = self.metadata.state == .on
            let logos = Watermarks.library()
            if self.watermark.indexOfSelectedItem > 0, logos.indices.contains(self.watermark.indexOfSelectedItem - 1) { settings.watermark = WatermarkSettings(asset: logos[self.watermark.indexOfSelectedItem - 1].asset) }
            let gallery = self.items.map { GalleryItem($0) }
            self.busy = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try WebGallery.build(gallery, settings: settings, into: folder, progress: { done, total in DispatchQueue.main.async { self?.status.stringValue = "Rendering \(min(done + 1, total)) of \(total)…" } }) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let index): self.finish("Gallery saved. Opened it in your browser to check before uploading."); NSWorkspace.shared.open(index)
                    case .failure(let error): self.finish(error.localizedDescription)
                    }
                }
            }
        }
    }
}

// MARK: Slideshow

final class SlideshowWindow: OutputWindow {
    private var settings = SlideshowSettings()
    private let seconds = NSSlider(value: 4, minValue: 1, maxValue: 15, target: nil, action: nil), secondsLabel = NSTextField(labelWithString: "")
    private lazy var transition = popup(SlideTransition.allCases.map(\.title), selected: 1)
    private lazy var kenBurns = checkbox("Slow zoom (Ken Burns)", true)
    private lazy var loop = checkbox("Loop", true)
    private lazy var resolution = popup(["720p", "1080p", "4K"], selected: 1)
    private let musicName = NSTextField(labelWithString: "No music")
    private var player: SlideshowPlayer?
    private var exportTask: Task<Void, Never>?

    init(items: [ShootItem]) {
        super.init(title: "Slideshow · OpenStill", items: items, size: NSSize(width: 520, height: 380))
        seconds.target = self; seconds.action = #selector(changed); seconds.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let timing = NSStackView(views: [seconds, secondsLabel]); timing.spacing = 6
        let chooseMusic = NSButton(title: "Choose…", target: self, action: #selector(chooseMusic)); chooseMusic.bezelStyle = .rounded
        let clearMusic = NSButton(title: "None", target: self, action: #selector(clearMusic)); clearMusic.bezelStyle = .rounded
        musicName.lineBreakMode = .byTruncatingMiddle
        row("Each photo", timing); row("Transition", transition); row("", kenBurns); row("", loop)
        row("Music", NSStackView(views: [chooseMusic, clearMusic])); row("", musicName); row("Video size", resolution)
        button("Export Video…", #selector(exportVideo)); button("Play", #selector(play), primary: true)
        changed()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func changed() {
        settings.secondsPerSlide = seconds.doubleValue.rounded(); settings.transition = SlideTransition.allCases[max(0, transition.indexOfSelectedItem)]
        settings.kenBurns = kenBurns.state == .on; settings.loop = loop.state == .on
        (settings.width, settings.height) = [(1280, 720), (1920, 1080), (3840, 2160)][max(0, resolution.indexOfSelectedItem)]
        secondsLabel.stringValue = "\(Int(settings.secondsPerSlide)) s"
        let total = Int(settings.duration(slides: items.count))
        status.stringValue = "\(items.count) photo\(items.count == 1 ? "" : "s") · \(total / 60):" + String(format: "%02d", total % 60) + ". In the show: Space pauses, ← → step, Esc ends."
    }
    @objc private func chooseMusic() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.settings.musicPath = url.path; self.musicName.stringValue = url.lastPathComponent
        }
    }
    @objc private func clearMusic() { settings.musicPath = nil; musicName.stringValue = "No music" }
    @objc private func play() {
        busy = true; status.stringValue = "Preparing photos…"
        let items = self.items, frame = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080), settings = self.settings
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Render once at screen size so playback only composites.
            let slides = items.compactMap { item -> CIImage? in
                guard let image = try? Self.render(item) else { return nil }
                let scale = min(1, 1.15 * max(frame.width * 2 / image.extent.width, frame.height * 2 / image.extent.height))
                let small = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
                return ModernRenderer.context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!).map { CIImage(cgImage: $0) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.finish(slides.isEmpty ? "No photos could be rendered." : "")
                guard !slides.isEmpty else { return }
                self.player = SlideshowPlayer(slides: slides, settings: settings); self.player?.start()
            }
        }
    }
    @objc private func exportVideo() {
        guard let window else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.quickTimeMovie]; panel.nameFieldStringValue = "Slideshow.mov"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.busy = true; self.status.stringValue = "Rendering photos…"
            let items = self.items, settings = self.settings
            self.exportTask = Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let slides = try items.map { try Self.render($0) }
                    try await SlideshowRenderer.exportVideo(slides, settings: settings, to: url, progress: { value in
                        DispatchQueue.main.async { self?.status.stringValue = "Writing video… \(Int(value * 100))%" }
                    })
                    await MainActor.run { self?.finish("Saved \(url.lastPathComponent)."); NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } catch {
                    await MainActor.run { self?.finish(error.localizedDescription) }
                }
            }
        }
    }
    func windowWillClose(_ notification: Notification) { player?.stop() }
}

/// Full-screen playback. Frames are composed with the same renderer as the exported video.
@MainActor final class SlideshowPlayer: NSObject {
    private let slides: [CIImage], settings: SlideshowSettings
    private var window: NSWindow?, layer = CALayer(), timer: Timer?, audio: AVAudioPlayer?
    private var began = Date(), pausedAt: Double?, offset = 0.0
    init(slides: [CIImage], settings: SlideshowSettings) { self.slides = slides; self.settings = settings.sanitized }
    private var time: Double { pausedAt ?? (Date().timeIntervalSince(began) + offset) }
    func start() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let window = KeyWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        window.level = .screenSaver; window.backgroundColor = .black; window.isReleasedWhenClosed = false
        let view = NSView(frame: screen.frame); view.wantsLayer = true; view.layer?.backgroundColor = .black
        layer.frame = view.bounds; layer.contentsGravity = .resizeAspect; view.layer?.addSublayer(layer)
        window.contentView = view
        window.keyDown = { [weak self] event in self?.key(event) }
        window.makeKeyAndOrderFront(nil); NSCursor.setHiddenUntilMouseMoves(true)
        self.window = window
        if let path = settings.musicPath { audio = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)); audio?.numberOfLoops = -1; audio?.play() }
        began = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        tick()
    }
    func stop() { timer?.invalidate(); timer = nil; audio?.stop(); window?.orderOut(nil); window = nil }
    private func tick() {
        var t = time
        let total = settings.duration(slides: slides.count)
        if t >= total { if settings.loop { offset -= total; t -= total } else { stop(); return } }
        guard let window else { return }
        let size = CGSize(width: window.frame.width * window.backingScaleFactor, height: window.frame.height * window.backingScaleFactor)
        let frame = SlideshowRenderer.frame(at: t, slides: slides, settings: settings, size: size)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.contents = ModernRenderer.context.createCGImage(frame, from: frame.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
        CATransaction.commit()
    }
    private func key(_ event: NSEvent) {
        let per = settings.secondsPerSlide
        switch event.keyCode {
        case 53: stop()                                                        // Esc
        case 49:                                                               // Space
            if let paused = pausedAt { pausedAt = nil; offset = paused; began = Date(); audio?.play() } else { pausedAt = time; audio?.pause() }
        case 123, 124:                                                         // ← →
            let slide = (Int(time / per) + (event.keyCode == 124 ? 1 : -1) + slides.count) % slides.count
            let target = Double(slide) * per + 0.01
            if pausedAt != nil { pausedAt = target } else { offset = target; began = Date() }
            tick()
        default: break
        }
    }
}
private final class KeyWindow: NSWindow {
    var keyDown: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) { keyDown?(event) }
}

// MARK: Publish

final class PublishWindow: OutputWindow, NSTableViewDataSource, NSTableViewDelegate {
    private var collections = PublishStore.load()
    private let library: [UUID: ShootItem]
    private let table = NSTableView(), summary = NSTextField(wrappingLabelWithString: "")
    private lazy var size = popup(["1024 px", "2048 px", "3000 px", "Full size"], selected: 1)
    private let album = NSTextField(string: "")
    private let connect = NSButton(title: "Connect…", target: nil, action: nil)
    private var pending: OAuthCredentials?

    init(items: [ShootItem], library: [ShootItem]) {
        self.library = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let side = NSStackView(); side.orientation = .vertical; side.alignment = .leading; side.spacing = 8
        super.init(title: "Publish · OpenStill", items: items, size: NSSize(width: 820, height: 520), content: side)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); column.title = "Publish collections"; column.width = 280; table.addTableColumn(column)
        table.dataSource = self; table.delegate = self; table.setAccessibilityLabel("Publish collections")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 300).isActive = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        let add = NSButton(title: "New Collection…", target: self, action: #selector(newCollection)); add.bezelStyle = .rounded
        let delete = NSButton(title: "Delete", target: self, action: #selector(deleteCollection)); delete.bezelStyle = .rounded
        form.addRow(with: [NSStackView(views: [add, delete])]); form.addRow(with: [scroll])
        summary.font = .systemFont(ofSize: 12)
        connect.target = self; connect.action = #selector(connectService); connect.bezelStyle = .rounded
        album.placeholderString = "SmugMug album key"; album.target = self; album.action = #selector(albumChanged); album.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let chooseFolder = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseFolder)); chooseFolder.bezelStyle = .rounded
        let addPhotos = NSButton(title: "Add \(items.count) Selected Photo\(items.count == 1 ? "" : "s")", target: self, action: #selector(addPhotos)); addPhotos.bezelStyle = .rounded
        let removePhotos = NSButton(title: "Remove Selected Photos", target: self, action: #selector(removePhotos)); removePhotos.bezelStyle = .rounded
        let sizeRow = NSStackView(views: [NSTextField(labelWithString: "Size"), size]); sizeRow.spacing = 6
        for view in [summary, NSStackView(views: [chooseFolder, connect]), album, sizeRow, NSStackView(views: [addPhotos, removePhotos])] as [NSView] { side.addArrangedSubview(view) }
        summary.widthAnchor.constraint(equalToConstant: 440).isActive = true
        button("Publish", #selector(publish), primary: true)
        status.stringValue = "A collection keeps track of what’s been published. Edit a photo and it shows as modified; Publish sends only new and modified photos, and removes photos you take out."
        table.reloadData(); if !collections.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    private var selected: Int? { collections.indices.contains(table.selectedRow) ? table.selectedRow : nil }
    func numberOfRows(in tableView: NSTableView) -> Int { collections.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let c = collections[row], cell = NSTextField(labelWithString: "\(c.name) · \(c.kind.title)"); cell.lineBreakMode = .byTruncatingTail; return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { refresh() }
    private func save() { do { try PublishStore.save(collections) } catch { status.stringValue = error.localizedDescription } }
    private func refresh() {
        guard let i = selected else { summary.stringValue = "Create a collection for a folder, Flickr or SmugMug."; connect.isHidden = true; album.isHidden = true; return }
        let c = collections[i]
        let states = c.photos.compactMap { library[$0] }.map { c.state(of: $0.record) }
        let missing = c.photos.count - states.count
        var text = "\(c.photos.count) photo\(c.photos.count == 1 ? "" : "s"): \(states.filter { $0 == .new }.count) new, \(states.filter { $0 == .modified }.count) modified, \(states.filter { $0 == .published }.count) published"
        if !c.pendingRemoval.isEmpty { text += ", \(c.pendingRemoval.count) to remove" }
        if missing > 0 { text += ". \(missing) aren’t in the open folder and are skipped." }
        switch c.kind {
        case .folder: text += "\nFolder: " + (c.folderPath ?? "not chosen")
        case .flickr, .smugmug: text += "\n" + (PublishStore.credentials(for: c)?.isAuthorized == true ? "Connected." : "Not connected.")
        }
        summary.stringValue = text
        connect.isHidden = c.kind == .folder; album.isHidden = c.kind != .smugmug; album.stringValue = c.albumKey ?? ""
        let edge = c.export.longestEdge
        size.selectItem(at: edge == 1024 ? 0 : edge == 3000 ? 2 : edge == nil ? 3 : 1)
    }
    override func changed() {
        guard let i = selected else { return }
        collections[i].export.longestEdge = [1024, 2048, 3000, nil][max(0, size.indexOfSelectedItem)]; save()
    }
    @objc private func albumChanged() { guard let i = selected else { return }; collections[i].albumKey = album.stringValue.trimmingCharacters(in: .whitespaces); save() }
    @objc private func newCollection() {
        let alert = NSAlert(); alert.messageText = "New publish collection"
        let name = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24)); name.placeholderString = "Name, e.g. Portfolio"
        let kind = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26)); kind.addItems(withTitles: PublishServiceKind.allCases.map(\.title))
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56)); box.addSubview(name); box.addSubview(kind)
        alert.accessoryView = box; alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let title = name.stringValue.trimmingCharacters(in: .whitespaces)
            self.collections.append(PublishCollection(name: title.isEmpty ? "Collection" : title, kind: PublishServiceKind.allCases[max(0, kind.indexOfSelectedItem)]))
            self.save(); self.table.reloadData(); self.table.selectRowIndexes([self.collections.count - 1], byExtendingSelection: false); self.refresh()
        }
    }
    @objc private func deleteCollection() {
        guard let i = selected else { return }
        Keychain.delete(account: collections[i].keychainAccount)
        collections.remove(at: i); save(); table.reloadData(); refresh()
        status.stringValue = "Collection deleted. Photos already published stay where they are."
    }
    @objc private func chooseFolder() {
        guard let i = selected, let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.collections[i].folderPath = url.path; self.save(); self.refresh()
        }
    }
    @objc private func addPhotos() { guard let i = selected else { return }; collections[i].add(items.map(\.id)); save(); refresh() }
    @objc private func removePhotos() { guard let i = selected else { return }; collections[i].remove(items.map(\.id)); save(); refresh() }
    /// OAuth sign-in: your own API key and secret, approval in the browser, then the code the service shows.
    @objc private func connectService() {
        guard let i = selected, let window else { return }
        let kind = collections[i].kind
        let alert = NSAlert(); alert.messageText = "Connect \(kind.title)"
        alert.informativeText = "Enter the API key and secret from your \(kind.title) developer account. OpenStill doesn’t include its own. Your browser opens to approve access."
        let key = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 24)); key.placeholderString = "API key"
        let secret = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); secret.placeholderString = "API secret"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56)); box.addSubview(key); box.addSubview(secret)
        alert.accessoryView = box; alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.busy = true; self.status.stringValue = "Asking \(kind.title) for a sign-in…"
            let k = key.stringValue.trimmingCharacters(in: .whitespaces), s = secret.stringValue.trimmingCharacters(in: .whitespaces)
            Task { @MainActor in
                do {
                    let started = try await OAuthSignIn.start(kind, key: k, secret: s)
                    self.pending = started.credentials; self.busy = false
                    NSWorkspace.shared.open(started.authorize)
                    self.askForCode(kind: kind, collection: i)
                } catch { self.finish(error.localizedDescription) }
            }
        }
    }
    private func askForCode(kind: PublishServiceKind, collection i: Int) {
        guard let window, let pending else { return }
        let alert = NSAlert(); alert.messageText = "Paste the code from \(kind.title)"
        alert.informativeText = "After you approve OpenStill in the browser, \(kind.title) shows a code. Paste it here."
        let code = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); alert.accessoryView = code
        alert.addButton(withTitle: "Connect"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.busy = true
            Task { @MainActor in
                do {
                    let credentials = try await OAuthSignIn.finish(kind, pending: pending, verifier: code.stringValue)
                    try PublishStore.saveCredentials(credentials, for: self.collections[i])
                    self.finish("Connected to \(kind.title). The sign-in is stored in your keychain."); self.refresh()
                } catch { self.finish(error.localizedDescription) }
            }
        }
    }
    @objc private func publish() {
        guard let i = selected else { status.stringValue = "Choose a collection."; return }
        let start = collections[i]
        let service: PublishService
        do { service = try PublishStore.service(for: start) } catch { status.stringValue = error.localizedDescription; return }
        busy = true; status.stringValue = "Publishing…"
        let library = self.library
        Task { @MainActor in
            var collection = start
            let report = await Publisher.run(&collection, items: library, service: service, progress: { done, total in
                DispatchQueue.main.async { self.status.stringValue = "Publishing \(min(done + 1, total)) of \(total)…" }
            })
            if let index = self.collections.firstIndex(where: { $0.id == collection.id }) { self.collections[index] = collection }
            self.save(); self.refresh()
            var text = "Published \(report.published), removed \(report.removed)."
            if !report.failures.isEmpty { text += " \(report.failures.count) failed: " + report.failures.prefix(3).joined(separator: "; ") }
            self.finish(text)
        }
    }
}
