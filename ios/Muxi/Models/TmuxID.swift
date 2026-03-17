/// Strong-typed tmux identifiers.
///
/// Tmux assigns prefixed IDs to sessions (`$0`), windows (`@0`), and
/// panes (`%0`).  These wrapper types prevent accidental mixups that
/// plain `String` allows (e.g. passing a pane ID where a window ID is
/// expected) and eliminate the `"%\(pane.paneId)"` formatting pattern.

// MARK: - PaneID

struct PaneID: Hashable, Identifiable, Sendable, CustomStringConvertible {
    let rawValue: String   // e.g. "%0"
    var id: String { rawValue }
    var description: String { rawValue }

    /// Create from a numeric tmux pane index (adds "%" prefix).
    init(index: Int) { rawValue = "%\(index)" }

    /// Create from a raw tmux pane ID string (e.g. "%0").
    init(_ string: String) { rawValue = string }
}

// MARK: - WindowID

struct WindowID: Hashable, Identifiable, Sendable, CustomStringConvertible {
    let rawValue: String   // e.g. "@0"
    var id: String { rawValue }
    var description: String { rawValue }

    /// Create from a raw tmux window ID string (e.g. "@0").
    init(_ string: String) { rawValue = string }
}

// MARK: - SessionID

struct SessionID: Hashable, Identifiable, Sendable, CustomStringConvertible {
    let rawValue: String   // e.g. "$0"
    var id: String { rawValue }
    var description: String { rawValue }

    /// Create from a raw tmux session ID string (e.g. "$0").
    init(_ string: String) { rawValue = string }
}

