import AppKit
import CoreImage
import OpenStillCore
import UniformTypeIdentifiers

extension ViewerController {
    var currentSource: URL? { urls.indices.contains(selected) ? urls[selected] : nil }
    func configureEditing() {
        info.editChanged = { [weak self] edits, title, final in self?.changeEdits(edits, title: title, commit: final) }
        info.command = { [weak self] name in self?.editingCommand(name) }
        info.chooseHistory = { [weak self] index in
            guard let self, !self.localAI.isRunning, !self.aiPreparing, self.editDocument.steps.indices.contains(index) else { return }
            self.editDocument.cursor = index
            self.restoreHistory()
        }
        info.brushChanged = { [weak self] key,radius,softness,strength in
            guard let self else { return };self.maskRadius = radius;self.maskSoftness = softness;self.maskStrength = strength
            self.canvas.maskRadius = radius;self.canvas.maskSoftness = softness;self.canvas.needsDisplay = true
        }
        canvas.resizeMaskBrush = { [weak self] delta in guard let self,let key = self.activeMaskKey else { return };self.info.resizeBrush(key:key,delta:delta) }
        canvas.maskDrawn = { [weak self] points, kind in self?.drawAdjustmentMask(points, kind:kind) }
        canvas.retouchSourceChosen = { [weak self] point in self?.chooseRetouchSource(point) }
        canvas.retouchDrawn = { [weak self] points in self?.drawRetouch(points) }
        info.retouchSettingsChanged = { [weak self] settings in self?.updateRetouchSettings(settings) }
        canvas.rangeChosen = { [weak self] point in self?.sampleMaskRange(at:point) }
        canvas.whiteBalanceChosen = { [weak self] point in self?.chooseWhiteBalance(at:point) }
        canvas.objectChosen = { [weak self] point in self?.selectMaskObject(at:point) }
        canvas.toggleClipping = { [weak self] in self?.editingCommand("toggleClipping") }
        canvas.toggleSplit = { [weak self] in self?.editingCommand("compareSplit") }
        canvas.toggleCompare = { [weak self] in self?.editingCommand("compare") }
        canvas.cropReport = { [weak self] selection, photo in self?.info.showCrop(selection:selection,photo:photo) }
        canvas.sunPlaced = { [weak self] point, final in
            guard let self else { return }; var edits = self.currentEdits
            var settings = edits.editableSunSettings(sourceSize:self.editSourceSize())
            settings.place(at:point,geometry:EditGeometry(size:self.editSourceSize(),edits:edits))
            edits.sunSettings = settings
            let now = ProcessInfo.processInfo.systemUptime
            if !final && now-self.lastSunPreviewAt < 0.18 { self.currentEdits = edits; return }
            self.lastSunPreviewAt = now
            self.changeEdits(edits, title: "Place sun", commit: final)
        }
    }
    func prepareEditor(for source: URL) {
        updateHistogram(nil)
        info.setLUTPhoto(nil,edits:PhotoEdits())
        localAI.cancel(); aiPreparing = false; maskSession.end(); maskVisible = false; maskToken = UUID()
        info.resetMaskInteractions()
        editWork?.cancel(); editToken = UUID(); comparing = false; canvas.clearTool();retouchSession.reset();canvas.retouchSource=nil
        canvas.beforeImage = nil; canvas.clippingOverlay = nil
        do { photoRecord = try EditStorage.record(source) }
        catch { photoRecord = nil; info.status("Couldn’t open saved versions: " + error.localizedDescription) }
        editDocument = photoRecord?.active.document ?? EditStorage.load(source); currentEdits = editDocument.current
        info.updateVersions(photoRecord, raw:RawDecoder.isRAW(source))
        info.update(currentEdits, document: editDocument, enabled: false)
        info.status("Edits are saved on this Mac. Originals stay untouched.")
    }
    func changeEdits(_ incoming: PhotoEdits, title: String, commit: Bool) {
        var edits = incoming
        if title.hasPrefix("Sunrays ·"), currentEdits.advanced?.sunSettings == nil, var sun = edits.advanced?.sunSettings {
            let converted = currentEdits.editableSunSettings(sourceSize:editSourceSize())
            sun.centerX = converted.centerX; sun.centerY = converted.centerY; edits.sunSettings = sun
        }
        guard currentSource != nil, renderedPhoto != nil, !localAI.isRunning, !aiPreparing else { return }
        if photoRecord?.active.renderer == .legacy && (!edits.curves.isIdentity || edits.neutralBalance != NeutralBalance() || edits.lens.hasEffect || !edits.retouch.isEmpty || edits.advanced?.masks.values.contains(where:{$0.components != nil || $0.range != nil}) == true) {
            photoRecord?.upgrade(); editDocument = photoRecord!.active.document
        }
        currentEdits = edits; comparing = false
        if commit {
            editDocument.commit(edits, title: title)
            saveEdits()
            info.update(edits, document: editDocument, enabled: true)
        }
        renderEdits(interactive:!commit)
    }
    func saveEdits() {
        guard let source = currentSource else { return }
        do {
            if var record = photoRecord {
                guard editDocument.fingerprint == EditStorage.fingerprint(source) else { throw WorkflowError.changedSource }
                let versionID=record.activeVersionID,version=record.active
                record=try EditStorage.records.update(record.id) { saved in
                    if let index=saved.versions.firstIndex(where:{$0.id==versionID}) {saved.versions[index].document=editDocument;saved.versions[index].revision=UUID()}
                    else {var added=version;added.document=editDocument;added.revision=UUID();saved.versions.append(added)}
                    saved.activeVersionID=versionID
                }
                photoRecord = record;shootWindow?.refresh()
                info.updateVersions(record, raw:RawDecoder.isRAW(source))
            } else { try EditStorage.save(editDocument, for: source) }
        }
        catch { info.status("Couldn’t save edit history: \(error.localizedDescription)") }
    }
    func renderEdits(interactive:Bool = false) {
        guard let original = renderedPhoto?.image, let source = currentSource else { return }
        canvas.sunPosition = currentEdits.editableSunSettings(sourceSize:editSourceSize()).displayedCenter(geometry:EditGeometry(size:editSourceSize(),edits:currentEdits))
        info.setLUTPhoto(original,edits:currentEdits, source:renderedPhoto?.sourceImage, url:source, recipe:photoRecord?.active.recipe)
        editWork?.cancel(); let token = UUID(); editToken = token
        if comparing { canvas.maskOverlay = nil }
        else { refreshMaskOverlay() }
        if comparing || currentEdits.isOriginal {
            canvas.replaceRenderedImage(original); updateHistogram(original); refreshCompareExtras(original, interactive:false)
            info.status(comparing ? "Showing original. Click Compare again to return to your edit." : "Edits are saved on this Mac. Originals stay untouched.")
            return
        }
        let edits = currentEdits
        let previewLimit:Int?=interactive ? 1600:nil
        let logicalSize=EditGeometry(size:editSourceSize(),edits:edits).extent.size
        let linearSource = renderedPhoto?.sourceImage
        var recipe = photoRecord?.active.recipe
        recipe?.edits = edits
        if recipe?.sourceMode == .raw { recipe = RenderRecipe(renderer:recipe!.renderer, sourceMode:.raw, raw:recipe!.raw, edits:edits) }
        info.status("Rendering edit…")
        let work = DispatchWorkItem { [weak self] in
            let result = Result { try autoreleasepool { () -> CGImage in
                if let recipe, recipe.renderer == .linear2020 { return try ModernRenderer.display(ModernRenderer.render(source:source, recipe:recipe,maximumDimension:previewLimit)) }
                if let linearSource { return try ModernRenderer.display(ModernRenderer.process(linearSource, edits:edits,maximumDimension:previewLimit)) }
                return try PhotoEditor.render(original, edits: edits,previewMaxDimension:previewLimit)
            } }
            DispatchQueue.main.async {
                guard let self, self.editToken == token, self.currentSource == source else { return }
                switch result {
                case .success(let image):
                    self.canvas.replaceRenderedImage(image,pixelSize:interactive ? logicalSize:nil); self.updateHistogram(image)
                    self.refreshCompareExtras(image, interactive:interactive)
                    self.refreshMaskOverlay()
                    self.info.status(interactive ? "Interactive preview · Full resolution on release":"Edited · \(image.width) × \(image.height) px · Original preserved")
                case .failure(let error): self.info.status(error.localizedDescription)
                }
            }
        }
        editWork = work; editQueue.asyncAfter(deadline: .now() + (canvas.tool == .sun ? 0 : 0.12), execute: work)
    }
    func restoreHistory() {
        finishMaskEditing()
        currentEdits = editDocument.current; comparing = false; canvas.clearTool()
        info.update(currentEdits, document: editDocument, enabled: renderedPhoto != nil)
        saveEdits(); renderEdits()
    }
    @objc func undoEdit() { editingCommand("undo") }
    @objc func redoEdit() { editingCommand("redo") }
    @objc func exportPhoto() {
        if let items=libraryExportItems {
            guard !items.isEmpty else{return}
            let panel=ExportPanel(items:items);exportPanel=panel;panel.showWindow(nil);panel.window?.makeKeyAndOrderFront(nil)
        } else { editingCommand("export") }
    }
    func editingCommand(_ name: String) {
        if name.hasPrefix("recovery:"),let value=Int(name.dropFirst(9)){var edits=currentEdits;edits.ensureAdvanced();edits.advanced?.rawRecovery=min(9,max(0,value));changeEdits(edits,title:"RAW highlight recovery",commit:true);return}
        if name == "finishMask" {
            if canvas.tool == .sun { canvas.clearTool() }
            finishMaskEditing()
            return
        }
        if name == "cancelAI" {
            if maskSession.selection != nil { finishMaskEditing(); return }
            if aiPreparing { aiPreparing = false; editToken = UUID(); info.status("AI processing cancelled.") }
            localAI.cancel(); return
        }
        if name == "setupAI" { setupAI(); return }
        if name.hasPrefix("version:") || name.hasPrefix("source:") { versionCommand(name); return }
        guard let source = currentSource, let original = renderedPhoto?.image, !localAI.isRunning, !aiPreparing else { return }
        if comparing && name != "compare" { comparing = false; renderEdits() }
        if name.hasPrefix("mask:") { maskCommand(name); return }
        if name.hasPrefix("libraryLUT:"), let item = info.libraryLUT(id:String(name.dropFirst(11))) { applyLibraryLUT(item); return }
        if name.hasPrefix("lut:") { applyLUT(URL(fileURLWithPath:String(name.dropFirst(4))).lastPathComponent); return }
        if ["crop","eraseBrush","placeSun","reset","cancelTool"].contains(name) { maskVisible = false; maskToken = UUID() }
        var edits = currentEdits
        switch name {
        case "whiteBalance": finishMaskEditing(); canvas.tool = .whiteBalance; info.status("Click a neutral gray area. Overlays and watermarks are excluded.")
        case "retouchSource":finishMaskEditing();canvas.tool = .retouchSource;info.status("Click a clean source area. Then brush over the area to repair.")
        case "retouchPaint":activateRetouch()
        case "retouchRemoveLast":if !edits.retouch.isEmpty{edits.retouch.removeLast();changeEdits(edits,title:"Remove last retouch stroke",commit:true)}
        case "retouchClear":edits.retouch=[];changeEdits(edits,title:"Clear retouch strokes",commit:true)
        case "matchLens":
            guard let source = currentSource else { return }
            var settings = LensLibrary.shared.suggested(for:source)
            settings.enabled = settings.profileID != nil
            edits.lens = settings; changeEdits(edits,title:"Match lens profile",commit:true)
            if settings.profileID == nil { info.status("No unambiguous profile match. Search for your lens and enable corrections, or use the manual sliders.") }
        case "resetWhiteBalance": edits.temperature = 6500; edits.tint = 0; edits.neutralBalance = NeutralBalance(); edits.advanced?.rawWhiteBalance = nil; changeEdits(edits,title:"Reset white balance",commit:true)
        case "undo": editDocument.undo(); restoreHistory()
        case "redo": editDocument.redo(); restoreHistory()
        case "compare": comparing.toggle(); if comparing { splitCompare = false }; renderEdits()
        case "compareSplit": toggleSplitCompare()
        case "toggleClipping": showClipping.toggle(); info.setClippingOverlay(showClipping); renderEdits()
        case "autoTone": autoTone()
        case "reset": changeEdits(PhotoEdits(), title: "Reset all edits", commit: true); canvas.clearTool()
        case "crop":
            // Start from the current full crop; the new rectangle is composed with the existing crop on Apply.
            finishMaskEditing()
            let pixels = EditGeometry(size:editSourceSize(),edits:edits).extent.size
            canvas.beginCrop(aspect:info.cropAspect(for:pixels),pixels:pixels)
            info.status("Drag the frame to move it, or a corner to resize. Apply crop saves; Escape cancels.")
        case "applyCrop":
            guard let rect = canvas.cropSelection, rect.width > 0.01, rect.height > 0.01 else { info.status("Draw a crop rectangle on the photo first."); return }
            let prior = edits.crop?.rect ?? CGRect(x: 0,y: 0,width: 1,height: 1)
            edits.crop = EditRect(CGRect(x: prior.minX+rect.minX*prior.width,y:prior.minY+rect.minY*prior.height,width:rect.width*prior.width,height:rect.height*prior.height))
            canvas.clearTool(); changeEdits(edits, title: "Crop", commit: true)
        case "cancelTool": canvas.clearTool(); info.status("Edits are saved on this Mac. Originals stay untouched.")
        case "rotate": edits.rotation = (edits.rotation+1)%4; edits.crop = nil; canvas.clearTool(); changeEdits(edits, title: "Rotate clockwise", commit: true)
        case "flip": edits.flip.toggle(); edits.crop = nil; changeEdits(edits, title: "Flip horizontally", commit: true)
        case "resetCrop": edits.straighten = 0; edits.crop = nil; edits.rotation = 0; edits.flip = false; canvas.clearTool(); changeEdits(edits, title: "Reset crop & rotation", commit: true)
        case "eraseBrush": canvas.clearTool(); canvas.native = false; canvas.tool = .erase; info.status("Paint over the unwanted object, then click Remove marked area.")
        case "brushSmall", "brushMedium", "brushLarge":
            canvas.clearTool(); canvas.tool = .erase; canvas.brushWidth = name == "brushSmall" ? 0.015 : (name == "brushLarge" ? 0.08 : 0.035)
            info.status("Brush size changed. Paint the whole object, including its edges.")
        case "placeSun":
            finishMaskEditing(); canvas.clearTool(); canvas.native = false; canvas.tool = .sun
            canvas.sunPosition = edits.editableSunSettings(sourceSize:editSourceSize()).displayedCenter(geometry:EditGeometry(size:editSourceSize(),edits:edits))
            info.status("Drag the sun center inside or outside the photo. Escape finishes placement. Increase Amount to reveal the light.")
        case "addLayer": chooseImage(title: "Choose image layer") { [weak self] url in
            guard let self, self.currentSource == source else { return }
            do {
                let asset = try EditStorage.newAsset(extension: url.pathExtension)
                try FileManager.default.copyItem(at: url, to: asset)
                var e = self.currentEdits; e.overlayAsset = asset.lastPathComponent
                self.changeEdits(e, title: "Add image layer", commit: true)
            } catch { self.info.status(error.localizedDescription) }
        }
        case "removeLayer": edits.overlayAsset = nil; changeEdits(edits, title: "Remove image layer", commit: true)
        case "blendNormal", "blendScreen", "blendMultiply":
            edits.overlayBlend = name == "blendNormal" ? "CISourceOverCompositing" : (name == "blendScreen" ? "CIScreenBlendMode" : "CIMultiplyBlendMode")
            changeEdits(edits, title: "Layer blend", commit: true)
        case "export": exportCurrent(source: source, original: original, edits: edits)
        case "horizon": alignHorizon()
        case "importLUT": importLUT()
        case "removeLUT": edits.ensureAdvanced(); edits.advanced!.lutAsset = nil; edits.advanced!.lutName = nil; edits.advanced!.lutID = nil; changeEdits(edits,title:"Remove LUT",commit:true)
        case "savePreset": savePreset()
        case "loadPreset": loadPreset()
        default:
            if name.hasPrefix("preset:") { applyPreset(String(name.dropFirst(7))) }
            if name == "ai:sky" { chooseImage(title: "Choose replacement sky") { [weak self] sky in self?.runAI("sky", sky: sky) } }
            else if name.hasPrefix("ai:") { runAI(String(name.dropFirst(3))) }
        }
    }
    private func chooseImage(title: String, completion: @escaping (URL) -> Void) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel(); panel.title = title; panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in if response == .OK, let url = panel.url { completion(url) } }
    }
    private func applyPreset(_ name: String) {
        var e = currentEdits
        e.highlights = 1; e.shadows = 0; e.exposure = 0; e.contrast = 1; e.saturation = 1; e.vibrance = 0; e.temperature = 6500; e.tint = 0; e.monochrome = 0; e.blacks = 0; e.whites = 0; e.advanced!.colors = [ColorBand](repeating:ColorBand(),count:8); e.autoEnhance = false
        e.clarity = 0; e.texture = 0; e.dehaze = 0; e.colorGrading = ColorGrading()
        switch name {
        case "Warm light": e.temperature = 7800; e.vibrance = 0.15; e.contrast = 1.05
        case "Cool shadows": e.temperature = 5200; e.shadows = 0.2; e.contrast = 1.05
        case "Vivid": e.vibrance = 0.35; e.saturation = 1.12; e.contrast = 1.12; e.clarity = 0.15
        case "Soft portrait": e.contrast = 0.9; e.shadows = 0.2; e.saturation = 0.95; e.temperature = 6900
        case "Monochrome": e.monochrome = 1; e.contrast = 1.2
        default: break
        }
        changeEdits(e, title: name, commit: true)
    }
    private func savePreset() {
        guard let window = view.window else { return }
        var preset = currentEdits
        preset.ensureAdvanced(); preset.advanced!.masks = [:]; preset.advanced!.rawWhiteBalance = nil; preset.straighten = 0; preset.advanced!.lutAsset = nil; preset.advanced!.lutName = nil; preset.advanced!.lutID = nil; preset.advanced!.aiBackgroundAsset = nil; preset.advanced!.aiFeatureKey = nil
        preset.baseAsset = nil; preset.overlayAsset = nil; preset.crop = nil; preset.rotation = 0; preset.flip = false
        let panel = NSSavePanel(); panel.title = "Save preset"; panel.nameFieldStringValue = "My preset.openstillpreset"; panel.allowedContentTypes = [UTType(filenameExtension: "openstillpreset") ?? .json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try JSONEncoder().encode(preset).write(to: url, options: .atomic); self?.info.status("Preset saved.") }
            catch { self?.info.status(error.localizedDescription) }
        }
    }
    private func loadPreset() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel(); panel.title = "Load preset"; panel.allowedContentTypes = [UTType(filenameExtension: "openstillpreset") ?? .json, .json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                var preset = try JSONDecoder().decode(PhotoEdits.self, from: Data(contentsOf: url)).sanitized
                preset.baseAsset = self.currentEdits.baseAsset; preset.overlayAsset = self.currentEdits.overlayAsset
                preset.crop = self.currentEdits.crop; preset.rotation = self.currentEdits.rotation; preset.flip = self.currentEdits.flip
                preset.ensureAdvanced(); preset.straighten = self.currentEdits.straighten
                preset.advanced!.masks = self.currentEdits.advanced?.masks ?? [:]
                preset.advanced!.aiBackgroundAsset = self.currentEdits.advanced?.aiBackgroundAsset; preset.advanced!.aiFeatureKey = self.currentEdits.advanced?.aiFeatureKey
                preset.advanced!.lutAsset = self.currentEdits.advanced?.lutAsset; preset.advanced!.lutName = self.currentEdits.advanced?.lutName; preset.advanced!.lutID = self.currentEdits.advanced?.lutID; preset.lutAmount = self.currentEdits.lutAmount
                self.changeEdits(preset, title: url.deletingPathExtension().lastPathComponent, commit: true)
            } catch { self.info.status("Couldn’t read this preset. \(error.localizedDescription)") }
        }
    }
    private func exportCurrent(source: URL, original: CGImage, edits: PhotoEdits) {
        guard var record=photoRecord else{info.status("Open a photo with a saved edit record before exporting.");return}
        var document=record.active.document;document.commit(edits,title:"Export snapshot");record.updateDocument(document)
        let item=ShootItem(url:source,record:record,captured:(try? ShootItem.read(source).captured) ?? Date.distantPast)
        let panel=ExportPanel(items:[item]);exportPanel=panel;panel.showWindow(nil);panel.window?.makeKeyAndOrderFront(nil)
    }
    private func setupAI() {
        guard !localAI.isRunning, !aiPreparing else { return }
        info.status("Setting up local AI tools. Downloading about 350 MB of models…", busy: true)
        localAI.run(tool: "setup", status: { [weak self] text in self?.info.status(text, busy: true) }) { [weak self] result in
            switch result {
            case .success: self?.info.status("Local AI tools are ready. Photos stay on this Mac.")
            case .failure(let error): self?.info.status(error.localizedDescription)
            }
        }
    }
    private func runAI(_ tool: String, sky: URL? = nil) {
        guard let source = currentSource, renderedPhoto != nil, !localAI.isRunning, !aiPreparing else { return }
        guard LocalAI.ready else { info.status("Choose Set up local AI tools first (one-time download, about 350 MB)."); return }
        let keys = ["sky":"Sky replacement", "erase":"Erase", "denoise":"Noise removal", "detail":"Detail restoration"]
        guard let key = keys[tool] else { return }
        let edits = currentEdits, size = editSourceSize()
        let adjustmentMask = edits.advanced?.masks[key]
        let legacyMask = tool == "erase" && adjustmentMask == nil ? canvas.image.flatMap { canvas.removalMask(width:$0.width,height:$0.height) } : nil
        if tool == "erase", adjustmentMask == nil, legacyMask == nil { info.status("Create an Erase mask over the unwanted object first."); return }
        let renderer = photoRecord?.active.renderer ?? .legacy
        let sourceMode = photoRecord?.active.sourceMode ?? .original
        let rawSettings = photoRecord?.active.raw ?? RawSettings()
        aiPreparing = true; editWork?.cancel(); editToken = UUID()
        let token = editToken
        info.status("Preparing full-resolution photo for local AI…", busy: true)
        editQueue.async { [weak self] in
            var temporaryFiles: [URL] = []
            let prepared = Result { () -> (URL, URL, URL?, URL?) in
                let input = try EditStorage.newAsset(extension:"osfloat"); temporaryFiles.append(input)
                let recipe = RenderRecipe(renderer:renderer, sourceMode:sourceMode, raw:rawSettings, edits:edits)
                let incoming=try ModernRenderer.render(source:source, recipe:recipe)
                try FloatImageBridge.write(incoming, to:input)
                let output = try EditStorage.newAsset(extension:"osfloat")
                var maskURL: URL?
                var maskImage = legacyMask
                if let adjustmentMask {
                    let geometry = EditGeometry(size:size,edits:edits)
                    let selection = try adjustmentMask.coverage(geometry:geometry,lens:edits.lens,input:incoming,modern:renderer == .linear2020)
                    guard let cg = CIContext().createCGImage(selection,from:geometry.extent) else { throw EditError.render }
                    maskImage = cg
                }
                if let maskImage { maskURL = try EditStorage.newAsset(); temporaryFiles.append(maskURL!); try PhotoEditor.write(maskImage,to:maskURL!) }
                var skyURL: URL?
                if let sky { skyURL = try EditStorage.newAsset(extension:"osfloat"); temporaryFiles.append(skyURL!); try FloatImageBridge.write(ModernRenderer.readImage(sky),to:skyURL!) }
                return (input,output,maskURL,skyURL)
            }
            let cleanupFiles = temporaryFiles
            DispatchQueue.main.async {
                guard let self, self.currentSource == source, self.editToken == token else {
                    for file in cleanupFiles { try? FileManager.default.removeItem(at:file) }; return
                }
                self.aiPreparing = false
                switch prepared {
                case .failure(let error):
                    for file in cleanupFiles { try? FileManager.default.removeItem(at:file) }; self.info.status(error.localizedDescription)
                case .success(let (input,output,maskURL,skyURL)):
                    var arguments = ["--input",input.path,"--output",output.path]
                    if tool == "erase", let maskURL { arguments += ["--mask",maskURL.path] }
                    if let skyURL { arguments += ["--sky",skyURL.path] }
                    self.info.status("Running local \(tool)… You can cancel below.",busy:true)
                    self.localAI.run(tool:tool,arguments:arguments,status: { [weak self] text in
                        guard self?.currentSource == source else { return }; self?.info.status(text,busy:true)
                    }) { [weak self] result in
                        if let skyURL { try? FileManager.default.removeItem(at:skyURL) }
                        try? FileManager.default.removeItem(at:output.deletingPathExtension().appendingPathExtension("mask.png"))
                        guard let self, self.currentSource == source, self.editToken == token else {
                            for file in [input,output,maskURL].compactMap({$0}) { try? FileManager.default.removeItem(at:file) }; return
                        }
                        self.info.status("Local processing finished.")
                        switch result {
                        case .success:
                            if self.photoRecord?.active.renderer == .legacy { self.photoRecord?.upgrade(); self.editDocument = self.photoRecord!.active.document }
                            var next = PhotoEdits(); next.baseAsset = output.lastPathComponent; next.ensureAdvanced()
                            next.advanced!.aiBackgroundAsset = input.lastPathComponent; next.advanced!.aiFeatureKey = key
                            if let maskURL {
                                var mask = AdjustmentMask(kind:"object"); mask.asset = maskURL.lastPathComponent; mask.feather = 0
                                next.setMask(mask,for:key)
                            }
                            let names = ["sky":"AI sky replacement", "erase":"AI object removal", "denoise":"AI noise removal", "detail":"AI detail restoration"]
                            self.maskVisible = false; self.canvas.clearTool(); self.changeEdits(next,title:names[tool] ?? "AI edit",commit:true); self.select(self.selected, preservingSelection:true)
                        case .failure(let error):
                            for file in [input,output,maskURL].compactMap({$0}) { try? FileManager.default.removeItem(at:file) }
                            self.info.status(error.localizedDescription)
                        }
                    }
                }
            }
        }
    }
}
