import AppKit
import UniformTypeIdentifiers
import OpenStillCore

/// Watermark logos in three clearly separate modes:
/// Design your own (manual, no AI), Generate with AI (a prompt, by your connected AI or the optional local model), and Import.
final class LogoDesigner:NSWindowController,NSWindowDelegate,NSTextFieldDelegate,NSTextViewDelegate {
    var saved:((WatermarkLogo)->Void)?
    private enum Mode:Int { case design, generate, importing }
    private let modes=NSSegmentedControl(labels:["Design your own","Generate with AI","Import"],trackingMode:.selectOne,target:nil,action:nil)
    private let name=NSTextField(string:""),tagline=NSTextField(string:"")
    private let prompt=NSTextView(),promptHint=NSTextField(labelWithString:"Describe the logo you want: mood, style, colors…")
    private let typography=NSPopUpButton(),layout=NSPopUpButton(),symbol=NSPopUpButton(),savedLogos=NSPopUpButton()
    private let primary=NSColorWell(),accent=NSColorWell(),spacing=NSSlider(value:3,minValue:-5,maxValue:20,target:nil,action:nil),symbolSize=NSSlider(value:1,minValue:0.4,maxValue:1.6,target:nil,action:nil)
    private let preview=NSImageView(),status=NSTextField(wrappingLabelWithString:"Enter your exact photographer name, then design a logo yourself, generate one with AI, or import your own.")
    private let candidate=NSSegmentedControl(labels:["1","2","3"],trackingMode:.selectOne,target:nil,action:nil)
    private let generate=NSButton(title:"Generate three designs",target:nil,action:nil),download=NSButton(title:"Download local model · 639 MB",target:nil,action:nil),stop=NSButton(title:"Cancel",target:nil,action:nil),remove=NSButton(title:"Remove model",target:nil,action:nil),cpu=NSButton(checkboxWithTitle:"Use CPU instead of Metal",target:nil,action:nil)
    private let editChosen=NSButton(title:"Edit in Design your own",target:nil,action:nil)
    private let engineLabel=NSTextField(wrappingLabelWithString:"")
    private let progress=NSProgressIndicator()
    private var sections:[Mode:NSStackView]=[:]
    private var candidates:[LogoDesign]=[],logos:[WatermarkLogo]=[],downloader:LogoModelDownload?,inference:LogoInference?,busy=false,closed=false,generation=UUID()
    private var manifest:LogoModelManifest?{try? LogoModelManifest.load()}
    private var modelURL:URL{EditStorage.root.appendingPathComponent("Models/Logo/"+(manifest?.model.filename ?? "Qwen3-0.6B-Q8_0.gguf"))}
    private var engine:LogoEngine{LogoEngine.choose(assistant:AssistantServer.shared.samplingClient,localModelInstalled:FileManager.default.fileExists(atPath:modelURL.path))}
    init(){
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1050,height:770),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        super.init(window:window);window.title="Watermarks · Logo designer";window.minSize=NSSize(width:990,height:720);window.center();window.delegate=self;Appearance.configure(window)
        let root=Appearance.panel(in:window)
        func note(_ text:String)->NSTextField{let l=NSTextField(wrappingLabelWithString:text);l.font = .systemFont(ofSize:11);l.textColor = .secondaryLabelColor;return l}
        func label(_ text:String)->NSTextField{NSTextField(labelWithString:text)}
        name.placeholderString="Exact photographer name or initials";tagline.placeholderString="Optional tagline"
        for field in [name,tagline]{field.delegate=self}
        typography.addItems(withTitles:LogoTypography.allCases.map{$0.rawValue.capitalized});layout.addItems(withTitles:["Horizontal","Stacked","Type only"]);symbol.addItems(withTitles:LogoSymbol.allCases.map{$0.rawValue.capitalized});symbol.selectItem(at:1)
        primary.color = .white;accent.color = .white
        for (control,text) in [(name,"Exact photographer name"),(tagline,"Exact photographer tagline"),(typography,"Logo typography"),(layout,"Logo layout"),(symbol,"Logo symbol"),(spacing,"Letter spacing"),(symbolSize,"Symbol size"),(primary,"Logo text color"),(accent,"Logo symbol color")] as [(NSControl,String)]{control.setAccessibilityLabel(text)}
        for control in [typography,layout,symbol,spacing,symbolSize,primary,accent] as [NSControl]{control.target=self;control.action = #selector(changed)}
        modes.selectedSegment=0;modes.target=self;modes.action = #selector(modeChanged);modes.segmentStyle = .rounded;modes.setAccessibilityLabel("Logo designer mode")

        // Shared: the exact text, which OpenStill always draws itself.
        let text=NSGridView(views:[[label("Name / initials"),name],[label("Tagline"),tagline]]);text.rowSpacing=10;text.columnSpacing=14;text.column(at:1).width=265

        // Design your own: every control by hand, no AI.
        let grid=NSGridView(views:[[label("Typography"),typography],[label("Layout"),layout],[label("Symbol"),symbol],[label("Letter spacing"),spacing],[label("Symbol size"),symbolSize],[label("Text color"),primary],[label("Symbol color"),accent]])
        grid.rowSpacing=12;grid.columnSpacing=14;grid.column(at:1).width=265
        let save=NSButton(title:"Save & use watermark",target:self,action:#selector(saveLogo)),export=NSButton(title:"Export SVG / PDF / PNG…",target:self,action:#selector(exportLogo));save.bezelStyle = .rounded;export.bezelStyle = .rounded;Appearance.primary(save)
        let design=NSStackView(views:[note("Design it yourself: choose the typography, layout, symbol, spacing and colors. No AI and no download needed."),grid,NSStackView(views:[save,export])])

        // Generate with AI: a prompt; your connected AI or the optional local model picks the design.
        let promptScroll=NSScrollView();promptScroll.documentView=prompt;promptScroll.hasVerticalScroller=true;promptScroll.borderType = .bezelBorder
        prompt.isRichText=false;prompt.font = .systemFont(ofSize:13);prompt.delegate=self;prompt.string="Minimal, refined photography";prompt.setAccessibilityLabel("Logo prompt")
        prompt.isVerticallyResizable=true;prompt.autoresizingMask=[.width];prompt.textContainerInset=NSSize(width:4,height:6)
        promptScroll.heightAnchor.constraint(equalToConstant:88).isActive=true
        promptHint.font = .systemFont(ofSize:11);promptHint.textColor = .secondaryLabelColor
        for (button,action) in [(generate,#selector(generateLogos)),(download,#selector(downloadModel)),(stop,#selector(cancelWork)),(remove,#selector(removeModel)),(editChosen,#selector(editInDesigner))]{button.target=self;button.action=action;button.bezelStyle = .rounded}
        Appearance.primary(generate)
        progress.isIndeterminate=false;progress.minValue=0;progress.maxValue=1;progress.style = .bar
        engineLabel.font = .systemFont(ofSize:11,weight:.medium)
        let local=note("Optional local model: Qwen3-0.6B · 639 MB · Apache 2.0. Runs offline on this Mac. When an AI app connected through the OpenStill MCP can answer OpenStill’s requests, it’s used instead.")
        let generateBox=NSStackView(views:[note("AI chooses fonts, symbols, layout and colors from OpenStill’s set to match your prompt. Your exact name and tagline are always drawn by OpenStill, never by the AI."),
                                          label("Prompt"),promptScroll,promptHint,engineLabel,NSStackView(views:[generate,stop]),editChosen,local,download,progress,NSStackView(views:[remove,cpu])])
        editChosen.isEnabled=false

        // Import: your own finished logo, or one saved earlier.
        let importButton=NSButton(title:"Import logo…",target:self,action:#selector(importLogo));importButton.bezelStyle = .rounded
        savedLogos.target=self;savedLogos.action = #selector(loadSaved);savedLogos.setAccessibilityLabel("Saved watermark logos");refreshLibrary()
        let importing=NSStackView(views:[note("Use a logo you already have (transparent PNG, static SVG or PDF), or pick one saved earlier. OpenStill keeps a private copy."),importButton,label("Saved logos"),savedLogos])

        sections=[.design:design,.generate:generateBox,.importing:importing]
        for stack in sections.values{stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=12}
        let left=NSStackView(views:[modes,text,design,generateBox,importing]);left.orientation = .vertical;left.alignment = .leading;left.spacing=16
        candidate.target=self;candidate.action = #selector(selectCandidate);candidate.selectedSegment=0;candidate.isEnabled=false;candidate.setAccessibilityLabel("Generated logo candidate")
        preview.imageScaling = .scaleProportionallyUpOrDown;preview.wantsLayer=true;preview.layer?.backgroundColor=NSColor(white:0.13,alpha:1).cgColor;preview.layer?.cornerRadius=8;preview.setAccessibilityLabel("Watermark logo preview")
        preview.setContentCompressionResistancePriority(.defaultLow,for:.horizontal);preview.setContentCompressionResistancePriority(.defaultLow,for:.vertical);preview.setContentHuggingPriority(.defaultLow,for:.horizontal);preview.setContentHuggingPriority(.defaultLow,for:.vertical)
        status.font = .systemFont(ofSize:12);status.textColor = .secondaryLabelColor
        let right=NSStackView(views:[candidate,preview,status]);right.orientation = .vertical;right.alignment = .leading;right.spacing=14
        for view in [left,right]{view.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(view)}
        NSLayoutConstraint.activate([left.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:20),left.topAnchor.constraint(equalTo:root.topAnchor,constant:20),left.bottomAnchor.constraint(lessThanOrEqualTo:root.bottomAnchor,constant:-20),left.widthAnchor.constraint(equalToConstant:450),right.leadingAnchor.constraint(equalTo:left.trailingAnchor,constant:22),right.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-20),right.topAnchor.constraint(equalTo:left.topAnchor),right.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-20),preview.heightAnchor.constraint(greaterThanOrEqualToConstant:300)])
        for view in [preview,status]{view.widthAnchor.constraint(equalTo:right.widthAnchor).isActive=true}
        for view in [design,generateBox,importing,promptScroll,local,progress,savedLogos] as [NSView]{view.widthAnchor.constraint(equalTo:left.widthAnchor).isActive=true}
        for stack in sections.values{for case let label as NSTextField in stack.arrangedSubviews where label.maximumNumberOfLines != 1 {label.widthAnchor.constraint(equalTo:left.widthAnchor).isActive=true}}
        #if arch(x86_64)
        cpu.state = .on;cpu.isEnabled=false
        #endif
        NotificationCenter.default.addObserver(self,selector:#selector(assistantChanged),name:AssistantServer.changed,object:nil)
        modeChanged();updateModelState()
    }
    required init?(coder:NSCoder){fatalError()}
    func controlTextDidChange(_ obj:Notification){changed()}
    func textDidChange(_ notification:Notification){if prompt.string.count>500{prompt.string=String(prompt.string.prefix(500))}}
    private var mode:Mode{Mode(rawValue:modes.selectedSegment) ?? .design}
    @objc private func modeChanged(){
        for (key,stack) in sections{stack.isHidden = key != mode}
        name.superview?.isHidden = mode == .importing
        candidate.isHidden = mode != .generate
        if mode != .importing{changed()}
        updateModelState()
    }
    @objc private func assistantChanged(){updateModelState()}
    private func color(_ well:NSColorWell)->LogoColor{let c=well.color.usingColorSpace(.sRGB) ?? .white;return LogoColor(String(format:"#%02X%02X%02X",Int(c.redComponent*255),Int(c.greenComponent*255),Int(c.blueComponent*255)))}
    private func design()->LogoDesign{var d=LogoDesign(name:name.stringValue,tagline:tagline.stringValue);d.suggestion.typography=LogoTypography.allCases[max(0,typography.indexOfSelectedItem)];d.suggestion.layout=LogoLayout.allCases[max(0,layout.indexOfSelectedItem)];d.suggestion.symbol=LogoSymbol.allCases[max(0,symbol.indexOfSelectedItem)];d.suggestion.spacing=spacing.doubleValue;d.suggestion.symbolSize=symbolSize.doubleValue;d.color=color(primary);d.accent=color(accent);return d}
    private func show(_ design:LogoDesign){name.stringValue=design.name;tagline.stringValue=design.tagline;typography.selectItem(at:LogoTypography.allCases.firstIndex(of:design.suggestion.typography)!);layout.selectItem(at:LogoLayout.allCases.firstIndex(of:design.suggestion.layout)!);symbol.selectItem(at:LogoSymbol.allCases.firstIndex(of:design.suggestion.symbol)!);spacing.doubleValue=design.suggestion.spacing;symbolSize.doubleValue=design.suggestion.symbolSize;primary.color=NSColor(cgColor:design.color.cg) ?? .white;accent.color=NSColor(cgColor:design.accent.cg) ?? .white;changed()}
    @objc private func changed(){do{let d=design();preview.image=NSImage(cgImage:try LogoRenderer.vector(d).raster(maximum:1200),size:.zero);if mode == .generate,candidates.indices.contains(candidate.selectedSegment){candidates[candidate.selectedSegment]=d}}catch{if !name.stringValue.isEmpty{status.stringValue=error.localizedDescription}}}
    private func refreshLibrary(){logos=Watermarks.library();savedLogos.removeAllItems();savedLogos.addItem(withTitle:"Saved logos…");savedLogos.addItems(withTitles:logos.map(\.name))}
    @objc private func loadSaved(){guard savedLogos.indexOfSelectedItem>0 else{return};let logo=logos[savedLogos.indexOfSelectedItem-1];if let design=logo.design{modes.selectedSegment=Mode.design.rawValue;modeChanged();show(design)}else{saved?(logo);status.stringValue="Using imported logo: "+logo.name}}
    @objc private func importLogo(){guard let window else{return};let panel=NSOpenPanel();panel.allowedContentTypes=[.png,.tiff,.jpeg,.pdf,.svg];panel.beginSheetModal(for:window){[weak self] response in guard let self,response == .OK,let url=panel.url else{return};do{let logo=try Watermarks.importLogo(url);self.refreshLibrary();self.saved?(logo);let image=try ModernRenderer.display(Watermarks.image(EditStorage.asset(logo.asset),maximum:1200));self.preview.image=NSImage(cgImage:image,size:.zero);self.status.stringValue="Imported a private copy · "+logo.name}catch{self.status.stringValue=error.localizedDescription}}}
    @objc private func saveLogo(){do{let logo=try Watermarks.saveDesign(design());refreshLibrary();saved?(logo);status.stringValue="Saved reusable logo. Placement is controlled in Export."}catch{status.stringValue=error.localizedDescription}}
    @objc private func exportLogo(){guard let window else{return};let panel=NSSavePanel();panel.allowedContentTypes=[.svg,.pdf,.png];panel.nameFieldStringValue="photographer-logo.svg";panel.message="Choose .svg, .pdf, or .png. PNG keeps a transparent background.";let design=design();panel.beginSheetModal(for:window){[weak self] response in guard let self,response == .OK,let url=panel.url else{return};do{try Watermarks.export(design,to:url);self.status.stringValue="Exported "+url.lastPathComponent}catch{self.status.stringValue=error.localizedDescription}}}
    private func updateModelState(){
        let exists=FileManager.default.fileExists(atPath:modelURL.path),engine=engine
        download.isEnabled = !busy && !exists;remove.isEnabled = !busy && exists;stop.isEnabled=busy
        generate.isEnabled = !busy && engine != .unavailable
        engineLabel.stringValue=engine.label;engineLabel.textColor = engine == .unavailable ? .secondaryLabelColor : .labelColor
        editChosen.isEnabled = !busy && !candidates.isEmpty
    }
    @objc private func downloadModel(){guard let manifest,!busy else{return};busy=true;updateModelState();status.stringValue="Downloading optional model from the official Qwen repository…";let downloader=LogoModelDownload(manifest:manifest.model,destination:modelURL);self.downloader=downloader;downloader.progress = {[weak self] fraction,message in self?.progress.doubleValue=fraction;self?.status.stringValue=message};downloader.completion = {[weak self] result in guard let self else{return};self.busy=false;self.downloader=nil;self.updateModelState();switch result{case .success:self.status.stringValue="Local model ready. Generation works offline.";case .failure(let error):self.status.stringValue=(error as NSError).code == NSURLErrorCancelled ? "Download cancelled.":error.localizedDescription}};downloader.start()}
    @objc private func removeModel(){guard !busy else{return};do{try FileManager.default.removeItem(at:modelURL);status.stringValue="Optional model removed. Design your own and imported logos remain available.";updateModelState()}catch{status.stringValue=error.localizedDescription}}
    @objc private func cancelWork(){generation=UUID();downloader?.cancel();inference?.cancel();busy=false;updateModelState();status.stringValue="Cancelled."}
    @objc private func generateLogos(){
        guard !busy else{return}
        do{_ = try LogoRenderer.vector(design())}catch{status.stringValue=error.localizedDescription;return}
        let d=design(),brief=String(prompt.string.trimmingCharacters(in:.whitespacesAndNewlines).prefix(500)),token=UUID();generation=token;busy=true
        let chosen=engine;updateModelState()
        func finish(_ result:Result<[LogoDesign],Error>,source:String){
            busy=false;inference=nil;updateModelState()
            guard !closed,generation==token,name.stringValue==d.name,tagline.stringValue==d.tagline else{status.stringValue="Generation cancelled or text changed. Your current text is preserved.";return}
            switch result{
            case .success(let designs):candidates=designs;candidate.isEnabled=true;candidate.selectedSegment=0;show(designs[0]);updateModelState()
                status.stringValue="Three suggestions \(source). Choose one, or Edit in Design your own to fine-tune it."
            case .failure(let error):status.stringValue=error.localizedDescription
            }
        }
        switch chosen{
        case .assistant(let assistant):
            status.stringValue="Asking \(assistant) for three designs…"
            do{
                let request=try LogoInference.samplingRequest(name:d.name,tagline:d.tagline,style:brief,symbol:d.suggestion.symbol.rawValue,color:d.color,accent:d.accent)
                AssistantServer.shared.sample(request){[weak self] result in
                    guard let self else{return}
                    let designs=Result<[LogoDesign],Error>{
                        let answer=try result.get()
                        let text=answer["content"]?["text"]?.string ?? answer["text"]?.string ?? ""
                        return try LogoInference.decode(Data(text.utf8),name:d.name,tagline:d.tagline,color:d.color,accent:d.accent)
                    }
                    if case .failure=designs,FileManager.default.fileExists(atPath:self.modelURL.path){self.status.stringValue="\(assistant) couldn’t answer; using the local model instead.";self.runLocal(d,brief:brief,token:token,finish:finish);return}
                    finish(designs,source:"from \(assistant)")
                }
            }catch{finish(.failure(error),source:"")}
        case .local:runLocal(d,brief:brief,token:token,finish:finish)
        case .unavailable:busy=false;updateModelState();status.stringValue=chosen.label
        }
    }
    private func runLocal(_ d:LogoDesign,brief:String,token:UUID,finish:@escaping (Result<[LogoDesign],Error>,String)->Void){
        guard let manifest else{finish(.failure(LogoError.invalid("The local model manifest is missing.")),"");return}
        let helper=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OpenStillLogoInference"),model=modelURL,useCPU=cpu.state == .on
        status.stringValue="Designing three layouts on this Mac…";let engine=LogoInference();inference=engine
        DispatchQueue.global(qos:.userInitiated).async{
            let result=Result{guard try PhotoRecordStore.contentHash(model)==manifest.model.sha256 else{throw LogoError.invalid("Model verification failed. Remove it and download it again.")};return try engine.generate(helper:helper,model:model,name:d.name,tagline:d.tagline,style:brief,symbol:d.suggestion.symbol.rawValue,color:d.color,accent:d.accent,cpu:useCPU)}
            DispatchQueue.main.async{finish(result,"made on this Mac")}
        }
    }
    @objc private func selectCandidate(){guard candidates.indices.contains(candidate.selectedSegment) else{return};show(candidates[candidate.selectedSegment])}
    /// Takes the chosen AI design into the manual controls to fine-tune by hand.
    @objc private func editInDesigner(){
        if candidates.indices.contains(candidate.selectedSegment){show(candidates[candidate.selectedSegment])}
        modes.selectedSegment=Mode.design.rawValue;modeChanged();status.stringValue="Fine-tune the AI design by hand, then Save & use watermark."
    }
    func windowWillClose(_ notification:Notification){closed=true;generation=UUID();downloader?.cancel();inference?.cancel()}
}
