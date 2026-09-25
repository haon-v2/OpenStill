import AppKit
import OpenStillCore

final class WorkflowCancellation {
    private let lock=NSLock();private var value=false
    var cancelled:Bool{lock.lock();defer{lock.unlock()};return value}
    func cancel(){lock.lock();value=true;lock.unlock()}
}
final class BatchPanel:NSWindowController,NSWindowDelegate {
    var completed:(()->Void)?
    private let source:ShootItem,targets:[ShootItem]
    private var options=BatchOptions(),preview:BatchTransaction?,token=UUID(),running=false
    private var cancellation=WorkflowCancellation()
    private let queue=OperationQueue(),details=NSTextView(),status=NSTextField(labelWithString:"Preparing preview…")
    private var checks:[NSButton]=[]
    private let apply=NSButton(title:"Apply to selected photos",target:nil,action:nil)
    init(source:ShootItem,targets:[ShootItem]) {
        self.source=source;self.targets=targets
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:660,height:640),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        super.init(window:window);window.title="Batch adjustments · OpenStill";window.minSize=NSSize(width:600,height:580);window.center();window.delegate=self;Appearance.configure(window)
        queue.maxConcurrentOperationCount=1;queue.qualityOfService = .userInitiated
        let root=Appearance.panel(in:window)
        let title=NSTextField(labelWithString:"Copy from "+source.url.lastPathComponent);title.font = .systemFont(ofSize:15,weight:.semibold)
        let grid=NSGridView();grid.rowSpacing=9;grid.columnSpacing=24
        for start in stride(from:0,to:AdjustmentGroup.allCases.count,by:2) {
            var row:[NSView]=[]
            for i in start..<min(start+2,AdjustmentGroup.allCases.count){let group=AdjustmentGroup.allCases[i],button=NSButton(checkboxWithTitle:group.title,target:self,action:#selector(changed));button.tag=i;button.state=options.groups.contains(group) ? .on:.off;checks.append(button);row.append(button)}
            if row.count==1{row.append(NSView())};grid.addRow(with:row)
        }
        let masks=NSButton(checkboxWithTitle:"Include independent copies of masks for selected tools",target:self,action:#selector(changed));masks.tag=100;checks.append(masks)
        let note=NSTextField(wrappingLabelWithString:"Crop, masks, and healing require matching source geometry. Source mode, AI replacement images, and camera-specific white balance are never copied.");note.font = .systemFont(ofSize:11);note.textColor = .secondaryLabelColor
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder;scroll.documentView=details
        details.isEditable=false;details.isSelectable=true;details.font = .systemFont(ofSize:12);details.backgroundColor = .textBackgroundColor;details.textContainerInset=NSSize(width:10,height:10);details.autoresizingMask=[.width];details.isVerticallyResizable=true;details.textContainer?.widthTracksTextView=true
        apply.target=self;apply.action = #selector(applyChanges);apply.bezelStyle = .rounded;Appearance.primary(apply);apply.isEnabled=false
        let cancel=NSButton(title:"Cancel",target:self,action:#selector(cancelWork));cancel.bezelStyle = .rounded
        let footer=NSStackView(views:[status,NSView(),cancel,apply]);footer.spacing=10;status.font = .systemFont(ofSize:11)
        let stack=NSStackView(views:[title,grid,masks,note,scroll,footer]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=16;stack.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:root.topAnchor,constant:20),stack.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-20),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:150)])
        for view in [note,scroll,footer]{view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true}
        prepare()
    }
    required init?(coder:NSCoder){fatalError()}
    @objc private func changed(){
        options.groups=Set(checks.filter{$0.tag<100 && $0.state == .on}.map{AdjustmentGroup.allCases[$0.tag]});options.masks=checks.last?.state == .on;prepare()
    }
    private func prepare(){
        token=UUID();let current=token,options=options;apply.isEnabled=false;preview=nil;status.stringValue="Preparing preview…"
        queue.cancelAllOperations()
        queue.addOperation{[weak self] in
            guard let self else{return}
            let result=Result{try BatchEdits.prepare(source:self.source,targets:self.targets,options:options)}
            DispatchQueue.main.async{[weak self] in guard let self,self.token==current else{return};switch result{
            case .success(let preview):self.preview=preview;self.details.string=preview.entries.map{"\($0.sourcePath.components(separatedBy:"/").last ?? $0.sourcePath)\n  \($0.failure ?? ($0.before == $0.after ? "Already matches":"Ready to apply"))"}.joined(separator:"\n\n");let ready=preview.entries.filter{$0.failure==nil && $0.before != $0.after}.count;self.status.stringValue="\(ready) photos will change";self.apply.isEnabled=ready>0
            case .failure(let error):self.status.stringValue=error.localizedDescription;self.details.string=""
            }}
        }
    }
    @objc private func applyChanges(){
        guard let preview,!running else{return};running=true;cancellation=WorkflowCancellation();let cancel=cancellation
        checks.forEach{$0.isEnabled=false};apply.isEnabled=false;status.stringValue="Applying…"
        queue.addOperation{[weak self] in
            let result=Result{try BatchEdits.apply(preview,cancelled:{cancel.cancelled},progress:{done,total in DispatchQueue.main.async{self?.status.stringValue="\(done) of \(total)"}})}
            DispatchQueue.main.async{guard let self else{return};self.running=false;self.completed?();switch result{
            case .success(let transaction):self.details.string=transaction.entries.map{entry in let record=try? EditStorage.records.read(entry.photoID);let applied=record?.active.revision==entry.afterRevision;return URL(fileURLWithPath:entry.sourcePath).lastPathComponent+"\n  "+(entry.failure ?? (applied ? "Applied · available in Undo batch":entry.before==entry.after ? "Already matched":"Not applied"))}.joined(separator:"\n\n");self.status.stringValue=cancel.cancelled ? "Stopped. Completed edits are retained.":"Batch finished. Review results above."
            case .failure(let error):self.status.stringValue=error.localizedDescription
            }}
        }
    }
    @objc private func cancelWork(){if running{cancellation.cancel();status.stringValue="Stopping after the current photo…"}else{close()}}
    func windowWillClose(_ notification:Notification){token=UUID();cancellation.cancel();queue.cancelAllOperations()}
}
