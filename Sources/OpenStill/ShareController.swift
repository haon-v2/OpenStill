import AppKit
import OpenStillCore

private final class DraggablePhoto: NSImageView, NSDraggingSource {
    var files: [URL] = []
    override func mouseDown(with event: NSEvent) {
        guard !files.isEmpty else { return }
        let items = files.enumerated().map { index, file in
            let item = NSDraggingItem(pasteboardWriter: file as NSURL)
            let offset = CGFloat(min(index, 4)) * 4
            item.setDraggingFrame(bounds.offsetBy(dx: offset, dy: -offset), contents: image ?? NSWorkspace.shared.icon(forFile: file.path))
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { false }
}

final class ShareController: NSViewController, NSSharingServiceDelegate, NSSharingServicePickerDelegate {
    private let sources: [URL]
    private let initialImage: CGImage?
    private let edits: [URL: PhotoEdits]
    private let preview = DraggablePhoto()
    private let formats = NSPopUpButton()
    private let websites = NSPopUpButton()
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let resultLabel = NSTextField(wrappingLabelWithString: "Preparing photo…")
    private let fileLabel = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []
    private var prepared: [URL] = []
    private var preparationID = UUID()
    private var picker: NSSharingServicePicker?
    private var sharingService: NSSharingService?
    private let progress = NSProgressIndicator()
    private let destinations: [(String, String)] = [
        ("Google Drive", "https://drive.google.com/drive/my-drive"),
        ("Dropbox", "https://www.dropbox.com/home"),
        ("WeTransfer", "https://wetransfer.com/"),
        ("Pixieset", "https://pixieset.com/"),
        ("Pic-Time", "https://www.pic-time.com/")
    ]

    init(sources: [URL], image: CGImage?, edits: [URL: PhotoEdits] = [:]) {
        self.edits = edits
        self.sources = sources
        self.initialImage = image
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let chrome = GlassChrome(frame: NSRect(x: 0, y: 0, width: 440, height: 690)); chrome.cornerRadius = 0; view = chrome
        let content = chrome.contentView
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20)
        ])
        let heading = NSTextField(labelWithString: sources.count == 1 ? "Share a photograph" : "Share \(sources.count) photographs")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        stack.addArrangedSubview(heading)
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.image = initialImage.map { NSImage(cgImage: $0, size: .zero) }
        preview.setAccessibilityLabel("Drag all \(sources.count) selected photos to another app or a website upload area")
        preview.toolTip = "Drag the selected photos into another app or a website’s upload area"
        preview.widthAnchor.constraint(equalToConstant: 104).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 104).isActive = true
        let name = NSTextField(labelWithString: sources.count == 1 ? sources[0].lastPathComponent : "\(sources.count) photos selected")
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = sources.map(\.lastPathComponent).joined(separator: "\n")
        fileLabel.font = .systemFont(ofSize: 11)
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingMiddle
        let dragHint = smallText(sources.count == 1 ? "Drag the photo to share it." : "Drag this stack to share all photos.")
        let labels = NSStackView(views: [name, fileLabel, dragHint])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 7
        let photoRow = NSStackView(views: [preview, labels])
        photoRow.spacing = 18
        stack.addArrangedSubview(photoRow)
        photoRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        formats.addItems(withTitles: ShareFormat.allCases.map(\.title))
        formats.target = self
        formats.action = #selector(preparePhoto)
        formats.setAccessibilityLabel("Shared file format")
        stack.addArrangedSubview(formats)
        formats.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        descriptionLabel.font = .systemFont(ofSize: 12)
        descriptionLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(descriptionLabel)
        descriptionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        descriptionLabel.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let native = NSStackView(views: [
            button("Messages", symbol: "message", action: #selector(messages)),
            button("AirDrop", symbol: "airplayaudio", action: #selector(airDrop)),
            button("More…", symbol: "square.and.arrow.up", action: #selector(moreSharing(_:)))
        ])
        native.distribution = .fillEqually
        native.spacing = 8
        stack.addArrangedSubview(native)
        native.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let divider = NSBox()
        divider.boxType = .separator
        stack.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let websiteTitle = NSTextField(labelWithString: "Share through a website")
        websiteTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(websiteTitle)
        websites.addItems(withTitles: destinations.map(\.0))
        websites.setAccessibilityLabel("Photo sharing website")
        let websiteRow = NSStackView(views: [websites, button("Open website ↗", action: #selector(openWebsite))])
        websiteRow.distribution = .fill
        websiteRow.spacing = 12
        stack.addArrangedSubview(websiteRow)
        websiteRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let websiteHelp = smallText("Sign in in your browser, then drag the photos above into the site’s upload area. You can also choose the files using Show in Finder.")
        stack.addArrangedSubview(websiteHelp)
        websiteHelp.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let saveRow = NSStackView(views: [button(sources.count == 1 ? "Save a copy…" : "Save copies…", symbol: "folder", action: #selector(saveCopy)),
                                           button("Show in Finder", action: #selector(showInFinder))])
        saveRow.distribution = .fillEqually
        saveRow.spacing = 10
        stack.addArrangedSubview(saveRow)
        saveRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let saveHelp = smallText("Save to a local folder or your synced Drive, Dropbox, or iCloud folder.")
        stack.addArrangedSubview(saveHelp)
        saveHelp.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        resultLabel.font = .systemFont(ofSize: 11)
        resultLabel.textColor = .secondaryLabelColor
        let statusRow = NSStackView(views: [progress, resultLabel])
        statusRow.spacing = 8
        stack.addArrangedSubview(statusRow)
        statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        resultLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        preparePhoto()
    }
    private func smallText(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        return field
    }
    private func button(_ title: String, symbol: String? = nil, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        if let symbol { button.image = Appearance.symbol(symbol, size: 14); button.imagePosition = .imageLeading }
        buttons.append(button)
        return button
    }
    @objc private func preparePhoto() {
        let token = UUID()
        preparationID = token
        prepared = []
        preview.files = []
        formats.isEnabled = false
        fileLabel.stringValue = ""
        buttons.forEach { $0.isEnabled = false }
        progress.startAnimation(nil)
        resultLabel.stringValue = "Preparing sharing copy…"
        let format = ShareFormat.allCases[formats.indexOfSelectedItem]
        descriptionLabel.stringValue = format == .original
            ? "Untouched originals, including recorded metadata. RAW files may look different in another app."
            : "Full-resolution JPEGs with your edits. Lumix camera previews keep the recorded LUT look."
        let sources = self.sources
        let edits = self.edits
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> [URL] in
                let directory = try Self.sharingDirectory()
                let recipes = try Dictionary(uniqueKeysWithValues:sources.map { ($0, try EditStorage.record($0).active.recipe) })
                return try ShareExporter.prepare(sources, format: format, in: directory, edits: edits, recipes:recipes) { completed, total in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.preparationID == token else { return }
                        self.resultLabel.stringValue = "Preparing photos… \(completed) of \(total)"
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self, self.preparationID == token else { return }
                self.progress.stopAnimation(nil)
                self.formats.isEnabled = true
                switch result {
                case .success(let files):
                    self.prepared = files
                    self.preview.files = files
                    let size = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                    self.fileLabel.stringValue = "\(files.count) file\(files.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
                    self.buttons.forEach { $0.isEnabled = true }
                    self.resultLabel.stringValue = "Ready to share \(files.count) photo\(files.count == 1 ? "" : "s"). Originals stay unchanged."
                case .failure(let error): self.resultLabel.stringValue = error.localizedDescription
                }
            }
        }
    }
    private static func sharingDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenStill-Sharing", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Keep copies long enough for other apps to finish reading their attachments.
        let old = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        for directory in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey, .isSymbolicLinkKey])) ?? [] {
            let values = try? directory.resourceValues(forKeys: [.creationDateKey, .isSymbolicLinkKey])
            if UUID(uuidString: directory.lastPathComponent) != nil, values?.isSymbolicLink != true,
               let date = values?.creationDate, date < old { try? FileManager.default.removeItem(at: directory) }
        }
        return root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
    @objc private func messages() { perform(.composeMessage) }
    @objc private func airDrop() { perform(.sendViaAirDrop) }
    private func perform(_ name: NSSharingService.Name) {
        guard !prepared.isEmpty else { return }
        guard let service = NSSharingService(named: name), service.canPerform(withItems: prepared) else {
            resultLabel.stringValue = "This sharing service isn’t available on this Mac. Try More… or save a copy."
            return
        }
        sharingService = service
        service.delegate = self
        service.perform(withItems: prepared)
    }
    @objc private func moreSharing(_ sender: NSButton) {
        guard !prepared.isEmpty else { return }
        picker = NSSharingServicePicker(items: prepared)
        picker?.delegate = self
        picker?.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
    @objc private func openWebsite() {
        guard !prepared.isEmpty else { return }
        let destination = destinations[websites.indexOfSelectedItem]
        if NSWorkspace.shared.open(URL(string: destination.1)!) {
            resultLabel.stringValue = "\(destination.0) opened. Drag the photos into its upload area. Nothing has been uploaded yet."
        } else { resultLabel.stringValue = "Couldn’t open your browser. Save a copy and open the website yourself." }
    }
    @objc private func showInFinder() {
        guard !prepared.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(prepared)
    }
    @objc private func saveCopy() {
        guard !prepared.isEmpty, let window = view.window else { return }
        let prepared = self.prepared
        let panel = NSOpenPanel()
        panel.title = "Save sharing copies"
        panel.message = "Choose a folder. A synced Google Drive, Dropbox, or iCloud folder works too."
        panel.prompt = "Save here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let directory = panel.url, let self else { return }
            self.resultLabel.stringValue = "Saving copy…"
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var savedCount = 0
                let result = Result { () -> Int in
                    for file in prepared {
                        _ = try ShareExporter.copy(file, to: directory)
                        savedCount += 1
                    }
                    return savedCount
                }
                let completed = savedCount
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let count): self.resultLabel.stringValue = "Saved \(count) photo\(count == 1 ? "" : "s") in \(directory.lastPathComponent). Cloud folders sync through their own app."
                    case .failure(let error): self.resultLabel.stringValue = "Saved \(completed) of \(prepared.count) photos. \(error.localizedDescription)"
                    }
                }
            }
        }
    }
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? { self }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        resultLabel.stringValue = "Sharing didn’t complete: \(error.localizedDescription)"
        self.sharingService = nil
    }
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        resultLabel.stringValue = "Handed off to \(sharingService.title)."
        self.sharingService = nil
    }
    func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any], sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? { view.window }
}
