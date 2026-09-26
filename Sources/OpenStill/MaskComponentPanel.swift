import AppKit
import OpenStillCore

final class MaskComponentPanel:NSStackView {
    var changed:((AdjustmentMask?,String,Bool)->Void)?
    var command:((String)->Void)?
    private(set) var selectedID:UUID?
    private var root:AdjustmentMask?
    private let picker=NSPopUpButton(frame:.zero,pullsDown:false)
    private let name=NSTextField(string:"")
    private let visible=NSButton(checkboxWithTitle:"Visible",target:nil,action:nil)
    private let operation=NSPopUpButton(frame:.zero,pullsDown:false)
    private let opacity=ContinuousSlider(range:0...100,value:100)
    private let rangeControls=NSStackView()
    private let color=NSColorWell()
    private let low=ContinuousSlider(range:0...1,value:0.25),high=ContinuousSlider(range:0...1,value:0.75)
    private let tolerance=ContinuousSlider(range:0...1,value:0.15),softness=ContinuousSlider(range:0...1,value:0.15)
    private let luminance=NSStackView(),colors=NSStackView()
    private let componentActions=NSPopUpButton(frame:.zero,pullsDown:true)
    private let aiActions=NSPopUpButton(frame:.zero,pullsDown:true)
    private static let aiChoices:[(String,String)]=[("Subject","subject"),("Background","background"),("People","people"),("Person 1","person.1"),("Person 2","person.2"),("Person 3","person.3"),("Person 4","person.4"),("Face","face"),("Eyes","eyes"),("Eyebrows","eyebrows"),("Lips","lips"),("Skin","skin"),("Sky (local AI)","sky"),("Depth range","depth")]
    private static var clipboard:AdjustmentMask?
    override init(frame:NSRect){
        super.init(frame:frame);orientation = .vertical;alignment = .leading;spacing=8
        picker.target=self;picker.action = #selector(select);picker.setAccessibilityLabel("Named mask components");row(picker)
        name.placeholderString="Mask name";name.setAccessibilityLabel("Mask component name");name.target=self;name.action = #selector(rename);row(name)
        visible.target=self;visible.action = #selector(toggle);visible.font = .systemFont(ofSize:11)
        operation.addItems(withTitles:["Add","Subtract","Intersect"]);operation.target=self;operation.action = #selector(combine);operation.setAccessibilityLabel("Combine mask component")
        row(NSStackView(views:[visible,NSView(),operation]))
        let label=NSTextField(labelWithString:"Component opacity");label.font = .systemFont(ofSize:10);row(label)
        opacity.setAccessibilityLabel("Mask component opacity");opacity.changed = { [weak self] value,final in self?.mutate("Mask opacity",final:final){$0.opacity=value/100} };row(opacity)
        componentActions.addItems(withTitles:["Component actions…","New brush","New linear gradient","New radial","New object selection","New color range","New luminance range","Duplicate component","Delete component","Invert component","Copy entire tool mask","Paste independent mask"])
        componentActions.target=self;componentActions.action = #selector(action);row(componentActions)
        aiActions.addItem(withTitle:"Select with AI…");for (title,_) in Self.aiChoices{aiActions.addItem(withTitle:title)}
        aiActions.target=self;aiActions.action = #selector(aiAction);aiActions.setAccessibilityLabel("Add an AI selection");aiActions.toolTip="Runs on this Mac. Each choice adds a new mask component you can combine, invert or subtract.";row(aiActions)
        for stack in [rangeControls,colors,luminance] {stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=8}
        row(rangeControls);rangeControls.addArrangedSubview(colors);rangeControls.addArrangedSubview(luminance)
        color.target=self;color.action = #selector(colorChanged);color.setAccessibilityLabel("Color range target");colors.addArrangedSubview(color)
        color.widthAnchor.constraint(equalToConstant:80).isActive=true
        for (title,slider,stack) in [("Color tolerance",tolerance,colors),("Luminance lower bound",low,luminance),("Luminance upper bound",high,luminance),("Range transition",softness,rangeControls)] {
            let label=NSTextField(labelWithString:title);label.font = .systemFont(ofSize:10);stack.addArrangedSubview(label)
            slider.setAccessibilityLabel(title);stack.addArrangedSubview(slider);slider.widthAnchor.constraint(equalTo:widthAnchor).isActive=true
        }
        tolerance.changed = { [weak self] v,f in self?.range("Range tolerance",final:f){$0.tolerance=v} }
        low.changed = { [weak self] v,f in self?.range("Luminance range",final:f){$0.low=v} }
        high.changed = { [weak self] v,f in self?.range("Luminance range",final:f){$0.high=v} }
        softness.changed = { [weak self] v,f in self?.range("Range transition",final:f){$0.softness=v} }
        let sample=NSButton(title:"Sample range from photo",target:self,action:#selector(sample));sample.bezelStyle = .rounded;rangeControls.addArrangedSubview(sample)
        update(nil,enabled:false)
    }
    required init?(coder:NSCoder){fatalError()}
    private func row(_ view:NSView){addArrangedSubview(view);view.widthAnchor.constraint(equalTo:widthAnchor).isActive=true}
    var selected:MaskComponent?{root?.component(selectedID)}
    func update(_ mask:AdjustmentMask?,enabled:Bool){
        root=mask
        let list=mask?.namedComponents ?? []
        if !list.contains(where:{$0.id==selectedID}) {selectedID=list.first?.id}
        picker.removeAllItems()
        for c in list {picker.addItem(withTitle:(c.visible ? "":"Hidden · ")+c.name);picker.lastItem?.representedObject=c.id.uuidString}
        if let i=list.firstIndex(where:{$0.id==selectedID}){picker.selectItem(at:i)}
        let c=selected
        aiActions.isEnabled=enabled;picker.isEnabled=enabled && c != nil;name.isEnabled=enabled && c != nil;visible.isEnabled=enabled && c != nil;operation.isEnabled=enabled && c != nil;opacity.isEnabled=enabled && c != nil;componentActions.isEnabled=enabled
        name.stringValue=c?.name ?? "";visible.state=c?.visible == false ? .off:.on;operation.selectItem(at:MaskCombination.allCases.firstIndex(of:c?.operation ?? .add) ?? 0);opacity.doubleValue=(c?.opacity ?? 1)*100
        let range=c?.selection.range ?? RangeSelection(),kind=c?.selection.kind
        rangeControls.isHidden=kind != "colorRange" && kind != "luminanceRange";colors.isHidden=kind != "colorRange";luminance.isHidden=kind != "luminanceRange"
        color.color=NSColor(srgbRed:range.red,green:range.green,blue:range.blue,alpha:1)
        low.doubleValue=range.low;high.doubleValue=range.high;tolerance.doubleValue=range.tolerance;softness.doubleValue=range.softness
    }
    private func mutate(_ title:String,final:Bool = true,_ update:(inout MaskComponent)->Void){
        guard var root,var c=selected else{return};update(&c);root.updateComponent(c);self.root=root;changed?(root,title,final)
    }
    private func range(_ title:String,final:Bool,_ update:(inout RangeSelection)->Void){mutate(title,final:final){c in var r=c.selection.range ?? RangeSelection();update(&r);c.selection.range=r.sanitized}}
    @objc private func select(){selectedID=(picker.selectedItem?.representedObject as? String).flatMap(UUID.init(uuidString:));update(root,enabled:true);command?("componentChanged")}
    @objc private func rename(){let value=name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines);if !value.isEmpty{mutate("Rename mask"){$0.name=String(value.prefix(120))}}}
    @objc private func toggle(){mutate("Mask visibility"){$0.visible=visible.state == .on}}
    @objc private func combine(){mutate("Combine masks"){$0.operation=MaskCombination.allCases[max(0,operation.indexOfSelectedItem)]}}
    @objc private func colorChanged(){guard let rgb=color.color.usingColorSpace(.sRGB)else{return};range("Color range",final:true){$0.red=rgb.redComponent;$0.green=rgb.greenComponent;$0.blue=rgb.blueComponent}}
    @objc private func sample(){command?("sampleRange")}
    @objc private func aiAction(){let i=aiActions.indexOfSelectedItem;aiActions.selectItem(at:0);guard i>0,i<=Self.aiChoices.count else{return};command?("ai."+Self.aiChoices[i-1].1)}
    func select(_ id:UUID){selectedID=id;update(root,enabled:true)}
    @objc private func action(){
        let i=componentActions.indexOfSelectedItem;componentActions.selectItem(at:0)
        if (1...6).contains(i){
            let kinds=["brush","linear","radial","object","colorRange","luminanceRange"],titles=["Brush","Linear gradient","Radial","Object","Color range","Luminance range"]
            var mask=AdjustmentMask(kind:kinds[i-1]);if i>=5{mask.range=RangeSelection();mask.feather=0}
            let c=MaskComponent(name:titles[i-1]+" \((root?.namedComponents.count ?? 0)+1)",selection:mask)
            var next=root ?? AdjustmentMask(kind:"stack");if root==nil{next.components=[]};next.updateComponent(c);selectedID=c.id;root=next;changed?(next,"Add mask component",true)
            command?("componentChanged");if i<=4{command?(kinds[i-1])};return
        }
        if i==10{Self.clipboard=root;return}
        if i==11,let copy=Self.clipboard?.independentCopy(){root=copy;selectedID=copy.namedComponents.first?.id;changed?(copy,"Paste independent mask",true);command?("componentChanged");return}
        guard var next=root,let c=selected else{return}
        if i==7{let copy=c.independentCopy();next.updateComponent(copy);selectedID=copy.id;changed?(next,"Duplicate mask",true)}
        if i==8{let list=next.namedComponents.filter{$0.id != c.id};next.replaceComponents(list);selectedID=list.first?.id;changed?(list.isEmpty ? nil:next,"Delete mask component",true)}
        if i==9{mutate("Invert component"){$0.selection.inverted.toggle()}}
        command?("componentChanged")
    }
}
