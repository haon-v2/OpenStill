import AppKit
import OpenStillCore

private final class LensSlider:NSSlider {
    var changed:((Double,Bool)->Void)?
    private var tracking=false
    @objc func adjust() { changed?(doubleValue,!tracking) }
    override func mouseDown(with event:NSEvent) { tracking=true;super.mouseDown(with:event);tracking=false;changed?(doubleValue,true) }
}
final class LensPanel:NSStackView,NSSearchFieldDelegate {
    var changed:((LensSettings,Bool)->Void)?
    var match:(()->Void)?
    private var settings=LensSettings()
    private let enabled=NSButton(checkboxWithTitle:"Enable lens corrections",target:nil,action:nil)
    private let search=NSSearchField()
    private let profiles=NSPopUpButton(frame:.zero,pullsDown:false)
    private let details=NSTextField(wrappingLabelWithString:"")
    private var sliders:[(LensSlider,WritableKeyPath<LensSettings,Double>,NSTextField)]=[]
    private var switches:[(NSButton,WritableKeyPath<LensSettings,Bool>)]=[]
    private var fields:[(NSTextField,WritableKeyPath<LensSettings,Double>)]=[]
    override init(frame:NSRect) {
        super.init(frame:frame);orientation = .vertical;alignment = .leading;spacing=10
        enabled.target=self;enabled.action = #selector(toggleEnabled);row(enabled)
        search.placeholderString="Find a lens profile";search.setAccessibilityLabel("Search lens profiles");search.delegate=self;row(search)
        profiles.target=self;profiles.action = #selector(chooseProfile);profiles.setAccessibilityLabel("Lens profile");row(profiles)
        let detect=NSButton(title:"Match camera and lens metadata",target:self,action:#selector(matchMetadata));detect.bezelStyle = .rounded;row(detect)
        details.font = .systemFont(ofSize:10);details.textColor = .secondaryLabelColor;row(details)
        for (title,path) in [("Distortion",\LensSettings.distortion),("Lateral chromatic aberration",\.chromaticAberration),("Optical vignetting",\.opticalVignette)] {
            let button=NSButton(checkboxWithTitle:title,target:self,action:#selector(toggle(_:)));button.tag=switches.count;button.font = .systemFont(ofSize:11);switches.append((button,path));row(button)
        }
        for (title,path) in [("Focal length (mm)",\LensSettings.focal),("Aperture",\.aperture),("Sensor crop factor",\.crop),("Focus distance (m)",\.distance)] {
            let label=NSTextField(labelWithString:title);label.font = .systemFont(ofSize:10)
            let field=NSTextField(string:"");field.tag=fields.count;field.target=self;field.action = #selector(numberChanged(_:));field.setAccessibilityLabel(title);field.widthAnchor.constraint(equalToConstant:70).isActive=true
            fields.append((field,path));row(NSStackView(views:[label,NSView(),field]))
        }
        let manual=NSTextField(labelWithString:"MANUAL FINE TUNING");manual.font = .systemFont(ofSize:10,weight:.semibold);manual.textColor = .secondaryLabelColor;row(manual)
        for (title,path) in [("Barrel − / Pincushion +",\LensSettings.manualDistortion),("Red / blue fringe",\.manualChromatic),("Edge brightness",\.manualVignette)] {
            let label=NSTextField(labelWithString:title);label.font = .systemFont(ofSize:10)
            let value=NSTextField(labelWithString:"0");value.font = .monospacedDigitSystemFont(ofSize:10,weight:.regular)
            row(NSStackView(views:[label,NSView(),value]))
            let slider=LensSlider(value:0,minValue:-1,maxValue:1,target:nil,action:nil);slider.target=slider;slider.action = #selector(LensSlider.adjust);slider.isContinuous=true;slider.setAccessibilityLabel(title)
            slider.changed = { [weak self,weak value] v,final in guard let self else{return};self.settings[keyPath:path]=v;value?.stringValue=String(format:"%.2f",v);self.changed?(self.settings,final) }
            sliders.append((slider,path,value));row(slider)
        }
        let reset=NSButton(title:"Reset lens corrections",target:self,action:#selector(reset));reset.bezelStyle = .rounded;row(reset)
        reloadProfiles()
    }
    required init?(coder:NSCoder){fatalError()}
    private func row(_ view:NSView){addArrangedSubview(view);view.widthAnchor.constraint(equalTo:widthAnchor).isActive=true}
    func update(_ value:LensSettings,available:Bool){
        let previous=settings.profileID;settings=value.sanitized;enabled.isEnabled=available;enabled.state=settings.enabled ? .on:.off
        if previous != settings.profileID || profiles.numberOfItems == 0 { reloadProfiles() }
        for (slider,path,label) in sliders { slider.doubleValue=settings[keyPath:path];label.stringValue=String(format:"%.2f",settings[keyPath:path]);slider.isEnabled=available }
        for (button,path) in switches {button.state=settings[keyPath:path] ? .on:.off;button.isEnabled=available}
        for (field,path) in fields {field.doubleValue=settings[keyPath:path];field.isEnabled=available}
        if let profile=LensLibrary.shared.profile(id:settings.profileID) {
            let names=[(8,"distortion"),(1,"color fringes"),(2,"vignetting")].filter{profile.capabilities & $0.0 != 0}.map{$0.1}
            details.stringValue="Profile includes: "+(names.isEmpty ? "no compatible calibrations" : names.joined(separator:", "))
        } else {details.stringValue="No profile selected. Manual controls work independently. JPEG and Camera Look corrections start off."}
    }
    private func reloadProfiles(){
        profiles.removeAllItems();profiles.addItem(withTitle:"Manual corrections only")
        let query=search.stringValue.trimmingCharacters(in:.whitespaces)
        var matches=LensLibrary.shared.profiles.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        matches=Array(matches.prefix(150))
        if let selected=LensLibrary.shared.profile(id:settings.profileID),!matches.contains(selected){matches.insert(selected,at:0)}
        for profile in matches {profiles.addItem(withTitle:profile.title);profiles.lastItem?.representedObject=profile.id}
        if let id=settings.profileID,let item=profiles.itemArray.first(where:{$0.representedObject as? String == id}){profiles.select(item)}
    }
    func controlTextDidChange(_ obj:Notification){if obj.object as? NSSearchField === search {reloadProfiles()}}
    @objc private func toggleEnabled(){settings.enabled=enabled.state == .on;changed?(settings,true)}
    @objc private func toggle(_ sender:NSButton){settings[keyPath:switches[sender.tag].1]=sender.state == .on;changed?(settings,true)}
    @objc private func numberChanged(_ sender:NSTextField){settings[keyPath:fields[sender.tag].1]=sender.doubleValue;settings=settings.sanitized;changed?(settings,true)}
    @objc private func chooseProfile(){settings.profileID=profiles.selectedItem?.representedObject as? String;changed?(settings,true)}
    @objc private func matchMetadata(){match?()}
    @objc private func reset(){settings=LensSettings();changed?(settings,true)}
}
