import AppKit
import OpenStillCore

private final class SunSlider: NSSlider {
    var changed: ((Double,Bool)->Void)?
    private var tracking = false
    @objc func change() { changed?(doubleValue,!tracking) }
    override func mouseDown(with event:NSEvent) {
        tracking = true; super.mouseDown(with:event); tracking = false; changed?(doubleValue,true)
    }
}
final class SunraysPanel: NSStackView {
    var changed: ((SunraysSettings,String,Bool)->Void)?
    var command: ((String)->Void)?
    private var settings = SunraysSettings()
    private var controls: [(SunSlider,NSTextField,WritableKeyPath<SunraysSettings,Double>)] = []
    private var buttons: [NSButton] = []
    override init(frame:NSRect) {
        super.init(frame:frame)
        orientation = .vertical; alignment = .leading; spacing = 12
        button("Place Sun Center",action:#selector(place))
        let hint = NSTextField(wrappingLabelWithString:"Click or drag anywhere in the preview, including outside the photo. Press Escape when finished.")
        hint.font = .systemFont(ofSize:11); hint.textColor = .secondaryLabelColor; add(hint,to:self)
        slider("Amount",path:\.amount,in:self)
        slider("Overall Look",path:\.overallLook,in:self)
        slider("Sunrays Length",path:\.length,in:self)
        slider("Penetration",path:\.penetration,in:self)
        let sun = group("Sun Settings")
        slider("Sun Radius",path:\.sunRadius,in:sun)
        slider("Sun Glow Radius",path:\.glowRadius,in:sun)
        slider("Sun Glow Amount",path:\.glowAmount,in:sun)
        let rays = group("Rays Settings")
        slider("Number of Sunrays",path:\.rayCount,minimum:1,in:rays)
        slider("Randomize",path:\.randomize,in:rays)
        let warmth = group("Warmth")
        slider("Sun Warmth",path:\.sunWarmth,in:warmth)
        slider("Sunrays Warmth",path:\.raysWarmth,in:warmth)
        button("Reset Sunrays",action:#selector(reset))
        update(settings,enabled:false)
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    private func add(_ view:NSView,to stack:NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false; stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
    }
    private func button(_ title:String,action:Selector) {
        let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; b.font = .systemFont(ofSize:11)
        buttons.append(b); add(b,to:self)
    }
    private func group(_ title:String)->NSStackView {
        let content = NSStackView(); content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        let disclosure = NSButton(title:title,target:self,action:#selector(toggle))
        disclosure.isBordered = false; disclosure.alignment = .left; disclosure.font = .systemFont(ofSize:11,weight:.medium)
        disclosure.image = Appearance.symbol("chevron.right",size:9); disclosure.imagePosition = .imageLeading
        disclosure.setAccessibilityLabel("Show " + title)
        add(disclosure,to:self); add(content,to:self); content.isHidden = true
        return content
    }
    @objc private func toggle(_ sender:NSButton) {
        guard let index = arrangedSubviews.firstIndex(of:sender), arrangedSubviews.indices.contains(index+1) else {return}
        let content = arrangedSubviews[index+1]; content.isHidden.toggle()
        sender.image = Appearance.symbol(content.isHidden ? "chevron.right":"chevron.down",size:9)
        sender.setAccessibilityLabel((content.isHidden ? "Show ":"Hide ") + sender.title)
    }
    private func slider(_ title:String,path:WritableKeyPath<SunraysSettings,Double>,minimum:Double = 0,in stack:NSStackView) {
        let label = NSTextField(labelWithString:title); label.font = .systemFont(ofSize:11)
        let value = NSTextField(labelWithString:""); value.font = .monospacedDigitSystemFont(ofSize:10,weight:.regular); value.textColor = .secondaryLabelColor
        add(NSStackView(views:[label,NSView(),value]),to:stack)
        let slider = SunSlider(value:settings[keyPath:path],minValue:minimum,maxValue:100,target:nil,action:nil)
        slider.controlSize = .small; slider.isContinuous = true; slider.target = slider; slider.action = #selector(SunSlider.change)
        slider.setAccessibilityLabel("Sunrays " + title)
        slider.changed = { [weak self,weak value] number,final in
            guard let self else {return}
            self.settings[keyPath:path] = path == \SunraysSettings.rayCount ? number.rounded():number
            value?.stringValue = String(Int(self.settings[keyPath:path].rounded()))
            self.changed?(self.settings,"Sunrays · " + title,final)
        }
        controls.append((slider,value,path)); add(slider,to:stack)
    }
    @objc private func place() {command?("placeSun")}
    @objc private func reset() {settings = SunraysSettings(); changed?(settings,"Reset Sunrays",true)}
    func update(_ settings:SunraysSettings,enabled:Bool) {
        self.settings = settings.sanitized
        for (slider,label,path) in controls {slider.doubleValue = self.settings[keyPath:path]; label.stringValue = String(Int(slider.doubleValue.rounded()))}
        setEnabled(enabled)
    }
    func setEnabled(_ enabled:Bool) {
        for (slider,_,_) in controls {slider.isEnabled = enabled}; for button in buttons {button.isEnabled = enabled}
    }
}
