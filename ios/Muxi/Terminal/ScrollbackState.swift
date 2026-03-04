/// Tracks the scrollback state of a single terminal pane.
///
/// - `.live`: Normal mode — renderer reads from the live buffer.
/// - `.loading`: A `capture-pane` request is in flight.
/// - `.scrolling`: User has scrolled back into history.
enum ScrollbackState: Equatable {
    case live
    case loading
    case scrolling(offset: Int, totalLines: Int)

    /// Whether the user has scrolled away from the live position.
    var isScrolledBack: Bool {
        switch self {
        case .scrolling: return true
        default: return false
        }
    }

    /// Clamp a scroll offset to the valid range `[0, totalLines - visibleRows]`.
    static func clampedOffset(_ offset: Int, totalLines: Int, visibleRows: Int) -> Int {
        max(0, min(offset, totalLines - visibleRows))
    }

    /// Calculate the first row index in the scrollback buffer to render.
    ///
    /// The buffer has `totalLines` rows. We want to show `visibleRows` rows,
    /// ending `offset` lines from the bottom.
    static func startRow(offset: Int, totalLines: Int, visibleRows: Int) -> Int {
        max(0, totalLines - offset - visibleRows)
    }
}
