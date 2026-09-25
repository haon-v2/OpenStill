import AppKit
import CoreImage
import OpenStillCore

/// Auto tone, clipping warnings and the before/after split view.
extension ViewerController {
    func autoTone() {
        guard let source = currentSource, let record = photoRecord, let original = renderedPhoto?.image else { return }
        let edits = currentEdits, token = editToken
        var recipe = record.active.recipe
        info.status("Analyzing tones…")
        editQueue.async { [weak self] in
            let result = Result { () -> PhotoEdits in
                // Measure the photo as it enters Develop, without the tonal sliders Auto is about to set.
                var neutral = edits
                neutral.exposure = 0; neutral.contrast = 1; neutral.highlights = 1; neutral.shadows = 0; neutral.whites = 0; neutral.blacks = 0
                let input: CIImage
                if recipe.renderer == .legacy { input = CIImage(cgImage: try PhotoEditor.render(original, edits: neutral, previewMaxDimension: 1024)) }
                else { recipe.edits = neutral; input = try ModernRenderer.render(source: source, recipe: recipe, maximumDimension: 1024, stopBeforeTool: "Develop") }
                return AutoTone.apply(PhotoHistogram.measure(input), to: edits)
            }
            DispatchQueue.main.async {
                guard let self, self.editToken == token, self.currentSource == source else { return }
                switch result {
                case .success(let next): self.changeEdits(next, title: "Auto tone", commit: true)
                case .failure(let error): self.info.status(error.localizedDescription)
                }
            }
        }
    }
    @objc func toggleClippingOverlay() { editingCommand("toggleClipping") }
    @objc func toggleBeforeAfterSplit() { editingCommand("compareSplit") }
    func toggleSplitCompare() {
        if currentEdits.baseAsset != nil && !splitCompare {
            info.status("Before / after split isn’t available after an AI result changes the frame. Use Compare instead."); return
        }
        splitCompare.toggle(); if splitCompare { comparing = false }
        if !splitCompare { canvas.beforeImage = nil }
        info.status(splitCompare ? "Drag the divider to compare. Press Y to leave the split view." : "Edits are saved on this Mac. Originals stay untouched.")
        renderEdits()
    }
    /// Recomputes the clipping overlay and, when the split view is on, a "before" render with the same frame.
    func refreshCompareExtras(_ displayed: CGImage, interactive: Bool) {
        let token = UUID(); compareToken = token
        if showClipping {
            histogramQueue.async { [weak self] in
                let overlay = ClippingOverlay.render(displayed)
                DispatchQueue.main.async { guard let self, self.compareToken == token else { return }; self.canvas.clippingOverlay = overlay }
            }
        } else { canvas.clippingOverlay = nil }
        guard splitCompare, !comparing, !currentEdits.isOriginal, currentEdits.baseAsset == nil,
              let source = currentSource, let record = photoRecord, let original = renderedPhoto?.image else {
            if !splitCompare || comparing { canvas.beforeImage = nil }
            return
        }
        // Keep the last "before" frame during a drag; re-render once the edit settles.
        if interactive && canvas.beforeImage != nil { return }
        let before = ClippingOverlay.geometryOnly(currentEdits)
        var recipe = record.active.recipe; recipe.edits = before
        let limit: Int? = interactive ? 1600 : nil
        editQueue.async { [weak self] in
            let image = try? autoreleasepool { () -> CGImage in
                if recipe.renderer == .legacy { return try PhotoEditor.render(original, edits: before, previewMaxDimension: limit) }
                return try ModernRenderer.display(ModernRenderer.render(source: source, recipe: recipe, maximumDimension: limit))
            }
            DispatchQueue.main.async { guard let self, self.compareToken == token, self.splitCompare else { return }; self.canvas.beforeImage = image }
        }
    }
}
