import Foundation

/// A key plus modifiers, e.g. ⌘O or ⇧⌘E. Keys are lowercase characters or named special keys.
public struct KeyCombo: Codable, Hashable, Sendable {
    public var key: String
    public var command = false, shift = false, option = false, control = false
    public init(_ key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = KeyCombo.normalize(key); self.command = command; self.shift = shift; self.option = option; self.control = control
    }

    /// Named keys that aren't printable characters.
    public static let specialKeys: [String: String] = [
        "left": "←", "right": "→", "up": "↑", "down": "↓", "space": "Space", "return": "↩", "tab": "⇥",
        "delete": "⌫", "forwarddelete": "⌦", "escape": "⎋", "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
        "f1": "F1", "f2": "F2", "f3": "F3", "f4": "F4", "f5": "F5", "f6": "F6", "f7": "F7", "f8": "F8", "f9": "F9", "f10": "F10", "f11": "F11", "f12": "F12",
    ]
    static func normalize(_ key: String) -> String {
        let k = key.lowercased()
        switch k {
        case " ": return "space"
        case "\r", "\n", "enter": return "return"
        case "\t": return "tab"
        case "\u{7f}", "backspace": return "delete"
        case "\u{1b}", "esc": return "escape"
        default: return k
        }
    }
    public var isSpecial: Bool { Self.specialKeys[key] != nil }
    /// Letters, digits and punctuation only count as a shortcut with ⌘ or ⌃ unless the command is a single-key one.
    public var hasModifier: Bool { command || control || option }

    /// "⌃⌥⇧⌘O", in Apple's modifier order.
    public var display: String {
        var s = ""
        if control { s += "⌃" }; if option { s += "⌥" }; if shift { s += "⇧" }; if command { s += "⌘" }
        return s + (Self.specialKeys[key] ?? key.uppercased())
    }
    /// Spoken form for VoiceOver, e.g. "Command Shift O".
    public var spoken: String {
        var parts: [String] = []
        if control { parts.append("Control") }; if option { parts.append("Option") }; if shift { parts.append("Shift") }; if command { parts.append("Command") }
        let names = ["left": "Left Arrow", "right": "Right Arrow", "up": "Up Arrow", "down": "Down Arrow", "delete": "Delete", "forwarddelete": "Forward Delete",
                     "escape": "Escape", "return": "Return", "tab": "Tab", "space": "Space", "pageup": "Page Up", "pagedown": "Page Down", "home": "Home", "end": "End"]
        parts.append(names[key] ?? (Self.specialKeys[key] ?? key.uppercased()))
        return parts.joined(separator: " ")
    }
    /// "cmd+shift+o": stable text for settings files.
    public var text: String {
        var parts: [String] = []
        if control { parts.append("ctrl") }; if option { parts.append("opt") }; if shift { parts.append("shift") }; if command { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }
    public init?(text: String) {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "cmd++" means the plus key.
        var tokens = parts; var key = tokens.popLast() ?? ""
        if key.isEmpty, tokens.last == "" { tokens.removeLast(); key = "+" }
        guard !key.isEmpty, key.count == 1 || Self.specialKeys[key] != nil else { return nil }
        self.init(key)
        for t in tokens {
            switch t {
            case "cmd", "command": command = true
            case "shift": shift = true
            case "opt", "option", "alt": option = true
            case "ctrl", "control": control = true
            default: return nil
            }
        }
    }
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let combo = KeyCombo(text: text) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown shortcut \(text)")) }
        self = combo
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(text) }
}

/// Where a shortcut works. Menu shortcuts work everywhere; single-key shortcuts only while the library grid or the photo has focus.
/// Workspace keys (panels, lights out, switching modules) work in both the library grid and on the photo.
public enum ShortcutScope: String, Codable, Sendable {
    case menu, library, editor, workspace
    /// Whether the same keys in both places would clash.
    public func overlaps(_ other: ShortcutScope) -> Bool {
        self == other || self == .menu || other == .menu || self == .workspace || other == .workspace
    }
}

