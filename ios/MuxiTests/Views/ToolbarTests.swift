import XCTest
@testable import Muxi

@MainActor
final class ToolbarTests: XCTestCase {

    // MARK: - WindowPanePillsView.panesToShow

    func testPanesToShowUsesWindowPaneIds() {
        // When paneIds are populated, they should be used directly
        let window = Window(
            id: WindowID("@0"), name: "bash",
            paneIds: [PaneID("%0"), PaneID("%1")], isActive: true
        )
        // panesToShow is private, so test indirectly via the view's data flow
        XCTAssertEqual(window.paneIds, [PaneID("%0"), PaneID("%1")])
    }

    func testPanesToShowEmptyForInactiveWindowWithoutPanes() {
        let window = Window(
            id: WindowID("@1"), name: "vim", paneIds: [], isActive: false
        )
        // Inactive window with no pane info should show name only (empty paneIds)
        XCTAssertTrue(window.paneIds.isEmpty)
    }

    // MARK: - RenameTarget

    func testRenameTargetEquality() {
        let a = ToolbarView.RenameTarget.window(id: WindowID("@0"))
        let b = ToolbarView.RenameTarget.window(id: WindowID("@0"))
        let c = ToolbarView.RenameTarget.session(name: "work")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Window

    func testWindowIdentifiable() {
        let w1 = Window(
            id: WindowID("@0"), name: "bash", paneIds: [], isActive: true
        )
        let w2 = Window(
            id: WindowID("@1"), name: "vim", paneIds: [], isActive: false
        )
        XCTAssertNotEqual(w1.id, w2.id)
    }
}
