import Foundation
import Testing

@testable import Muxi

// MARK: - PaneSize Tests

@Suite("PaneSize Tests")
struct PaneSizeTests {

    @Test("PaneSize stores dimensions")
    func paneSizeCreation() {
        let size = PaneSize(columns: 80, rows: 24)
        #expect(size.columns == 80)
        #expect(size.rows == 24)
    }

    @Test("PaneSize equality")
    func paneSizeEquality() {
        let a = PaneSize(columns: 120, rows: 40)
        let b = PaneSize(columns: 120, rows: 40)
        let c = PaneSize(columns: 80, rows: 24)
        #expect(a == b)
        #expect(a != c)
    }
}

// MARK: - TmuxPane Tests

@Suite("TmuxPane Tests")
struct TmuxPaneTests {

    @Test("TmuxPane creation")
    func paneCreation() {
        let pane = TmuxPane(
            id: "%0",
            isActive: true,
            size: PaneSize(columns: 80, rows: 24)
        )
        #expect(pane.id == "%0")
        #expect(pane.isActive == true)
        #expect(pane.size.columns == 80)
        #expect(pane.size.rows == 24)
    }
}

// MARK: - TmuxWindow Tests

@Suite("TmuxWindow Tests")
struct TmuxWindowTests {

    @Test("TmuxWindow creation with panes")
    func windowCreation() {
        let pane = TmuxPane(
            id: "%0",
            isActive: true,
            size: PaneSize(columns: 80, rows: 24)
        )
        let window = TmuxWindow(
            id: "@0",
            name: "bash",
            panes: [pane],
            layout: "80x24,0,0"
        )
        #expect(window.id == "@0")
        #expect(window.name == "bash")
        #expect(window.panes.count == 1)
        #expect(window.layout == "80x24,0,0")
    }
}

// MARK: - TmuxSession Tests

@Suite("TmuxSession Tests")
struct TmuxSessionTests {

    @Test("TmuxSession creation with windows")
    func sessionCreation() {
        let now = Date()
        let pane = TmuxPane(
            id: "%0",
            isActive: true,
            size: PaneSize(columns: 120, rows: 40)
        )
        let window = TmuxWindow(
            id: "@0",
            name: "main",
            panes: [pane],
            layout: "120x40,0,0"
        )
        let session = TmuxSession(
            id: "$0",
            name: "dev",
            windows: [window],
            createdAt: now,
            lastActivity: now
        )

        #expect(session.id == "$0")
        #expect(session.name == "dev")
        #expect(session.windows.count == 1)
        #expect(session.windows.first?.name == "main")
        #expect(session.createdAt == now)
        #expect(session.lastActivity == now)
    }

    @Test("TmuxSession equality")
    func sessionEquality() {
        let now = Date()
        let pane = TmuxPane(id: "%0", isActive: true, size: PaneSize(columns: 80, rows: 24))
        let window = TmuxWindow(id: "@0", name: "bash", panes: [pane], layout: "80x24,0,0")

        let a = TmuxSession(id: "$0", name: "dev", windows: [window], createdAt: now, lastActivity: now)
        let b = TmuxSession(id: "$0", name: "dev", windows: [window], createdAt: now, lastActivity: now)

        #expect(a == b)
    }
}
