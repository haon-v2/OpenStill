import AppKit
import CoreImage
import OpenStillCore

/// Upright, guided perspective lines and the line-based auto straighten.
extension ViewerController {
    func transformCommand(_ name: String) {
        var edits = currentEdits
        switch name {
        case "resetTransform":
            if canvas.tool == .guide { canvas.clearTool() }
            edits.transform = TransformSettings(); changeEdits(edits, title: "Reset transform", commit: true); refreshGuides()
        case "clearGuides":
            var transform = edits.transform; transform.guides = nil
            if transform.upright?.mode == .guided { transform.upright = nil }
            edits.transform = transform; changeEdits(edits, title: "Clear guides", commit: true); refreshGuides()
        case "autoStraighten": autoStraighten()
        default:
            guard let mode = UprightMode(rawValue: String(name.dropFirst("upright:".count))) else { return }
            if canvas.tool == .guide && mode != .guided { canvas.clearTool() }
            switch mode {
            case .off:
                edits.transform.upright = nil; changeEdits(edits, title: "Upright · Off", commit: true)
            case .guided:
                finishMaskEditing(); canvas.clearTool(); canvas.native = false; canvas.tool = .guide; refreshGuides()
                info.status("Drag along 2–4 edges that should be vertical or horizontal. Escape finishes.")
                if let guides = edits.transform.guides, !guides.isEmpty { solveGuided(edits) }
            default: runUpright(mode)
            }
        }
    }
    private func runUpright(_ mode: UprightMode) {
        guard let source = currentSource, let record = photoRecord else { return }
        let token = UUID(); editToken = token; editWork?.cancel()
        var recipe = record.active.recipe; recipe.edits = currentEdits
        info.status("Finding straight lines…", busy: true)
        editQueue.async { [weak self] in
            let result = Result { try Upright.analyze(source: source, recipe: recipe, mode: mode) }
            DispatchQueue.main.async {
                guard let self, self.editToken == token, self.currentSource == source else { return }
                self.info.status("Edits are saved on this Mac. Originals stay untouched.")
                switch result {
                case .success(let solution?):
                    var next = self.currentEdits; next.transform.upright = solution
                    self.changeEdits(next, title: "Upright · " + mode.title, commit: true)
                    self.info.status(Self.describe(solution))
                case .success(nil): self.info.status("Couldn’t find enough straight lines for Upright \(mode.title). Try Guided and draw the lines yourself.")
                case .failure(let error): self.info.status(error.localizedDescription)
                }
            }
        }
    }
    private static func describe(_ s: UprightSolution) -> String {
        func n(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(2))) }
        return "Upright \(s.mode.title): rotate \(n(s.rotate))°, vertical \(n(s.vertical)), horizontal \(n(s.horizontal))."
    }
    /// Converts a line drawn on the displayed photo into the frame Upright works in, then re-solves.
    func addGuide(_ a: CGPoint, _ b: CGPoint) {
        var edits = currentEdits
        guard let first = guideInput(a, edits: edits), let second = guideInput(b, edits: edits) else { return }
        var transform = edits.transform
        var guides = transform.guides ?? []
        guides.append(GuideLine(first, second)); if guides.count > 4 { guides.removeFirst(guides.count-4) }
        transform.guides = guides; edits.transform = transform
        solveGuided(edits)
    }
    private func solveGuided(_ incoming: PhotoEdits) {
        var edits = incoming
        let size = DisplayOrientation(turn: edits.rotation, flip: edits.flip).displaySize(editSourceSize(edits))
        let lines = (edits.transform.guides ?? []).map { LineSegment($0.start, $0.end) }
        edits.transform.upright = Upright.solve(.guided, lines: lines, displaySize: size)
        changeEdits(edits, title: "Upright · Guided", commit: true)
        refreshGuides()
        info.status(edits.transform.upright.map { Self.describe($0) + " Draw more lines or press Escape." } ?? "Draw a line along an edge that should be vertical or horizontal.")
    }
    private func guideInput(_ displayed: CGPoint, edits: PhotoEdits) -> CGPoint? {
        let size = editSourceSize(edits), orientation = DisplayOrientation(turn: edits.rotation, flip: edits.flip)
        let source = EditGeometry(size: size, edits: edits).sourcePoint(displayed)
        let display = orientation.display(source)
        guard let perspective = Perspective(edits.transform, sourceSize: size, orientation: orientation) else { return display }
        return perspective.displayInput(display)
    }
    /// Guide overlay positions on the displayed photo.
    func refreshGuides() {
        let edits = currentEdits, size = editSourceSize(edits)
        guard canvas.tool == .guide, let guides = edits.transform.guides, size.width > 1 else { canvas.guideLines = []; return }
        let orientation = DisplayOrientation(turn: edits.rotation, flip: edits.flip), geometry = EditGeometry(size: size, edits: edits)
        let perspective = Perspective(edits.transform, sourceSize: size, orientation: orientation)
        func displayed(_ p: CGPoint) -> CGPoint? {
            var out = p
            if let perspective { guard let moved = perspective.displayOutput(p) else { return nil }; out = moved }
            let q = orientation.source(out)
            let placed = CGPoint(x: q.x*size.width, y: q.y*size.height).applying(geometry.transform)
            return CGPoint(x: placed.x/geometry.extent.width, y: placed.y/geometry.extent.height)
        }
        canvas.guideLines = guides.compactMap { g in displayed(g.start).flatMap { a in displayed(g.end).map { (a, $0) } } }
    }
    /// Straighten from long edges: the same line search as Upright Level, measured after any perspective correction.
    func autoStraighten() {
        guard let source = currentSource, let record = photoRecord else { return }
        let token = UUID(); editToken = token; editWork?.cancel()
        var recipe = record.active.recipe; recipe.edits = currentEdits
        let edits = currentEdits
        info.status("Finding straight lines…", busy: true)
        editQueue.async { [weak self] in
            let result = Result { () -> Double? in
                let input = try Upright.analysisImage(source: source, recipe: recipe)
                var lines = Upright.detectLines(input)
                if let perspective = Perspective(edits.transform, sourceSize: input.extent.size, orientation: DisplayOrientation(turn: 0, flip: false)) {
                    // The analysis image is already oriented, so the perspective acts on it directly.
                    lines = lines.compactMap { l in perspective.displayOutput(l.start).flatMap { a in perspective.displayOutput(l.end).map { LineSegment(a, $0, weight: l.weight) } } }
                }
                return Upright.straightenAngle(lines: lines, displaySize: input.extent.size)
            }
            DispatchQueue.main.async {
                guard let self, self.editToken == token, self.currentSource == source else { return }
                self.info.status("Edits are saved on this Mac. Originals stay untouched.")
                switch result {
                case .success(let angle?):
                    var next = self.currentEdits; next.straighten = min(20, max(-20, angle))
                    self.changeEdits(next, title: "Auto straighten", commit: true)
                case .success(nil): self.info.status("Couldn’t find a clear horizontal or vertical edge. Try AI align horizon or the slider.")
                case .failure(let error): self.info.status(error.localizedDescription)
                }
            }
        }
    }
}
