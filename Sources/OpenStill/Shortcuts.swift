import AppKit
import OpenStillCore

/// All keyboard shortcuts: menu commands and the single-key shortcuts in the library and editor.
/// Any of them can be changed in Settings → Shortcuts; menus update immediately.
@MainActor enum Shortcuts {
    static let map = ShortcutMap()
    private static var menuItems: [String: NSMenuItem] = [:]
    static let changedNotification = Notification.Name("OpenStillShortcutsChanged")

    /// A menu item whose shortcut comes from the map. `key`/`modifiers` are its default.
    static func menuItem(_ id: String, title: String, group: String, action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        map.register(ShortcutCommand(id: id, title: title, group: group, scope: .menu, defaultCombo: combo(key: key, modifiers: modifiers)))
        menuItems[id] = item
        apply(id)
        return item
    }
    static func apply(_ id: String) {
        guard let item = menuItems[id] else { return }
        if let combo = map.combo(for: id), let (key, mask) = keyEquivalent(combo) {
            item.keyEquivalent = key; item.keyEquivalentModifierMask = mask
        } else { item.keyEquivalent = ""; item.keyEquivalentModifierMask = [] }
    }

    /// Single-key shortcuts that aren't menu commands.
    static func registerKeys() {
        let library: [(String, String, String)] = [
            ("library.rate0", "Clear rating", "0"), ("library.rate1", "Rate 1 star", "1"), ("library.rate2", "Rate 2 stars", "2"), ("library.rate3", "Rate 3 stars", "3"),
            ("library.rate4", "Rate 4 stars", "4"), ("library.rate5", "Rate 5 stars", "5"),
            ("library.label.red", "Red label", "6"), ("library.label.yellow", "Yellow label", "7"), ("library.label.green", "Green label", "8"), ("library.label.blue", "Blue label", "9"),
            ("library.pick", "Flag as pick", "p"), ("library.reject", "Flag as reject", "x"), ("library.unflag", "Remove flag", "u"), ("library.open", "Edit selected photo", "return"),
        ]
        for (id, title, key) in library { map.register(ShortcutCommand(id: id, title: title, group: "Library grid", scope: .library, defaultCombo: KeyCombo(key))) }
        let editor: [(String, String, KeyCombo?)] = [
            ("editor.clipping", "Show or hide clipping", KeyCombo("j")), ("editor.split", "Before / after split", KeyCombo("y")),
            ("editor.compare", "Compare with original", KeyCombo("\\")),
            ("editor.previousAlt", "Previous photo (alternate)", KeyCombo("up")), ("editor.nextAlt", "Next photo (alternate)", KeyCombo("down")),
            ("editor.nextSpace", "Next photo (Space)", KeyCombo("space")), ("editor.previousSpace", "Previous photo (Shift-Space)", KeyCombo("space", shift: true)),
            ("editor.trash", "Move photo to Trash", KeyCombo("delete")), ("editor.escape", "Cancel tool or leave full screen", KeyCombo("escape")),
            ("editor.brushSmaller", "Smaller mask brush", KeyCombo("[")), ("editor.brushLarger", "Larger mask brush", KeyCombo("]")),
        ]
        for (id, title, combo) in editor { map.register(ShortcutCommand(id: id, title: title, group: "Photo and filmstrip", scope: .editor, defaultCombo: combo)) }
        map.changed = {
            MainActor.assumeIsolated {
                for id in menuItems.keys { apply(id) }
                NotificationCenter.default.post(name: changedNotification, object: nil)
            }
        }
    }

    /// The command a key press triggers in the library grid or on the photo.
    static func command(for event: NSEvent, in scope: ShortcutScope) -> String? {
        combo(from: event).flatMap { map.command(for: $0, in: scope)?.id }
    }

    /// −1 or 1 when the key is the View menu's Previous or Next Photo shortcut, for views that get the key before the menu does.
    static func menuStep(for event: NSEvent) -> Int? {
        guard let combo = combo(from: event) else { return nil }
        if combo == map.combo(for: "view.previous-photo") { return -1 }
        if combo == map.combo(for: "view.next-photo") { return 1 }
        return nil
    }
    // MARK: Conversions
    private static let keyCodes: [UInt16: String] = [
        123: "left", 124: "right", 125: "down", 126: "up", 49: "space", 36: "return", 76: "return", 48: "tab", 51: "delete", 117: "forwarddelete",
        53: "escape", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]
    private static let functionKeys: [String: Int] = [
        "left": NSLeftArrowFunctionKey, "right": NSRightArrowFunctionKey, "up": NSUpArrowFunctionKey, "down": NSDownArrowFunctionKey,
        "home": NSHomeFunctionKey, "end": NSEndFunctionKey, "pageup": NSPageUpFunctionKey, "pagedown": NSPageDownFunctionKey, "forwarddelete": NSDeleteFunctionKey,
        "f1": NSF1FunctionKey, "f2": NSF2FunctionKey, "f3": NSF3FunctionKey, "f4": NSF4FunctionKey, "f5": NSF5FunctionKey, "f6": NSF6FunctionKey,
        "f7": NSF7FunctionKey, "f8": NSF8FunctionKey, "f9": NSF9FunctionKey, "f10": NSF10FunctionKey, "f11": NSF11FunctionKey, "f12": NSF12FunctionKey,
    ]
    static func combo(from event: NSEvent) -> KeyCombo? {
        let flags = event.modifierFlags
        let key: String
        if let special = keyCodes[event.keyCode] { key = special }
        else if let base = event.characters(byApplyingModifiers: [])?.lowercased(), let first = base.first, !base.isEmpty { key = String(first) }
        else { return nil }
        return KeyCombo(key, command: flags.contains(.command), shift: flags.contains(.shift), option: flags.contains(.option), control: flags.contains(.control))
    }
    /// A menu's default key equivalent as a combo.
    static func combo(key: String, modifiers: NSEvent.ModifierFlags) -> KeyCombo? {
        guard let scalar = key.unicodeScalars.first else { return nil }
        var name = key
        if let function = functionKeys.first(where: { $0.value == Int(scalar.value) })?.key { name = function }
        else if key == "\u{7f}" || key == "\u{8}" { name = "delete" }
        return KeyCombo(name, command: modifiers.contains(.command), shift: modifiers.contains(.shift), option: modifiers.contains(.option), control: modifiers.contains(.control))
    }
    static func keyEquivalent(_ combo: KeyCombo) -> (String, NSEvent.ModifierFlags)? {
        var mask: NSEvent.ModifierFlags = []
        if combo.command { mask.insert(.command) }; if combo.shift { mask.insert(.shift) }; if combo.option { mask.insert(.option) }; if combo.control { mask.insert(.control) }
        let key: String
        if let function = functionKeys[combo.key], let scalar = UnicodeScalar(function) { key = String(Character(scalar)) }
        else {
            switch combo.key {
            case "space": key = " "
            case "return": key = "\r"
            case "tab": key = "\t"
            case "delete": key = "\u{7f}"
            case "escape": key = "\u{1b}"
            default: guard combo.key.count == 1 else { return nil }; key = combo.key
            }
        }
        return (key, mask)
    }
}
