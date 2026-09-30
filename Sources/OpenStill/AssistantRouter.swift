import AppKit
import OpenStillCore

/// The tools an AI assistant can use, run inside OpenStill through the same paths as its own controls.
/// Each edit is one undo step, drawn live and saved as usual.
extension ViewerController {
    typealias AssistantReply = (Result<JSONValue, Error>) -> Void
    func startAssistant() {
        AssistantServer.shared.handler = { [weak self] tool, args, reply in
            guard let self else { reply(.failure(AssistantError.message("OpenStill is closing."))); return }
            self.assistant(tool, args, reply: reply)
        }
        AssistantServer.shared.applySetting()
    }

    func assistant(_ tool: String, _ args: [String: JSONValue], reply: @escaping AssistantReply) {
        func fail(_ text: String) { reply(.failure(AssistantError.message(text))) }
        switch tool {
        case "status":
            var result: [String: JSONValue] = ["photos_in_library": .number(Double(EditStorage.records.catalog?.photoCount ?? 0))]
            if let record = photoRecord, let url = currentSource { result["open_photo"] = .object(["id": .string(record.id.uuidString), "file": .string(url.lastPathComponent)]) }
            reply(.success(.object(result)))
        case "list_photos":
            guard let catalog = EditStorage.records.catalog else { fail("The library catalog isn’t available."); return }
            let found = AssistantQuery.filter(catalog.photos(), args)
            reply(.success(.object(["count": .number(Double(found.count)), "photos": .array(found.map(AssistantQuery.describe))])))
        case "get_photo":
            withAssistantPhoto(args, open: false, reply: reply) { record, url in
                var result = self.assistantFacts(record.id, url: url)
                let edits = url == self.currentSource ? self.currentEdits : record.active.document.current
                result["adjustments"] = AssistantAdjustments.describe(edits)
                reply(.success(.object(result)))
            }
        case "open_photo":
            withAssistantPhoto(args, open: true, reply: reply) { record, url in reply(.success(.object(self.assistantFacts(record.id, url: url)))) }
        case "preview":
            withAssistantPhoto(args, open: false, reply: reply) { record, url in
                self.assistantPreview(record, url: url, size: args["size"]?.int, compare: args["compare"]?.bool == true, reply: reply)
            }
        case "set_adjustments":
            guard let values = args["values"]?.object else { fail("Give “values”, e.g. {\"exposure\": 0.3, \"contrast\": 1.1}."); return }
            editAssistantPhoto(args, reply: reply) { edits in
                let (next, changed) = try AssistantAdjustments.apply(values, to: edits)
                return (next, "AI · " + changed.joined(separator: ", "))
            }
        case "auto_tone":
            withAssistantPhoto(args, open: true, reply: reply) { _, _ in
                self.autoTone()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { reply(.success(.object(["adjustments": AssistantAdjustments.describe(self.currentEdits)]))) }
            }
        case "apply_preset":
            guard let name = args["name"]?.string, info.preset(named: name) != nil else { fail("Unknown preset. Use a preset name from OpenStill’s Presets panel, for example “Vivid”."); return }
            withAssistantPhoto(args, open: true, reply: reply) { _, _ in
                self.editingCommand("preset:" + name)
                reply(.success(.object(["adjustments": AssistantAdjustments.describe(self.currentEdits)])))
            }
        case "crop":
            editAssistantPhoto(args, reply: reply) { edits in
                var next = edits
                if args["reset"]?.bool == true { next.crop = nil; return (next, "AI · Clear crop") }
                guard let x = args["x"]?.double, let y = args["y"]?.double, let w = args["width"]?.double, let h = args["height"]?.double,
                      [x, y, w, h].allSatisfy(\.isFinite), w >= 0.05, h >= 0.05, x >= 0, y >= 0, x + w <= 1.0001, y + h <= 1.0001 else {
                    throw AssistantError.message("Give x, y, width and height as fractions of the whole photo from its top-left (each 0…1, at least 0.05 wide and tall), or reset: true.")
                }
                next.crop = EditRect(CGRect(x: x, y: 1 - y - h, width: w, height: h))
                return (next, "AI · Crop")
            }
        case "reset":
            editAssistantPhoto(args, reply: reply) { _ in (PhotoEdits(), "AI · Reset all") }
        case "undo":
            withAssistantPhoto(args, open: true, reply: reply) { _, _ in
                self.editingCommand("undo")
                reply(.success(.object(["adjustments": AssistantAdjustments.describe(self.currentEdits)])))
            }
        case "add_mask_layer":
            addAssistantMaskLayer(args, reply: reply)
        case "list_mask_layers":
            withAssistantPhoto(args, open: true, reply: reply) { _, _ in
                let edits = self.currentEdits
                reply(.success(.object(["layers": .array(edits.localAdjustments.map { AssistantMasks.describe($0, mask: edits.advanced?.masks[$0.maskKey]) })])))
            }
        case "preview_mask":
            withAssistantPhoto(args, open: true, reply: reply) { _, _ in
                do { self.assistantMaskView(try self.assistantLayer(args).id, size: args["size"]?.int, reply: reply) } catch { reply(.failure(error)) }
            }
        case "update_mask_layer":
            updateAssistantMaskLayer(args, reply: reply)
        case "delete_mask_layer":
            withAssistantPhoto(args, open: true, reply: reply) { _, _ in
                do {
                    let layer = try self.assistantLayer(args)
                    self.maskLayerCommand("maskLayer:delete:" + layer.id.uuidString)
                    let edits = self.currentEdits
                    reply(.success(.object(["deleted": .string(layer.name),
                                            "layers": .array(edits.localAdjustments.map { AssistantMasks.describe($0, mask: edits.advanced?.masks[$0.maskKey]) })])))
                } catch { reply(.failure(error)) }
            }
        case "rate", "flag", "label", "add_keywords":
            markAssistantPhotos(tool, args, reply: reply)
        case "export":
            exportForAssistant(args, reply: reply)
        case "list_luts":
            let items = info.lutItems.filter { item in args["category"]?.string.map { item.entry.category == $0 } ?? true }
            reply(.success(.object(["luts": .array(items.map { item in
                .object(["id": .string(item.entry.id), "name": .string(item.entry.displayName), "category": .string(item.entry.category),
                         "creator": .string(item.entry.creator), "license": .string(item.entry.license)])
            })])))
        case "apply_lut":
            guard let id = args["id"]?.string, let item = info.lutItem(id: id) else { fail("Unknown LUT id. Call list_luts to see them."); return }
            withAssistantPhoto(args, open: true, reply: reply) { _, _ in
                do {
                    var edits = try item.applying(to: self.currentEdits)
                    if let amount = args["amount"]?.double, amount.isFinite { edits.lutAmount = min(1, max(0, amount)) }
                    self.changeEdits(edits, title: "AI · LUT " + item.entry.displayName, commit: true)
                    reply(.success(.object(["applied": .string(item.entry.displayName), "amount": .number(edits.lutAmount)])))
                } catch { reply(.failure(error)) }
            }
        case "import_lut":
            importLUTForAssistant(args, reply: reply)
        default:
            fail("OpenStill doesn’t know the tool “\(tool)”. Update OpenStill if the MCP is newer.")
        }
    }

