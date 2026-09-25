import AppKit
import UniformTypeIdentifiers
import OpenStillCore

final class LogoDesigner:NSWindowController,NSWindowDelegate,NSTextFieldDelegate {
    var saved:((WatermarkLogo)->Void)?
    private let name=NSTextField(string:""),tagline=NSTextField(string:""),style=NSTextField(string:"Minimal, refined photography")
    private let typography=NSPopUpButton(),layout=NSPopUpButton(),symbol=NSPopUpButton(),savedLogos=NSPopUpButton()
    private let primary=NSColorWell(),accent=NSColorWell(),spacing=NSSlider(value:3,minValue:-5,maxValue:20,target:nil,action:nil),symbolSize=NSSlider(value:1,minValue:0.4,maxValue:1.6,target:nil,action:nil)
    private let preview=NSImageView(),status=NSTextField(wrappingLabelWithString:"Import a logo or enter your exact photographer name to create one.")
    private let candidate=NSSegmentedControl(labels:["1","2","3"],trackingMode:.selectOne,target:nil,action:nil)
    private let generate=NSButton(title:"Generate three layouts",target:nil,action:nil),download=NSButton(title:"Download local model · 639 MB",target:nil,action:nil),stop=NSButton(title:"Cancel",target:nil,action:nil),remove=NSButton(title:"Remove model",target:nil,action:nil),cpu=NSButton(checkboxWithTitle:"Use CPU instead of Metal",target:nil,action:nil)
    private let progress=NSProgressIndicator()
    private var candidates:[LogoDesign]=[],logos:[WatermarkLogo]=[],downloader:LogoModelDownload?,inference:LogoInference?,busy=false,closed=false,generation=UUID()
    private var manifest:LogoModelManifest?{try? LogoModelManifest.load()}
    private var modelURL:URL{EditStorage.root.appendingPathComponent("Models/Logo/"+(manifest?.model.filename ?? "Qwen3-0.6B-Q8_0.gguf"))}
    init(){
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1050,height:770),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        super.init(window:window);window.title="Watermarks · Logo designer";window.minSize=NSSize(width:990,height:720);window.center();window.delegate=self;Appearance.configure(window)
        let root=Appearance.panel(in:window)
        name.placeholderString="Exact photographer name or initials";tagline.placeholderString="Optional tagline"
        for field in [name,tagline,style]{field.delegate=self}
        typography.addItems(withTitles:LogoTypography.allCases.map{$0.rawValue.capitalized});layout.addItems(withTitles:["Horizontal","Stacked","Type only"]);symbol.addItems(withTitles:LogoSymbol.allCases.map{$0.rawValue.capitalized});symbol.selectItem(at:1)
        primary.color = .white;accent.color = .white
        let grid=NSGridView(views:[[NSTextField(labelWithString:"Name / initials"),name],[NSTextField(labelWithString:"Tagline"),tagline],[NSTextField(labelWithString:"Style brief"),style],[NSTextField(labelWithString:"Typography"),typography],[NSTextField(labelWithString:"Layout"),layout],[NSTextField(labelWithString:"Symbol"),symbol],[NSTextField(labelWithString:"Letter spacing"),spacing],[NSTextField(labelWithString:"Symbol size"),symbolSize],[NSTextField(labelWithString:"Text color"),primary],[NSTextField(labelWithString:"Symbol color"),accent]])
        grid.rowSpacing=14;grid.columnSpacing=14;grid.column(at:1).width=265
        for (control,label) in [(name,"Exact photographer name"),(tagline,"Exact photographer tagline"),(style,"Logo style brief"),(typography,"Logo typography"),(layout,"Logo layout"),(symbol,"Logo symbol"),(spacing,"Letter spacing"),(symbolSize,"Symbol size"),(primary,"Logo text color"),(accent,"Logo symbol color")] as [(NSControl,String)]{control.setAccessibilityLabel(label)}
        for control in [typography,layout,symbol,spacing,symbolSize,primary,accent] as [NSControl]{control.target=self;control.action = #selector(changed)}
        let importButton=NSButton(title:"Import logo…",target:self,action:#selector(importLogo));importButton.bezelStyle = .rounded
        savedLogos.target=self;savedLogos.action = #selector(loadSaved);savedLogos.setAccessibilityLabel("Saved watermark logos");refreshLibrary()
        let library=NSStackView(views:[savedLogos,importButton]);library.spacing=8
        let save=NSButton(title:"Save & use watermark",target:self,action:#selector(saveLogo)),export=NSButton(title:"Export SVG / PDF / PNG…",target:self,action:#selector(exportLogo));save.bezelStyle = .rounded;export.bezelStyle = .rounded
        for (button,action) in [(generate,#selector(generateLogos)),(download,#selector(downloadModel)),(stop,#selector(cancelWork)),(remove,#selector(removeModel))]{button.target=self;button.action=action;button.bezelStyle = .rounded}
        progress.isIndeterminate=false;progress.minValue=0;progress.maxValue=1;progress.style = .bar
        let local=NSTextField(wrappingLabelWithString:"Optional Qwen3-0.6B · 639 MB · Apache 2.0\nGenerates layout suggestions offline. Your exact text is drawn by OpenStill. Importing and manual design need no model.");local.font = .systemFont(ofSize:11);local.textColor = .secondaryLabelColor
        Appearance.primary(save);Appearance.primary(generate)
        let left=NSStackView(views:[library,grid,save,export,local,download,progress,NSStackView(views:[generate,stop,remove]),cpu]);left.orientation = .vertical;left.alignment = .leading;left.spacing=14
        candidate.target=self;candidate.action = #selector(selectCandidate);candidate.selectedSegment=0;candidate.isEnabled=false;candidate.setAccessibilityLabel("Generated logo candidate")
        preview.imageScaling = .scaleProportionallyUpOrDown;preview.wantsLayer=true;preview.layer?.backgroundColor=NSColor(white:0.13,alpha:1).cgColor;preview.layer?.cornerRadius=8;preview.setAccessibilityLabel("Watermark logo preview")
        preview.setContentCompressionResistancePriority(.defaultLow,for:.horizontal);preview.setContentCompressionResistancePriority(.defaultLow,for:.vertical);preview.setContentHuggingPriority(.defaultLow,for:.horizontal);preview.setContentHuggingPriority(.defaultLow,for:.vertical)
        status.font = .systemFont(ofSize:12);status.textColor = .secondaryLabelColor
        let right=NSStackView(views:[candidate,preview,status]);right.orientation = .vertical;right.alignment = .leading;right.spacing=14
        for view in [left,right]{view.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(view)}
        NSLayoutConstraint.activate([left.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:20),left.topAnchor.constraint(equalTo:root.topAnchor,constant:20),left.bottomAnchor.constraint(lessThanOrEqualTo:root.bottomAnchor,constant:-20),left.widthAnchor.constraint(equalToConstant:450),right.leadingAnchor.constraint(equalTo:left.trailingAnchor,constant:22),right.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-20),right.topAnchor.constraint(equalTo:left.topAnchor),right.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-20),preview.heightAnchor.constraint(greaterThanOrEqualToConstant:300)])
        for view in [preview,status]{view.widthAnchor.constraint(equalTo:right.widthAnchor).isActive=true};for view in [local,progress,library]{view.widthAnchor.constraint(equalTo:left.widthAnchor).isActive=true}
        #if arch(x86_64)
        cpu.state = .on;cpu.isEnabled=false
        #endif
        updateModelState()
    }
    required init?(coder:NSCoder){fatalError()}
    func controlTextDidChange(_ obj:Notification){changed()}
    private func color(_ well:NSColorWell)->LogoColor{let c=well.color.usingColorSpace(.sRGB) ?? .white;return LogoColor(String(format:"#%02X%02X%02X",Int(c.redComponent*255),Int(c.greenComponent*255),Int(c.blueComponent*255)))}
    private func design()->LogoDesign{var d=LogoDesign(name:name.stringValue,tagline:tagline.stringValue);d.suggestion.typography=LogoTypography.allCases[max(0,typography.indexOfSelectedItem)];d.suggestion.layout=LogoLayout.allCases[max(0,layout.indexOfSelectedItem)];d.suggestion.symbol=LogoSymbol.allCases[max(0,symbol.indexOfSelectedItem)];d.suggestion.spacing=spacing.doubleValue;d.suggestion.symbolSize=symbolSize.doubleValue;d.color=color(primary);d.accent=color(accent);return d}
    private func show(_ design:LogoDesign){name.stringValue=design.name;tagline.stringValue=design.tagline;typography.selectItem(at:LogoTypography.allCases.firstIndex(of:design.suggestion.typography)!);layout.selectItem(at:LogoLayout.allCases.firstIndex(of:design.suggestion.layout)!);symbol.selectItem(at:LogoSymbol.allCases.firstIndex(of:design.suggestion.symbol)!);spacing.doubleValue=design.suggestion.spacing;symbolSize.doubleValue=design.suggestion.symbolSize;primary.color=NSColor(cgColor:design.color.cg) ?? .white;accent.color=NSColor(cgColor:design.accent.cg) ?? .white;changed()}
    @objc private func changed(){do{let d=design();preview.image=NSImage(cgImage:try LogoRenderer.vector(d).raster(maximum:1200),size:.zero);if candidates.indices.contains(candidate.selectedSegment){candidates[candidate.selectedSegment]=d}}catch{if !name.stringValue.isEmpty{status.stringValue=error.localizedDescription}}}
    private func refreshLibrary(){logos=Watermarks.library();savedLogos.removeAllItems();savedLogos.addItem(withTitle:"Saved logos…");savedLogos.addItems(withTitles:logos.map(\.name))}
    @objc private func loadSaved(){guard savedLogos.indexOfSelectedItem>0 else{return};let logo=logos[savedLogos.indexOfSelectedItem-1];if let design=logo.design{show(design)}else{saved?(logo);status.stringValue="Using imported logo: "+logo.name}}
    @objc private func importLogo(){guard let window else{return};let panel=NSOpenPanel();panel.allowedContentTypes=[.png,.tiff,.jpeg,.pdf,.svg];panel.beginSheetModal(for:window){[weak self] response in guard let self,response == .OK,let url=panel.url else{return};do{let logo=try Watermarks.importLogo(url);self.refreshLibrary();self.saved?(logo);let image=try ModernRenderer.display(Watermarks.image(EditStorage.asset(logo.asset),maximum:1200));self.preview.image=NSImage(cgImage:image,size:.zero);self.status.stringValue="Imported a private copy · "+logo.name}catch{self.status.stringValue=error.localizedDescription}}}
    @objc private func saveLogo(){do{let logo=try Watermarks.saveDesign(design());refreshLibrary();saved?(logo);status.stringValue="Saved reusable logo. Placement is controlled in Export."}catch{status.stringValue=error.localizedDescription}}
    @objc private func exportLogo(){guard let window else{return};let panel=NSSavePanel();panel.allowedContentTypes=[.svg,.pdf,.png];panel.nameFieldStringValue="photographer-logo.svg";panel.message="Choose .svg, .pdf, or .png. PNG keeps a transparent background.";let design=design();panel.beginSheetModal(for:window){[weak self] response in guard let self,response == .OK,let url=panel.url else{return};do{try Watermarks.export(design,to:url);self.status.stringValue="Exported "+url.lastPathComponent}catch{self.status.stringValue=error.localizedDescription}}}
    private func updateModelState(){let exists=FileManager.default.fileExists(atPath:modelURL.path);download.isEnabled = !busy && !exists;generate.isEnabled = !busy && exists;remove.isEnabled = !busy && exists;stop.isEnabled=busy}
    @objc private func downloadModel(){guard let manifest,!busy else{return};busy=true;updateModelState();status.stringValue="Downloading optional model from the official Qwen repository…";let downloader=LogoModelDownload(manifest:manifest.model,destination:modelURL);self.downloader=downloader;downloader.progress = {[weak self] fraction,message in self?.progress.doubleValue=fraction;self?.status.stringValue=message};downloader.completion = {[weak self] result in guard let self else{return};self.busy=false;self.downloader=nil;self.updateModelState();switch result{case .success:self.status.stringValue="Local model ready. Generation works offline.";case .failure(let error):self.status.stringValue=(error as NSError).code == NSURLErrorCancelled ? "Download cancelled.":error.localizedDescription}};downloader.start()}
    @objc private func removeModel(){guard !busy else{return};do{try FileManager.default.removeItem(at:modelURL);status.stringValue="Optional model removed. Manual design and imported logos remain available.";updateModelState()}catch{status.stringValue=error.localizedDescription}}
    @objc private func cancelWork(){generation=UUID();downloader?.cancel();inference?.cancel();status.stringValue="Cancelling…"}
    @objc private func generateLogos(){
        guard !busy,let manifest else{return};let helper=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OpenStillLogoInference")
        do{_ = try LogoRenderer.vector(design())}catch{status.stringValue=error.localizedDescription;return}
        let d=design(),brief=style.stringValue,model=modelURL,useCPU=cpu.state == .on,token=UUID();generation=token;busy=true;updateModelState();status.stringValue="Designing three layouts locally…";let engine=LogoInference();inference=engine
        DispatchQueue.global(qos:.userInitiated).async{[weak self] in
            let result=Result{guard try PhotoRecordStore.contentHash(model)==manifest.model.sha256 else{throw LogoError.invalid("Model verification failed. Remove it and download it again.")};return try engine.generate(helper:helper,model:model,name:d.name,tagline:d.tagline,style:brief,symbol:d.suggestion.symbol.rawValue,color:d.color,accent:d.accent,cpu:useCPU)}
            DispatchQueue.main.async{guard let self else{return};self.busy=false;self.inference=nil;self.updateModelState();guard !self.closed,self.generation==token,self.name.stringValue==d.name,self.tagline.stringValue==d.tagline else{self.status.stringValue="Generation cancelled or text changed. Your current text is preserved.";return};switch result{case .success(let designs):self.candidates=designs;self.candidate.isEnabled=true;self.candidate.selectedSegment=0;self.show(designs[0]);self.status.stringValue="Three local suggestions. Choose one, then edit the typography, spacing, symbol, and colors.";case .failure(let error):self.status.stringValue=error.localizedDescription}}
        }
    }
    @objc private func selectCandidate(){guard candidates.indices.contains(candidate.selectedSegment) else{return};show(candidates[candidate.selectedSegment])}
    func windowWillClose(_ notification:Notification){closed=true;generation=UUID();downloader?.cancel();inference?.cancel()}
}
