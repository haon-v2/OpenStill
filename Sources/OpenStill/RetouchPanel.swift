import AppKit
import OpenStillCore

final class RetouchPanel:NSStackView {
    var settingsChanged:((RetouchSession)->Void)?
    var command:((String)->Void)?
    private var settings=RetouchSession()
    private let mode=NSSegmentedControl(labels:["Heal","Clone"],trackingMode:.selectOne,target:nil,action:nil)
    private let aligned=NSButton(checkboxWithTitle:"Aligned source",target:nil,action:nil)
    private let count=NSTextField(labelWithString:"No retouch strokes")
    override init(frame:NSRect){
        super.init(frame:frame);orientation = .vertical;alignment = .leading;spacing=10
        mode.selectedSegment=0;mode.target=self;mode.action = #selector(chooseRetouchMode);mode.setAccessibilityLabel("Retouch mode");row(mode)
        let help=NSTextField(wrappingLabelWithString:"Choose a clean source, then brush to repair. Option-click picks a new source. Heal blends texture with local tone; Clone copies the source.");help.font = .systemFont(ofSize:11);help.textColor = .secondaryLabelColor;row(help)
        for (title,key) in [("Choose source point","retouchSource"),("Paint repair","retouchPaint")] {button(title,key)}
        aligned.state = .on;aligned.target=self;aligned.action = #selector(changeAligned);aligned.font = .systemFont(ofSize:11);row(aligned)
        for (title,path,range) in [("Size",\RetouchSession.radius,0.005...0.15),("Feather",\.feather,0.0...1.0),("Opacity",\.opacity,0.0...1.0)] {
            let label=NSTextField(labelWithString:title);label.font = .systemFont(ofSize:11);row(label)
            let slider=ContinuousSlider(range:range,value:settings[keyPath:path]);slider.setAccessibilityLabel("Retouch "+title.lowercased());slider.changed = { [weak self] value,_ in guard let self else{return};self.settings[keyPath:path]=value;self.settingsChanged?(self.settings) };row(slider)
        }
        count.font = .systemFont(ofSize:10);count.textColor = .secondaryLabelColor;row(count)
        button("Remove last stroke","retouchRemoveLast");button("Clear retouch strokes","retouchClear")
    }
    required init?(coder:NSCoder){fatalError()}
    private func row(_ view:NSView){addArrangedSubview(view);view.widthAnchor.constraint(equalTo:widthAnchor).isActive=true}
    private func button(_ title:String,_ key:String){let button=NSButton(title:title,target:self,action:#selector(action(_:)));button.identifier=NSUserInterfaceItemIdentifier(key);button.bezelStyle = .rounded;row(button)}
    func update(_ strokes:[RetouchStroke]){count.stringValue="\(strokes.count) saved stroke\(strokes.count == 1 ? "":"s") · Undo available in Edits"}
    @objc private func chooseRetouchMode(){settings.mode=mode.selectedSegment == 0 ? .heal:.clone;settingsChanged?(settings)}
    @objc private func changeAligned(){settings.aligned=aligned.state == .on;settingsChanged?(settings)}
    @objc private func action(_ sender:NSButton){command?(sender.identifier!.rawValue)}
}
extension ViewerController {
    func updateRetouchSettings(_ next:RetouchSession){
        retouchSession.mode=next.mode;retouchSession.radius=next.radius;retouchSession.feather=next.feather;retouchSession.opacity=next.opacity;retouchSession.aligned=next.aligned
        if canvas.tool == .retouch {canvas.maskRadius=next.radius;canvas.maskSoftness=next.feather}
    }
    func chooseRetouchSource(_ point:CGPoint){
        let geometry=EditGeometry(size:editSourceSize(),edits:currentEdits)
        let source=LensCorrections.sourcePoint(geometry.sourcePoint(point),size:geometry.sourceSize,settings:currentEdits.lens)
        retouchSession.setSource(source);canvas.retouchSource=point;activateRetouch()
    }
    func activateRetouch(){
        finishMaskEditing()
        guard currentSource != nil else{return}
        guard retouchSession.source != nil else{canvas.tool = .retouchSource;info.status("Click a clean source area first.");return}
        if let source=retouchSession.source {
            let geometry=EditGeometry(size:editSourceSize(),edits:currentEdits)
            let corrected=LensCorrections.correctedPoint(source,size:geometry.sourceSize,settings:currentEdits.lens)
            let p=CGPoint(x:corrected.x*geometry.sourceSize.width,y:corrected.y*geometry.sourceSize.height).applying(geometry.transform)
            canvas.retouchSource=CGPoint(x:p.x/geometry.extent.width,y:p.y/geometry.extent.height)
        }
        canvas.tool = .retouch;canvas.maskRadius=retouchSession.radius;canvas.maskSoftness=retouchSession.feather
        info.status("Brush to \(retouchSession.mode.rawValue). Option-click changes the source. Each stroke is undoable.")
        view.window?.makeFirstResponder(canvas)
    }
    func drawRetouch(_ points:[CGPoint]){
        guard canvas.tool == .retouch,!aiPreparing,!localAI.isRunning else{return}
        let geometry=EditGeometry(size:editSourceSize(),edits:currentEdits)
        let sourcePoints=points.map{LensCorrections.sourcePoint(geometry.sourcePoint($0),size:geometry.sourceSize,settings:currentEdits.lens)}
        let scale=hypot(geometry.transform.a,geometry.transform.b)
        let radius=retouchSession.radius*min(geometry.extent.width,geometry.extent.height)/(max(0.001,scale)*min(geometry.sourceSize.width,geometry.sourceSize.height))
        guard let stroke=retouchSession.stroke(points:sourcePoints,radius:radius)else{return}
        var edits=currentEdits;edits.retouch.append(stroke);changeEdits(edits,title:retouchSession.mode == .heal ? "Heal stroke":"Clone stroke",commit:true)
    }
}
