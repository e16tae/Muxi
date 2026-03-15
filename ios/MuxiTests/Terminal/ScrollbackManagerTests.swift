import XCTest
@testable import Muxi

@MainActor
final class ScrollbackManagerTests: XCTestCase {

    func testInitialStateIsLive() {
        let manager = ScrollbackManager()
        XCTAssertEqual(manager.state(for: "%0"), .live)
        XCTAssertNil(manager.cache(for: "%0"))
    }

    func testSetLoadingState() {
        let manager = ScrollbackManager()
        manager.setLoading(paneId: "%0")
        XCTAssertEqual(manager.state(for: "%0"), .loading)
    }

    func testSetScrollingWithCache() {
        let manager = ScrollbackManager()
        let buffer = TerminalBuffer(cols: 80, rows: 100)
        manager.setScrolling(paneId: "%0", offset: 5, totalLines: 100, cache: buffer)
        XCTAssertEqual(manager.state(for: "%0"), .scrolling(offset: 5, totalLines: 100))
        XCTAssertNotNil(manager.cache(for: "%0"))
    }

    func testReturnToLive() {
        let manager = ScrollbackManager()
        let buffer = TerminalBuffer(cols: 80, rows: 100)
        manager.setScrolling(paneId: "%0", offset: 5, totalLines: 100, cache: buffer)
        manager.returnToLive(paneId: "%0")
        XCTAssertEqual(manager.state(for: "%0"), .live)
        XCTAssertNil(manager.cache(for: "%0"))
    }

    func testReturnAllToLive() {
        let manager = ScrollbackManager()
        let buf1 = TerminalBuffer(cols: 80, rows: 50)
        let buf2 = TerminalBuffer(cols: 80, rows: 50)
        manager.setScrolling(paneId: "%0", offset: 1, totalLines: 50, cache: buf1)
        manager.setScrolling(paneId: "%1", offset: 3, totalLines: 50, cache: buf2)
        manager.returnAllToLive()
        XCTAssertEqual(manager.state(for: "%0"), .live)
        XCTAssertEqual(manager.state(for: "%1"), .live)
        XCTAssertTrue(manager.scrolledPaneIds.isEmpty)
    }

    func testScrolledPaneIds() {
        let manager = ScrollbackManager()
        let buffer = TerminalBuffer(cols: 80, rows: 50)
        manager.setScrolling(paneId: "%0", offset: 1, totalLines: 50, cache: buffer)
        XCTAssertTrue(manager.scrolledPaneIds.contains("%0"))
        manager.returnToLive(paneId: "%0")
        XCTAssertFalse(manager.scrolledPaneIds.contains("%0"))
    }

    func testUpdateOffset() {
        let manager = ScrollbackManager()
        let buffer = TerminalBuffer(cols: 80, rows: 100)
        manager.setScrolling(paneId: "%0", offset: 5, totalLines: 100, cache: buffer)
        manager.updateOffset(paneId: "%0", offset: 10, totalLines: 100)
        XCTAssertEqual(manager.state(for: "%0"), .scrolling(offset: 10, totalLines: 100))
    }
}
