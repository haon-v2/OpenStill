import AppKit
import CoreImage
import OpenStillCore

private final class LUTCard: NSButton {
    override var isFlipped:Bool { false }
    var preview: NSImage? { didSet { needsDisplay = true } }
    var failed = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect:NSRect) {
        let frame = bounds.insetBy(dx:1,dy:1), path = NSBezierPath(roundedRect:frame,xRadius:7,yRadius:7)
        NSColor(calibratedWhite:0.12,alpha:0.6).setFill();path.fill()
        let photo = NSRect(x:5,y:30,width:bounds.width-10,height:bounds.height-35)
        if let preview {
            let scale = min(photo.width/preview.size.width,photo.height/preview.size.height)
            let size = NSSize(width:preview.size.width*scale,height:preview.size.height*scale)
            preview.draw(in:NSRect(x:photo.midX-size.width/2,y:photo.midY-size.height/2,width:size.width,height:size.height),from:.zero,operation:.sourceOver,fraction:isEnabled ? 1 : 0.55)
        } else {
            let symbol = NSImage(systemSymbolName:failed ? "exclamationmark.triangle" : "photo",accessibilityDescription:nil)
            symbol?.draw(in:NSRect(x:photo.midX-10,y:photo.midY-10,width:20,height:20),from:.zero,operation:.sourceOver,fraction:0.45)
        }
        let style = NSMutableParagraphStyle();style.alignment = .center;style.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in:NSRect(x:6,y:7,width:bounds.width-12,height:16),withAttributes:[.font:NSFont.systemFont(ofSize:10,weight:.medium),.foregroundColor:NSColor.labelColor,.paragraphStyle:style])
        if state == .on {
            Appearance.accent.setStroke();path.lineWidth = 2;path.stroke()
            NSImage(systemSymbolName:"checkmark.circle.fill",accessibilityDescription:nil)?.draw(in:NSRect(x:bounds.width-23,y:bounds.height-24,width:17,height:17))
        }
        if window?.firstResponder === self { NSColor.keyboardFocusIndicatorColor.setStroke();path.lineWidth = 3;path.stroke() }
    }
}

