import Foundation

/// Transient ownership of canvas input. Saved masks live separately in PhotoEdits.
public struct MaskEditingSession {
    public private(set) var tool: String?
    public private(set) var selection: UUID?
    public init() {}
    public mutating func activate(_ tool: String) {
        if self.tool != tool { selection = nil }
        self.tool = tool
    }
    @discardableResult public mutating func end() -> Bool {
        let wasSelecting = selection != nil
        tool = nil; selection = nil
        return wasSelecting
    }
    public mutating func beginSelection() -> UUID {
        let token = UUID(); selection = token; return token
    }
    public func accepts(_ token: UUID, for tool: String) -> Bool {
        self.tool == tool && selection == token
    }
    public mutating func completeSelection(_ token: UUID) {
        if selection == token { selection = nil }
    }
}
