import AppKit
import CoreImage
import OpenStillCore

/// Commands for the Develop tools added in M11: Point Color, targeted adjustment, B&W mix, chromatic aberration,
/// red eye, Visualize Spots and snapshots.
extension ViewerController {
    func configureDevelopM11() {
        canvas.pointColorChosen = { [weak self] point in self?.pickPointColor(at: point) }
        canvas.targetBegan = { [weak self] point in self?.beginTargeted(at: point) }
        canvas.targetDragged = { [weak self] dy, final in self?.dragTargeted(dy, final: final) }
        canvas.eyeDrawn = { [weak self] center, corner in self?.addEyeFix(center: center, corner: corner) }
    }

    /// Returns true when the command was one of these tools.
    func developM11Command(_ name: String) -> Bool {
        switch name {
        case "pointColor:pick":
            finishMaskEditing(); canvas.tool = .pointColor; info.status("Click a color in the photo to adjust colors like it.")
        case "tat:curve", "tat:hue", "tat:saturation", "tat:luminance":
            finishMaskEditing(); canvas.tool = .targeted; targetState = nil
            info.status(name == "tat:curve" ? "Press on a tone in the photo and drag up to brighten it, down to darken it." : "Press on a color in the photo and drag up or down. Escape finishes.")
            pendingTarget = String(name.dropFirst(4))
        case "grayMix:auto":
            var e = currentEdits; e.grayMix = autoGrayMix(); if e.monochrome == 0 { e.monochrome = 1 }; changeEdits(e, title: "Auto B&W mix", commit: true)
        case "grayMix:reset":
            var e = currentEdits; e.grayMix = PhotoEdits.neutralGrayMix; changeEdits(e, title: "Reset B&W mix", commit: true)
        case "autoCA": measureChromaticAberration()
        case "autoCA:off":
            var e = currentEdits; e.autoCA = AutoCASettings(enabled: false); changeEdits(e, title: "Chromatic aberration off", commit: true)
        case "eye:redEye", "eye:petEye":
            finishMaskEditing(); eyeKind = name == "eye:redEye" ? .redEye : .petEye; canvas.tool = .eyeFix
            info.status("Drag from the centre of the eye outward to cover it. Escape finishes.")
        case "eye:removeLast":
            var e = currentEdits; guard !e.eyeFixes.isEmpty else { return true }; e.eyeFixes.removeLast(); changeEdits(e, title: "Remove eye correction", commit: true)
        case "eye:clear":
            var e = currentEdits; e.eyeFixes = []; changeEdits(e, title: "Clear eye corrections", commit: true)
        case "spots:toggle":
            spotsVisible.toggle(); refreshSpots()
            info.status(spotsVisible ? "Visualize Spots is on: dust and small spots show as white specks. Retouch them, then turn it off." : "Visualize Spots is off.")
        case "snapshot:add": addSnapshot()
        default:
            if name.hasPrefix("spots:threshold:"), let v = Double(name.dropFirst(16)) { spotThreshold = v; refreshSpots(); return true }
            if name.hasPrefix("snapshot:") { snapshotCommand(name); return true }
            return false
        }
        return true
    }

    // MARK: Point Color
    private func pickPointColor(at point: CGPoint) {
        guard let source = currentSource, let record = photoRecord else { return }
        let token = editToken, edits = currentEdits, displayed = canvas.image
        canvas.clearTool(); info.status("Sampling color…")
        editQueue.async { [weak self] in
            // Sample the photo as it enters Color, so the colour you click is the one you'll adjust.
            var recipe = record.active.recipe; recipe.edits = edits
            let input: CIImage? = recipe.renderer == .legacy ? displayed.map { CIImage(cgImage: $0) } : try? ModernRenderer.render(source: source, recipe: recipe, maximumDimension: 1400, stopBeforeTool: "Color")
            let picked = input.flatMap { PointColor.sample($0, at: point) }
            DispatchQueue.main.async {
                guard let self, self.editToken == token, self.currentSource == source else { return }
                guard let picked else { self.info.status("Couldn’t read the color there. Try another spot."); return }
                var e = self.currentEdits
                guard e.pointColors.count < 8 else { self.info.status("Point Color holds up to 8 colors. Remove one first."); return }
                e.pointColors = e.pointColors + [picked]; self.changeEdits(e, title: "Pick Point Color", commit: true)
                self.info.selectLastPointColor()
                self.info.status("Color picked. Use Hue, Saturation and Luminance to shift colors near it; Range widens or narrows the match.")
            }
        }
    }

