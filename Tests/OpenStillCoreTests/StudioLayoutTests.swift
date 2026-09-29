import Foundation
import Testing
@testable import OpenStillCore

@Suite struct StudioLayoutTests {
    func defaults() -> UserDefaults {
        let name = "StudioLayoutTests-" + UUID().uuidString
        let d = UserDefaults(suiteName: name)!; d.removePersistentDomain(forName: name); return d
    }

    @Test func tabsOpenSwitchAndCloseLikeABrowser() {
        var tabs = OpenPhotoTabs()
        tabs.open("/p/a.raf"); tabs.open("/p/b.raf"); tabs.open("/p/c.raf")
        #expect(tabs.paths == ["/p/a.raf", "/p/b.raf", "/p/c.raf"] && tabs.active == "/p/c.raf")
        // Opening one that's open just switches to it.
        tabs.open("/p/a.raf")
        #expect(tabs.paths.count == 3 && tabs.active == "/p/a.raf")
        // Closing the active tab shows the one to its right, or its left at the end.
        #expect(tabs.close("/p/a.raf") == "/p/b.raf")
        tabs.open("/p/c.raf")
        #expect(tabs.close("/p/c.raf") == "/p/b.raf" && tabs.paths == ["/p/b.raf"])
        // Closing a tab that isn't active leaves the active one.
        tabs.open("/p/d.raf"); tabs.open("/p/b.raf")
        #expect(tabs.close("/p/d.raf") == "/p/b.raf")
        #expect(tabs.close("/p/b.raf") == nil && tabs.paths.isEmpty && tabs.active == nil)
    }

    @Test func pastTheLimitTheOldestUneditedPhotoCloses() {
        var tabs = OpenPhotoTabs()
        tabs.open("/p/0.jpg", edited: true)
        for i in 1..<OpenPhotoTabs.limit { tabs.open("/p/\(i).jpg") }
        #expect(tabs.paths.count == OpenPhotoTabs.limit)
        tabs.open("/p/new.jpg")
        // The edited first photo stays; the oldest unedited one (1) goes.
        #expect(tabs.paths.count == OpenPhotoTabs.limit && tabs.paths.first == "/p/0.jpg" && !tabs.paths.contains("/p/1.jpg") && tabs.active == "/p/new.jpg")
        // When every tab is edited, the oldest one goes.
        var all = OpenPhotoTabs()
        for i in 0..<OpenPhotoTabs.limit { all.open("/e/\(i).jpg", edited: true) }
        all.open("/e/more.jpg", edited: true)
        #expect(!all.paths.contains("/e/0.jpg") && all.paths.last == "/e/more.jpg")
    }

    @Test func tabsFollowEditsRenamesAndMissingFiles() {
        var tabs = OpenPhotoTabs()
        tabs.open("/p/a.jpg"); tabs.open("/p/b.jpg")
        tabs.setEdited("/p/a.jpg", true)
        #expect(tabs.edited == ["/p/a.jpg"])
        tabs.setEdited("/p/zzz.jpg", true)
        #expect(tabs.edited == ["/p/a.jpg"])
        tabs.rename(["/p/a.jpg": "/p/Trip-001.jpg"])
        #expect(tabs.paths == ["/p/Trip-001.jpg", "/p/b.jpg"] && tabs.edited == ["/p/Trip-001.jpg"])
        tabs.prune { $0 != "/p/b.jpg" }
        #expect(tabs.paths == ["/p/Trip-001.jpg"] && tabs.active == "/p/Trip-001.jpg")
    }

    @Test func tabsAreRememberedPerCatalog() {
        let d = defaults()
        var tabs = OpenPhotoTabs(); tabs.open("/p/a.jpg", edited: true); tabs.open("/p/b.jpg")
        tabs.save(root: URL(fileURLWithPath: "/catalog/one"), defaults: d)
        #expect(OpenPhotoTabs.load(root: URL(fileURLWithPath: "/catalog/one"), defaults: d) == tabs)
        #expect(OpenPhotoTabs.load(root: URL(fileURLWithPath: "/catalog/two"), defaults: d).paths.isEmpty)
    }

    @Test func layoutRemembersPanelsAndClampsTheWidth() {
        let d = defaults()
        var layout = StudioLayout()
        #expect(layout.panelWidth == 300 && !layout.panelHidden && !layout.filmstripShown)
        layout.panelWidth = 900
        #expect(layout.panelWidth == 420)
        layout.panelWidth = 10
        #expect(layout.panelWidth == 240)
        #expect(StudioLayout.clamp(.nan) == StudioLayout.defaultPanelWidth && StudioLayout.clamp(333.4) == 333)
        layout.filmstripShown = true; layout.libraryTab = 1
        layout.save(to: d)
        #expect(StudioLayout.load(from: d) == layout)
        // Tab hides the rail and the panel together; Shift-Tab every bar.
        layout.toggleSidePanels()
        #expect(layout.panelHidden && layout.railHidden && !layout.optionsBarHidden)
        layout.toggleSidePanels()
        #expect(!layout.panelHidden && !layout.railHidden)
        layout.toggleAllChrome()
        #expect(layout.panelHidden && layout.railHidden && layout.optionsBarHidden)
        layout.toggleAllChrome()
        #expect(!layout.panelHidden && !layout.railHidden && !layout.optionsBarHidden)
    }

    @Test func firstLaunchCarriesOverTheOldPanelChoices() {
        let d = defaults()
        var old = LightroomPanels(); old.hidden = [.right]; old.toolbarHidden = true; old.save(to: d)
        let layout = StudioLayout.load(from: d)
        #expect(layout.panelHidden && layout.optionsBarHidden && !layout.railHidden)
        // A saved EZ Layout choice from an old version doesn't matter anymore.
        d.set("luminar", forKey: "OpenStillWorkspaceLayout")
        #expect(StudioLayout.load(from: d).panelHidden)
    }

    @Test func everyToolHasASymbolAHintAndAKeyWhereLightroomHasOne() {
        for tool in StudioTool.allCases {
            #expect(!tool.title.isEmpty && !tool.symbol.isEmpty && !tool.hint.isEmpty)
        }
        #expect(StudioTool.crop.shortcutID == "workspace.crop" && StudioTool.remove.shortcutID == "workspace.remove" && StudioTool.masking.shortcutID == "workspace.masking")
        #expect(!StudioTool.adjust.needsPhoto && StudioTool.crop.needsPhoto)
        #expect(Set(StudioTool.allCases.compactMap(\.shortcutID)).count == StudioTool.allCases.compactMap(\.shortcutID).count)
    }
}
