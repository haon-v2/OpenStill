import AppKit
import OpenStillCore

/// The tools an AI assistant can use, run inside OpenStill through the same paths as its own controls.
/// Each edit is one undo step, drawn live and saved as usual.
extension ViewerController {
    typealias AssistantReply = (Result<JSONValue, Error>) -> Void
    private static let presets = ["Warm light", "Cool shadows", "Vivid", "Soft portrait", "Monochrome"]

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
            withAssistantPhoto(args, open: false, reply: reply) { record, url in self.assistantPreview(record, url: url, size: args["size"]?.int, reply: reply) }
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
            guard let name = args["name"]?.string, Self.presets.contains(name) else { fail("Presets: " + Self.presets.joined(separator: ", ") + "."); return }
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
        case "rate", "flag", "label", "add_keywords":
            markAssistantPhotos(tool, args, reply: reply)
        case "export":
            exportForAssistant(args, reply: reply)
        case "list_luts":
            let items = info.lutItems.filter { item in args["category"]?.string.map { item.entry.category == $0 } ?? true }
            reply(.success(.object(["luts": .array(items.map { item in
                .object(["id": .string(item.entry.id), "name": .string(item.entry.name), "category": .string(item.entry.category),
                         "creator": .string(item.entry.creator), "license": .string(item.entry.license)])
            })])))
        case "apply_lut":
            guard let id = args["id"]?.string, let item = info.lutItem(id: id) else { fail("Unknown LUT id. Call list_luts to see them."); return }
            withAssistantPhoto(args, open: true, reply: reply) { _, _ in
                do {
                    var edits = try item.applying(to: self.currentEdits)
                    if let amount = args["amount"]?.double, amount.isFinite { edits.lutAmount = min(1, max(0, amount)) }
                    self.changeEdits(edits, title: "AI · LUT " + item.entry.name, commit: true)
                    reply(.success(.object(["applied": .string(item.entry.name), "amount": .number(edits.lutAmount)])))
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
    private func assistantPreview(_ record: PhotoRecord, url: URL, size: Int?, reply: @escaping AssistantReply) {
        let limit = Assistant.previewSize(UserDefaults.standard.object(forKey: Assistant.previewKey) as? Int)
        let edge = min(limit, max(256, size ?? limit))
        var recipe = record.active.recipe
        if url == currentSource { recipe.edits = currentEdits }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<JSONValue, Error> {
                let image = try ModernRenderer.render(source: url, recipe: recipe.sdr, maximumDimension: edge)
                guard let cg = ModernRenderer.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
                      let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
                    throw AssistantError.message("The preview couldn’t be rendered.")
                }
                return .object(["mime": .string("image/jpeg"), "data": .string(jpeg.base64EncodedString()),
                                "width": .number(Double(cg.width)), "height": .number(Double(cg.height))])
            }
            DispatchQueue.main.async { reply(result) }
        }
    }

    // MARK: Masks
    private func addAssistantMaskLayer(_ args: [String: JSONValue], reply: @escaping AssistantReply) {
        guard let kind = args["kind"]?.string, AssistantMasks.kinds.contains(kind) else {
            reply(.failure(AssistantError.message("kind is one of: " + AssistantMasks.kinds.joined(separator: ", ") + "."))); return
        }
        let settings: LocalSettings
        do { settings = try AssistantMasks.settings(args["values"]?.object ?? [:]) } catch { reply(.failure(error)); return }
        withAssistantPhoto(args, open: true, reply: reply) { _, _ in
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
            var edits = self.currentEdits
            edits.updateLocalAdjustment(layer.id) { l in l.settings = settings; if let name = args["name"]?.string { l.name = name } }
            self.changeEdits(edits, title: "AI · " + layer.name, commit: true)
            self.info.selectMaskLayer(layer.id)
            reply(.success(.object(["layer": .string(layer.name), "id": .string(layer.id.uuidString), "adjustments": AssistantAdjustments.describe(self.currentEdits),
                                    "note": .string(AssistantMasks.aiKinds[kind] != nil ? "The AI selection is computed on this Mac and may take a few seconds to appear." : "")])))
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
