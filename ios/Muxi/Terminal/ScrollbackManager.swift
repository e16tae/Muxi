import Foundation

/// Manages per-pane scrollback state and caches.
///
/// Extracted from `TerminalSessionView` so that scrollback dictionary
/// mutations only trigger redraws in scrollback-dependent views, not
/// the entire terminal session body.
@MainActor
@Observable
final class ScrollbackManager {
    private var states: [PaneID: ScrollbackState] = [:]
    private var caches: [PaneID: TerminalBuffer] = [:]

    /// Pane IDs that are currently scrolled back (not live).
    var scrolledPaneIds: Set<PaneID> {
        Set(states.filter { $0.value != .live }.map(\.key))
    }

    func state(for paneId: PaneID) -> ScrollbackState {
        states[paneId] ?? .live
    }

    func cache(for paneId: PaneID) -> TerminalBuffer? {
        caches[paneId]
    }

    func setLoading(paneId: PaneID) {
        states[paneId] = .loading
    }

    func setScrolling(paneId: PaneID, offset: Int, totalLines: Int, cache: TerminalBuffer) {
        states[paneId] = .scrolling(offset: offset, totalLines: totalLines)
        caches[paneId] = cache
    }

    func updateOffset(paneId: PaneID, offset: Int, totalLines: Int) {
        states[paneId] = .scrolling(offset: offset, totalLines: totalLines)
    }

    func returnToLive(paneId: PaneID) {
        states[paneId] = .live
        caches[paneId] = nil
    }

    func returnAllToLive() {
        let scrolledPanes = states.filter { $0.value != .live }.map(\.key)
        for paneId in scrolledPanes {
            returnToLive(paneId: paneId)
        }
    }
}
