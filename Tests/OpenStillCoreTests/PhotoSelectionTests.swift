import Testing
@testable import OpenStillCore

struct PhotoSelectionTests {
    @Test func commandClickTogglesIndividualPhotos() {
        var selection = PhotoSelection()
        selection.click(1)
        selection.click(4, toggling: true)
        #expect(selection.indices == [1, 4])
        selection.click(1, toggling: true)
        #expect(selection.indices == [4])
        #expect(selection.active == 4)
        selection.click(4, toggling: true)
        #expect(selection.indices.isEmpty)
        #expect(selection.active == nil)
    }
    @Test func shiftRangeExtendsAndShrinksFromAnchor() {
        var selection = PhotoSelection()
        selection.click(2)
        selection.click(5, extending: true)
        #expect(selection.indices == [2, 3, 4, 5])
        selection.click(3, extending: true)
        #expect(selection.indices == [2, 3])
        selection.click(0, extending: true)
        #expect(selection.indices == [0, 1, 2])
    }
    @Test func singleClickReplacesSelectAllAndKeyboardRangeClamps() {
        var selection = PhotoSelection()
        selection.selectAll(count: 3)
        #expect(selection.indices == [0, 1, 2])
        selection.click(0)
        #expect(selection.indices == [0])
        selection.extend(by: 1, count: 3)
        #expect(selection.indices == [0, 1])
        selection.extend(by: -1, count: 3)
        #expect(selection.indices == [0])
        selection.extend(by: -1, count: 3)
        #expect(selection.indices == [0])
        selection.extend(by: 100, count: 3)
        #expect(selection.indices == [0, 1, 2])
        selection.selectAll(count: 0)
        #expect(selection.indices.isEmpty)
    }
}