    // MARK: Photos
    private func assistantFacts(_ id: UUID, url: URL) -> [String: JSONValue] {
        if let photo = EditStorage.records.catalog?.photo(id), case .object(let o) = AssistantQuery.describe(photo) { return o }
        return ["id": .string(id.uuidString), "file": .string(url.lastPathComponent), "path": .string(url.path)]
    }
    /// Finds the photo named by `photo_id` (or the open photo), opening it in Develop when needed, then runs `body`.
    private func withAssistantPhoto(_ args: [String: JSONValue], open: Bool, reply: @escaping AssistantReply, _ body: @escaping (PhotoRecord, URL) -> Void) {
        let requested = args["photo_id"]?.string
        if requested == nil || requested == photoRecord?.id.uuidString {
            guard let record = photoRecord, let url = currentSource, renderedPhoto != nil else {
                reply(.failure(AssistantError.message("No photo is open. Pass photo_id (from list_photos).")))
                return
            }
            if isLibrary && open { showEditor() }
            body(record, url); return
        }
        guard let id = requested.flatMap(UUID.init(uuidString:)), let photo = EditStorage.records.catalog?.photo(id) else {
            reply(.failure(AssistantError.message("No photo with that id. Call list_photos first.")))
            return
        }
        let url = URL(fileURLWithPath: photo.path)
        guard FileManager.default.fileExists(atPath: url.path) || SmartPreviews.stand(in: url) != nil else {
            reply(.failure(AssistantError.message("That photo’s file is offline or was moved.")))
            return
        }
        if !open, let record = try? EditStorage.records.record(for: url) { body(record, url); return }
        if let index = urls.firstIndex(of: url) { if isLibrary { showEditor() }; select(index) } else { self.open([url]); showEditor() }
        waitForAssistantPhoto(url, attempts: 250, reply: reply, body)
    }
    private func waitForAssistantPhoto(_ url: URL, attempts: Int, reply: @escaping AssistantReply, _ body: @escaping (PhotoRecord, URL) -> Void) {
        if currentSource == url, renderedPhoto != nil, let record = photoRecord { body(record, url); return }
        guard attempts > 0 else { reply(.failure(AssistantError.message("The photo took too long to open."))); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.waitForAssistantPhoto(url, attempts: attempts - 1, reply: reply, body) }
    }
    /// One edit on the photo: opened in Develop, then applied like a slider change, as a single undo step.
    private func editAssistantPhoto(_ args: [String: JSONValue], reply: @escaping AssistantReply, _ change: @escaping (PhotoEdits) throws -> (PhotoEdits, String)) {
        withAssistantPhoto(args, open: true, reply: reply) { _, _ in
            do {
                let (next, title) = try change(self.currentEdits)
                self.changeEdits(next, title: title, commit: true)
                reply(.success(.object(["adjustments": AssistantAdjustments.describe(self.currentEdits)])))
            } catch { reply(.failure(error)) }
        }
    }
    private func assistantPreviewEdge(_ size: Int?) -> Int {
        let limit = Assistant.previewSize(UserDefaults.standard.object(forKey: Assistant.previewKey) as? Int)
        return min(limit, max(256, size ?? min(limit, 1024)))
    }
    /// The image as a JPEG for the AI app, with any extra facts beside it.
    private static func jpegPayload(_ image: CIImage, _ extra: [String: JSONValue] = [:]) throws -> JSONValue {
        guard let cg = ModernRenderer.context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
              let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
            throw AssistantError.message("The preview couldn’t be rendered.")
        }
        return .object(extra.merging(["mime": .string("image/jpeg"), "data": .string(jpeg.base64EncodedString()),
                                      "width": .number(Double(cg.width)), "height": .number(Double(cg.height))]) { _, new in new })
    }
    /// The photo with its edits; with `compare`, the unedited photo on the left and the edited one on the right.
    private func assistantPreview(_ record: PhotoRecord, url: URL, size: Int?, compare: Bool, reply: @escaping AssistantReply) {
        let edge = assistantPreviewEdge(size)
        var recipe = record.active.recipe
        if url == currentSource { recipe.edits = currentEdits }
        var before = recipe; before.edits = PhotoEdits()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<JSONValue, Error> {
                let after = try ModernRenderer.render(source: url, recipe: recipe.sdr, maximumDimension: edge)
                guard compare else { return try ViewerController.jpegPayload(after) }
                let original = try ModernRenderer.render(source: url, recipe: before.sdr, maximumDimension: edge)
                // Same height side by side with a small gap, then fitted to the size limit.
                let height = min(original.extent.height, after.extent.height)
                func fit(_ image: CIImage) -> CIImage {
                    let s = height / image.extent.height
                    let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
                    return scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY))
                }
                let left = fit(original), right = fit(after), gap = max(4, height * 0.01)
                let joined = right.transformed(by: CGAffineTransform(translationX: left.extent.width + gap, y: 0))
                    .composited(over: left)
                    .composited(over: CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: left.extent.width + gap + right.extent.width, height: height)))
                let s = min(1, Double(edge) / max(joined.extent.width, joined.extent.height))
                let final = joined.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
                return try ViewerController.jpegPayload(final, ["layout": .string("Left: before (no edits). Right: after (current edits).")])
            }
            DispatchQueue.main.async { reply(result) }
        }
    }

    // MARK: Masks
    /// A mask layer of the open photo, by id (or by its exact name).
    private func assistantLayer(_ args: [String: JSONValue]) throws -> LocalAdjustment {
        guard let key = args["layer_id"]?.string else { throw AssistantError.message("Pass layer_id (from list_mask_layers or add_mask_layer).") }
        let layers = currentEdits.localAdjustments
        guard let layer = layers.first(where: { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame }) ?? layers.first(where: { $0.name == key }) else {
            throw AssistantError.message("No mask layer “\(key)” on this photo. Call list_mask_layers to see them.")
        }
        return layer
    }
    /// The photo with a layer's selection tinted red (as OpenStill shows masks with O), and where the selection lies.
    func assistantMaskView(_ id: UUID, size: Int?, extra: [String: JSONValue] = [:], reply: @escaping AssistantReply) {
        let edits = currentEdits
        guard let layer = edits.localAdjustments.first(where: { $0.id == id }), let source = currentSource, var recipe = photoRecord?.active.recipe else {
            reply(.failure(AssistantError.message("That mask layer is gone."))); return
        }
        guard let mask = edits.advanced?.masks[layer.maskKey] else {
            var result = extra; result["layer"] = AssistantMasks.describe(layer, mask: nil)
            result["selection"] = .object(["coverage": .number(0), "summary": .string("This layer has no selection yet, so it changes nothing.")])
            reply(.success(.object(result))); return
        }
        recipe.edits = edits
        let edge = assistantPreviewEdge(size), sourceSize = editSourceSize()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<JSONValue, Error> {
                let photo = try ModernRenderer.render(source: source, recipe: recipe.sdr, maximumDimension: edge)
                // The selection is found exactly as for the mask overlay in the app.
                let scale = min(1, Double(edge) / max(sourceSize.width, sourceSize.height))
                let geometry = EditGeometry(size: CGSize(width: (sourceSize.width * scale).rounded(), height: (sourceSize.height * scale).rounded()), edits: edits)
                let input = try ModernRenderer.render(source: source, recipe: recipe, maximumDimension: edge, stopBeforeTool: "Details")
                let selection = try mask.coverage(geometry: geometry, lens: edits.optics, input: input, modern: recipe.renderer == .linear2020)
                let area = photo.extent
                let fitted = selection
                    .transformed(by: CGAffineTransform(translationX: -selection.extent.minX, y: -selection.extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: area.width / selection.extent.width, y: area.height / selection.extent.height))
                    .transformed(by: CGAffineTransform(translationX: area.minX, y: area.minY))
                    .cropped(to: area)
                let tinted = CIImage(color: CIColor(red: 1, green: 0.08, blue: 0.08, alpha: 0.5)).cropped(to: area).composited(over: photo)
                let shown = tinted.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: photo, kCIInputMaskImageKey: fitted])
                var facts = extra
                facts["layer"] = AssistantMasks.describe(layer, mask: mask)
                facts["selection"] = try AssistantMasks.stats(fitted)
                facts["how_to_read"] = .string("Red shows where this layer's sliders apply; the photo already includes every layer's edits.")
                return try ViewerController.jpegPayload(shown, facts)
            }
            DispatchQueue.main.async { reply(result) }
        }
    }
    private func addAssistantMaskLayer(_ args: [String: JSONValue], reply: @escaping AssistantReply) {
        guard let kind = args["kind"]?.string, AssistantMasks.kinds.contains(kind) else {
            reply(.failure(AssistantError.message("kind is one of: " + AssistantMasks.kinds.joined(separator: ", ") + "."))); return
        }
        let settings: LocalSettings
        do { settings = try AssistantMasks.settings(args["values"]?.object ?? [:]) } catch { reply(.failure(error)); return }
        withAssistantPhoto(args, open: true, reply: reply) { _, _ in
            if kind == "sky" && !LocalAI.ready {
                reply(.failure(AssistantError.message("Selecting the sky needs OpenStill's on-device AI, which isn't set up. Ask the person to choose Set up on-device AI in OpenStill (a one-time download of about 450 MB), or use a linear mask from the top of the photo instead.")))
                return
            }
            let before = Set(self.currentEdits.localAdjustments.map(\.id))
            if let aiKind = AssistantMasks.aiKinds[kind] {
                // The same on-device selection as New Mask → Subject / Sky / Background / People.
                self.maskLayerCommand("maskLayer:new:" + aiKind)
            } else {
                do {
                    var edits = self.currentEdits
                    let layer = edits.addLocalAdjustment(named: args["name"]?.string ?? kind.capitalized)
                    edits.setMask(try AssistantMasks.shape(kind, args), for: layer.maskKey)
                    self.changeEdits(edits, title: "AI · New mask · " + layer.name, commit: true)
                } catch { reply(.failure(error)); return }
            }
            guard let layer = self.currentEdits.localAdjustments.first(where: { !before.contains($0.id) }) else {
                reply(.failure(AssistantError.message("The mask couldn’t be added."))); return
            }
            let finish = {
                var edits = self.currentEdits
                edits.updateLocalAdjustment(layer.id) { l in l.settings = settings; if let name = args["name"]?.string { l.name = name } }
                self.changeEdits(edits, title: "AI · " + layer.name, commit: true)
                self.info.selectMaskLayer(layer.id)
                self.assistantMaskView(layer.id, size: args["size"]?.int,
                                       extra: ["added": .string("Layer added. Check the red area; change it with update_mask_layer or remove it with delete_mask_layer.")], reply: reply)
            }
            guard AssistantMasks.aiKinds[kind] != nil else { finish(); return }
            self.waitForAssistantSelection(layer.id, started: Date()) { found in
                if found { finish(); return }
                let reason = self.info.lastStatus.hasPrefix("Selecting") ? "" : " " + self.info.lastStatus
                if self.currentEdits.localAdjustments.contains(where: { $0.id == layer.id }) {
                    var edits = self.currentEdits; edits.removeLocalAdjustment(layer.id)
                    self.changeEdits(edits, title: "AI · Remove empty mask", commit: true)
                }
                reply(.failure(AssistantError.message("No \(kind) was found, so no layer was added." + reason + " Try a linear or radial mask instead.")))
            }
        }
    }
    /// Waits for an on-device AI selection to land in a new layer (true), or to finish without one (false).
    private func waitForAssistantSelection(_ id: UUID, started: Date, _ done: @escaping (Bool) -> Void) {
        guard let layer = currentEdits.localAdjustments.first(where: { $0.id == id }) else { done(false); return }
        if let components = currentEdits.advanced?.masks[layer.maskKey]?.components, !components.isEmpty { done(true); return }
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > 90 || (elapsed > 1 && !aiPreparing && !localAI.isRunning) { done(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.waitForAssistantSelection(id, started: started, done) }
    }
    private func updateAssistantMaskLayer(_ args: [String: JSONValue], reply: @escaping AssistantReply) {
        withAssistantPhoto(args, open: true, reply: reply) { _, _ in
            do {
                let layer = try self.assistantLayer(args)
                var edits = self.currentEdits
                let settings = try AssistantMasks.settings(args["values"]?.object ?? [:], onto: layer.settings)
                edits.updateLocalAdjustment(layer.id) { l in
                    l.settings = settings
                    if let name = args["name"]?.string { l.name = name }
                    if let hidden = args["hidden"]?.bool { l.hidden = hidden }
                }
                if var mask = edits.advanced?.masks[layer.maskKey] {
                    if AssistantMasks.shapeKeys.contains(where: { args[$0] != nil }) || (args["feather"] != nil && mask.components == nil) {
                        guard mask.components == nil, mask.kind == "linear" || mask.kind == "radial" else {
                            throw AssistantError.message("Only linear and radial layers can be moved or resized. For an AI selection, use invert, or delete it and add a linear or radial layer.")
                        }
                        mask = try AssistantMasks.shape(mask.kind, args, base: mask)
                    } else if let invert = args["invert"]?.bool {
                        mask.inverted = invert
                    }
                    edits.setMask(mask, for: layer.maskKey)
                }
                self.changeEdits(edits, title: "AI · " + layer.name, commit: true)
                self.assistantMaskView(layer.id, size: args["size"]?.int, reply: reply)
            } catch { reply(.failure(error)) }
        }
    }

    // MARK: Library
    private func markAssistantPhotos(_ tool: String, _ args: [String: JSONValue], reply: @escaping AssistantReply) {
        let ids: [UUID]
        if let list = args["photo_ids"]?.array { ids = list.compactMap { $0.string.flatMap(UUID.init(uuidString:)) } }
        else if let one = args["photo_id"]?.string.flatMap(UUID.init(uuidString:)) { ids = [one] }
        else if let open = photoRecord?.id { ids = [open] }
        else { reply(.failure(AssistantError.message("Pass photo_id or photo_ids."))); return }
        guard !ids.isEmpty, ids.count <= 1000 else { reply(.failure(AssistantError.message("Pass between 1 and 1000 photo ids."))); return }
        do {
            for id in ids {
                let updated: PhotoRecord
                switch tool {
                case "rate":
                    guard let stars = args["rating"]?.int, (0...5).contains(stars) else { throw AssistantError.message("rating is 0 to 5.") }
                    updated = try ShootWorkflow.mark(id, rating: stars)
                case "flag":
                    guard let flag = args["flag"]?.string.flatMap(PhotoFlag.init(rawValue:)) else { throw AssistantError.message("flag is pick, reject or none.") }
                    updated = try ShootWorkflow.mark(id, flag: flag)
                case "label":
                    guard let label = args["label"]?.string.flatMap({ ColorLabel(rawValue: $0.lowercased()) }) else { throw AssistantError.message("label is red, yellow, green, blue, purple or none.") }
                    updated = try ShootWorkflow.mark(id, label: label)
                default:
                    let words = (args["keywords"]?.array ?? []).compactMap(\.string).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    guard !words.isEmpty else { throw AssistantError.message("Give keywords as a list of words.") }
                    var metadata = IPTCMetadata(); metadata.keywords = Array(words.prefix(50))
                    updated = try ShootWorkflow.applyMetadata(id, metadata)
                }
                if photoRecord?.id == id { photoRecord = updated }
            }
            refreshLibrary()
            reply(.success(.object(["updated": .number(Double(ids.count))])))
        } catch { reply(.failure(error)) }
    }
    private func exportForAssistant(_ args: [String: JSONValue], reply: @escaping AssistantReply) {
        var ids = (args["photo_ids"]?.array ?? []).compactMap { $0.string.flatMap(UUID.init(uuidString:)) }
        if ids.isEmpty, let one = args["photo_id"]?.string.flatMap(UUID.init(uuidString:)) ?? photoRecord?.id { ids = [one] }
        guard !ids.isEmpty, ids.count <= 500, let catalog = EditStorage.records.catalog else { reply(.failure(AssistantError.message("Pass photo_id or up to 500 photo_ids."))); return }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let folder = args["folder"]?.string.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenStill Exports")
        guard folder.path.hasPrefix(home + "/") else { reply(.failure(AssistantError.message("Export folders must be inside your home folder."))); return }
        var settings = ExportSettings()
        if let format = args["format"]?.string { guard let f = ExportFormat(rawValue: format) else { reply(.failure(AssistantError.message("format is jpeg, png, tiff or heif."))); return }; settings.format = f }
        if let edge = args["long_edge"]?.int { settings.longestEdge = min(20_000, max(64, edge)) }
        if photoRecord != nil { saveEdits() }
        let items: [ShootItem] = ids.compactMap { id in
            guard let photo = catalog.photo(id) else { return nil }
            let url = URL(fileURLWithPath: photo.path)
            guard let record = try? EditStorage.records.record(for: url) else { return nil }
            return ShootItem(url: url, record: record, captured: photo.captured ?? Date(timeIntervalSince1970: photo.modified))
        }
        guard !items.isEmpty else { reply(.failure(AssistantError.message("None of those photos could be found."))); return }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { reply(.failure(error)); return }
        let batch = ExportBatch(items: items, settings: settings, directory: folder)
        ExportWorkflow.queue.addOperation {
            let finished = ExportWorkflow.run(batch)
            let files = finished.jobs.compactMap(\.output).map { JSONValue.string($0.path) }
            let failed = finished.jobs.filter { $0.state != .complete }.map { JSONValue.string(($0.source.lastPathComponent) + ": " + ($0.error ?? "failed")) }
            DispatchQueue.main.async { reply(.success(.object(["exported": .array(files), "failed": .array(failed)]))) }
        }
    }

    // MARK: LUTs
    private func importLUTForAssistant(_ args: [String: JSONValue], reply: @escaping AssistantReply) {
        guard let link = args["url"]?.string, let url = URL(string: link) else { reply(.failure(AssistantError.message("Give the LUT’s download url."))); return }
        do { try LUTImport.check(url) } catch { reply(.failure(error)); return }
        let source = LUTSource(name: args["name"]?.string ?? url.deletingPathExtension().lastPathComponent, creator: args["creator"]?.string ?? "",
                               license: args["license"]?.string ?? "", sourcePage: args["source_page"]?.string ?? "", url: link, foundByAI: true)
        guard LUTImport.license(source.license) != nil else {
            reply(.failure(AssistantError.message("Give the LUT’s license as stated on its page. Only free licenses are accepted: " + LUTImport.freeLicenses.map(\.name).joined(separator: ", ") + ".")))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 60); request.setValue("OpenStill", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result = Result<[URL], Error> {
                if let error { throw error }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else { throw AssistantError.message("The download failed.") }
                if let final = http.url { try LUTImport.check(final) }
                return try LUTImport.install(data, suggestedName: url.lastPathComponent, source: source, into: EditStorage.root.appendingPathComponent("LUTLibrary"))
            }
            DispatchQueue.main.async { [weak self] in
                switch result {
                case .success(let files):
                    self?.info.refreshLUTs()
                    let names = Set(files.map { $0.deletingPathExtension().lastPathComponent })
                    let items = self?.info.lutItems.filter { names.contains($0.entry.name) } ?? []
                    reply(.success(.object(["imported": .array(items.map { .object(["id": .string($0.entry.id), "name": .string($0.entry.name)]) }),
                                            "license": .string(LUTImport.license(source.license) ?? source.license)])))
                case .failure(let error): reply(.failure(error))
                }
            }
        }.resume()
    }
}