public struct ShortcutCommand: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// The section it's listed under, e.g. "File" or "Library".
    public var group: String
    public var scope: ShortcutScope
    public var defaultCombo: KeyCombo?
    public init(id: String, title: String, group: String, scope: ShortcutScope = .menu, defaultCombo: KeyCombo?) {
        self.id = id; self.title = title; self.group = group; self.scope = scope; self.defaultCombo = defaultCombo
    }
}

/// Every command's shortcut: its default, unless the person changed or removed it. Saved in user defaults.
public final class ShortcutMap {
    public static let defaultsKey = "OpenStillShortcuts"
    public private(set) var commands: [ShortcutCommand] = []
    /// Changed shortcuts by command ID. A nil value means "no shortcut".
    public private(set) var overrides: [String: KeyCombo?] = [:]
    private let defaults: UserDefaults
    /// Called after any change, so menus and key handlers pick it up.
    public var changed: (() -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey), let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            for (id, text) in saved {
                if text.isEmpty { overrides[id] = .some(nil) } else if let combo = KeyCombo(text: text) { overrides[id] = .some(combo) }
            }
        }
    }
    /// Adds a command (or replaces one with the same ID).
    public func register(_ command: ShortcutCommand) {
        if let i = commands.firstIndex(where: { $0.id == command.id }) { commands[i] = command } else { commands.append(command) }
    }
    public func command(_ id: String) -> ShortcutCommand? { commands.first { $0.id == id } }
    public func combo(for id: String) -> KeyCombo? {
        if let override = overrides[id] { return override }
        return command(id)?.defaultCombo
    }
    public func isCustomized(_ id: String) -> Bool {
        guard let override = overrides[id] else { return false }
        return override != command(id)?.defaultCombo
    }
    /// Commands that would clash with `combo` for command `id`: same keys in the same place. Menu shortcuts clash with everything.
    public func conflicts(for combo: KeyCombo, assigningTo id: String) -> [ShortcutCommand] {
        guard let scope = command(id)?.scope else { return [] }
        return commands.filter { other in
            other.id != id && self.combo(for: other.id) == combo && other.scope.overlaps(scope)
        }
    }
    /// Sets a shortcut (nil removes it). Commands it clashes with lose theirs.
    public func set(_ combo: KeyCombo?, for id: String) {
        guard command(id) != nil else { return }
        if let combo { for other in conflicts(for: combo, assigningTo: id) { overrides[other.id] = .some(nil) } }
        overrides[id] = .some(combo)
        tidy(); save(); changed?()
    }
    public func reset(_ id: String) { overrides.removeValue(forKey: id); save(); changed?() }
    public func resetAll() { overrides.removeAll(); save(); changed?() }
    /// The command a key press triggers in a place, if any. Menu commands aren't returned: the menu handles those.
    public func command(for combo: KeyCombo, in scope: ShortcutScope) -> ShortcutCommand? {
        commands.first { $0.scope == scope && self.combo(for: $0.id) == combo }
    }
    /// Commands whose title, group or shortcut match a search, e.g. "export" or "⌘E".
    public func search(_ query: String) -> [ShortcutCommand] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return commands }
        return commands.filter { c in
            c.title.localizedCaseInsensitiveContains(q) || c.group.localizedCaseInsensitiveContains(q) ||
            (combo(for: c.id).map { $0.display.localizedCaseInsensitiveContains(q) || $0.spoken.localizedCaseInsensitiveContains(q) } ?? false)
        }
    }
    /// Drops overrides equal to the default so "customized" stays accurate.
    private func tidy() {
        for (id, value) in overrides where value == command(id)?.defaultCombo { overrides.removeValue(forKey: id) }
    }
    private func save() {
        var out: [String: String] = [:]
        for (id, value) in overrides { out[id] = value?.text ?? "" }
        if let data = try? JSONEncoder().encode(out) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
