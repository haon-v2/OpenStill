import AppKit
import CoreImage
import OpenStillCore
import UniformTypeIdentifiers

extension ViewerController {
    var currentSource: URL? { urls.indices.contains(selected) ? urls[selected] : nil }
    func configureEditing() {
        info.editChanged = { [weak self] edits, title, final in self?.changeEdits(edits, title: title, commit: final) }
        info.command = { [weak self] name in self?.editingCommand(name) }
        configureDevelopM11()
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
        canvas.guideDrawn = { [weak self] a, b in self?.addGuide(a, b) }
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
        flushPendingSave()
        updateHistogram(nil)
        info.setLUTPhoto(nil,edits:PhotoEdits())
        localAI.cancel(); aiPreparing = false; maskSession.end(); maskVisible = false; maskToken = UUID()
        info.resetMaskInteractions()
        cancelRenders(); editToken = UUID(); comparing = false; canvas.clearTool();retouchSession.reset();canvas.retouchSource=nil
        canvas.beforeImage = nil; canvas.clippingOverlay = nil
        if let old = preparedSource, old != source { previousEdits = currentEdits }
        preparedSource = source
        do { photoRecord = try EditStorage.record(source) }
        catch { photoRecord = nil; info.status("Couldn’t open saved versions: " + error.localizedDescription) }
        editDocument = photoRecord?.active.document ?? EditStorage.load(source); currentEdits = editDocument.current
        info.updateVersions(photoRecord, raw:RawDecoder.isRAW(source))
        info.update(currentEdits, document: editDocument, enabled: false)
        info.status("Edits are saved on this Mac. Originals stay untouched.")
    }
    func changeEdits(_ incoming: PhotoEdits, title: String, commit: Bool) {
        var edits = incoming
        // Moving Contrast switches this edit to Smart Contrast; untouched older edits keep their look.
        edits.adoptSmartContrast(changedFrom: currentEdits)
        if title.hasPrefix("Sunrays ·"), currentEdits.advanced?.sunSettings == nil, var sun = edits.advanced?.sunSettings {
            let converted = currentEdits.editableSunSettings(sourceSize:editSourceSize())
            sun.centerX = converted.centerX; sun.centerY = converted.centerY; edits.sunSettings = sun
        }
        guard currentSource != nil, renderedPhoto != nil, !localAI.isRunning, !aiPreparing else {
            // Not applied (no photo, or AI is working): put the panel's controls back where the edit really is.
            if commit { info.update(currentEdits, document: editDocument, enabled: renderedPhoto != nil) }
            return
        }
        if photoRecord?.active.renderer == .legacy && (edits.autoCA.hasEffect || !edits.curves.isIdentity || edits.neutralBalance != NeutralBalance() || edits.optics.hasEffect || edits.hdr.enabled || edits.profile.hasEffect || edits.calibration.hasEffect || !edits.retouch.isEmpty || edits.advanced?.masks.values.contains(where:{$0.components != nil || $0.range != nil}) == true) {
            photoRecord?.upgrade(); editDocument = photoRecord!.active.document
        }
        currentEdits = edits; comparing = false
        if commit {
            let before = editDocument.current
            editDocument.commit(edits, title: title)
            scheduleSave()
            if autoSync, !title.hasPrefix("Auto Sync") { autoSyncChange(from: before, to: edits, title: title) }
            info.update(edits, document: editDocument, enabled: true)
        }
        renderEdits(interactive:!commit)
    }
    /// Saves after a short pause, so a run of slider releases writes the record once.
    func scheduleSave() {
        pendingSave?.cancel()
        // The photo is captured now: by the time a flush runs, the selection may already point at the next photo.
        let source = currentSource
        let work = DispatchWorkItem { [weak self] in self?.saveEdits(for: source) }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    /// Writes a scheduled save now (before switching photos, leaving Develop or quitting).
    func flushPendingSave() { if let work = pendingSave, !work.isCancelled { work.perform(); work.cancel() } }
    func saveEdits(for photo: URL? = nil) {
        pendingSave?.cancel(); pendingSave = nil
        guard let source = photo ?? currentSource else { return }
        do {
            if var record = photoRecord {
                guard editDocument.fingerprint == EditStorage.fingerprint(source) else { throw WorkflowError.changedSource }
                let versionID=record.activeVersionID,version=record.active
                record=try EditStorage.records.update(record.id) { saved in
                    if let index=saved.versions.firstIndex(where:{$0.id==versionID}) {saved.versions[index].document=editDocument;saved.versions[index].revision=UUID()}
                    else {var added=version;added.document=editDocument;added.revision=UUID();saved.versions.append(added)}
                    saved.activeVersionID=versionID
                }
                photoRecord = record
                info.updateVersions(record, raw:RawDecoder.isRAW(source))
            } else { try EditStorage.save(editDocument, for: source) }
        }
        catch { info.status("Couldn’t save edit history: \(error.localizedDescription)") }
    }
    /// Shows the current edits. Renders run one at a time and the newest edits always win: while one renders, later
    /// changes wait and the next render starts the moment it finishes, so the photo follows a slider as fast as the GPU
    /// allows. The screen gets the whole frame at the size it is shown (never more than `ModernRenderer.screenEdge`);
    /// when zoomed in past that, the visible part is rendered sharp on its own once the edit settles.
    func renderEdits(interactive:Bool = false) {
        guard let photo = renderedPhoto, currentSource != nil else { return }
        if canvas.tool == .sun || !interactive {
            let sun = currentEdits.editableSunSettings(sourceSize:editSourceSize()).displayedCenter(geometry:EditGeometry(size:editSourceSize(),edits:currentEdits))
            if canvas.sunPosition != sun { canvas.sunPosition = sun }
        }
        editToken = UUID()
        if comparing || currentEdits.isOriginal {
            renderQueued = false
            if comparing { canvas.maskOverlay = nil } else { refreshMaskOverlay() }
            canvas.replaceRenderedImage(photo.preview, pixelSize:photo.pixelSize); updateHistogram(photo.preview); refreshCompareExtras(photo.preview, interactive:false)
            info.status(comparing ? "Showing original. Click Compare again to return to your edit." : "Edits are saved on this Mac. Originals stay untouched.")
            return
        }
        if renderInFlight {
            queuedInteractive = renderQueued ? queuedInteractive && interactive : interactive
            renderQueued = true
            return
        }
        startRender(interactive:interactive)
    }
    /// Stops showing renders already under way (a new photo, or an AI step taking over).
    func cancelRenders() { renderGeneration = UUID(); renderQueued = false; renderInFlight = false }
    private func startRender(interactive:Bool) {
        guard let photo = renderedPhoto, let source = currentSource else { return }
        renderInFlight = true
        let generation = renderGeneration, edits = currentEdits
        let fullSize = editSourceSize()
        let logicalSize = EditGeometry(size:fullSize,edits:edits).extent.size
        let fullEdge = max(fullSize.width, fullSize.height), outputEdge = max(1, max(logicalSize.width, logicalSize.height))
        // The source limit that gives an output this many pixels on its longest edge (nil: full size).
        func sourceLimit(_ edge:CGFloat) -> Int? { let limit = edge*fullEdge/outputEdge; return limit >= fullEdge*0.98 ? nil : Int(limit.rounded(.up)) }
        let screen = CGFloat(ModernRenderer.screenEdge)
        // While a slider moves, frames are lighter (at most 1600 px); the release renders the full screen size.
        let baseEdge = min(interactive ? 1600 : screen, max(canvas.fitPixels(for:logicalSize), min(canvas.shownPixels, screen)))
        // Zoomed in past the whole-frame render: once the edit settles, render just the visible part at the zoom's resolution.
        var detailPlan: (limit:Int?, region:CGRect)?
        if !interactive, !canvas.isFit, canvas.shownPixels > baseEdge*1.05, let visible = canvas.visibleFraction {
            let margin = CGFloat(0.08)
            let region = visible.insetBy(dx:-visible.width*margin, dy:-visible.height*margin).intersection(CGRect(x:0,y:0,width:1,height:1))
            detailPlan = (sourceLimit(min(canvas.shownPixels, outputEdge)), region)
        }
        let linearSource = photo.sourceImage, original = photo
        var recipe = photoRecord?.active.recipe
        recipe?.edits = edits
        if recipe?.sourceMode == .raw { recipe = RenderRecipe(renderer:recipe!.renderer, sourceMode:.raw, raw:recipe!.raw, edits:edits) }
        // HDR edits show in extended range on HDR displays; elsewhere the SDR rendition is shown.
        let hdrPreview = edits.hdr.enabled && PhotoBackdrop.hdrAvailable
        var sdrEdits = edits; sdrEdits.hdrEnabled = false
        let baseLimit = sourceLimit(baseEdge)
        renderQueue.async { [weak self] in
            let result = Result { try autoreleasepool { () -> (CGImage, CGImage?, (image:CGImage, region:CGRect)?) in
                func render(_ limit:Int?) throws -> CIImage? {
                    if let recipe, recipe.renderer == .linear2020 { return try ModernRenderer.render(source:source, recipe:hdrPreview ? recipe:recipe.sdr, maximumDimension:limit, dragging:interactive) }
                    if let linearSource { return try ModernRenderer.process(linearSource, edits:hdrPreview ? edits:sdrEdits, maximumDimension:limit) }
                    return nil
                }
                guard let base = try render(baseLimit) else {
                    return (try PhotoEditor.render(original.image, edits:edits, previewMaxDimension:baseLimit), nil, nil)
                }
                let shown = hdrPreview ? try ModernRenderer.display(HDRTone.toneMapSDR(base)) : try ModernRenderer.display(base)
                let hdr = hdrPreview ? try ModernRenderer.displayHDR(base) : nil
                var detail: (image:CGImage, region:CGRect)?
                if let plan = detailPlan, !hdrPreview, let image = try render(plan.limit) {
                    let e = image.extent
                    let rect = CGRect(x:e.minX+plan.region.minX*e.width, y:e.minY+plan.region.minY*e.height, width:plan.region.width*e.width, height:plan.region.height*e.height).integral.intersection(e)
                    if rect.width >= 1, rect.height >= 1, let cg = try? ModernRenderer.display(image.cropped(to:rect)) {
                        detail = (cg, CGRect(x:(rect.minX-e.minX)/e.width, y:(rect.minY-e.minY)/e.height, width:rect.width/e.width, height:rect.height/e.height))
                    }
                }
                return (shown, hdr, detail)
            } }
            DispatchQueue.main.async {
                guard let self, self.renderGeneration == generation else { return }
                self.renderInFlight = false
                guard self.currentSource == source else { self.renderQueued = false; return }
                switch result {
                case .success(let (image, hdr, detail)):
                    self.canvas.replaceRenderedImage(image, pixelSize:logicalSize, detail:detail); self.canvas.hdrImage = hdr
                case .failure(let error): self.info.status(error.localizedDescription)
                }
                if self.renderQueued {
                    self.renderQueued = false
                    self.startRender(interactive:self.queuedInteractive)
                    return
                }
                guard case .success(let (image, _, _)) = result else { return }
                self.updateHistogram(image)
                self.refreshCompareExtras(image, interactive:interactive)
                guard !interactive else { return }
                // The edit has settled: the extras that only matter once it stops changing.
                self.refreshMaskOverlay()
                self.info.setLUTPhoto(original.preview, edits:edits, source:original.sourceImage, url:source, recipe:self.photoRecord?.active.recipe)
                self.info.status("Edited · \(Int(logicalSize.width)) × \(Int(logicalSize.height)) px · Original preserved")
            }
        }
    }
    /// Re-renders the sharp part after zooming or panning, once the view stops moving.
    func viewportSettled() {
        detailWork?.cancel()
        guard renderedPhoto != nil, !canvas.isFit else { return }
        let work = DispatchWorkItem { [weak self] in self?.renderEdits() }
        detailWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
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
        if name.hasPrefix("lr:") { lightroomCommand(name); return }
        if name.hasPrefix("studio:tool:") { if let t = StudioTool(rawValue: String(name.dropFirst(12))) { selectTool(t) }; return }
        if name.hasPrefix("lib:") { libraryCommand(name); return }
        if name.hasPrefix("maskLayer:") { maskLayerCommand(name); return }
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
        guard let source = currentSource, renderedPhoto != nil, !localAI.isRunning, !aiPreparing else { return }
        if comparing && name != "compare" { comparing = false; renderEdits() }
        if name.hasPrefix("mask:") { maskCommand(name); return }
        if name.hasPrefix("lensBlur:") { lensBlurCommand(name); return }
        if developM11Command(name) { return }
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
        case "previousSettings":
            // Lightroom's Previous: the last photo's settings, without its crop, retouching, lens and transform.
            guard let previous = previousEdits else { info.status("Edit another photo first. Previous copies its settings to this one."); return }
            do { changeEdits(try BatchEdits.merging(previous, into: edits, options: BatchOptions(), geometryCompatible: false), title: "Previous settings", commit: true) }
            catch { info.status(error.localizedDescription) }
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
        case "export": exportCurrent(source: source, edits: edits)
        case "horizon": alignHorizon()
        case "importLUT": importLUT()
        case "removeLUT": edits.ensureAdvanced(); edits.advanced!.lutAsset = nil; edits.advanced!.lutName = nil; edits.advanced!.lutID = nil; changeEdits(edits,title:"Remove LUT",commit:true)
        case "savePreset": savePreset()
        case "loadPreset": loadPreset()
        case "exportPreset": exportPreset()
        case "chooseSky":
            if studioPanels["presets"]?.isVisible != true { toggleFloatingPanel("presets") }
            info.showSkies()
        case "customSky": customSky()
        case "skyFlip": if var sky = edits.sky { sky.flip.toggle(); edits.sky = sky; changeEdits(edits, title: "Flip sky", commit: true) }
        case "removeSky": edits.sky = nil; changeEdits(edits, title: "Remove sky", commit: true)
        default:
            if name.hasPrefix("preset:"), let preset = info.preset(named:String(name.dropFirst(7))) { applyPreset(preset,amount:1) }
            if name.hasPrefix("sky:"), let sky = info.sky(id: String(name.dropFirst(4))) { applySky(sky) }
            if name.hasPrefix("applyPreset:") {
                let parts = name.dropFirst(12).split(separator:":",maxSplits:1).map(String.init)
                if parts.count == 2, let amount = Double(parts[0]), let preset = info.preset(id:parts[1]) { applyPreset(preset,amount:amount) }
            }
            if name.hasPrefix("profile:") || name.hasPrefix("rawOptions:") || name == "importDCP" { profileCommand(name) }
            if name.hasPrefix("upright:") || ["resetTransform","clearGuides","autoStraighten"].contains(name) { transformCommand(name) }
            if name.hasPrefix("ai:") { runAI(String(name.dropFirst(3))) }
        }
    }
    private func chooseImage(title: String, completion: @escaping (URL) -> Void) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel(); panel.title = title; panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in if response == .OK, let url = panel.url { completion(url) } }
    }
    /// Applies a preset; changing its Amount re-applies it to the edit it started from, while nothing else has changed since.
    private func applyPreset(_ preset: PresetRecipe, amount: Double) {
        var base = currentEdits
        if let last = lastPreset, last.id == preset.id, last.result == currentEdits { base = last.baseline }
        do {
            let result = try preset.apply(to: base, amount: amount, library: info.lutLibrary)
            changeEdits(result, title: "Preset · " + preset.name + (amount == 1 ? "" : " \(Int((amount*100).rounded()))%"), commit: true)
            lastPreset = (preset.id, base, currentEdits)
        } catch { info.status("Couldn’t apply this preset: " + error.localizedDescription) }
    }
    /// Puts a new sky in: the first time, on-device AI finds this photo's sky and keeps it as the "Sky" mask.
    private func applySky(_ sky: SkyItem) {
        func apply(_ base: PhotoEdits) {
            do { changeEdits(try sky.applying(to: base), title: "Sky · " + sky.entry.name, commit: true); info.status("Sky: \(sky.entry.name). Adjust Relight scene to change how much the photo follows it.") }
            catch { info.status("Couldn’t use this sky: " + error.localizedDescription) }
        }
        if currentEdits.advanced?.masks[PhotoEdits.skyMaskKey] != nil { apply(currentEdits); return }
        let source = currentSource
        workerMask("skymask", title: "Sky") { [weak self] mask in
            guard let self, self.currentSource == source else { return }
            var edits = self.currentEdits; edits.setMask(mask, for: PhotoEdits.skyMaskKey)
            apply(edits)
        }
    }
    /// Adds a sky photo of your own to Your Skies and puts it in.
    private func customSky() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel(); panel.title = "Choose a sky photo"; panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let sky = try SkyLibrary.importSky(url, into: LookBrowserView.userSkies)
                self.info.refreshSkies(); self.applySky(sky)
            } catch { self.info.status("Couldn’t read this photo. \(error.localizedDescription)") }
        }
    }
    /// Saves the current edit (without crop, masks, retouching or the photo's look file) to My Presets.
    private func savePreset() {
        guard let window = view.window else { return }
        let alert = NSAlert(); alert.messageText = "Save current as preset"; alert.informativeText = "Saves tone, color and effects to My Presets. Crop, masks, retouching and AI results stay with this photo."
        let field = NSTextField(string: "My preset"); field.frame = NSRect(x: 0, y: 0, width: 280, height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        let edits = currentEdits
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            do { try PresetLibrary.save(edits, name: name, in: LookBrowserView.userPresets); self.info.presetSaved(name); self.info.status("Saved to My Presets: \(name).") }
            catch { self.info.status(error.localizedDescription) }
        }
    }
    /// Copies a `.openstillpreset` into My Presets and applies it.
    private func loadPreset() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel(); panel.title = "Import preset"; panel.allowedContentTypes = [UTType(filenameExtension: PresetLibrary.fileExtension) ?? .json, .json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let saved = try PresetLibrary.importPreset(url, into: LookBrowserView.userPresets)
                let name = saved.deletingPathExtension().lastPathComponent
                self.info.presetSaved(name)
                if let preset = self.info.preset(id: "user-" + name) { self.applyPreset(preset, amount: 1) }
            } catch { self.info.status("Couldn’t read this preset. \(error.localizedDescription)") }
        }
    }
    /// Writes the current edit as a `.openstillpreset` file to share.
    private func exportPreset() {
        guard let window = view.window else { return }
        let preset = PresetRecipe.snapshot(of: currentEdits)
        let panel = NSSavePanel(); panel.title = "Export preset"; panel.nameFieldStringValue = "My preset." + PresetLibrary.fileExtension; panel.allowedContentTypes = [UTType(filenameExtension: PresetLibrary.fileExtension) ?? .json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try JSONEncoder().encode(preset).write(to: url, options: .atomic); self?.info.status("Preset exported.") }
            catch { self?.info.status(error.localizedDescription) }
        }
    }
    private func exportCurrent(source: URL, edits: PhotoEdits) {
        guard var record=photoRecord else{info.status("Open a photo with a saved edit record before exporting.");return}
        var document=record.active.document;document.commit(edits,title:"Export snapshot");record.updateDocument(document)
        let item=ShootItem(url:source,record:record,captured:(try? ShootItem.read(source).captured) ?? Date.distantPast)
        let panel=ExportPanel(items:[item]);exportPanel=panel;panel.showWindow(nil);panel.window?.makeKeyAndOrderFront(nil)
    }
    private func setupAI() {
        guard !localAI.isRunning, !aiPreparing else { return }
        let missing = LocalAI.missingModels
        info.status(missing.isEmpty ? "Setting up on-device AI. Downloading about 450 MB of models…" : "Downloading new AI models: " + missing.joined(separator: ", ") + "…", busy: true)
        localAI.run(tool: "setup", status: { [weak self] text in self?.info.status(text, busy: true) }) { [weak self] result in
            switch result {
            case .success: self?.info.status("On-device AI is ready. Photos stay on this Mac.")
            case .failure(let error): self?.info.status(error.localizedDescription)
            }
        }
    }
    private func runAI(_ tool: String) {
        guard let source = currentSource, renderedPhoto != nil, !localAI.isRunning, !aiPreparing else { return }
        guard LocalAI.ready else { info.status("Choose Set up on-device AI first (one-time download, about 450 MB)."); return }
        let keys = ["erase":"Erase", "denoise":"Noise removal", "detail":"Detail restoration", "upscale":"Super resolution", "rawdenoise":"Noise removal"]
        guard let key = keys[tool] else { return }
        let edits = currentEdits, size = editSourceSize()
        let adjustmentMask = edits.advanced?.masks[key]
        let legacyMask = tool == "erase" && adjustmentMask == nil ? canvas.image.flatMap { canvas.removalMask(width:$0.width,height:$0.height) } : nil
        if tool == "erase", adjustmentMask == nil, legacyMask == nil { info.status("Create an Erase mask over the unwanted object first."); return }
        let renderer = photoRecord?.active.renderer ?? .legacy
        let sourceMode = photoRecord?.active.sourceMode ?? .original
        let rawSettings = photoRecord?.active.raw ?? RawSettings()
        if tool == "rawdenoise" && sourceMode != .raw { info.status("RAW denoise works on photos developed from RAW. Use Remove noise for other photos."); return }
        if tool == "rawdenoise" && edits.baseAsset != nil { info.status("This version already has an AI result. Start from a version without one to denoise the RAW data."); return }
        aiPreparing = true; cancelRenders(); editToken = UUID()
        let token = editToken
        info.status("Preparing full-resolution photo for on-device AI…", busy: true)
        editQueue.async { [weak self] in
            var temporaryFiles: [URL] = []
            let prepared = Result { () -> (URL, URL, URL?) in
                let input = try EditStorage.newAsset(extension:"osfloat"); temporaryFiles.append(input)
                // RAW denoise works on the decoded sensor data only (white balance and RAW options), so every edit stays adjustable.
                let recipe = RenderRecipe(renderer:renderer, sourceMode:sourceMode, raw:rawSettings, edits:tool == "rawdenoise" ? RawDenoiseBase.decodeOnly(edits) : edits)
                let incoming=try ModernRenderer.render(source:source, recipe:recipe)
                try FloatImageBridge.write(incoming, to:input)
                let output = try EditStorage.newAsset(extension:"osfloat")
                var maskURL: URL?
                var maskImage = legacyMask
                if let adjustmentMask {
                    let geometry = EditGeometry(size:size,edits:edits)
                    let selection = try adjustmentMask.coverage(geometry:geometry,lens:edits.optics,input:incoming,modern:renderer == .linear2020)
                    guard let cg = RenderContexts.utility.createCGImage(selection,from:geometry.extent) else { throw EditError.render }
                    maskImage = cg
                }
                if let maskImage { maskURL = try EditStorage.newAsset(); temporaryFiles.append(maskURL!); try PhotoEditor.write(maskImage,to:maskURL!) }
                return (input,output,maskURL)
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
                case .success(let (input,output,maskURL)):
                    var arguments = ["--input",input.path,"--output",output.path]
                    let workerTool = tool == "rawdenoise" ? "denoise" : tool
                    if tool == "erase", let maskURL { arguments += ["--mask",maskURL.path] }
                    self.info.status("Running local \(tool)… You can cancel below.",busy:true)
                    self.localAI.run(tool:workerTool,arguments:arguments,status: { [weak self] text in
                        guard self?.currentSource == source else { return }; self?.info.status(text,busy:true)
                    }) { [weak self] result in
                        try? FileManager.default.removeItem(at:output.deletingPathExtension().appendingPathExtension("mask.png"))
                        guard let self, self.currentSource == source, self.editToken == token else {
                            for file in [input,output,maskURL].compactMap({$0}) { try? FileManager.default.removeItem(at:file) }; return
                        }
                        self.info.status("Local processing finished.")
                        switch result {
                        case .success:
                            if self.photoRecord?.active.renderer == .legacy { self.photoRecord?.upgrade(); self.editDocument = self.photoRecord!.active.document }
                            if tool == "rawdenoise" {
                                // Keep every edit live on top of the denoised sensor data.
                                try? FileManager.default.removeItem(at:input)
                                var next = self.currentEdits; next.baseAsset = output.lastPathComponent; next.ensureAdvanced()
                                next.advanced!.rawDenoise = RawDenoiseBase(temperature:edits.temperature, tint:edits.tint)
                                self.maskVisible = false; self.canvas.clearTool(); self.changeEdits(next,title:"AI RAW denoise",commit:true); self.select(self.selected, preservingSelection:true)
                                return
                            }
                            if tool == "upscale" {
                                // A new version at twice the size; the current version is kept as it was.
                                try? FileManager.default.removeItem(at:input)
                                guard var record = self.photoRecord else { return }
                                record.duplicateVersion(named:"Super resolution 2×")
                                var next = PhotoEdits(); next.baseAsset = output.lastPathComponent
                                var document = EditDocument(fingerprint:record.active.document.fingerprint); document.commit(next,title:"AI super resolution 2×")
                                record.updateDocument(document)
                                self.maskVisible = false; self.canvas.clearTool(); self.saveVersionRecord(record)
                                self.info.status("Created the version “Super resolution 2×” at twice the size. The previous version is unchanged.")
                                return
                            }
                            var next = PhotoEdits(); next.baseAsset = output.lastPathComponent; next.ensureAdvanced()
                            next.advanced!.aiBackgroundAsset = input.lastPathComponent; next.advanced!.aiFeatureKey = key
                            if let maskURL {
                                var mask = AdjustmentMask(kind:"object"); mask.asset = maskURL.lastPathComponent; mask.feather = 0
                                next.setMask(mask,for:key)
                            }
                            let names = ["erase":"AI object removal", "denoise":"AI noise removal", "detail":"AI detail restoration"]
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
