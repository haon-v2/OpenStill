import AppKit
import OpenStillCore

private final class ShootCollection:NSCollectionView {
    var mark:((Int?,PhotoFlag?)->Void)?
    var setLabel:((ColorLabel)->Void)?
    var openSelection:(()->Void)?
    override func mouseDown(with event:NSEvent){
        let clicked = indexPathForItem(at:convert(event.locationInWindow,from:nil))
        super.mouseDown(with:event)
        if event.clickCount==2,let clicked {selectionIndexPaths=[clicked];openSelection?()}
    }
    /// Rating, label, flag and open keys come from Settings → Shortcuts.
    override func keyDown(with event:NSEvent){
        if Shortcuts.performWorkspace(event){return}
        guard let id=Shortcuts.command(for:event,in:.library) else{super.keyDown(with:event);return}
        switch id{
        case let id where id.hasPrefix("library.rate"):mark?(Int(id.dropFirst("library.rate".count)) ?? 0,nil)
        case let id where id.hasPrefix("library.label."):if let label=ColorLabel(rawValue:String(id.dropFirst("library.label.".count))){setLabel?(label)}
        case "library.pick":mark?(nil,.pick)
        case "library.reject":mark?(nil,.reject)
        case "library.unflag":mark?(nil,PhotoFlag.none)
        case "library.open":openSelection?()
        default:super.keyDown(with:event)
        }
    }
}
private final class ShootCell:NSCollectionViewItem {
    let preview=NSImageView(),caption=NSTextField(labelWithString:""),rating=NSTextField(labelWithString:""),labelStrip=NSView()
    var requestKey:String?
    override func loadView(){
        view=NSView();view.wantsLayer=true;view.layer?.cornerRadius=8
        preview.imageScaling = .scaleProportionallyUpOrDown
        caption.font = .systemFont(ofSize:11);caption.lineBreakMode = .byTruncatingMiddle;caption.alignment = .center
        rating.font = .systemFont(ofSize:11);rating.textColor = .secondaryLabelColor;rating.alignment = .center
        labelStrip.wantsLayer=true;labelStrip.layer?.cornerRadius=2
        for child in [preview,caption,rating,labelStrip]{child.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(child)}
        NSLayoutConstraint.activate([labelStrip.topAnchor.constraint(equalTo:view.topAnchor,constant:2),labelStrip.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:10),labelStrip.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-10),labelStrip.heightAnchor.constraint(equalToConstant:3)])
        NSLayoutConstraint.activate([preview.topAnchor.constraint(equalTo:view.topAnchor,constant:6),preview.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:6),preview.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-6),preview.heightAnchor.constraint(equalToConstant:145),caption.topAnchor.constraint(equalTo:preview.bottomAnchor,constant:7),caption.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:5),caption.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-5),rating.topAnchor.constraint(equalTo:caption.bottomAnchor,constant:4),rating.centerXAnchor.constraint(equalTo:view.centerXAnchor)])
    }
    static func color(_ label:ColorLabel)->NSColor {
        switch label{case .red:return .systemRed;case .yellow:return .systemYellow;case .green:return .systemGreen;case .blue:return .systemBlue;case .purple:return .systemPurple;case .none:return .clear}
    }
    override var isSelected:Bool{didSet{view.layer?.borderWidth=isSelected ? 1.5:0;view.layer?.borderColor=Appearance.accent.cgColor;view.layer?.backgroundColor=isSelected ? Appearance.accent.withAlphaComponent(0.12).cgColor:NSColor.clear.cgColor}}
    func configure(_ item:ShootItem){
        caption.stringValue=item.url.lastPathComponent
        rating.stringValue=String(repeating:"★",count:item.record.rating)+String(repeating:"☆",count:5-item.record.rating)+(item.record.flag == .pick ? "  Pick":item.record.flag == .reject ? "  Reject":"")
        let label=item.record.colorLabel
        labelStrip.isHidden=label == .none;labelStrip.layer?.backgroundColor=ShootCell.color(label).cgColor
        var help=caption.stringValue;let meta=item.record.iptc
        if !meta.title.isEmpty{help+="\n"+meta.title};if !meta.keywords.isEmpty{help+="\nKeywords: "+meta.keywords.joined(separator:", ")}
        view.setAccessibilityLabel(caption.stringValue+", \(item.record.rating) stars, "+item.record.flag.rawValue+(label == .none ? "":", \(label.title) label"));view.toolTip=help
        preview.imageScaling = .scaleProportionallyDown;preview.image=Appearance.symbol("photo",size:28)
    }
}
final class ShootWindow:NSWindowController,NSCollectionViewDataSource,NSCollectionViewDelegate,NSWindowDelegate {
    var edit:(([URL],URL)->Void)?
    var recordsChanged:(()->Void)?
    var selectionChanged:(()->Void)?
    /// A merged photo was written; the viewer adds it to the library.
    var merged:((URL)->Void)?
    private var merging=false
    let browserView = NSView()
    private let urls:[URL]
    private var all:[ShootItem]=[],shown:[ShootItem]=[]
    private let grid=ShootCollection(),scroll=NSScrollView(),message=NSTextField(labelWithString:"Reading photographs…")
    private let minimum=NSPopUpButton(frame:.zero,pullsDown:false),flag=NSPopUpButton(frame:.zero,pullsDown:false),sort=NSPopUpButton(frame:.zero,pullsDown:false),labelFilter=NSPopUpButton(frame:.zero,pullsDown:false)
    /// Label filter choices: nil = all, then each label, then unlabeled.
    private static let labelChoices:[ColorLabel?]=[nil,.red,.yellow,.green,.blue,.purple,ColorLabel.none]
    /// The collection shown, if the library was opened from one.
    var collection:PhotoCollection?
    var collectionsChanged:(()->Void)?
    private var metadataWindow:MetadataWindow?
    private var duplicatesWindow:DuplicatesWindow?
    private var outputWindows:[OutputWindow]=[]
    /// Photos picked from People, Map or Timeline: the library shows only these until "Show all photos".
    private var focused:(ids:Set<UUID>,title:String)?
    private let queue=OperationQueue(),cache=NSCache<NSString,NSImage>()
    private let search = NSSearchField()
    private var preferredURL: URL?
    private var closed=false
    private static var copied:ShootItem?
    private var batchPanel:BatchPanel?
    private var exportPanel:ExportPanel?
    private var generation=UUID(),comparisons:[ComparisonWindow]=[]
    init(urls:[URL], embedded:Bool = false, selectedURL:URL? = nil){
        self.urls=urls;self.preferredURL=selectedURL
        let window = embedded ? nil : NSWindow(contentRect:NSRect(x:0,y:0,width:1080,height:750),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init(window:window)
        let content = browserView
        if let window {
            window.title="Shoot · OpenStill";window.minSize=NSSize(width:850,height:500);window.center();window.delegate=self;Appearance.configure(window)
            let root=Appearance.panel(in:window)
            content.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(content)
            NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo:root.leadingAnchor),content.trailingAnchor.constraint(equalTo:root.trailingAnchor),content.topAnchor.constraint(equalTo:root.topAnchor),content.bottomAnchor.constraint(equalTo:root.bottomAnchor)])
        }
        // Thumbnails render on the GPU; two at a time keeps the grid filling quickly on Macs with room to spare.
        queue.maxConcurrentOperationCount=ProcessInfo.processInfo.activeProcessorCount>=8 ? 2:1;queue.qualityOfService = .utility;cache.totalCostLimit=64*1024*1024
        minimum.addItems(withTitles:["All ratings","1★ and up","2★ and up","3★ and up","4★ and up","5★"])
        flag.addItems(withTitles:["All flags","Picks","Rejects","Unflagged"]);sort.addItems(withTitles:["Filename","Capture date","Rating"])
        labelFilter.addItems(withTitles:Self.labelChoices.map{$0.map{$0 == ColorLabel.none ? "Unlabeled":$0.title} ?? "All labels"})
        for (control,title) in [(minimum,"Minimum star rating"),(flag,"Flag filter"),(sort,"Sort photographs"),(labelFilter,"Color label filter")]{control.target=self;control.action = #selector(filterChanged);control.setAccessibilityLabel(title)}
        search.placeholderString="Search names, titles, keywords, camera, lens";search.target=self;search.action = #selector(filterChanged);search.sendsSearchStringImmediately=true;search.setAccessibilityLabel("Search library filenames")
        let open=button("Edit selected",#selector(openSelected)),compare=button("Compare two",#selector(compareSelected)),refreshButton=button("Refresh",#selector(refreshAction))
        let top: NSStackView
        if embedded {
            let more = NSPopUpButton(frame:.zero,pullsDown:true)
            more.addItem(withTitle:"Actions")
            for (title, action) in [("Edit selected",#selector(openSelected)),("Compare two",#selector(compareSelected)),("Edit metadata…",#selector(editMetadata)),("Write metadata to XMP",#selector(writeXMP)),("Read metadata from XMP",#selector(readXMP)),("Import Camera Raw edits from XMP",#selector(importCameraRaw)),("Add to collection…",#selector(addToCollection)),("Find duplicates…",#selector(findDuplicates)),("Merge to HDR…",#selector(mergeHDR)),("Merge to panorama…",#selector(mergePanorama)),("Focus stack…",#selector(mergeFocusStack)),("Remove from this collection",#selector(removeFromCollection)),("Copy adjustments",#selector(copyAdjustments)),("Paste adjustments…",#selector(pasteAdjustments)),("Undo batch",#selector(undoBatch)),("Export selected…",#selector(exportSelection)),("Print…",#selector(printPhotos)),("Slideshow…",#selector(slideshow)),("Web gallery…",#selector(webGallery)),("Publish…",#selector(publishPhotos)),("People…",#selector(showPeople)),("Map…",#selector(showMap)),("Timeline…",#selector(showTimeline)),("Show all photos",#selector(clearFocus)),("Refresh",#selector(refreshAction))] {
                let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=self;more.menu?.addItem(item)
            }
            top=NSStackView(views:[minimum,flag,labelFilter,sort,NSView(),more])
        } else { top=NSStackView(views:[minimum,flag,labelFilter,sort,NSView(),open,compare,refreshButton]) }
        top.spacing=8
        let searchRow=NSStackView(views:[search]);searchRow.spacing=8;searchRow.isHidden = !embedded
        let marks=NSStackView();marks.spacing=6
        let title=NSTextField(labelWithString:"Rate selection");title.font = .systemFont(ofSize:11);marks.addArrangedSubview(title)
        for i in 0...5{let b=button(i==0 ? "Clear":"\(i)★",#selector(rate(_:)));b.tag=i;b.setAccessibilityLabel("Rate selected photos \(i) stars");marks.addArrangedSubview(b)}
        for (title,tag) in [("Pick",1),("Reject",2),("Unflag",0)]{let b=button(title,#selector(flagSelected(_:)));b.tag=tag;marks.addArrangedSubview(b)}
        let labels=NSPopUpButton(frame:.zero,pullsDown:true);labels.addItem(withTitle:"Label")
        for label in ColorLabel.allCases {
            let item=NSMenuItem(title:label == .none ? "Clear label":label.title+(label.key.map{"  (\($0))"} ?? ""),action:#selector(labelSelected(_:)),keyEquivalent:"");item.target=self;item.representedObject=label.rawValue
            if label != .none{item.image=NSImage(systemSymbolName:"circle.fill",accessibilityDescription:nil)?.withSymbolConfiguration(.init(paletteColors:[ShootCell.color(label)]))}
            labels.menu?.addItem(item)
        }
        labels.setAccessibilityLabel("Set color label");marks.addArrangedSubview(labels)
        let batch=NSStackView(views:[button("Copy adjustments",#selector(copyAdjustments)),button("Paste adjustments…",#selector(pasteAdjustments)),button("Undo batch",#selector(undoBatch)),button("Export selected…",#selector(exportSelection))]);batch.spacing=10
        let hint=NSTextField(labelWithString:Self.hintText());hint.font = .systemFont(ofSize:10);hint.textColor = .secondaryLabelColor
        let flow=NSCollectionViewFlowLayout();flow.itemSize=NSSize(width:210,height:205);flow.minimumInteritemSpacing=12;flow.minimumLineSpacing=12;flow.sectionInset=NSEdgeInsets(top:12,left:16,bottom:16,right:16)
        grid.collectionViewLayout=flow;grid.isSelectable=true;grid.allowsMultipleSelection=true;grid.dataSource=self;grid.delegate=self;grid.backgroundColors=[.clear];grid.register(ShootCell.self,forItemWithIdentifier:NSUserInterfaceItemIdentifier("shoot"))
        grid.mark = {[weak self] rating,flag in self?.mark(rating:rating,flag:flag)};grid.setLabel = {[weak self] label in self?.toggleLabel(label)};grid.openSelection = {[weak self] in self?.openSelected()}
        scroll.documentView=grid;scroll.hasVerticalScroller=true;scroll.drawsBackground=false
        message.font = .systemFont(ofSize:11);message.textColor = .secondaryLabelColor
        if embedded { batch.isHidden=true; for control in marks.arrangedSubviews.compactMap({$0 as? NSControl}) {control.controlSize = .small;control.font = .systemFont(ofSize:11)} }
        for child in [top,searchRow,marks,batch,hint,scroll,message]{child.translatesAutoresizingMaskIntoConstraints=false;content.addSubview(child)}
        NSLayoutConstraint.activate([top.topAnchor.constraint(equalTo:content.topAnchor,constant:16),top.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:16),top.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-16),searchRow.topAnchor.constraint(equalTo:top.bottomAnchor,constant:10),searchRow.leadingAnchor.constraint(equalTo:top.leadingAnchor),searchRow.trailingAnchor.constraint(equalTo:top.trailingAnchor),marks.topAnchor.constraint(equalTo:embedded ? searchRow.bottomAnchor : top.bottomAnchor,constant:12),marks.leadingAnchor.constraint(equalTo:top.leadingAnchor),batch.topAnchor.constraint(equalTo:marks.bottomAnchor,constant:10),batch.leadingAnchor.constraint(equalTo:top.leadingAnchor),hint.topAnchor.constraint(equalTo:embedded ? marks.bottomAnchor : batch.bottomAnchor,constant:8),hint.leadingAnchor.constraint(equalTo:top.leadingAnchor),scroll.topAnchor.constraint(equalTo:hint.bottomAnchor,constant:10),scroll.leadingAnchor.constraint(equalTo:content.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:content.trailingAnchor),scroll.bottomAnchor.constraint(equalTo:message.topAnchor,constant:-8),message.leadingAnchor.constraint(equalTo:top.leadingAnchor),message.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-12),message.trailingAnchor.constraint(equalTo:top.trailingAnchor)])
        Appearance.applyAccent(in:content)
        refresh()
    }
    required init?(coder:NSCoder){fatalError()}
    /// The key hint under the toolbar, from the current shortcuts.
    static func hintText()->String{
        func key(_ id:String)->String{Shortcuts.map.combo(for:id)?.display ?? "—"}
        return "\(key("library.rate0"))–\(key("library.rate5")) rate · \(key("library.label.red"))–\(key("library.label.blue")) labels · \(key("library.pick")) pick · \(key("library.reject")) reject · \(key("library.unflag")) unflag · ⌘-click selects multiple"
    }
    private func button(_ title:String,_ action:Selector)->NSButton{let b=NSButton(title:title,target:self,action:action);b.bezelStyle = .rounded;return b}
    var selectedItems:[ShootItem]{grid.selectionIndexPaths.sorted{$0.item<$1.item}.compactMap{shown.indices.contains($0.item) ? shown[$0.item]:nil}}
    func refresh(){
        guard !closed else{return}
        let token=UUID();generation=token;queue.cancelAllOperations()
        let selected=Set(selectedItems.map(\.id))
        message.stringValue="Reading \(urls.count) photographs…"
        let operation=BlockOperation();operation.addExecutionBlock{[weak self,weak operation] in
            guard let self else{return}
            var items:[ShootItem]=[],failures=0
            for url in self.urls {guard operation?.isCancelled==false else{return};do{items.append(try ShootItem.read(url))}catch{failures += 1}}
            DispatchQueue.main.async{[weak self] in guard let self,self.generation==token else{return};self.all=items;self.applyFilter(preserving:selected);if failures>0{self.message.stringValue += " · \(failures) unavailable files"}}
        };queue.addOperation(operation)
    }
    func setFlagFilter(_ index:Int) { flag.selectItem(at:max(0,min(index,3)));filterChanged() }
    @objc private func refreshAction(){refresh()}
    @objc private func filterChanged(){applyFilter(preserving:Set(selectedItems.map(\.id)))}
    private func applyFilter(preserving selection:Set<UUID>){
        let query=search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        shown=ShootWorkflow.filter(all,minimumRating:max(0,minimum.indexOfSelectedItem),flag:ShootFlagFilter.allCases[max(0,flag.indexOfSelectedItem)],sort:ShootSort.allCases[max(0,sort.indexOfSelectedItem)],label:Self.labelChoices[max(0,labelFilter.indexOfSelectedItem)],text:query)
        if let focused{shown=shown.filter{focused.ids.contains($0.id)}}
        grid.reloadData();grid.selectionIndexPaths=Set(shown.enumerated().filter{selection.contains($0.element.id) || $0.element.url == preferredURL}.map{IndexPath(item:$0.offset,section:0)})
        preferredURL=nil
        message.stringValue=focused.map{"\(shown.count) of \(all.count) photographs · \($0.title) · Actions → Show all photos to see the rest"} ?? "\(shown.count) of \(all.count) photographs · Reject flags never delete files"
        selectionChanged?()
    }
    func exportSelectedPhotos() { exportSelection() }
    func selectAllPhotos() {grid.selectionIndexPaths=Set(shown.indices.map {IndexPath(item:$0,section:0)});selectionChanged?()}
    var visibleURLs:[URL] {shown.map(\.url)}
    func collectionView(_ collectionView:NSCollectionView,didSelectItemsAt indexPaths:Set<IndexPath>){selectionChanged?()}
    func collectionView(_ collectionView:NSCollectionView,didDeselectItemsAt indexPaths:Set<IndexPath>){selectionChanged?()}
    @objc private func exportSelection(){
        guard !selectedItems.isEmpty else{message.stringValue="Select photos to export.";return}
        let panel=ExportPanel(items:selectedItems);exportPanel=panel;panel.showWindow(nil);panel.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func copyAdjustments(){
        guard selectedItems.count==1,let item=selectedItems.first else{message.stringValue="Select one source photo to copy adjustments.";return}
        Self.copied=item;message.stringValue="Copied adjustments from "+item.url.lastPathComponent+". Select destination photos, then Paste adjustments."
    }
    @objc private func pasteAdjustments(){
        guard let source=Self.copied else{message.stringValue="Copy adjustments from one source photo first.";return}
        let targets=selectedItems.filter{$0.id != source.id};guard !targets.isEmpty else{message.stringValue="Select destination photographs.";return}
        let panel=BatchPanel(source:source,targets:targets);batchPanel=panel;panel.completed = {[weak self] in self?.refresh();self?.recordsChanged?()};panel.showWindow(nil);panel.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func undoBatch(){
        guard let batch=BatchEdits.latest() else{message.stringValue="No saved batch to undo.";return}
        message.stringValue="Undoing batch…"
        DispatchQueue.global(qos:.userInitiated).async{[weak self] in
            let result=Result{try BatchEdits.undo(batch)}
            DispatchQueue.main.async{guard let self else{return};self.refresh();self.recordsChanged?();switch result{case .success(let undone):let failures=undone.entries.filter{!$0.undone}.count;let alert=NSAlert();alert.messageText="Batch undo";alert.informativeText="\(undone.entries.filter(\.undone).count) photos restored. \(failures) unchanged because they were not applied or were edited afterward.";if let window=self.browserView.window ?? self.window{alert.beginSheetModal(for:window)};case .failure(let error):self.message.stringValue=error.localizedDescription}}
        }
    }
    @objc private func rate(_ sender:NSButton){mark(rating:sender.tag)}
    @objc private func labelSelected(_ sender:NSMenuItem){if let raw=sender.representedObject as? String,let label=ColorLabel(rawValue:raw){mark(label:label)}}
    /// Lightroom behavior: pressing a photo's current label key again clears it.
    private func toggleLabel(_ label:ColorLabel){let selected=selectedItems;mark(label:!selected.isEmpty && selected.allSatisfy{$0.record.colorLabel == label} ? ColorLabel.none:label)}
    @objc private func editMetadata(){
        let items=selectedItems;guard !items.isEmpty else{message.stringValue="Select photos to describe.";return}
        let window=MetadataWindow(items:items);metadataWindow=window
        window.saved = {[weak self] updated in guard let self else{return};for record in updated{if let i=self.all.firstIndex(where:{$0.id==record.id}){self.all[i].record=record}};self.applyFilter(preserving:Set(items.map(\.id)));self.recordsChanged?()}
        window.showWindow(nil);window.window?.makeKeyAndOrderFront(nil)
    }
    /// Writes rating, flag, label and metadata to each photo's .xmp sidecar, keeping any other tags already in it.
    @objc private func writeXMP(){
        let items=selectedItems;guard !items.isEmpty else{message.stringValue="Select photos to write XMP sidecars for.";return}
        var failures=0
        for item in items{do{try XMPSidecar.write(item.record,for:item.url)}catch{failures += 1}}
        message.stringValue="Wrote \(items.count-failures) XMP sidecar\(items.count-failures == 1 ? "":"s")"+(failures>0 ? " · \(failures) couldn’t be written (is the folder read-only?)":".")
    }
    /// Reads rating, flag, label and metadata from sidecars (or XMP embedded in the photo), replacing what OpenStill has.
    @objc private func readXMP(){
        let items=selectedItems;guard !items.isEmpty else{message.stringValue="Select photos to read XMP for.";return}
        var read=0
        for item in items{
            guard let xmp=XMPSidecar.read(item.url),xmp.hasLibraryMetadata,let updated=try? EditStorage.records.update(item.id,{xmp.apply(to:&$0)}) else{continue}
            if let i=all.firstIndex(where:{$0.id==item.id}){all[i].record=updated};read += 1
        }
        applyFilter(preserving:Set(items.map(\.id)));recordsChanged?()
        message.stringValue=read == 0 ? "No XMP metadata found for the selected photos.":"Read XMP metadata for \(read) of \(items.count) photos."
    }
    /// Adds a "Camera Raw" version developed with the Lightroom / Camera Raw settings in each photo's XMP.
    @objc private func importCameraRaw(){
        let items=selectedItems;guard !items.isEmpty else{message.stringValue="Select photos with Camera Raw or Lightroom XMP sidecars.";return}
        var imported=0,none=0,notes:[String:Int]=[:],approximate:Set<String>=[]
        for item in items{
            guard let xmp=XMPSidecar.read(item.url),xmp.hasDevelopSettings else{none += 1;continue}
            var outcome:CameraRawImport?
            guard let updated=try? EditStorage.records.update(item.id,{outcome=$0.importCameraRaw(xmp)}),let result=outcome else{none += 1;continue}
            if let i=all.firstIndex(where:{$0.id==item.id}){all[i].record=updated}
            imported += 1;for line in result.unsupported{notes[line.components(separatedBy:" (").first ?? line,default:0] += 1};approximate.formUnion(result.approximated.map{$0.components(separatedBy:" (").first ?? $0})
        }
        applyFilter(preserving:Set(items.map(\.id)));recordsChanged?()
        let alert=NSAlert();alert.messageText=imported == 0 ? "No Camera Raw settings found":"Imported Camera Raw settings for \(imported) photo\(imported == 1 ? "":"s")"
        var text=imported == 0 ? "The selected photos have no .xmp sidecar with develop settings.":"Each photo has a new version named “Camera Raw”. The originals and the sidecars are unchanged. OpenStill’s tools are its own, so the look is close to Lightroom’s but not identical."
        if none>0 && imported>0{text += "\n\n\(none) photo\(none == 1 ? " had":"s had") no develop settings."}
        if !approximate.isEmpty{text += "\n\nApproximated: "+approximate.sorted().joined(separator:", ")+"."}
        if !notes.isEmpty{text += "\n\nNot carried over:\n"+notes.sorted{$0.key<$1.key}.prefix(20).map{"• \($0.key)"+(items.count>1 ? " (\($0.value))":"")}.joined(separator:"\n")}
        alert.informativeText=text
        if let window=browserView.window ?? window{alert.beginSheetModal(for:window)}else{alert.runModal()}
    }
    @objc private func mergeHDR(){merge(.hdr)}
    @objc private func mergePanorama(){merge(.panorama)}
    @objc private func mergeFocusStack(){merge(.focusStack)}
    /// HDR, panorama or focus stack from the selected photos, written as a float TIFF next to the first one.
    private func merge(_ kind:MergeKind){
        let items=selectedItems
        guard !merging else{message.stringValue="A merge is already running.";return}
        guard items.count>=2 else{message.stringValue="Select two or more photos to merge.";return}
        // Panoramas follow capture order; the others don't depend on it.
        let urls=items.sorted{$0.captured == $1.captured ? $0.url.lastPathComponent<$1.url.lastPathComponent:$0.captured<$1.captured}.map(\.url)
        let alert=NSAlert();alert.messageText="\(kind == .focusStack ? "Focus stack":"Merge to "+kind.title.lowercased().replacingOccurrences(of:"hdr",with:"HDR")) · \(urls.count) photos"
        let align=NSButton(checkboxWithTitle:"Align hand-held photos",target:nil,action:nil);align.state = .on
        let deghost=NSPopUpButton();deghost.addItems(withTitles:["No deghosting","Low deghosting","Medium deghosting","High deghosting"]);deghost.selectItem(at:2)
        let projection=NSPopUpButton();projection.addItems(withTitles:PanoramaProjection.allCases.map(\.title))
        let crop=NSButton(checkboxWithTitle:"Crop to fill the frame",target:nil,action:nil);crop.state = .on
        let stack=NSStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=8
        switch kind {
        case .hdr:
            alert.informativeText="Bracketed exposures of the same scene become one photo with the detail of all of them. Deghosting takes moving things from a single exposure."
            stack.addArrangedSubview(align);stack.addArrangedSubview(deghost)
        case .panorama:
            alert.informativeText="Frames are joined in the order they were taken. Each frame should overlap its neighbour by about a third."
            stack.addArrangedSubview(projection);stack.addArrangedSubview(crop)
        case .focusStack:
            alert.informativeText="Photos focused at different distances become one photo that is sharp throughout."
            stack.addArrangedSubview(align)
        }
        stack.frame=NSRect(x:0,y:0,width:300,height:CGFloat(stack.arrangedSubviews.count)*30);alert.accessoryView=stack
        alert.addButton(withTitle:"Merge");alert.addButton(withTitle:"Cancel")
        let run:(NSApplication.ModalResponse)->Void={[weak self] response in
            guard let self,response == .alertFirstButtonReturn else{return}
            var options=MergeOptions();options.align=align.state == .on;options.deghost=[0,0.3,0.6,1][max(0,deghost.indexOfSelectedItem)]
            options.projection=PanoramaProjection.allCases[max(0,projection.indexOfSelectedItem)];options.autoCrop=crop.state == .on
            self.merging=true;self.message.stringValue="Merging \(urls.count) photos…"
            DispatchQueue.global(qos:.userInitiated).async{[weak self] in
                let result=Result{try autoreleasepool{try Merges.merge(urls,kind:kind,options:options,progress:{text in DispatchQueue.main.async{self?.message.stringValue=text}})}}
                DispatchQueue.main.async{[weak self] in
                    guard let self else{return};self.merging=false
                    switch result{
                    case .success(let url):self.message.stringValue="Saved \(url.lastPathComponent) next to the originals.";self.merged?(url)
                    case .failure(let error):self.message.stringValue=error.localizedDescription
                    }
                }
            }
        }
        if let window=browserView.window ?? window{alert.beginSheetModal(for:window,completionHandler:run)}else{run(alert.runModal())}
    }
    /// The selected photos, or every photo shown when nothing is selected.
    private var outputItems:[ShootItem]{selectedItems.isEmpty ? shown:selectedItems}
    private func present(_ window:OutputWindow){outputWindows.removeAll{$0.window?.isVisible != true};outputWindows.append(window);window.showWindow(nil);window.window?.makeKeyAndOrderFront(nil)}
    @objc private func printPhotos(){guard !outputItems.isEmpty else{message.stringValue="Open photos to print.";return};present(PrintWindow(items:outputItems))}
    @objc private func slideshow(){guard !outputItems.isEmpty else{message.stringValue="Open photos for a slideshow.";return};present(SlideshowWindow(items:outputItems))}
    @objc private func webGallery(){guard !outputItems.isEmpty else{message.stringValue="Open photos for a gallery.";return};present(GalleryWindow(items:outputItems))}
    @objc private func publishPhotos(){present(PublishWindow(items:selectedItems,library:all))}
    // MARK: Lightroom layout: module picker and panel buttons
    /// Opens Map, Slideshow, Print or Web for the selected photos (or all shown photos).
    func openModule(_ module:LightroomModule){
        switch module{case .map:showMap();case .slideshow:slideshow();case .print:printPhotos();case .web:webGallery();case .library,.develop:break}
    }
    func openPublish(){publishPhotos()}
    /// Selects this photo in the grid, e.g. when it's clicked in the Lightroom filmstrip.
    func select(url:URL){
        guard let i=shown.firstIndex(where:{$0.url==url}) else{return}
        let path=IndexPath(item:i,section:0);grid.selectionIndexPaths=[path];grid.scrollToItems(at:[path],scrollPosition:.centeredVertically);selectionChanged?()
    }
    func openMetadataEditor(){editMetadata()}
    func exportSelected(){exportSelection()}
    /// Sync Settings: the first selected photo's adjustments go to the other selected photos, after review.
    func syncSettings(){
        let chosen=selectedItems;guard chosen.count>1,let source=chosen.first else{message.stringValue="Select the source photo, then ⌘-click the photos to sync.";return}
        Self.copied=source;pasteAdjustments()
    }
    /// Copy… in Develop. Returns a status line.
    func copySettings(from url:URL)->String{
        guard let item=all.first(where:{$0.url==url}) else{return "The library is still reading this photo. Try again in a moment."}
        Self.copied=item;return "Copied settings from \(url.lastPathComponent). Choose another photo, then Paste."
    }
    /// Paste in Develop: reviews and applies the copied settings to this photo. Returns a status line.
    func pasteSettings(to url:URL)->String{
        guard let source=Self.copied else{return "Copy settings from a photo first."}
        let targets=all.filter{$0.url==url && $0.id != source.id};guard !targets.isEmpty else{return source.url==url ? "Choose a different photo to paste onto." : "The library is still reading this photo. Try again in a moment."}
        let panel=BatchPanel(source:source,targets:targets);batchPanel=panel;panel.completed = {[weak self] in self?.refresh();self?.recordsChanged?()};panel.showWindow(nil);panel.window?.makeKeyAndOrderFront(nil)
        return "Review the settings to paste from \(source.url.lastPathComponent)."
    }
    /// Shows only these photos (from People, Map or Timeline) until Show all photos.
    func focus(on ids:Set<UUID>,title:String){
        focused=(ids,title);applyFilter(preserving:[]);(browserView.window ?? window)?.makeKeyAndOrderFront(nil)
        if shown.isEmpty{message.stringValue="None of the photos for \(title) are in this folder or collection."}
    }
    @objc private func clearFocus(){focused=nil;applyFilter(preserving:Set(selectedItems.map(\.id)))}
    @objc private func showPeople(){
        guard !all.isEmpty else{message.stringValue="Open a folder of photos first.";return}
        let w=PeopleWindow(items:all)
        w.show={[weak self] ids,title in self?.focus(on:ids,title:title)};w.changedRecords={[weak self] in self?.refresh();self?.recordsChanged?()};present(w)
    }
    @objc private func showMap(){
        guard !all.isEmpty else{message.stringValue="Open a folder of photos first.";return}
        let w=MapWindow(items:all)
        w.show={[weak self] ids,title in self?.focus(on:ids,title:title)};w.changedRecords={[weak self] in self?.refresh();self?.recordsChanged?()};present(w)
    }
    @objc private func showTimeline(){
        guard !all.isEmpty else{message.stringValue="Open a folder of photos first.";return}
        let w=TimelineWindow(items:all)
        w.show={[weak self] ids,title in self?.focus(on:ids,title:title)};present(w)
    }
    /// Exact copies and near-duplicates among the selected photos, or all shown photos when none (or one) is selected.
    @objc private func findDuplicates(){
        let chosen=selectedItems.count>1 ? selectedItems:shown;guard chosen.count>1 else{message.stringValue="Open a folder with at least two photos to look for duplicates.";return}
        let window=DuplicatesWindow(urls:chosen.map(\.url));duplicatesWindow=window
        window.changed={[weak self] in self?.refresh();self?.recordsChanged?()}
        window.showWindow(nil);window.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func addToCollection(){
        let items=selectedItems;guard !items.isEmpty,let catalog=EditStorage.records.catalog else{message.stringValue="Select photos to add to a collection.";return}
        let collections=catalog.collections().filter{!$0.isSmart}
        let alert=NSAlert();alert.messageText="Add \(items.count) photo\(items.count == 1 ? "":"s") to a collection"
        alert.informativeText="Choose a collection, or type a name for a new one."
        let popup=NSComboBox(frame:NSRect(x:0,y:0,width:280,height:26));popup.addItems(withObjectValues:collections.map(\.name));popup.placeholderString="Collection name";popup.completes=true
        if let current=collection,!current.isSmart{popup.stringValue=current.name}
        alert.accessoryView=popup;alert.addButton(withTitle:"Add");alert.addButton(withTitle:"Cancel")
        let finish:(NSApplication.ModalResponse)->Void={[weak self] response in
            guard let self,response == .alertFirstButtonReturn else{return}
            let name=popup.stringValue.trimmingCharacters(in:.whitespacesAndNewlines);guard !name.isEmpty else{return}
            do{
                let target=try collections.first{$0.name.caseInsensitiveCompare(name) == .orderedSame} ?? catalog.createCollection(name:name)
                try catalog.add(items.map(\.id),to:target.id);self.message.stringValue="Added \(items.count) to “\(target.name)”.";self.collectionsChanged?()
            }catch{self.message.stringValue=error.localizedDescription}
        }
        if let window=browserView.window ?? window{alert.beginSheetModal(for:window,completionHandler:finish)}else{finish(alert.runModal())}
    }
    @objc private func removeFromCollection(){
        guard let current=collection,!current.isSmart else{message.stringValue="Open a regular collection to remove photos from it.";return}
        let items=selectedItems;guard !items.isEmpty else{message.stringValue="Select photos to remove from “\(current.name)”.";return}
        do{try EditStorage.records.catalog?.remove(items.map(\.id),from:current.id);all.removeAll{item in items.contains{$0.id==item.id}};applyFilter(preserving:[]);message.stringValue="Removed \(items.count) from “\(current.name)”. The files are untouched.";collectionsChanged?()}
        catch{message.stringValue=error.localizedDescription}
    }
    @objc private func flagSelected(_ sender:NSButton){mark(flag:PhotoFlag.allCases[sender.tag])}
    private func mark(rating:Int? = nil,flag:PhotoFlag? = nil,label:ColorLabel? = nil){
        let selected=selectedItems;guard !selected.isEmpty else{message.stringValue="Select one or more photographs first.";return}
        do{
            for item in selected{let updated=try ShootWorkflow.mark(item.id,rating:rating,flag:flag,label:label);if let i=all.firstIndex(where:{$0.id==item.id}){all[i].record=updated}}
            applyFilter(preserving:Set(selected.map(\.id)));recordsChanged?()
        }catch{message.stringValue=error.localizedDescription}
    }
    @objc private func openSelected(){guard let first=selectedItems.first else{message.stringValue="Select a photograph to edit.";return};edit?(shown.map(\.url),first.url)}
    @objc private func compareSelected(){let items=selectedItems;guard items.count==2 else{message.stringValue="Select exactly two photographs to compare.";return};let comparison=ComparisonWindow(items:items);comparisons.append(comparison);comparison.showWindow(nil);comparison.window?.makeKeyAndOrderFront(nil)}
    func collectionView(_ collectionView:NSCollectionView,numberOfItemsInSection section:Int)->Int{shown.count}
    func collectionView(_ collectionView:NSCollectionView,itemForRepresentedObjectAt indexPath:IndexPath)->NSCollectionViewItem{
        let cell=collectionView.makeItem(withIdentifier:NSUserInterfaceItemIdentifier("shoot"),for:indexPath) as! ShootCell
        let item=shown[indexPath.item],request=RenderRequest(photo:item.record,profile:.displayP3,maximumDimension:420)
        let key="\(request.photoID)|\(request.sourceFingerprint)|\(request.sourceMode)|\(request.versionID)|\(request.revision)|\(request.profile)"
        cell.configure(item);cell.requestKey=key
        if let image=cache.object(forKey:key as NSString){cell.preview.imageScaling = .scaleProportionallyUpOrDown;cell.preview.image=image;return cell}
        let operation=BlockOperation();operation.addExecutionBlock{[weak self,weak cell,weak operation] in
            guard operation?.isCancelled==false else{return}
            // Previews saved on disk skip rendering; they're keyed by the edit revision, so edits make a new one.
            var result=PreviewCache.read(request)
            if result==nil{
                result=try? autoreleasepool{try ModernRenderer.display(ModernRenderer.render(source:item.url,recipe:item.record.active.recipe,maximumDimension:420))}
                if let rendered=result{PreviewCache.write(rendered,for:request)}
            }
            guard operation?.isCancelled==false else{return}
            DispatchQueue.main.async{guard let cell,cell.requestKey==key else{return};if let result{let image=NSImage(cgImage:result,size:.zero);self?.cache.setObject(image,forKey:key as NSString,cost:result.bytesPerRow*result.height);cell.preview.imageScaling = .scaleProportionallyUpOrDown;cell.preview.image=image}else{cell.preview.image=Appearance.symbol("exclamationmark.triangle",size:24)}}
        };queue.addOperation(operation);return cell
    }
    func stopBrowsing(){closed=true;generation=UUID();queue.cancelAllOperations();cache.removeAllObjects()}
    func windowWillClose(_ notification:Notification){stopBrowsing()}
}

final class ComparisonWindow:NSWindowController,NSWindowDelegate {
    private let canvases=[PhotoCanvas(),PhotoCanvas()]
    private var zoomControls:[NSSegmentedControl]=[]
    private var closed=false
    private let queue=OperationQueue()
    init(items:[ShootItem]){
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:750),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        super.init(window:window);queue.maxConcurrentOperationCount=1;queue.qualityOfService = .utility;window.delegate=self;window.title="Compare · OpenStill";window.center();Appearance.configure(window)
        let content=Appearance.panel(in:window)
        let columns=NSStackView();columns.distribution = .fillEqually;columns.spacing=12;columns.translatesAutoresizingMaskIntoConstraints=false;content.addSubview(columns)
        NSLayoutConstraint.activate([columns.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:12),columns.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-12),columns.topAnchor.constraint(equalTo:content.topAnchor,constant:12),columns.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-12)])
        for i in 0..<2 {
            let canvas=canvases[i],item=items[i]
            let name=NSTextField(labelWithString:item.url.lastPathComponent);name.font = .systemFont(ofSize:12,weight:.medium)
            let metadata=NSTextField(wrappingLabelWithString:"Loading camera information…");metadata.font = .systemFont(ofSize:11);metadata.textColor = .secondaryLabelColor;metadata.isSelectable=true
            let zoom=NSSegmentedControl(labels:["Fit","100%"],trackingMode:.selectOne,target:self,action:#selector(changeZoom(_:)));zoom.tag=i;zoom.selectedSegment=0;zoomControls.append(zoom);zoom.setAccessibilityLabel("Comparison zoom "+item.url.lastPathComponent)
            let column=NSStackView(views:[name,zoom,canvas,metadata]);column.orientation = .vertical;column.alignment = .leading;column.spacing=10;columns.addArrangedSubview(column)
            for child in [canvas,metadata]{child.widthAnchor.constraint(equalTo:column.widthAnchor).isActive=true};canvas.heightAnchor.constraint(greaterThanOrEqualToConstant:300).isActive=true;metadata.heightAnchor.constraint(equalToConstant:65).isActive=true
            canvas.message="Loading…";canvas.viewportChanged = {[weak self] in guard let self else{return};self.canvases[1-i].setViewport(self.canvases[i].viewport);self.updateZoomControls()}
            canvas.toggleZoom = {[weak canvas] in guard let canvas else{return};canvas.native = !canvas.native}
            queue.addOperation{[weak self,weak canvas,weak metadata] in
                guard self?.closed==false else{return}
                let result=try? autoreleasepool{try ModernRenderer.display(ModernRenderer.render(source:item.url,recipe:item.record.active.recipe))}
                let info=PhotoMetadata.read(item.url)
                DispatchQueue.main.async{guard let self,!self.closed,let canvas else{return};let state=self.canvases[1-i].viewport;canvas.image=result;canvas.setViewport(state);self.updateZoomControls();canvas.message=result==nil ? "Couldn’t render this photograph":"";metadata?.stringValue="\(info.camera) · \(info.lens)\n\(info.shutter) · \(info.aperture) · ISO \(info.iso) · \(info.focalLength)";metadata?.toolTip=info.allFields.joined(separator:"\n")}
            }
        }
    }
    required init?(coder:NSCoder){fatalError()}
    func windowWillClose(_ notification:Notification){closed=true;queue.cancelAllOperations();canvases.forEach{$0.image=nil}}
    private func updateZoomControls(){for i in canvases.indices{zoomControls[i].selectedSegment=canvases[i].isFit ? 0:canvases[i].native ? 1:-1}}
    @objc private func changeZoom(_ sender:NSSegmentedControl){canvases[sender.tag].native=sender.selectedSegment==1}
}
extension ViewerController {
    @objc func showShoot(){
        guard !urls.isEmpty else{info.status("Open a photo folder first.");return}
        let window=ShootWindow(urls:shootCatalog.isEmpty ? urls:shootCatalog);shootWindow=window
        window.merged = {[weak self] url in self?.addMergedPhoto(url)}
        window.edit = {[weak self] filtered,url in
            guard let self else{return}
            self.showShootSelection(filtered:filtered,url:url)
        }
        window.recordsChanged = {[weak self] in guard let self,let id=self.photoRecord?.id,let latest=try? EditStorage.records.read(id) else{return};let changed=self.photoRecord?.active.revision != latest.active.revision || self.photoRecord?.activeVersionID != latest.activeVersionID;self.photoRecord=latest;if changed{self.editDocument=latest.active.document;self.currentEdits=latest.active.document.current;self.info.update(self.currentEdits,document:self.editDocument,enabled:true);self.renderEdits()}}
        window.showWindow(nil);window.window?.makeKeyAndOrderFront(nil)
    }
}
