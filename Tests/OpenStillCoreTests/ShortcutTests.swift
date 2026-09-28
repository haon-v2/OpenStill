import Foundation
import Testing
@testable import OpenStillCore

@Suite final class ShortcutTests {
    let suite = "OpenStillShortcutTests-" + UUID().uuidString
    let defaults: UserDefaults
    init() { defaults = UserDefaults(suiteName: suite)! }
    deinit { UserDefaults().removePersistentDomain(forName: suite) }

    func map() -> ShortcutMap {
        let m = ShortcutMap(defaults: defaults)
        m.register(ShortcutCommand(id: "file.open", title: "Open Photo or Folder…", group: "File", defaultCombo: KeyCombo("o", command: true)))
        m.register(ShortcutCommand(id: "file.print", title: "Print…", group: "File", defaultCombo: KeyCombo("p", command: true)))
        m.register(ShortcutCommand(id: "file.export", title: "Export Edited Photo…", group: "File", defaultCombo: KeyCombo("e", command: true, shift: true)))
        m.register(ShortcutCommand(id: "library.pick", title: "Flag as pick", group: "Library grid", scope: .library, defaultCombo: KeyCombo("p")))
        m.register(ShortcutCommand(id: "editor.split", title: "Before / after split", group: "Photo", scope: .editor, defaultCombo: KeyCombo("y")))
        m.register(ShortcutCommand(id: "editor.pickish", title: "Something with P", group: "Photo", scope: .editor, defaultCombo: nil))
        return m
    }

    @Test func combosDisplayParseAndRoundTrip() throws {
        let c = KeyCombo("O", command: true, shift: true, option: true, control: true)
        #expect(c.key == "o" && c.display == "⌃⌥⇧⌘O" && c.text == "ctrl+opt+shift+cmd+o" && c.spoken == "Control Option Shift Command O")
        #expect(KeyCombo(text: "cmd+shift+o") == KeyCombo("o", command: true, shift: true))
        #expect(KeyCombo(text: "cmd++") == KeyCombo("+", command: true) && KeyCombo(text: "+") == KeyCombo("+"))
        #expect(KeyCombo(text: "cmd+left")?.display == "⌘←" && KeyCombo(text: "space")?.display == "Space" && KeyCombo(text: "f5")?.display == "F5")
        #expect(KeyCombo(text: "hyper+o") == nil && KeyCombo(text: "cmd+") == nil && KeyCombo(text: "cmd+ab") == nil)
        #expect(KeyCombo("\u{7f}").key == "delete" && KeyCombo(" ").key == "space" && KeyCombo("\r").key == "return" && KeyCombo("\u{1b}").key == "escape")
        #expect(KeyCombo("left").isSpecial && !KeyCombo("a").isSpecial && KeyCombo("a", option: true).hasModifier && !KeyCombo("a", shift: true).hasModifier)
        let data = try JSONEncoder().encode([c])
        #expect(String(decoding: data, as: UTF8.self) == "[\"ctrl+opt+shift+cmd+o\"]")
        #expect(try JSONDecoder().decode([KeyCombo].self, from: data) == [c])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([KeyCombo].self, from: Data("[\"nonsense+x\"]".utf8)) }
    }

    @Test func changingAShortcutSavesAndSurvivesRelaunch() {
        let m = map()
        #expect(m.combo(for: "file.open") == KeyCombo("o", command: true) && !m.isCustomized("file.open"))
        var notified = 0; m.changed = { notified += 1 }
        m.set(KeyCombo("o", command: true, option: true), for: "file.open")
        #expect(m.combo(for: "file.open")?.display == "⌥⌘O" && m.isCustomized("file.open") && notified == 1)
        // Removed shortcuts stay removed; setting the default again stops counting as customized.
        m.set(nil, for: "file.export")
        #expect(m.combo(for: "file.export") == nil && m.isCustomized("file.export"))
        let reopened = map()
        #expect(reopened.combo(for: "file.open")?.display == "⌥⌘O" && reopened.combo(for: "file.export") == nil)
        reopened.set(KeyCombo("o", command: true), for: "file.open")
        #expect(!reopened.isCustomized("file.open") && reopened.overrides["file.open"] == nil)
        reopened.reset("file.export")
        #expect(reopened.combo(for: "file.export")?.display == "⇧⌘E")
        reopened.set(KeyCombo("x", command: true, control: true), for: "file.print")
        reopened.resetAll()
        #expect(reopened.overrides.isEmpty && map().combo(for: "file.print")?.display == "⌘P")
        // Unknown commands are ignored.
        reopened.set(KeyCombo("q", command: true), for: "nope")
        #expect(reopened.combo(for: "nope") == nil)
    }

    @Test func theOpenToCommandPExampleTakesItFromPrint() {
        let m = map()
        let cmdP = KeyCombo("p", command: true)
        #expect(m.conflicts(for: cmdP, assigningTo: "file.open").map(\.id) == ["file.print"])
        m.set(cmdP, for: "file.open")
        #expect(m.combo(for: "file.open") == cmdP && m.combo(for: "file.print") == nil)
        // Single keys only clash within their own place: P in the library doesn't clash with the photo view.
        #expect(m.conflicts(for: KeyCombo("p"), assigningTo: "editor.pickish").isEmpty)
        #expect(m.conflicts(for: KeyCombo("p"), assigningTo: "library.pick").isEmpty)
        #expect(m.conflicts(for: KeyCombo("y"), assigningTo: "library.pick").isEmpty)
        // A menu shortcut clashes with a single-key one everywhere.
        m.set(KeyCombo("y", command: true), for: "editor.split")
        #expect(m.conflicts(for: KeyCombo("y", command: true), assigningTo: "file.export").map(\.id) == ["editor.split"])
    }

    @Test func keyPressesFindTheirCommandInTheRightPlace() {
        let m = map()
        #expect(m.command(for: KeyCombo("p"), in: .library)?.id == "library.pick")
        #expect(m.command(for: KeyCombo("p"), in: .editor) == nil)
        #expect(m.command(for: KeyCombo("y"), in: .editor)?.id == "editor.split")
        m.set(KeyCombo("k"), for: "library.pick")
        #expect(m.command(for: KeyCombo("p"), in: .library) == nil && m.command(for: KeyCombo("k"), in: .library)?.id == "library.pick")
    }

    @Test func searchFindsTitlesGroupsAndKeys() {
        let m = map()
        #expect(m.search("").count == 6)
        #expect(m.search("export").map(\.id) == ["file.export"])
        #expect(m.search("⇧⌘E").map(\.id) == ["file.export"])
        #expect(Set(m.search("library").map(\.id)) == ["library.pick"])
        #expect(m.search("shift command e").map(\.id) == ["file.export"])
        #expect(m.search("zzz").isEmpty)
    }

    @Test func thereIsOneLayout() {
        let key = WorkspaceLayout.defaultsKey, saved = UserDefaults.standard.string(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        // An EZ Layout choice saved by an older version is ignored.
        UserDefaults.standard.set("luminar", forKey: key)
        #expect(WorkspaceLayout.current == .lightroom)
        #expect(WorkspaceLayout.current.modeNames.library == "Library" && WorkspaceLayout.current.modeNames.edit == "Develop")
    }
}