    // MARK: Targeted adjustment
    private func beginTargeted(at point: CGPoint) {
        guard let kind = pendingTarget, let source = currentSource, let record = photoRecord else { return }
        let edits = currentEdits, displayed = canvas.image
        var recipe = record.active.recipe; recipe.edits = edits
        let stop = kind == "curve" ? "Curves" : "Color"
        let input: CIImage? = recipe.renderer == .legacy ? displayed.map { CIImage(cgImage: $0) } : try? ModernRenderer.render(source: source, recipe: recipe, maximumDimension: 900, stopBeforeTool: stop)
        guard let rgb = input.flatMap({ PointColors.sample($0, at: point) }) else { info.status("Couldn’t read the photo there."); return }
        let (h, _, l) = HSL.of(rgb)
        // Luminance of the sampled tone, in the curve's 0–1 scale.
        targetState = (kind, edits, 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2], h)
        _ = l
    }
    private func dragTargeted(_ dy: CGFloat, final: Bool) {
        guard let state = targetState else { return }
        let amount = Double(dy) / 250
        var e = state.base
        switch state.kind {
        case "curve":
            // Lift or lower the curve at the tone under the pointer, keeping a point there.
            var curves = e.curves, channel = info.curveChannel
            let paths: [WritableKeyPath<ToneCurves, [CurvePoint]?>] = [\.masterPoints, \.redPoints, \.greenPoints, \.bluePoints]
            let samples: [WritableKeyPath<ToneCurves, [Double]>] = [\.master, \.red, \.green, \.blue]
            channel = min(3, max(0, channel))
            var points = curves[keyPath: paths[channel]] ?? zip(ToneCurves.identity, curves[keyPath: samples[channel]]).map { CurvePoint($0, $1) }
            let x = min(0.98, max(0.02, state.luminance))
            let y = min(1, max(0, CurvePoint.value(at: x, points: points) + amount))
            points.removeAll { abs($0.x - x) < 0.02 }; points.append(CurvePoint(x, y))
            curves[keyPath: paths[channel]] = CurvePoint.cleaned(points); curves[keyPath: samples[channel]] = ToneCurves.identity
            e.curves = curves
        default:
            e.ensureAdvanced()
            for i in 0..<8 {
                let w = HSL.bandWeight(state.hue, band: i); guard w > 0.01 else { continue }
                var band = e.advanced!.colors[i]
                switch state.kind {
                case "hue": band.hue = min(1, max(-1, band.hue + amount * w))
                case "saturation": band.saturation = min(1, max(-1, band.saturation + amount * w))
                default: band.lightness = min(1, max(-1, (band.lightness ?? 0) + amount * w))
                }
                band.displayMode = "hsl"; e.advanced!.colors[i] = band
            }
        }
        changeEdits(e, title: "Targeted " + state.kind, commit: final)
        if final { targetState = nil }
    }

    // MARK: Black & white mix
    /// Lightroom's Auto mix: each color keeps roughly the brightness it had before becoming gray.
    private func autoGrayMix() -> [Double] {
        (0..<8).map { i in
            let rgb = ColorMixer.rgb(hue: ColorMixer.centers[i], saturation: 1, lightness: 0.5)
            let luminance = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
            return min(1, max(-1, (0.5 - luminance) * 0.9))
        }
    }

    // MARK: Chromatic aberration
    private func measureChromaticAberration() {
        guard let source = currentSource, let record = photoRecord else { return }
        let token = editToken, edits = currentEdits
        info.status("Measuring chromatic aberration…")
        editQueue.async { [weak self] in
            // Measure the whole frame, before crop and rotation, so the optical centre is the photo's centre.
            var neutral = edits
            neutral.crop = nil; neutral.rotation = 0; neutral.flip = false; neutral.straighten = 0; neutral.advanced?.transform = nil
            neutral.autoCA = AutoCASettings(enabled: false)
            var recipe = record.active.recipe; recipe.renderer = .linear2020; recipe.edits = neutral
            let measured = (try? ModernRenderer.render(source: source, recipe: recipe, maximumDimension: 1800, stopBeforeTool: "Retouch")).map { AutoCA.estimate($0) }
            DispatchQueue.main.async {
                guard let self, self.editToken == token, self.currentSource == source else { return }
                guard let measured else { self.info.status("Couldn’t measure this photo."); return }
                var e = self.currentEdits; e.autoCA = measured
                self.changeEdits(e, title: "Remove chromatic aberration", commit: true)
                let shift = max(abs(measured.redScale - 1), abs(measured.blueScale - 1))
                self.info.status(shift < 0.00015 ? "No noticeable chromatic aberration found; the correction is on and has almost no effect." : String(format: "Chromatic aberration removed (red %.2f‰, blue %.2f‰).", (measured.redScale - 1) * 1000, (measured.blueScale - 1) * 1000))
            }
        }
    }

    // MARK: Red eye
    private func addEyeFix(center: CGPoint, corner: CGPoint) {
        let geometry = EditGeometry(size: editSourceSize(), edits: currentEdits)
        func source(_ p: CGPoint) -> CGPoint { LensCorrections.sourcePoint(geometry.sourcePoint(p), size: geometry.sourceSize, settings: currentEdits.optics) }
        let c = source(center)
        let dx = abs(corner.x - center.x), dy = abs(corner.y - center.y)
        let sx = source(CGPoint(x: center.x + dx, y: center.y)), sy = source(CGPoint(x: center.x, y: center.y + dy))
        let rx = max(abs(sx.x - c.x), abs(sy.x - c.x)), ry = max(abs(sx.y - c.y), abs(sy.y - c.y))
        var e = currentEdits
        e.eyeFixes = e.eyeFixes + [EyeFix(kind: eyeKind, center: c, radiusX: max(0.002, rx), radiusY: max(0.002, ry))]
        changeEdits(e, title: eyeKind == .redEye ? "Red eye" : "Pet eye", commit: true)
        info.status("Eye corrected. Drag over another eye, or press Escape to finish.")
    }

    // MARK: Visualize Spots
    func refreshSpots() {
        guard spotsVisible, let displayed = canvas.image else { canvas.spotOverlay = nil; return }
        let threshold = spotThreshold
        histogramQueue.async { [weak self] in
            let map = SpotVisualizer.map(CIImage(cgImage: displayed), threshold: threshold).flatMap { ModernRenderer.context.createCGImage($0, from: $0.extent) }
            DispatchQueue.main.async { guard let self, self.spotsVisible else { return }; self.canvas.spotOverlay = map }
        }
    }

    // MARK: Snapshots
    private func addSnapshot() {
        guard let window = view.window else { return }
        let alert = NSAlert(); alert.messageText = "New snapshot"; alert.informativeText = "Saves the current edit so you can return to it."
        let field = NSTextField(string: ""); field.placeholderString = "Name (optional)"; field.frame = NSRect(x: 0, y: 0, width: 260, height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "Save Snapshot"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.editDocument.addSnapshot(field.stringValue); self.saveEdits()
            self.info.update(self.currentEdits, document: self.editDocument, enabled: self.renderedPhoto != nil)
        }
    }
    private func snapshotCommand(_ name: String) {
        let parts = name.split(separator: ":"); guard parts.count == 3, let id = UUID(uuidString: String(parts[2])) else { return }
        switch parts[1] {
        case "restore": editDocument.restoreSnapshot(id); restoreHistory()
        case "delete": editDocument.deleteSnapshot(id); saveEdits(); info.update(currentEdits, document: editDocument, enabled: renderedPhoto != nil)
        case "rename":
            guard let window = view.window, let snap = editDocument.snapshotList.first(where: { $0.id == id }) else { return }
            let alert = NSAlert(); alert.messageText = "Rename snapshot"
            let field = NSTextField(string: snap.name); field.frame = NSRect(x: 0, y: 0, width: 260, height: 24); alert.accessoryView = field
            alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn else { return }
                self.editDocument.renameSnapshot(id, to: field.stringValue); self.saveEdits()
                self.info.update(self.currentEdits, document: self.editDocument, enabled: self.renderedPhoto != nil)
            }
        default: break
        }
    }
}
