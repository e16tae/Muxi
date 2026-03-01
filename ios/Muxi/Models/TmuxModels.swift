import Foundation

// MARK: - PaneSize

/// The dimensions of a tmux pane in terminal cells.
struct PaneSize: Equatable, Sendable {
    var columns: Int
    var rows: Int
}

// MARK: - TmuxPane

/// A single pane inside a tmux window.
struct TmuxPane: Identifiable, Equatable, Sendable {
    /// The tmux pane identifier, e.g. "%0".
    let id: String
    var isActive: Bool
    var size: PaneSize
}

// MARK: - TmuxWindow

/// A window inside a tmux session, containing one or more panes.
struct TmuxWindow: Identifiable, Equatable, Sendable {
    /// The tmux window identifier, e.g. "@0".
    let id: String
    var name: String
    var panes: [TmuxPane]
    /// The tmux layout description string.
    var layout: String
}

// MARK: - TmuxSession

/// A tmux session running on a remote server.
struct TmuxSession: Identifiable, Equatable, Sendable {
    /// The tmux session identifier, e.g. "$0".
    let id: String
    var name: String
    var windows: [TmuxWindow]
    var createdAt: Date
    var lastActivity: Date
}
