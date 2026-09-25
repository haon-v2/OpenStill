import AppKit
import CoreImage
import UniformTypeIdentifiers
import OpenStillCore

private final class ExportControlStack:NSStackView {override var isFlipped:Bool{true}}

final class ExportPanel:NSWindowController,NSWindowDelegate,NSTextFieldDelegate {
    private let items:[ShootItem]
    private var settings=ExportSettings(),proof=ProofSettings(),presets=ExportPresets.load()
    private let preview=NSImageView(),result=NSTextView(),status=NSTextField(labelWithString:"Preparing export preview…")
    private let preset=NSPopUpButton(),format=NSPopUpButton(),profile=NSPopUpButton(),depth=NSPopUpButton(),intent=NSPopUpButton()
    private let quality=NSSlider(value:90,minValue:1,maxValue:100,target:nil,action:nil),sharp=NSSlider(value:0,minValue:0,maxValue:2,target:nil,action:nil)
    private let edge=NSTextField(string:""),name=NSTextField(string:"{name}-edited")
    private let upscale=NSButton(checkboxWithTitle:"Allow upscaling",target:nil,action:nil),metadata=NSButton(checkboxWithTitle:"Keep camera, lens & copyright metadata",target:nil,action:nil),gps=NSButton(checkboxWithTitle:"Include GPS location",target:nil,action:nil)
    private let proofEnabled=NSButton(checkboxWithTitle:"Soft proof preview",target:nil,action:nil),paper=NSButton(checkboxWithTitle:"Simulate paper & ink",target:nil,action:nil),gamut=NSButton(checkboxWithTitle:"Show out-of-gamut colors in magenta",target:nil,action:nil)
    private let proofName=NSTextField(labelWithString:"No printer/paper profile selected")
    private let start=NSButton(title:"Choose folder & export…",target:nil,action:nil),retry=NSButton(title:"Retry unfinished",target:nil,action:nil),cancel=NSButton(title:"Stop queue",target:nil,action:nil)
    private let watermark=NSPopUpButton(),anchor=NSPopUpButton(),markSize=NSSlider(value:20,minValue:1,maxValue:100,target:nil,action:nil),margin=NSSlider(value:3,minValue:0,maxValue:25,target:nil,action:nil),markOpacity=NSSlider(value:0.8,minValue:0,maxValue:1,target:nil,action:nil)
    private var logos:[WatermarkLogo]=[],designer:LogoDesigner?
    private var controls:[NSControl]=[],batch:ExportBatch?,running=false,closed=false,previewToken=UUID(),cancellation=WorkflowCancellation()
    private let previewQueue:OperationQueue={let q=OperationQueue();q.maxConcurrentOperationCount=1;q.qualityOfService = .userInitiated;return q}()
    init(items:[ShootItem]) {
        self.items=items
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1040,height:790),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        super.init(window:window);window.title="Export · OpenStill";window.minSize=NSSize(width:900,height:690);window.center();window.delegate=self;Appearance.configure(window)
        let root=Appearance.panel(in:window)
        let left=ExportControlStack();left.orientation = .vertical;left.alignment = .leading;left.spacing=12
        let scroller=NSScrollView();scroller.documentView=left;scroller.hasVerticalScroller=true;scroller.drawsBackground=false;left.translatesAutoresizingMaskIntoConstraints=false
        let heading=NSTextField(labelWithString:"Export \(items.count) photograph\(items.count==1 ? "":"s")");heading.font = .systemFont(ofSize:17,weight:.semibold);left.addArrangedSubview(heading)
        refreshPresets();preset.target=self;preset.action = #selector(loadPreset);preset.setAccessibilityLabel("Export preset")
        let save=NSButton(title:"Save preset…",target:self,action:#selector(savePreset));save.bezelStyle = .rounded
        let presetRow=NSStackView(views:[preset,save]);presetRow.spacing=8;left.addArrangedSubview(presetRow)
        format.addItems(withTitles:["JPEG","PNG","TIFF"]);profile.addItems(withTitles:ExportProfile.allCases.map(\.title));depth.addItems(withTitles:["8 bit","16 bit"]);intent.addItems(withTitles:RenderingIntent.allCases.map(\.title));intent.selectItem(at:1)
        edge.placeholderString="Original dimensions";edge.delegate=self;name.delegate=self
        let grid=NSGridView(views:[[NSTextField(labelWithString:"Format"),format],[NSTextField(labelWithString:"Color profile"),profile],[NSTextField(labelWithString:"Bit depth"),depth],[NSTextField(labelWithString:"JPEG quality"),quality],[NSTextField(labelWithString:"Longest edge (px)"),edge],[NSTextField(labelWithString:"Output sharpening"),sharp],[NSTextField(labelWithString:"Filename"),name]])
        grid.rowSpacing=12;grid.columnSpacing=12;grid.column(at:1).width=210;left.addArrangedSubview(grid)
        for (control,label) in [(format,"Export format"),(profile,"Export color profile"),(depth,"Export bit depth"),(quality,"JPEG quality percent"),(edge,"Longest edge pixels"),(sharp,"Output sharpening"),(name,"Filename template")] as [(NSControl,String)]{control.setAccessibilityLabel(label)}
        let hint=NSTextField(wrappingLabelWithString:"Filename tokens: {name}, {index}, {date}, {version}. Existing files receive a unique suffix.");hint.font = .systemFont(ofSize:10);hint.textColor = .secondaryLabelColor;left.addArrangedSubview(hint)
        metadata.state = .on
        for view in [upscale,metadata,gps]{left.addArrangedSubview(view)}
        let watermarkTitle=NSTextField(labelWithString:"Watermarks");watermarkTitle.font = .systemFont(ofSize:10,weight:.semibold);watermarkTitle.textColor = .secondaryLabelColor;left.addArrangedSubview(watermarkTitle)
        refreshLogos();anchor.addItems(withTitles:WatermarkAnchor.allCases.map(\.title));anchor.selectItem(at:8)
        let logoActions=NSStackView(views:[NSButton(title:"Import logo…",target:self,action:#selector(importLogo)),NSButton(title:"Create logo…",target:self,action:#selector(createLogo))]);logoActions.spacing=8;left.addArrangedSubview(logoActions)
        let watermarkGrid=NSGridView(views:[[NSTextField(labelWithString:"Logo"),watermark],[NSTextField(labelWithString:"Placement"),anchor],[NSTextField(labelWithString:"Size % of width"),markSize],[NSTextField(labelWithString:"Margin %"),margin],[NSTextField(labelWithString:"Opacity"),markOpacity]]);watermarkGrid.rowSpacing=10;watermarkGrid.columnSpacing=12;watermarkGrid.column(at:1).width=220;left.addArrangedSubview(watermarkGrid)
        for (control,label) in [(watermark,"Watermark logo"),(anchor,"Watermark anchor"),(markSize,"Watermark size percent"),(margin,"Watermark margin percent"),(markOpacity,"Watermark opacity")] as [(NSControl,String)]{control.setAccessibilityLabel(label);control.target=self;control.action = #selector(changed)}
        let proofTitle=NSTextField(labelWithString:"Print Proof · Preview Only");proofTitle.font = .systemFont(ofSize:10,weight:.semibold);proofTitle.textColor = .secondaryLabelColor;left.addArrangedSubview(proofTitle)
        let choose=NSButton(title:"Choose printer / paper ICC…",target:self,action:#selector(chooseProof));choose.bezelStyle = .rounded;left.addArrangedSubview(choose)
        proofName.font = .systemFont(ofSize:11);proofName.lineBreakMode = .byTruncatingMiddle;left.addArrangedSubview(proofName)
        for view in [proofEnabled,intent,paper,gamut]{left.addArrangedSubview(view)}
        let proofHint=NSTextField(wrappingLabelWithString:"Proofing simulates the selected printer profile on your display. It does not change exported files.");proofHint.font = .systemFont(ofSize:10);proofHint.textColor = .secondaryLabelColor;left.addArrangedSubview(proofHint)
        controls=[format,profile,depth,quality,sharp,edge,name,upscale,metadata,gps,preset,save,choose,proofEnabled,intent,paper,gamut,watermark,anchor,markSize,margin,markOpacity]+logoActions.arrangedSubviews.compactMap{$0 as? NSControl}
        for control in [format,profile,depth,quality,sharp,upscale,metadata,gps,proofEnabled,intent,paper,gamut] as [NSControl]{control.target=self;control.action = #selector(changed)}
        preview.setContentHuggingPriority(.defaultLow,for:.horizontal);preview.setContentHuggingPriority(.defaultLow,for:.vertical);preview.setContentCompressionResistancePriority(.defaultLow,for:.horizontal);preview.setContentCompressionResistancePriority(.defaultLow,for:.vertical);preview.imageScaling = .scaleProportionallyUpOrDown;preview.setAccessibilityLabel("Export preview of "+(items.first?.url.lastPathComponent ?? "photo"))
        result.isEditable=false;result.isSelectable=true;result.font = .systemFont(ofSize:11);result.textContainerInset=NSSize(width:8,height:8);result.autoresizingMask=[.width];result.isVerticallyResizable=true;result.textContainer?.widthTracksTextView=true
        let log=NSScrollView();log.documentView=result;log.hasVerticalScroller=true;log.borderType = .bezelBorder
        start.target=self;start.action = #selector(chooseDestination);retry.target=self;retry.action = #selector(retryBatch);cancel.target=self;cancel.action = #selector(stopBatch)
        for button in [start,retry,cancel]{button.bezelStyle = .rounded};retry.isEnabled=false;cancel.isEnabled=false;Appearance.primary(start)
        status.font = .systemFont(ofSize:11);status.lineBreakMode = .byWordWrapping;status.maximumNumberOfLines=3
        let actions=NSStackView(views:[start,cancel,retry]);actions.spacing=8
        let right=NSStackView(views:[preview,status,log,actions]);right.orientation = .vertical;right.spacing=12;right.alignment = .leading
        for child in [scroller,right]{child.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(child)}
        NSLayoutConstraint.activate([scroller.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:20),scroller.topAnchor.constraint(equalTo:root.topAnchor,constant:20),scroller.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-20),scroller.widthAnchor.constraint(equalToConstant:390),left.leadingAnchor.constraint(equalTo:scroller.contentView.leadingAnchor),left.topAnchor.constraint(equalTo:scroller.contentView.topAnchor),left.widthAnchor.constraint(equalTo:scroller.widthAnchor,constant:-16),right.leadingAnchor.constraint(equalTo:scroller.trailingAnchor,constant:20),right.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-20),right.topAnchor.constraint(equalTo:scroller.topAnchor),right.bottomAnchor.constraint(equalTo:scroller.bottomAnchor),preview.heightAnchor.constraint(greaterThanOrEqualToConstant:250),log.heightAnchor.constraint(equalToConstant:190)])
        for view in [preview,status,log,actions]{view.widthAnchor.constraint(equalTo:right.widthAnchor).isActive=true}
        for view in [hint,proofHint,proofName]{view.widthAnchor.constraint(equalTo:left.widthAnchor).isActive=true}
        updateEnabled();renderPreview()
    }
    required init?(coder:NSCoder){fatalError()}
    func controlTextDidChange(_ obj:Notification){changed()}
    private func readSettings(){settings.format=ExportFormat.allCases[max(0,format.indexOfSelectedItem)];settings.profile=ExportProfile.allCases[max(0,profile.indexOfSelectedItem)];settings.bitDepth=depth.indexOfSelectedItem==1 ? 16:8;settings.quality=quality.doubleValue/100;settings.sharpening=sharp.doubleValue;settings.longestEdge=edge.stringValue.isEmpty ? nil:Int(edge.stringValue);settings.allowUpscaling=upscale.state == .on;settings.keepMetadata=metadata.state == .on;settings.keepGPS=gps.state == .on;settings.filenameTemplate=name.stringValue;if watermark.indexOfSelectedItem>0,logos.indices.contains(watermark.indexOfSelectedItem-1){var mark=WatermarkSettings(asset:logos[watermark.indexOfSelectedItem-1].asset);mark.anchor=WatermarkAnchor.allCases[max(0,anchor.indexOfSelectedItem)];mark.size=markSize.doubleValue;mark.margin=margin.doubleValue;mark.opacity=markOpacity.doubleValue;settings.watermark=mark}else{settings.watermark=nil};settings=settings.sanitized;proof.enabled=proofEnabled.state == .on;proof.intent=RenderingIntent.allCases[max(0,intent.indexOfSelectedItem)];proof.paper=paper.state == .on;proof.gamut=gamut.state == .on}
    @objc private func changed(){readSettings();updateEnabled();renderPreview()}
    private func updateEnabled(){depth.isEnabled = !running && settings.format != .jpeg;quality.isEnabled = !running && settings.format == .jpeg;gps.isEnabled = !running && settings.keepMetadata;proofEnabled.isEnabled = !running && proof.profileAsset != nil;intent.isEnabled = !running && proof.enabled;paper.isEnabled=intent.isEnabled;gamut.isEnabled=intent.isEnabled;for control in [anchor,markSize,margin,markOpacity] as [NSControl]{control.isEnabled = !running && settings.watermark != nil}}
    private func refreshPresets(){preset.removeAllItems();preset.addItem(withTitle:"Custom settings");preset.addItems(withTitles:presets.map(\.name))}
    @objc private func loadPreset(){guard preset.indexOfSelectedItem>0 else{return};settings=presets[preset.indexOfSelectedItem-1].settings;format.selectItem(at:ExportFormat.allCases.firstIndex(of:settings.format)!);profile.selectItem(at:ExportProfile.allCases.firstIndex(of:settings.profile)!);depth.selectItem(at:settings.bitDepth==16 ? 1:0);quality.doubleValue=settings.quality*100;sharp.doubleValue=settings.sharpening;edge.stringValue=settings.longestEdge.map(String.init) ?? "";name.stringValue=settings.filenameTemplate;upscale.state=settings.allowUpscaling ? .on:.off;metadata.state=settings.keepMetadata ? .on:.off;gps.state=settings.keepGPS ? .on:.off;refreshLogos();if let mark=settings.watermark{watermark.selectItem(at:(logos.firstIndex{$0.asset==mark.asset}.map{$0+1}) ?? 0);anchor.selectItem(at:mark.anchor.rawValue);markSize.doubleValue=mark.size;margin.doubleValue=mark.margin;markOpacity.doubleValue=mark.opacity};updateEnabled();renderPreview()}
    @objc private func savePreset(){guard let window else{return};readSettings();let alert=NSAlert();alert.messageText="Save export preset";let field=NSTextField(string:"Photography export");field.frame=NSRect(x:0,y:0,width:300,height:24);alert.accessoryView=field;alert.addButton(withTitle:"Save");alert.addButton(withTitle:"Cancel");alert.beginSheetModal(for:window){[weak self] response in guard let self,response == .alertFirstButtonReturn,!field.stringValue.trimmingCharacters(in:.whitespaces).isEmpty else{return};self.presets.append(ExportPreset(name:field.stringValue,settings:self.settings));do{try ExportPresets.save(self.presets);self.refreshPresets();self.preset.selectItem(at:self.presets.count)}catch{self.status.stringValue=error.localizedDescription}}}
    private func refreshLogos(){let selected=settings.watermark?.asset;logos=Watermarks.library();watermark.removeAllItems();watermark.addItem(withTitle:"No watermark");watermark.addItems(withTitles:logos.map(\.name));watermark.selectItem(at:logos.firstIndex{$0.asset==selected}.map{$0+1} ?? 0)}
    private func useLogo(_ logo:WatermarkLogo){settings.watermark=WatermarkSettings(asset:logo.asset);refreshLogos();changed()}
    @objc private func importLogo(){guard let window else{return};let panel=NSOpenPanel();panel.allowedContentTypes=[.png,.tiff,.jpeg,.pdf,.svg];panel.beginSheetModal(for:window){[weak self] response in guard let self,response == .OK,let url=panel.url else{return};do{self.useLogo(try Watermarks.importLogo(url))}catch{self.status.stringValue=error.localizedDescription}}}
    @objc private func createLogo(){let designer=LogoDesigner();self.designer=designer;designer.saved = {[weak self] logo in self?.useLogo(logo)};designer.showWindow(nil);designer.window?.makeKeyAndOrderFront(nil)}
    @objc private func chooseProof(){guard let window else{return};let panel=NSOpenPanel();panel.allowedContentTypes=[UTType(filenameExtension:"icc") ?? .data,UTType(filenameExtension:"icm") ?? .data];panel.beginSheetModal(for:window){[weak self] response in guard let self,response == .OK,let url=panel.url else{return};do{self.proof.profileAsset=try SoftProof.importProfile(url);self.proofName.stringValue=url.lastPathComponent;self.proofEnabled.state = .on;self.changed()}catch{self.status.stringValue=error.localizedDescription}}}
    private func renderPreview(){
        guard let item=items.first else{return};let token=UUID();previewToken=token;let settings=settings,proof=proof
        previewQueue.cancelAllOperations();let operation=BlockOperation()
        operation.addExecutionBlock{[weak self,weak operation] in
            guard operation?.isCancelled==false else{return}
            let image=Result{try autoreleasepool{let rendered=try ModernRenderer.render(source:item.url,recipe:item.record.active.recipe);var output=try ModernRenderer.prepareOutput(rendered,settings:settings);let scale=min(1,1100/max(output.extent.width,output.extent.height));output=output.applyingFilter("CILanczosScaleTransform",parameters:[kCIInputScaleKey:scale]);output=try ModernRenderer.outputPreview(output,settings:settings);return try ModernRenderer.display(SoftProof.apply(output,settings:proof))}}
            DispatchQueue.main.async{guard let self,!self.closed,self.previewToken==token else{return};switch image{case .success(let cg):self.preview.image=NSImage(cgImage:cg,size:.zero);if !self.running{self.status.stringValue=proof.enabled ? "Soft proof preview · Exports keep their selected output profile":"Export preview · "+item.url.lastPathComponent};case .failure(let error):self.status.stringValue=error.localizedDescription}}
        };previewQueue.addOperation(operation)
    }
    @objc private func chooseDestination(){
        guard let window,!running else{return};readSettings()
        guard edge.stringValue.isEmpty || (Int(edge.stringValue) ?? 0)>0 else{status.stringValue="Enter a positive pixel size or leave it blank for original dimensions.";return}
        do{if let item=items.first{_ = try ExportWorkflow.filename(ExportJob(item),index:0,settings:settings)}}catch{status.stringValue=error.localizedDescription;return}
        let panel=NSOpenPanel();panel.title="Export folder";panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;panel.prompt="Export here";panel.beginSheetModal(for:window){[weak self] response in guard let self,response == .OK,let directory=panel.url else{return};self.batch=ExportBatch(items:self.items,settings:self.settings,directory:directory);self.runBatch()}
    }
    private func runBatch(){guard let batch,!running else{return};running=true;cancellation=WorkflowCancellation();let cancellation=cancellation;controls.forEach{$0.isEnabled=false};start.isEnabled=false;retry.isEnabled=false;cancel.isEnabled=true
        ExportWorkflow.queue.addOperation{[weak self] in let finished=ExportWorkflow.run(batch,cancelled:{cancellation.cancelled},progress:{progress in DispatchQueue.main.async{self?.showProgress(progress)}});DispatchQueue.main.async{guard let self else{return};self.batch=finished;self.running=false;self.controls.forEach{$0.isEnabled=true};self.start.isEnabled=true;self.cancel.isEnabled=false;self.retry.isEnabled=finished.jobs.contains{$0.state != .complete};self.updateEnabled();self.showProgress(finished)}}
    }
    private func showProgress(_ batch:ExportBatch){let done=batch.jobs.filter{$0.state == .complete}.count;status.stringValue="\(done) of \(batch.jobs.count) exported"+(running ? "…":" · Originals preserved");result.string=batch.jobs.map{$0.source.lastPathComponent+" → "+($0.output?.lastPathComponent ?? $0.state.rawValue)+($0.error.map{"\n  "+$0} ?? "")}.joined(separator:"\n\n")}
    @objc private func stopBatch(){cancellation.cancel();status.stringValue="Stopping after the current photo. Completed exports are retained."}
    @objc private func retryBatch(){runBatch()}
    func windowWillClose(_ notification:Notification){closed=true;previewToken=UUID();previewQueue.cancelAllOperations();cancellation.cancel()}
}
