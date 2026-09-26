import AppKit
import CoreImage
import OpenStillCore

/// AI mask components (Vision, plus the local AI worker for sky and depth) and Lens Blur depth sources.
extension ViewerController {
    /// The photo as the mask assets see it: the current base image (after any AI edit), upright, at most `maximum` pixels.
    private func aiBaseImage(_ edits: PhotoEdits, original: CGImage, maximum: Double = 2048) throws -> CGImage {
        let base = try edits.baseAsset.map { name -> CGImage in
            if name.hasSuffix(".osfloat") { let image = try ModernRenderer.readImage(EditStorage.asset(name)); guard let cg = ModernRenderer.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw EditError.render }; return cg }
            return try PhotoDecoder.decode(EditStorage.asset(name))
        } ?? original
        let scale = min(1, maximum / Double(max(base.width, base.height)))
        guard scale < 1 else { return base }
        let ci = CIImage(cgImage: base).applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        guard let small = ModernRenderer.context.createCGImage(ci, from: ci.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw EditError.render }
        return small
    }
    private func saveMask(_ image: CGImage) throws -> String {
        let asset = try EditStorage.newAsset(); try PhotoEditor.write(image, to: asset); return asset.lastPathComponent
    }

    /// "ai.subject", "ai.person.2", "ai.depth" … from a tool's mask panel: adds a new, selected mask component.
    func aiMaskCommand(_ command: String, key: String) {
        guard let original = renderedPhoto?.image, let source = currentSource, !aiPreparing, !localAI.isRunning else { return }
        let parts = command.split(separator: ".").map(String.init)
        guard parts.count >= 2, let kind = AIMaskKind(rawValue: parts[1]) else { return }
        let index = parts.count > 2 ? (Int(parts[2]) ?? 1) - 1 : 0
        let title = kind == .person ? "Person \(index + 1)" : kind.title
        if kind == .sky { runWorkerMask("skymask", title: title, key: key); return }
        if kind == .depth { makeDepthMap(preferAI: true) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let asset):
                var mask = AdjustmentMask(kind: "depthRange"); mask.asset = asset; mask.feather = 0
                var range = RangeSelection(); range.low = 0.5; range.high = 1; range.softness = 0.1; mask.range = range
                self.addMaskComponent(mask, title: "Depth range", key: key)
                self.info.status("Depth range selected: nearer half of the scene. Adjust the luminance bounds to move the band (white = near).")
            case .failure(let error): self.info.status(error.localizedDescription)
            }
        }; return }
        let edits = currentEdits, token = UUID(); editToken = token; aiPreparing = true
        info.status("Selecting \(title.lowercased()) on this Mac…", busy: true)
        editQueue.async { [weak self] in
            let result = Result { () -> String in
                guard let self else { throw EditError.render }
                let image = try self.aiBaseImage(edits, original: original)
                let mask: CGImage
                switch kind {
                case .subject: mask = try AIMasks.subject(image)
                case .background: mask = try AIMasks.background(image)
                case .people: mask = try AIMasks.people(image)
                case .person: mask = try AIMasks.person(image, index: index)
                case .face: mask = try AIMasks.face(image, part: .face)
                case .eyes: mask = try AIMasks.face(image, part: .eyes)
                case .eyebrows: mask = try AIMasks.face(image, part: .eyebrows)
                case .lips: mask = try AIMasks.face(image, part: .lips)
                case .skin: mask = try AIMasks.skin(image)
                case .sky, .depth: throw EditError.render
                }
                return try self.saveMask(mask)
            }
            DispatchQueue.main.async {
                guard let self, self.editToken == token, self.currentSource == source else { return }
                self.aiPreparing = false
                switch result {
                case .success(let asset):
                    var mask = AdjustmentMask(kind: "object"); mask.asset = asset; mask.feather = 0.05
                    self.addMaskComponent(mask, title: title, key: key)
                    self.info.status("\(title) selected. Combine it with other components, or invert it, in the mask panel.")
                case .failure(let error): self.info.status(error.localizedDescription)
                }
            }
        }
    }
    private func addMaskComponent(_ selection: AdjustmentMask, title: String, key: String) {
        var edits = currentEdits
        var root = edits.advanced?.masks[key] ?? AdjustmentMask(kind: "stack")
        if edits.advanced?.masks[key] == nil { root.components = [] }
        let component = MaskComponent(name: title, selection: selection)
        root.updateComponent(component); edits.setMask(root, for: key)
        changeEdits(edits, title: key + " · AI mask · " + title, commit: true)
        info.selectMaskComponent(key: key, id: component.id)
        maskSession.activate(key); maskVisible = true; refreshMaskOverlay()
    }

    /// Runs a mask-producing tool of the local AI worker on the base image and adds the result as a component.
    private func runWorkerMask(_ tool: String, title: String, key: String) {
        guard LocalAI.ready else { info.status("Sky selection uses the local AI tools. Choose Set up local AI tools first."); return }
        guard let original = renderedPhoto?.image, let source = currentSource else { return }
        let edits = currentEdits
        do {
            let input = try EditStorage.newAsset(), output = try EditStorage.newAsset()
            try PhotoEditor.write(try aiBaseImage(edits, original: original, maximum: 3072), to: input)
            info.status("Selecting \(title.lowercased()) with local AI…", busy: true)
            localAI.run(tool: tool, arguments: ["--input", input.path, "--output", output.path], status: { [weak self] text in self?.info.status(text, busy: true) }) { [weak self] result in
                try? FileManager.default.removeItem(at: input)
                guard let self, self.currentSource == source else { try? FileManager.default.removeItem(at: output); return }
                switch result {
                case .success:
                    var mask = AdjustmentMask(kind: "object"); mask.asset = output.lastPathComponent; mask.feather = 0.03
                    self.addMaskComponent(mask, title: title, key: key); self.info.status("\(title) selected.")
                case .failure(let error): try? FileManager.default.removeItem(at: output); self.info.status(error.localizedDescription)
                }
            }
        } catch { info.status(error.localizedDescription) }
    }

    /// A depth map asset (near = white): the photo's own depth data, else the local AI estimate when available.
    private func makeDepthMap(preferAI: Bool, completion: @escaping (Result<String, Error>) -> Void) {
        guard let original = renderedPhoto?.image, let source = currentSource else { return }
        let edits = currentEdits
        editQueue.async { [weak self] in
            guard let self else { return }
            let embedded = Result { () -> String? in
                guard edits.baseAsset == nil else { return nil }   // depth data matches the original, not an AI-edited base
                let size = CGSize(width: original.width, height: original.height)
                return try AIMasks.embeddedDepth(source, size: size).map { try self.saveMask($0) }
            }
            DispatchQueue.main.async {
                if case .success(let asset?) = embedded { completion(.success(asset)); return }
                guard preferAI, LocalAI.ready, LocalAI.hasModel("depth") else { completion(.failure(AIMaskError.noDepth)); return }
                self.runWorkerDepth(edits: edits, original: original, source: source, completion: completion)
            }
        }
    }
    private func runWorkerDepth(edits: PhotoEdits, original: CGImage, source: URL, completion: @escaping (Result<String, Error>) -> Void) {
        do {
            let input = try EditStorage.newAsset(), output = try EditStorage.newAsset()
            try PhotoEditor.write(try aiBaseImage(edits, original: original, maximum: 2048), to: input)
            info.status("Estimating depth with local AI…", busy: true)
            localAI.run(tool: "depth", arguments: ["--input", input.path, "--output", output.path], status: { [weak self] text in self?.info.status(text, busy: true) }) { [weak self] result in
                try? FileManager.default.removeItem(at: input)
                guard self?.currentSource == source else { try? FileManager.default.removeItem(at: output); return }
                switch result {
                case .success: completion(.success(output.lastPathComponent))
                case .failure(let error): try? FileManager.default.removeItem(at: output); completion(.failure(error))
                }
            }
        } catch { completion(.failure(error)) }
    }

    /// Lens blur: "lensBlur:camera", "lensBlur:ai", "lensBlur:subject", "lensBlur:remove".
    func lensBlurCommand(_ name: String) {
        guard let original = renderedPhoto?.image, let source = currentSource, !aiPreparing, !localAI.isRunning else { return }
        let choice = String(name.dropFirst("lensBlur:".count))
        func apply(_ asset: String, _ origin: String, _ message: String) {
            var edits = currentEdits; var blur = edits.lensBlur
            blur.depthAsset = asset; blur.depthSource = origin
            if blur.amount == 0 { blur.amount = 0.5 }
            if origin == "subject" { blur.focus = 1; blur.range = 0.3 }
            edits.lensBlur = blur
            changeEdits(edits, title: "Lens blur · depth", commit: true); info.status(message)
        }
        switch choice {
        case "remove":
            var edits = currentEdits; edits.lensBlur = LensBlurSettings(); changeEdits(edits, title: "Remove lens blur", commit: true)
        case "camera", "ai":
            if choice == "ai" && !(LocalAI.ready && LocalAI.hasModel("depth")) { info.status("Depth estimation uses the local AI tools. Choose Set up local AI tools (it downloads the depth model), then try again."); return }
            aiPreparing = true
            let finish: (Result<String, Error>) -> Void = { [weak self] result in
                guard let self, self.currentSource == source else { return }
                self.aiPreparing = false
                switch result {
                case .success(let asset): apply(asset, choice == "camera" ? "camera" : "ai", "Lens blur uses the depth map. Set Focus distance to what should stay sharp (1 = nearest).")
                case .failure(let error): self.info.status(error.localizedDescription)
                }
            }
            if choice == "camera" {
                let edited = currentEdits.baseAsset != nil
                editQueue.async { [weak self] in
                    let result = Result { () -> String in
                        guard let self, !edited, let depth = AIMasks.embeddedDepth(source, size: CGSize(width: original.width, height: original.height)) else { throw AIMaskError.noDepth }
                        return try self.saveMask(depth)
                    }
                    DispatchQueue.main.async { finish(result) }
                }
            } else { runWorkerDepth(edits: currentEdits, original: original, source: source, completion: finish) }
        case "subject":
            let edits = currentEdits, token = UUID(); editToken = token; aiPreparing = true
            info.status("Finding the subject on this Mac…", busy: true)
            editQueue.async { [weak self] in
                let result = Result { () -> String in
                    guard let self else { throw EditError.render }
                    return try self.saveMask(AIMasks.subjectDepth(try self.aiBaseImage(edits, original: original)))
                }
                DispatchQueue.main.async {
                    guard let self, self.editToken == token, self.currentSource == source else { return }
                    self.aiPreparing = false
                    switch result {
                    case .success(let asset): apply(asset, "subject", "Lens blur keeps the subject sharp and blurs the rest. Increase Blur amount to taste.")
                    case .failure(let error): self.info.status(error.localizedDescription)
                    }
                }
            }
        default: break
        }
    }
}
