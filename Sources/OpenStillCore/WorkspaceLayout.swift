import Foundation

/// How the main window arranges its panels.
public enum WorkspaceLayout: String, CaseIterable, Sendable {
    /// Icon rails on both sides, one tool panel on the right, filmstrip under the photo: quick, photo-first editing.
    case luminar
    /// Folders and collections (Library) or presets and history (Develop) on the left, adjustments on the right, filmstrip across the bottom.
    case lightroom

    /// Where older versions saved the layout choice. It's ignored now: OpenStill has one layout, Lightroom Classic's.
    public static let defaultsKey = "OpenStillWorkspaceLayout"
    public static var current: WorkspaceLayout { .lightroom }
    public var title: String { self == .luminar ? "EZ Layout" : "Lightroom Classic" }
    public var summary: String {
        switch self {
        case .luminar: return "Photo-first. Tools on the right, icon rails at the edges and the filmstrip under your photo. Great for quick edits."
        case .lightroom: return "Panels on both sides. Folders, presets and history on the left, adjustments on the right, filmstrip along the bottom."
        }
    }
    /// The names of the two workspaces in this layout's own words.
    public var modeNames: (library: String, edit: String) { self == .luminar ? ("Catalog", "Edit") : ("Library", "Develop") }
}
