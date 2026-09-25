import Foundation
import Testing
@testable import OpenStillCore

struct MaskEditingSessionTests {
    @Test func switchingToolsRejectsAnOldSelectionEvenWhenReturning() {
        var session = MaskEditingSession()
        session.activate("Glow")
        let old = session.beginSelection()
        #expect(session.accepts(old,for:"Glow"))
        #expect(!session.accepts(old,for:"Color"))
        session.end()
        #expect(session.tool == nil && session.selection == nil)
        session.activate("Color")
        #expect(!session.accepts(old,for:"Glow"))
        session.activate("Glow")
        #expect(!session.accepts(old,for:"Glow"))
        let current = session.beginSelection()
        session.completeSelection(old)
        #expect(session.accepts(current,for:"Glow"))
        session.completeSelection(current)
        #expect(!session.accepts(current,for:"Glow"))
    }
    @Test func changingOwnerOrPhotoCancelsPendingSelectionWithoutChangingSavedMasks() throws {
        var edits = PhotoEdits()
        let glow = AdjustmentMask(kind:"linear"), color = AdjustmentMask(kind:"radial")
        edits.setMask(glow,for:"Glow"); edits.setMask(color,for:"Color")
        var session = MaskEditingSession();session.activate("Glow")
        let token = session.beginSelection()
        session.activate("Color")
        #expect(session.selection == nil && !session.accepts(token,for:"Glow"))
        _ = session.beginSelection()
        let cancelled = session.end(), alreadyEnded = session.end()
        #expect(cancelled && !alreadyEnded)
        let saved = try JSONDecoder().decode(PhotoEdits.self,from:JSONEncoder().encode(edits))
        #expect(saved.advanced?.masks["Glow"] == glow)
        #expect(saved.advanced?.masks["Color"] == color)
        #expect(saved.advanced?.masks["Develop"] == nil)
    }
}
