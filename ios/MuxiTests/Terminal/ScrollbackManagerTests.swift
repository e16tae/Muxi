import XCTest
@testable import Muxi

@MainActor
final class ScrollbackManagerTests: XCTestCase {

    private let pane0 = PaneID(index: 0)
    private let pane1 = PaneID(index: 1)

    func testInitialStateIsLive() {
        let manager = ScrollbackManager()
        XCTAssertEqual(manager.state(for: pane0), .live)
        XCTAssertNil(manager.cache(for: pane0))
    }

    func testSetLoadingState() {
        let manager = ScrollbackManager()
        manager.setLoading(paneId: pane0)
        XCTAssertEqual(manager.state(for: pane0), .loading)
    }

    func testSetScrollingWithCache() {
        let manager = ScrollbackManager()
        let buffer = TerminalBuffer(cols: 80, rows: 100)
        manager.setScrolling(paneId: pane0, offset: 5, totalLines: 100, cache: buffer)
        XCTAssertEqual(manager.state(for: pane0), .scrolling(offset: 5, totalLines: 100))
        XCTAssertNotNil(manager.cache(for: pane0))
    }

    func testReturnToLive() {
        let manager = ScrollbackManager()
        let buffer = TerminalBuffer(cols: 80, rows: 100)
        manager.setScrolling(paneId: pane0, offset: 5, totalLines: 100, cache: buffer)
        manager.returnToLive(paneId: pane0)
        XCTAssertEqual(manager.state(for: pane0), .live)
        XCTAssertNil(manager.cache(for: pane0))
    }

    func testReturnAllToLive() {
        let manager = ScrollbackManager()
        let buf1 = TerminalBuffer(cols: 80, rows: 50)
        let buf2 = TerminalBuffer(cols: 80, rows: 50)
        manager.setScrolling(paneId: pane0, offset: 1, totalLines: 50, cache: buf1)
        manager.setScrolling(paneId: pane1, offset: 3, totalLines: 50, cache: buf2)
        manager.returnAllToLive()
        XCTAssertEqual(manager.state(for: pane0), .live)
        XCTAssertEqual(manager.state(for: pane1), .live)
        XCTAssertTrue(manager.scrolledPaneIds.isEmpty)
    }

    func testScrolledPaneIds() {
        let manager = ScrollbackManager()
        let buffer = TerminalBuffer(cols: 80, rows: 50)
        manager.setScrolling(paneId: pane0, offset: 1, totalLines: 50, cache: buffer)
        XCTAssertTrue(manager.scrolledPaneIds.contains(pane0))
        manager.returnToLive(paneId: pane0)
        XCTAssertFalse(manager.scrolledPaneIds.contains(pane0))
    }

    func testUpdateOffset() {
        let manager = ScrollbackManager()
        let buffer = TerminalBuffer(cols: 80, rows: 100)
        manager.setScrolling(paneId: pane0, offset: 5, totalLines: 100, cache: buffer)
        manager.updateOffset(paneId: pane0, offset: 10, totalLines: 100)
        XCTAssertEqual(manager.state(for: pane0), .scrolling(offset: 10, totalLines: 100))
    }
}
