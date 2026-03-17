import Foundation

// MARK: - Pane

/// A single leaf pane extracted from a tmux layout string.
///
/// Replaces both `TmuxControlService.ParsedPane` and the old `TmuxPane`.
struct Pane: Identifiable, Equatable, Sendable {
    let id: PaneID
    let frame: CellFrame

    struct CellFrame: Equatable, Sendable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }
}

// MARK: - Window

/// A window inside a tmux session, tracked for toolbar pills.
///
/// Replaces both the old `TmuxWindow` and `ConnectionManager.TmuxWindowInfo`.
struct Window: Identifiable, Equatable, Sendable {
    let id: WindowID
    var name: String
    var paneIds: [PaneID]
    var isActive: Bool
}

// MARK: - TmuxSession

/// A tmux session running on a remote server.
struct TmuxSession: Identifiable, Equatable, Sendable {
    let id: SessionID
    var name: String
    var windows: [Window]
    var createdAt: Date
    var lastActivity: Date
}
