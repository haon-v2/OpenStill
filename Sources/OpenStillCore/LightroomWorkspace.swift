import Foundation

/// The modules along the top of the Lightroom Classic layout.
public enum LightroomModule: String, CaseIterable, Codable, Sendable {
    case library, develop, map, book, slideshow, print, web
    public var title: String {
        switch self {
        case .library: "Library"
        case .develop: "Develop"
        case .map: "Map"
        case .book: "Book"
        case .slideshow: "Slideshow"
        case .print: "Print"
        case .web: "Web"
        }
    }
    /// Library and Develop live in the main window; the others open their own window.
    public var isWorkspace: Bool { self == .library || self == .develop }
}

/// The four panel areas around the photo: module picker (top), left and right panels, filmstrip (bottom).
public enum PanelEdge: String, CaseIterable, Codable, Sendable { case top, left, right, bottom }

/// Lights Out (L) cycles normal → dim → off, as in Lightroom.
public enum LightsOut: Int, Codable, Sendable {
    case normal, dim, off
    public var next: LightsOut { LightsOut(rawValue: (rawValue + 1) % 3)! }
    /// How visible the panels are: dimmed panels stay faintly visible; off hides them.
    public var chromeOpacity: Double { [1, 0.18, 0][rawValue] }
}

/// What's shown in the Lightroom layout: hidden panels, the toolbar, and which sections are open. Remembered between launches.
public struct LightroomPanels: Codable, Equatable, Sendable {
    public static let defaultsKey = "OpenStillLightroomPanels"
    public var hidden: Set<PanelEdge> = []
    public var toolbarHidden = false
    /// Sections the person opened or closed, keyed "module.side.Title". Unlisted sections use their default.
    public var expanded: [String: Bool] = [:]
    /// Panel groups in solo mode ("module.side"): opening one section closes the others.
    public var solo: Set<String> = []
    public init() {}

    public func isVisible(_ edge: PanelEdge) -> Bool { !hidden.contains(edge) }
    public mutating func toggle(_ edge: PanelEdge) { if hidden.contains(edge) { hidden.remove(edge) } else { hidden.insert(edge) } }
    /// Tab: hides both side panels, or shows both when either is hidden.
    public mutating func toggleSidePanels() {
        if isVisible(.left) && isVisible(.right) { hidden.formUnion([.left, .right]) } else { hidden.subtract([.left, .right]) }
    }
    /// Shift-Tab: hides every panel, or shows them all when any is hidden.
    public mutating func toggleAllPanels() {
        if hidden.isEmpty { hidden = Set(PanelEdge.allCases) } else { hidden = [] }
    }

    public static func key(_ module: LightroomModule, _ side: PanelEdge, _ title: String) -> String { "\(module.rawValue).\(side.rawValue).\(title)" }
    public static func group(_ module: LightroomModule, _ side: PanelEdge) -> String { "\(module.rawValue).\(side.rawValue)" }
    public func isExpanded(_ key: String, default initial: Bool) -> Bool { expanded[key] ?? initial }
    /// Opens or closes a section. In solo mode, opening one closes the rest of its group (`siblings`).
    public mutating func setExpanded(_ key: String, _ open: Bool, siblings: [String] = []) {
        expanded[key] = open
        let group = key.split(separator: ".").prefix(2).joined(separator: ".")
        if open, solo.contains(group) { for other in siblings where other != key { expanded[other] = false } }
    }
    /// Solo mode on turns every section but `keep` off, as Lightroom does.
    public mutating func toggleSolo(_ group: String, keep: String?, siblings: [String]) {
        if solo.contains(group) { solo.remove(group); return }
        solo.insert(group)
        for other in siblings { expanded[other] = other == keep }
    }

    public static func load(from defaults: UserDefaults = .standard) -> LightroomPanels {
        guard let data = defaults.data(forKey: defaultsKey), let panels = try? JSONDecoder().decode(LightroomPanels.self, from: data) else { return LightroomPanels() }
        return panels
    }
    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
