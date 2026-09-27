import Foundation
import Testing
@testable import OpenStillCore

@Suite final class LightroomWorkspaceTests {
    let suite = "OpenStillLightroomTests-" + UUID().uuidString
    let defaults: UserDefaults
    init() { defaults = UserDefaults(suiteName: suite)! }
    deinit { UserDefaults().removePersistentDomain(forName: suite) }

    @Test func modulesMatchLightroomWithoutBook() {
        #expect(LightroomModule.allCases.map(\.title) == ["Library", "Develop", "Map", "Slideshow", "Print", "Web"])
        #expect(LightroomModule.allCases.filter(\.isWorkspace) == [.library, .develop])
    }

    @Test func tabAndShiftTabHideAndShowPanelsLikeLightroom() {
        var p = LightroomPanels()
        #expect(PanelEdge.allCases.allSatisfy { p.isVisible($0) })
        p.toggleSidePanels()
        #expect(!p.isVisible(.left) && !p.isVisible(.right) && p.isVisible(.top) && p.isVisible(.bottom))
        p.toggleSidePanels()
        #expect(p.isVisible(.left) && p.isVisible(.right))
        // With only one side hidden, Tab shows both.
        p.toggle(.left); p.toggleSidePanels()
        #expect(p.isVisible(.left) && p.isVisible(.right))
        p.toggleAllPanels()
        #expect(p.hidden == Set(PanelEdge.allCases))
        p.toggleAllPanels()
        #expect(p.hidden.isEmpty)
        // Shift-Tab with any panel hidden shows everything.
        p.toggle(.bottom); p.toggleAllPanels()
        #expect(p.hidden.isEmpty)
    }

    @Test func soloModeKeepsOneSectionOpen() {
        var p = LightroomPanels()
        let basic = LightroomPanels.key(.develop, .right, "Basic"), curve = LightroomPanels.key(.develop, .right, "Tone Curve"), detail = LightroomPanels.key(.develop, .right, "Detail")
        let group = LightroomPanels.group(.develop, .right), all = [basic, curve, detail]
        #expect(basic == "develop.right.Basic" && group == "develop.right")
        #expect(p.isExpanded(basic, default: true) && !p.isExpanded(curve, default: false))
        p.setExpanded(curve, true, siblings: all)
        #expect(p.isExpanded(curve, default: false) && p.isExpanded(basic, default: true))
        p.toggleSolo(group, keep: detail, siblings: all)
        #expect(p.solo.contains(group) && p.isExpanded(detail, default: false) && !p.isExpanded(basic, default: true) && !p.isExpanded(curve, default: false))
        p.setExpanded(basic, true, siblings: all)
        #expect(p.isExpanded(basic, default: false) && !p.isExpanded(detail, default: true))
        // Solo mode in one panel leaves the other panels alone.
        let presets = LightroomPanels.key(.develop, .left, "Presets"), history = LightroomPanels.key(.develop, .left, "History")
        p.setExpanded(presets, true, siblings: [presets, history]); p.setExpanded(history, true, siblings: [presets, history])
        #expect(p.isExpanded(presets, default: false) && p.isExpanded(history, default: false))
        p.toggleSolo(group, keep: nil, siblings: all)
        #expect(!p.solo.contains(group))
    }

    @Test func panelsAreRememberedAndLightsOutCycles() {
        #expect(LightroomPanels.load(from: defaults) == LightroomPanels())
        var p = LightroomPanels(); p.toggle(.left); p.toolbarHidden = true
        p.setExpanded(LightroomPanels.key(.library, .left, "Folders"), false)
        p.save(to: defaults)
        #expect(LightroomPanels.load(from: defaults) == p)
        defaults.set(Data("nonsense".utf8), forKey: LightroomPanels.defaultsKey)
        #expect(LightroomPanels.load(from: defaults) == LightroomPanels())
        #expect(LightsOut.normal.next == .dim && LightsOut.dim.next == .off && LightsOut.off.next == .normal)
        #expect(LightsOut.normal.chromeOpacity == 1 && LightsOut.off.chromeOpacity == 0 && LightsOut.dim.chromeOpacity < 0.5)
    }

    @Test func workspaceKeysClashWithLibraryAndPhotoKeysButNotEachOther() {
        let m = ShortcutMap(defaults: defaults)
        m.register(ShortcutCommand(id: "workspace.grid", title: "Library grid (G)", group: "Workspace", scope: .workspace, defaultCombo: KeyCombo("g")))
        m.register(ShortcutCommand(id: "library.pick", title: "Flag as pick", group: "Library grid", scope: .library, defaultCombo: KeyCombo("p")))
        m.register(ShortcutCommand(id: "editor.split", title: "Before / after split", group: "Photo", scope: .editor, defaultCombo: KeyCombo("y")))
        #expect(m.conflicts(for: KeyCombo("p"), assigningTo: "workspace.grid").map(\.id) == ["library.pick"])
        #expect(m.conflicts(for: KeyCombo("y"), assigningTo: "workspace.grid").map(\.id) == ["editor.split"])
        #expect(m.conflicts(for: KeyCombo("g"), assigningTo: "library.pick").map(\.id) == ["workspace.grid"])
        #expect(m.command(for: KeyCombo("g"), in: .workspace)?.id == "workspace.grid" && m.command(for: KeyCombo("g"), in: .library) == nil)
        #expect(ShortcutScope.library.overlaps(.workspace) && !ShortcutScope.library.overlaps(.editor) && ShortcutScope.menu.overlaps(.editor))
    }

    @Test func previousCopiesSettingsButNotCropOrRetouching() throws {
        var previous = PhotoEdits(); previous.exposure = 0.8; previous.clarity = 0.4
        previous.rotation = 1
        var current = PhotoEdits(); current.rotation = 2
        let merged = try BatchEdits.merging(previous, into: current, options: BatchOptions(), geometryCompatible: false)
        #expect(merged.exposure == 0.8 && merged.clarity == 0.4 && merged.rotation == 2)
    }
}
