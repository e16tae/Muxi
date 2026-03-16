import Foundation

/// Manages per-pane scrollback state and caches.
///
/// Extracted from `TerminalSessionView` so that scrollback dictionary
/// mutations only trigger redraws in scrollback-dependent views, not
/// the entire terminal session body.
@MainActor
@Observable
final class ScrollbackManager {
    private var states: [String: ScrollbackState] = [:]
    private var caches: [String: TerminalBuffer] = [:]

    /// Pane IDs that are currently scrolled back (not live).
    var scrolledPaneIds: Set<String> {
        Set(states.filter { $0.value != .live }.map(\.key))
    }

    func state(for paneId: String) -> ScrollbackState {
        states[paneId] ?? .live
    }

    func cache(for paneId: String) -> TerminalBuffer? {
        caches[paneId]
    }

    func setLoading(paneId: String) {
        states[paneId] = .loading
    }

    func setScrolling(paneId: String, offset: Int, totalLines: Int, cache: TerminalBuffer) {
        states[paneId] = .scrolling(offset: offset, totalLines: totalLines)
        caches[paneId] = cache
    }

    func updateOffset(paneId: String, offset: Int, totalLines: Int) {
        states[paneId] = .scrolling(offset: offset, totalLines: totalLines)
    }

    func returnToLive(paneId: String) {
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
