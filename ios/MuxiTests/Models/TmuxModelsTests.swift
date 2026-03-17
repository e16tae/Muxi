import Foundation
import Testing

@testable import Muxi

// MARK: - Pane Tests

@Suite("Pane Tests")
struct PaneTests {

    @Test("Pane creation with CellFrame")
    func paneCreation() {
        let pane = Pane(
            id: PaneID(index: 0),
            frame: Pane.CellFrame(x: 0, y: 0, width: 80, height: 24)
        )
        #expect(pane.id == PaneID("%0"))
        #expect(pane.frame.width == 80)
        #expect(pane.frame.height == 24)
    }

    @Test("Pane equality")
    func paneEquality() {
        let a = Pane(id: PaneID(index: 0), frame: Pane.CellFrame(x: 0, y: 0, width: 80, height: 24))
        let b = Pane(id: PaneID(index: 0), frame: Pane.CellFrame(x: 0, y: 0, width: 80, height: 24))
        let c = Pane(id: PaneID(index: 1), frame: Pane.CellFrame(x: 0, y: 0, width: 80, height: 24))
        #expect(a == b)
        #expect(a != c)
    }
}

// MARK: - Window Tests

@Suite("Window Tests")
struct WindowTests {

    @Test("Window creation")
    func windowCreation() {
        let window = Window(
            id: WindowID("@0"),
            name: "bash",
            paneIds: [PaneID("%0"), PaneID("%1")],
            isActive: true
        )
        #expect(window.id == WindowID("@0"))
        #expect(window.name == "bash")
        #expect(window.paneIds.count == 2)
        #expect(window.isActive == true)
    }
}

// MARK: - TmuxSession Tests

@Suite("TmuxSession Tests")
struct TmuxSessionTests {

    @Test("TmuxSession creation")
    func sessionCreation() {
        let now = Date()
        let session = TmuxSession(
            id: "$0",
            name: "dev",
            windows: [],
            createdAt: now,
            lastActivity: now
        )

        #expect(session.id == "$0")
        #expect(session.name == "dev")
        #expect(session.windows.isEmpty)
        #expect(session.createdAt == now)
        #expect(session.lastActivity == now)
    }

    @Test("TmuxSession equality")
    func sessionEquality() {
        let now = Date()
        let a = TmuxSession(id: "$0", name: "dev", windows: [], createdAt: now, lastActivity: now)
        let b = TmuxSession(id: "$0", name: "dev", windows: [], createdAt: now, lastActivity: now)
        #expect(a == b)
    }
}

// MARK: - TmuxID Tests

@Suite("TmuxID Tests")
struct TmuxIDTests {

    @Test("PaneID init(index:) adds percent prefix")
    func paneIdFromIndex() {
        let id = PaneID(index: 5)
        #expect(id.rawValue == "%5")
        #expect(id.description == "%5")
    }

    @Test("PaneID init(_:) preserves raw string")
    func paneIdFromString() {
        let id = PaneID("%42")
        #expect(id.rawValue == "%42")
    }

    @Test("WindowID preserves raw string")
    func windowId() {
        let id = WindowID("@0")
        #expect(id.rawValue == "@0")
        #expect(id.description == "@0")
    }

    @Test("PaneID and WindowID are not interchangeable at compile time")
    func typeDistinction() {
        // This test verifies the types exist and are distinct.
        // Compile-time type safety is the real test — if these were both
        // plain String, accidental mixups would be invisible.
        let pane = PaneID("%0")
        let window = WindowID("@0")
        #expect(pane.rawValue != window.rawValue)
    }
}