final class LUTBrowserView: NSStackView {
    var choose: ((LUTItem)->Void)?
    let controls = NSStackView()
    private let picker = NSPopUpButton(frame:.zero,pullsDown:false)
    private let detail = NSTextField(wrappingLabelWithString:"Choose a look to start. 12 free looks included.")
    private let source = NSButton(title:"Creator & source ↗",target:nil,action:nil)
    private let notice = NSTextField(wrappingLabelWithString:"")
    private let grid = NSStackView()
    private var library = LUTLibrary(imported:EditStorage.root.appendingPathComponent("LUTLibrary"))
    private var cards:[String:LUTCard] = [:]
    private var images:[String:NSImage] = [:]
    private var failures:Set<String> = []
    private var original:CGImage?
    private var linearSource:CIImage?
    private var renderSourceURL:URL?
    private var renderRecipe:RenderRecipe?
    private var edits = PhotoEdits()
    private var enabled = false
    private var active = false
    private var sourceURL:URL?
    private let queue = DispatchQueue(label:"OpenStill.LUTPreviews",qos:.utility)
    private let generation = LUTPreviewGeneration()
    override var isFlipped:Bool { true }
    override init(frame:NSRect) {
        super.init(frame:frame);orientation = .vertical;alignment = .leading;spacing = 10
        picker.addItems(withTitles:LUTLibrary.categories);picker.target = self;picker.action = #selector(categoryChanged);picker.font = .systemFont(ofSize:11);picker.setAccessibilityLabel("LUT category");add(picker)
        detail.font = .systemFont(ofSize:11);detail.textColor = .secondaryLabelColor;add(detail)
        source.bezelStyle = .rounded;source.font = .systemFont(ofSize:10);source.target = self;source.action = #selector(openSource);add(source);source.isHidden = true
        controls.orientation = .vertical;controls.alignment = .leading;controls.spacing = 8;add(controls)
        notice.font = .systemFont(ofSize:10);notice.textColor = .secondaryLabelColor;add(notice);notice.isHidden = true
        grid.orientation = .vertical;grid.alignment = .leading;grid.spacing = 8;add(grid)
        reload()
    }
    required init?(coder:NSCoder) { fatalError() }
    private func add(_ view:NSView) { addArrangedSubview(view);view.widthAnchor.constraint(equalTo:widthAnchor).isActive = true }
    func reload() {
        generation.begin();images.removeAll();failures.removeAll()
        let imports = EditStorage.root.appendingPathComponent("LUTLibrary")
        let bundled = Bundle.main.resourceURL!.appendingPathComponent("LUTs")
        let folder = FileManager.default.fileExists(atPath:bundled.appendingPathComponent("catalog.json").path) ? bundled : URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/LUTs")
        do { library = try LUTLibrary(bundled:folder,imported:imports);notice.isHidden = true }
        catch { library = LUTLibrary(imported:imports);notice.stringValue = "The included LUT library couldn’t load. Imported looks are still available.";notice.isHidden = false }
        rebuild();updateSelection(edits)
    }
    func item(id:String) -> LUTItem? { library.items.first { $0.entry.id == id } }
    func imported(filename:String) -> LUTItem? { library.items.first { !$0.isBundled && $0.url.lastPathComponent == filename } }
    func setActive(_ value:Bool) { active = value;generation.begin();if value { schedule() } }
    func setEnabled(_ value:Bool) { enabled = value;cards.values.forEach { $0.isEnabled = value } }
    func setPhoto(_ image:CGImage?,edits next:PhotoEdits, source:CIImage? = nil, url:URL? = nil, recipe:RenderRecipe? = nil) {
        guard original !== image || linearSource !== source || edits != next else { return }
        linearSource = source; renderSourceURL = url; renderRecipe = recipe
        original = image;edits = next;generation.begin();images.removeAll();failures.removeAll()
        for card in cards.values { card.preview = nil;card.failed = false }
        updateSelection(next);schedule()
    }
    func updateSelection(_ value:PhotoEdits) {
        let selected = library.selected(for:value)
        for (id,card) in cards { card.state = selected?.entry.id == id ? .on : .off;card.needsDisplay = true }
        if let item = selected {
            detail.stringValue = "\(item.entry.name)\n\(item.entry.description)\n\(item.entry.creator) · \(item.entry.license)"
            sourceURL = URL(string:item.entry.source).flatMap { ["https","http"].contains($0.scheme ?? "") ? $0 : nil }
        } else {
            detail.stringValue = value.advanced?.lutName.map { "\($0)\nSaved with this edit." } ?? "Choose a look to start. Categories are suggestions—try any look on any photo."
            sourceURL = nil
        }
        source.isHidden = sourceURL == nil
    }
    @objc private func categoryChanged() { generation.begin();rebuild() }
    @objc private func openSource() { if let sourceURL { NSWorkspace.shared.open(sourceURL) } }
    @objc private func pick(_ sender:NSButton) { guard enabled, let id = sender.identifier?.rawValue,let item = item(id:id) else { return };choose?(item) }
    private func rebuild() {
        for view in grid.arrangedSubviews { grid.removeArrangedSubview(view);view.removeFromSuperview() };cards.removeAll()
        let items = library.filtered(picker.titleOfSelectedItem ?? "All")
        if items.isEmpty {
            let empty = NSTextField(wrappingLabelWithString:"No imported LUTs yet. Use Import .cube LUT below.");empty.font = .systemFont(ofSize:11);empty.textColor = .secondaryLabelColor;grid.addArrangedSubview(empty);empty.widthAnchor.constraint(equalTo:grid.widthAnchor).isActive = true
        }
        for offset in stride(from:0,to:items.count,by:2) {
            let row = NSStackView();row.spacing = 8;row.distribution = .fillEqually
            for item in items[offset..<min(offset+2,items.count)] {
                let card = LUTCard(title:item.entry.name,target:self,action:#selector(pick(_:)))
                card.identifier = NSUserInterfaceItemIdentifier(item.entry.id);card.setButtonType(.toggle);card.isBordered = false;card.isEnabled = enabled
                card.heightAnchor.constraint(equalToConstant:108).isActive = true;card.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
                card.setAccessibilityLabel(item.entry.name+" LUT");card.toolTip = item.entry.description+"\n"+item.entry.creator
                card.preview = images[item.entry.id];card.failed = failures.contains(item.entry.id);cards[item.entry.id] = card;row.addArrangedSubview(card)
            }
            if row.arrangedSubviews.count == 1 { row.addArrangedSubview(NSView()) }
            grid.addArrangedSubview(row);row.widthAnchor.constraint(equalTo:grid.widthAnchor).isActive = true
        }
        updateSelection(edits);schedule()
    }
    private func schedule() {
        let token = generation.begin()
        guard active,let original else { return }
        let snapshot = edits, selected = library.selected(for:edits)?.entry.id
        let pending = library.filtered(picker.titleOfSelectedItem ?? "All").filter { images[$0.entry.id] == nil && !failures.contains($0.entry.id) }
        let gate = generation
        let linearSource = linearSource, recipe = renderRecipe, url = renderSourceURL
        queue.asyncAfter(deadline:.now()+0.15) { [weak self] in
            for item in pending {
                guard gate.isCurrent(token) else { return }
                let result = Result { try autoreleasepool { () -> CGImage in
                    var previewEdits = snapshot;previewEdits.ensureAdvanced();previewEdits.advanced!.lutAsset = nil
                    previewEdits.lutAmount = selected == item.entry.id ? snapshot.lutAmount : 0.7
                    if let url, var recipe {
                        recipe.edits = previewEdits
                        return try ModernRenderer.display(ModernRenderer.render(source:url,recipe:recipe,maximumDimension:480,lutOverride:item.load()))
                    }
                    if let linearSource { return try ModernRenderer.display(ModernRenderer.process(linearSource, edits:previewEdits, maximumDimension:480, lutOverride:item.load())) }
                    return try PhotoEditor.render(original,edits:previewEdits,lutOverride:item.load(),previewMaxDimension:480)
                } }
                guard gate.isCurrent(token) else { return }
                DispatchQueue.main.async {
                    guard let self,gate.isCurrent(token) else { return }
                    switch result {
                    case .success(let image):
                        let preview = NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height))
                        self.images[item.entry.id] = preview;self.cards[item.entry.id]?.preview = preview
                    case .failure(let error):
                        self.failures.insert(item.entry.id);self.cards[item.entry.id]?.failed = true
                        self.cards[item.entry.id]?.toolTip = "Preview unavailable: "+error.localizedDescription
                    }
                }
            }
        }
    }
}
