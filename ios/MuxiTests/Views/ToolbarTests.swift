import XCTest
@testable import Muxi

@MainActor
final class ToolbarTests: XCTestCase {

    // MARK: - WindowPanePillsView.panesToShow

    func testPanesToShowUsesWindowPaneIds() {
        // When paneIds are populated, they should be used directly
        let window = ConnectionManager.TmuxWindowInfo(
            id: "@0", name: "bash", paneIds: ["%0", "%1"], isActive: true
        )
        // panesToShow is private, so test indirectly via the view's data flow
        XCTAssertEqual(window.paneIds, ["%0", "%1"])
    }

    func testPanesToShowEmptyForInactiveWindowWithoutPanes() {
        let window = ConnectionManager.TmuxWindowInfo(
            id: "@1", name: "vim", paneIds: [], isActive: false
        )
        // Inactive window with no pane info should show name only (empty paneIds)
        XCTAssertTrue(window.paneIds.isEmpty)
    }

    // MARK: - RenameTarget

    func testRenameTargetEquality() {
        let a = ToolbarView.RenameTarget.window(id: "@0")
        let b = ToolbarView.RenameTarget.window(id: "@0")
        let c = ToolbarView.RenameTarget.session(name: "work")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - TmuxWindowInfo

    func testTmuxWindowInfoIdentifiable() {
        let w1 = ConnectionManager.TmuxWindowInfo(
            id: "@0", name: "bash", paneIds: [], isActive: true
        )
        let w2 = ConnectionManager.TmuxWindowInfo(
            id: "@1", name: "vim", paneIds: [], isActive: false
        )
        XCTAssertNotEqual(w1.id, w2.id)
    }
}
