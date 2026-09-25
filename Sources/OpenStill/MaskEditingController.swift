import AppKit
import CoreImage
import ImageIO
import OpenStillCore
import UniformTypeIdentifiers

extension ViewerController {
    func finishMaskEditing() {
        let cancelledSelection = maskSession.end()
        maskVisible = false; maskToken = UUID(); maskSubtract = false
        canvas.maskOverlay = nil
        if [.maskBrush,.maskLinear,.maskRadial,.maskObject,.maskRange,.retouch,.retouchSource].contains(canvas.tool) { canvas.clearTool() }
        info.resetMaskInteractions()
        if cancelledSelection {
            editToken = UUID(); aiPreparing = false
            info.status("Object selection cancelled. Each tool keeps its own mask.")
            renderEdits()
        }
    }
    func editSourceSize(_ edits: PhotoEdits? = nil) -> CGSize {
        let edits = edits ?? currentEdits
        if let asset = edits.baseAsset, asset.hasSuffix(".osfloat"), let image = try? ModernRenderer.readImage(EditStorage.asset(asset)) { return image.extent.size }
        if let asset = edits.baseAsset,
           let io = CGImageSourceCreateWithURL(EditStorage.asset(asset) as CFURL,nil),
           let props = CGImageSourceCopyPropertiesAtIndex(io,0,nil) as? [CFString:Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int { return CGSize(width:w,height:h) }
        return CGSize(width:renderedPhoto?.image.width ?? 1,height:renderedPhoto?.image.height ?? 1)
    }
    func setEditingMask(_ shape:AdjustmentMask,for key:String,in edits:inout PhotoEdits) {
        var root=edits.advanced?.masks[key] ?? AdjustmentMask(kind:"stack")
        if edits.advanced?.masks[key] == nil {root.components=[]}
        var component=root.component(info.selectedMaskComponent(key:key)) ?? MaskComponent(name:"Mask 1",selection:shape)
        component.selection=shape;root.updateComponent(component);edits.setMask(root,for:key)
    }
    func sampleMaskRange(at point:CGPoint) {
        guard let key=activeMaskKey,let source=currentSource,var recipe=photoRecord?.active.recipe,
              var shape=currentEdits.advanced?.masks[key]?.component(info.selectedMaskComponent(key:key))?.selection,
              shape.kind == "colorRange" || shape.kind == "luminanceRange" else{return}
        let component=info.selectedMaskComponent(key:key),token=editToken
        recipe.edits=currentEdits
        info.status("Sampling this tool’s input…")
        editQueue.async { [weak self] in
            let result=Result { () -> RangeSelection in
                let input=try ModernRenderer.render(source:source,recipe:recipe,maximumDimension:1600,stopBeforeTool:key)
                let x=input.extent.width*point.x,y=input.extent.height*point.y
                let region=CGRect(x:x-2,y:y-2,width:5,height:5).intersection(input.extent)
                let average=input.applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:region)])
                var rgba=[Float](repeating:0,count:4)
                ModernRenderer.context.render(average,toBitmap:&rgba,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
                var range=shape.range ?? RangeSelection()
                range.red=Double(rgba[0]);range.green=Double(rgba[1]);range.blue=Double(rgba[2])
                let light=range.red*0.2126+range.green*0.7152+range.blue*0.0722
                range.low=max(0,light-0.1);range.high=min(1,light+0.1);return range.sanitized
            }
            DispatchQueue.main.async {
                guard let self,self.editToken==token,self.currentSource==source,self.activeMaskKey==key,self.info.selectedMaskComponent(key:key)==component else{return}
                switch result {
                case .success(let range):shape.range=range;var next=self.currentEdits;self.setEditingMask(shape,for:key,in:&next);self.maskVisible=true;self.changeEdits(next,title:key+" · Sample range",commit:true);self.info.maskInteraction(key:key,kind:nil,subtract:false,visible:true)
                case .failure(let error):self.info.status(error.localizedDescription)
                }
            }
        }
    }
    func maskCommand(_ name: String) {
        let parts = name.split(separator:":").map(String.init)
        guard parts.count == 3 else { return }
        let key = parts[1], command = parts[2]
        let wasVisible = maskVisible && activeMaskKey == key
        if activeMaskKey != key { finishMaskEditing(); maskSession.activate(key) }
        var edits = currentEdits
        switch command {
        case "componentChanged":
            finishMaskEditing();maskSession.activate(key);maskVisible=edits.advanced?.masks[key] != nil;refreshMaskOverlay()
        case "sampleRange":
            finishMaskEditing();maskSession.activate(key);canvas.tool = .maskRange;info.status("Click a color or tone to select. The sample excludes this tool’s own adjustment.")
        case "clear":
            edits.setMask(nil,for:key); maskVisible = false; maskToken = UUID(); canvas.clearTool()
            changeEdits(edits,title:key+" · Clear mask",commit:true)
        case "done": finishMaskEditing(); info.status("Mask saved for \(key). Adjust the sliders to edit the selected area.")
        case "show":
            guard edits.advanced?.masks[key] != nil else { info.status("Create a mask for \(key) first."); return }
            maskVisible = !wasVisible; refreshMaskOverlay()
        case "invert":
            guard var mask = edits.advanced?.masks[key] else { info.status("Create a mask for \(key) first."); return }
            mask.inverted.toggle(); edits.setMask(mask,for:key); maskVisible = true
            changeEdits(edits,title:key+" · Invert mask",commit:true)
        case "small", "medium", "large":
            maskRadius = command == "small" ? 0.012 : (command == "large" ? 0.065 : 0.025)
            activateMaskTool("brush",key:key)
        case "paint", "erase": maskSubtract = command == "erase";activateMaskTool("brush",key:key,resetSubtract:false)
        case "subtract": maskSubtract.toggle(); activateMaskTool("brush",key:key,resetSubtract:false)
        default: activateMaskTool(command,key:key)
        }
        let kind: String? = [PhotoCanvas.Tool.maskBrush:"brush",.maskLinear:"linear",.maskRadial:"radial",.maskObject:"object"][canvas.tool]
        info.maskInteraction(key:key,kind:kind,subtract:maskSubtract,visible:maskVisible)
    }
    private func activateMaskTool(_ kind: String, key:String, resetSubtract:Bool = true) {
        let tools: [String:PhotoCanvas.Tool] = ["brush":.maskBrush,"linear":.maskLinear,"radial":.maskRadial,"object":.maskObject]
        guard let tool = tools[kind] else { return }
        canvas.clearTool(); canvas.tool = tool; maskSession.activate(key); maskVisible = true
        if resetSubtract { maskSubtract = false }
        canvas.maskRadius = maskRadius; canvas.maskSoftness = maskSoftness; canvas.maskSubtract = maskSubtract
        let existing = currentEdits.advanced?.masks[key]?.component(info.selectedMaskComponent(key:key))?.selection
        canvas.maskFeather = existing?.kind == kind ? existing!.feather : (kind == "linear" ? 1 : 0.3)
        canvas.maskInverted = existing?.kind == kind ? existing!.inverted : false
        let instructions: String
        switch kind {
        case "brush": instructions = maskSubtract ? "Brush to subtract from the mask. Choose Paint to add again." : "Brush over the area to adjust. Each stroke is saved."
        case "linear": instructions = "Drag from the unaffected side toward the fully adjusted side. The red gradient previews the fade."
        case "radial": instructions = "Drag from the center outward to draw an ellipse."
        default: instructions = "Click inside a foreground object to select it locally on your Mac."
        }
        info.status(key+" · "+instructions); refreshMaskOverlay(); view.window?.makeFirstResponder(canvas)
    }
    func drawAdjustmentMask(_ points:[CGPoint], kind:String) {
        guard let key = activeMaskKey, !aiPreparing, !localAI.isRunning, let first = points.first, let last = points.last else { return }
        let expected: [String:PhotoCanvas.Tool] = ["brush":.maskBrush,"linear":.maskLinear,"radial":.maskRadial]
        guard expected[kind] == canvas.tool else { return }
        let geometry = EditGeometry(size:editSourceSize(),edits:currentEdits)
        var mask = currentEdits.advanced?.masks[key]?.component(info.selectedMaskComponent(key:key))?.selection ?? AdjustmentMask(kind:kind)
        if mask.kind != kind && kind != "brush" { mask = AdjustmentMask(kind:kind) }
        if kind == "brush" {
            // Preserve brush radius in source pixels through crop/straighten/rotation.
            let scale = hypot(geometry.transform.a,geometry.transform.b)
            let radius = maskRadius*min(geometry.extent.width,geometry.extent.height)/(max(0.001,scale)*min(geometry.sourceSize.width,geometry.sourceSize.height))
            var stroke = MaskStroke(points:points.map { MaskPoint(LensCorrections.sourcePoint(geometry.sourcePoint($0),size:geometry.sourceSize,settings:currentEdits.lens)) },radius:radius,subtract:maskSubtract != mask.inverted)
            stroke.softness = maskSoftness;stroke.strength = maskStrength
            if mask.strokes.isEmpty && mask.kind == "brush" { mask.feather = 0 }
            mask.strokes.append(stroke)
        } else {
            guard hypot(last.x-first.x,last.y-first.y) > 0.005 else { info.status("Drag a larger mask on the photo."); return }
            mask.strokes = []; mask.start = MaskPoint(LensCorrections.sourcePoint(geometry.sourcePoint(first),size:geometry.sourceSize,settings:currentEdits.lens)); mask.end = MaskPoint(LensCorrections.sourcePoint(geometry.sourcePoint(last),size:geometry.sourceSize,settings:currentEdits.lens))
        }
        var edits = currentEdits; setEditingMask(mask,for:key,in:&edits)
        changeEdits(edits,title:key+" · "+kind.capitalized+" mask",commit:true)
    }
    func refreshMaskOverlay() {
        let token = UUID(); maskToken = token
        guard maskVisible, !comparing, let key = activeMaskKey, let mask = currentEdits.advanced?.masks[key] else { canvas.maskOverlay = nil; return }
        if canvas.tool == .maskLinear,let shape=mask.component(info.selectedMaskComponent(key:key))?.selection,shape.kind == "linear" { canvas.maskFeather=shape.feather;canvas.maskInverted=shape.inverted }
        let edits = currentEdits, sourceSize = editSourceSize()
        guard let source=currentSource,var recipe=photoRecord?.active.recipe else{return}
        recipe.edits=edits
        editQueue.async { [weak self] in
            let result = try? autoreleasepool { () -> CGImage? in
                let scale = min(1,1200/max(sourceSize.width,sourceSize.height))
                let size = CGSize(width:(sourceSize.width*scale).rounded(),height:(sourceSize.height*scale).rounded())
                let geometry = EditGeometry(size:size,edits:edits)
                let input=try ModernRenderer.render(source:source,recipe:recipe,maximumDimension:1200,stopBeforeTool:key)
                let selection=try mask.coverage(geometry:geometry,lens:edits.lens,input:input,modern:recipe.renderer == .linear2020)
                let overlay = CIImage(color:CIColor(red:1,green:0.08,blue:0.08,alpha:0.42)).cropped(to:geometry.extent)
                    .applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:CIImage(color:.clear).cropped(to:geometry.extent),kCIInputMaskImageKey:selection])
                return CIContext().createCGImage(overlay,from:geometry.extent)
            }
            DispatchQueue.main.async { guard let self, self.maskToken == token, self.activeMaskKey == key, self.maskVisible else { return }; self.canvas.maskOverlay = result ?? nil }
        }
    }
    func selectMaskObject(at displayed:CGPoint) {
        guard canvas.tool == .maskObject, let key = activeMaskKey, let original = renderedPhoto?.image, let source = currentSource, !aiPreparing, !localAI.isRunning else { return }
        let edits = currentEdits, geometry = EditGeometry(size:editSourceSize(),edits:currentEdits)
        let selection = maskSession.beginSelection()
        let componentID=info.selectedMaskComponent(key:key)
        let point = LensCorrections.sourcePoint(geometry.sourcePoint(displayed),size:geometry.sourceSize,settings:edits.lens), token = UUID(); editToken = token; editWork?.cancel(); aiPreparing = true
        info.status("Selecting the object on this Mac…",busy:true)
        editQueue.async { [weak self] in
            let result = Result { () -> URL in
                let base = try edits.baseAsset.map { try PhotoDecoder.decode(EditStorage.asset($0)) } ?? original
                let scale = min(1,1600/Double(max(base.width,base.height)))
                let ci = CIImage(cgImage:base).transformed(by:CGAffineTransform(scaleX:scale,y:scale))
                guard let small = CIContext().createCGImage(ci,from:ci.extent) else { throw EditError.render }
                let mask = try VisionEditor.objectMask(small,at:point)
                let asset = try EditStorage.newAsset(); try PhotoEditor.write(mask,to:asset); return asset
            }
            DispatchQueue.main.async {
                guard let self, self.editToken == token, self.currentSource == source, self.maskSession.accepts(selection,for:key),self.info.selectedMaskComponent(key:key)==componentID else { if case .success(let asset) = result { try? FileManager.default.removeItem(at:asset) }; return }
                self.maskSession.completeSelection(selection)
                self.aiPreparing = false; self.info.status("Object selected.")
                switch result {
                case .success(let asset):
                    var mask = AdjustmentMask(kind:"object"); mask.asset = asset.lastPathComponent; mask.feather = 0.1
                    var next = self.currentEdits; self.setEditingMask(mask,for:key,in:&next); self.maskVisible = true
                    self.changeEdits(next,title:key+" · AI object mask",commit:true)
                case .failure(let error): self.info.status(error.localizedDescription)
                }
            }
        }
    }
    func alignHorizon() {
        guard let original = renderedPhoto?.image, let source = currentSource else { return }
        let edits = currentEdits, token = UUID(); editToken = token; editWork?.cancel(); aiPreparing = true
        info.status("Looking for the horizon on this Mac…",busy:true)
        editQueue.async { [weak self] in
            let result = Result { () -> Double in
                let current = try PhotoEditor.render(original,edits:edits)
                return try VisionEditor.horizon(current)
            }
            DispatchQueue.main.async {
                guard let self, self.editToken == token, self.currentSource == source else { return }
                self.aiPreparing = false; self.info.status("Horizon aligned.")
                switch result {
                case .success(let angle):
                    var next = self.currentEdits; next.straighten = min(20,max(-20,next.straighten+angle)); self.maskVisible = false; self.canvas.clearTool()
                    self.changeEdits(next,title:"AI horizon alignment",commit:true)
                case .failure(let error): self.info.status(error.localizedDescription)
                }
            }
        }
    }
    func applyLibraryLUT(_ item:LUTItem) {
        do { changeEdits(try item.applying(to:currentEdits),title:"LUT · "+item.entry.name,commit:true) }
        catch { info.status("Couldn’t apply this LUT: "+error.localizedDescription) }
    }
    func applyLUT(_ filename:String) {
        guard let item = info.importedLUT(filename:filename) else { info.status("This imported LUT is no longer available.");return }
        applyLibraryLUT(item)
    }
    func importLUT() {
        guard let window = view.window, let source = currentSource else { return }
        let panel = NSOpenPanel(); panel.title = "Import a 3D .cube LUT"; panel.allowedContentTypes = [UTType(filenameExtension:"cube") ?? .data]
        panel.beginSheetModal(for:window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url, self.currentSource == source else { return }
            do {
                _ = try CubeLUT.load(url)
                let folder = EditStorage.root.appendingPathComponent("LUTLibrary"); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                var target = folder.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath:target.path) { target = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent+"-"+UUID().uuidString.prefix(6)+".cube") }
                try FileManager.default.copyItem(at:url,to:target); self.info.refreshLUTs(); self.applyLUT(target.lastPathComponent)
            } catch { self.info.status(error.localizedDescription) }
        }
    }
}
