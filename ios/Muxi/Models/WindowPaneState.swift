/// State machine for window/pane layout lifecycle.
///
/// Eliminates the set of independent properties (`currentPanes`,
/// `activePaneId`, `activeWindowId`, `switchingToWindowId`, `isZoomed`,
/// `pendingAutoZoom`) that relied on implicit invariants. Each case
/// makes the valid property combinations explicit at the type level.
///
/// State transitions:
/// ```
/// disconnect / session-switch → awaitingLayout
///
/// awaitingLayout ── first %layout-change ──→ active
///
/// active ── selectWindow / sessionWindowChanged ──→ switchingWindow
/// active ── mobileAutoZoom + unzoomed multi-pane ──→ autoZooming
///
/// switchingWindow ── matching %layout-change ──→ active
/// switchingWindow ── stale %layout-change ─────→ (ignored)
///
/// autoZooming ── zoomed %layout-change ───→ active
/// autoZooming ── timeout (2s) ────────────→ active (fallback)
/// ```
enum WindowPaneState: Equatable {
    /// Layout not yet received. Waiting for the first `%layout-change`.
    case awaitingLayout

    /// Normal operation: active window with rendered panes.
    case active(ActiveState)

    /// Transitioning to a different window. UI shows placeholder.
    case switchingWindow(SwitchingState)

    /// Mobile auto-zoom in progress: suppressing unzoomed layout,
    /// waiting for the zoomed `%layout-change`.
    case autoZooming(AutoZoomState)

    struct ActiveState: Equatable {
        let windowId: WindowID
        var panes: [Pane]
        var activePaneId: PaneID
        var isZoomed: Bool
    }

    struct SwitchingState: Equatable {
        let targetWindowId: WindowID
        var optimisticPaneId: PaneID?
    }

    struct AutoZoomState: Equatable {
        let windowId: WindowID
        var unzoomedPanes: [Pane]
        var activePaneId: PaneID
    }
}
