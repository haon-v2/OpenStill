import Foundation

/// The Develop tools in the left rail. Adjust is the resting state: the sliders on the right, no tool on the photo.
public enum StudioTool: String, CaseIterable, Codable, Sendable {
    case adjust, crop, remove, redEye, masking, whiteBalance, targeted

    public var title: String {
        switch self {
        case .adjust: "Adjust"
        case .crop: "Crop"
        case .remove: "Remove"
        case .redEye: "Red Eye"
        case .masking: "Masking"
        case .whiteBalance: "White Balance"
        case .targeted: "Targeted Adjustment"
        }
    }
    /// SF Symbol for the rail.
    public var symbol: String {
        switch self {
        case .adjust: "slider.horizontal.3"
        case .crop: "crop"
        case .remove: "bandage"
        case .redEye: "eye"
        case .masking: "circle.dashed"
        case .whiteBalance: "eyedropper"
        case .targeted: "scope"
        }
    }
    /// The workspace shortcut that picks it, if it has one (the key itself is in the shortcut map, so it can be changed).
    public var shortcutID: String? {
        switch self {
        case .adjust: "workspace.adjust"
        case .crop: "workspace.crop"
        case .remove: "workspace.remove"
        case .masking: "workspace.masking"
        case .whiteBalance: "workspace.whiteBalance"
        case .redEye, .targeted: nil
        }
    }
    /// What to do with the tool, shown in the status line while it's active.
    public var hint: String {
        switch self {
        case .adjust: "Drag a slider or its name · Double-click to reset · ⇧↑↓ steps by 10 · Y before / after · J clipping"
        case .crop: "Drag to frame · Drag a corner to resize · Drag outside to rotate · Return apply · Esc cancel"
        case .remove: "Option-click a clean source · Brush over the spot · [ ] brush size · Return done"
        case .redEye: "Drag over an eye · Sliders change the last eye · Return done"
        case .masking: "Pick a new mask above · Paint or drag on the photo · [ ] brush size · Return done"
        case .whiteBalance: "Click something that should be neutral gray · Esc cancel"
        case .targeted: "Drag up or down on the photo to change that tone or color · Return done"
        }
    }
    /// Tools that work on the photo itself, so the library switches to Develop first.
    public var needsPhoto: Bool { self != .adjust }
}

/// How the Studio window is arranged, remembered between launches.
public struct StudioLayout: Codable, Equatable, Sendable {
    public static let defaultsKey = "OpenStillStudioLayout"
    public static let panelWidths: ClosedRange<Double> = 240...420
    public static let defaultPanelWidth = 300.0

    /// The right panel's width, 240–420 points.
    public var panelWidth = StudioLayout.defaultPanelWidth { didSet { panelWidth = Self.clamp(panelWidth) } }
    public var panelHidden = false
    public var railHidden = false
    public var optionsBarHidden = false
    public var filmstripShown = false
    /// Library's right panel tab: 0 Folders, 1 Collections, 2 Info.
    public var libraryTab = 0
    public init() {}

    public static func clamp(_ width: Double) -> Double {
        guard width.isFinite else { return defaultPanelWidth }
        return min(panelWidths.upperBound, max(panelWidths.lowerBound, width.rounded()))
    }
    /// Tab: the rail and the right panel together; shows both when either is hidden.
    public mutating func toggleSidePanels() {
        let hide = !panelHidden && !railHidden
        panelHidden = hide; railHidden = hide
    }
    /// Shift-Tab: every bar around the photo.
    public mutating func toggleAllChrome() {
        let hide = !(panelHidden && railHidden && optionsBarHidden)
        panelHidden = hide; railHidden = hide; optionsBarHidden = hide
    }

    /// Loads the saved layout; the first time, carries over whether the Lightroom layout's right panel was hidden.
    public static func load(from defaults: UserDefaults = .standard) -> StudioLayout {
        if let data = defaults.data(forKey: defaultsKey), var layout = try? JSONDecoder().decode(StudioLayout.self, from: data) {
            layout.panelWidth = clamp(layout.panelWidth); layout.libraryTab = min(2, max(0, layout.libraryTab))
            return layout
        }
        var layout = StudioLayout()
        let old = LightroomPanels.load(from: defaults)
        layout.panelHidden = old.hidden.contains(.right)
        layout.optionsBarHidden = old.toolbarHidden
        return layout
    }
    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// The photos open in Develop, shown as tabs in the toolbar like a browser's.
/// Opening a photo that's already open just switches to it. Past the limit, the oldest photo without edits closes first.
public struct OpenPhotoTabs: Codable, Equatable, Sendable {
    public static let limit = 12
    /// File paths, left to right.
    public private(set) var paths: [String] = []
    public private(set) var active: String?
    /// Photos with edits get a dot on their tab and are the last to close automatically.
    public private(set) var edited: Set<String> = []
    public init() {}

    public mutating func open(_ path: String, edited isEdited: Bool = false) {
        if isEdited { edited.insert(path) }
        if !paths.contains(path) {
            paths.append(path)
            while paths.count > Self.limit {
                let candidates = paths.filter { $0 != path && $0 != active }
                guard let victim = candidates.first(where: { !edited.contains($0) }) ?? candidates.first else { break }
                paths.removeAll { $0 == victim }; edited.remove(victim)
            }
        }
        active = path
    }
    /// Closes a tab. Returns the tab to show next when the active one closed: the one to its right, else its left.
    @discardableResult public mutating func close(_ path: String) -> String? {
        guard let index = paths.firstIndex(of: path) else { return active }
        paths.remove(at: index); edited.remove(path)
        guard active == path else { return active }
        active = paths.isEmpty ? nil : paths[min(index, paths.count - 1)]
        return active
    }
    public mutating func setEdited(_ path: String, _ value: Bool) {
        guard paths.contains(path) else { return }
        if value { edited.insert(path) } else { edited.remove(path) }
    }
    /// Keeps only photos that still exist (for example after files were moved or trashed).
    public mutating func prune(keeping exists: (String) -> Bool) {
        let gone = paths.filter { !exists($0) }
        for path in gone { close(path) }
    }
    /// Follows renamed files.
    public mutating func rename(_ moves: [String: String]) {
        paths = paths.map { moves[$0] ?? $0 }
        edited = Set(edited.map { moves[$0] ?? $0 })
        if let a = active { active = moves[a] ?? a }
    }

    // One set of tabs per catalog folder.
    static func key(root: URL) -> String { "OpenStillOpenTabs." + root.standardizedFileURL.path }
    public static func load(root: URL, defaults: UserDefaults = .standard) -> OpenPhotoTabs {
        guard let data = defaults.data(forKey: key(root: root)), let tabs = try? JSONDecoder().decode(OpenPhotoTabs.self, from: data) else { return OpenPhotoTabs() }
        return tabs
    }
    public func save(root: URL, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key(root: root)) }
    }
}
