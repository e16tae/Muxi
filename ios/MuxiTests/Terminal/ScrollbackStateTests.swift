import Testing
@testable import Muxi

@Suite("ScrollbackState")
struct ScrollbackStateTests {

    @Test("live is the default state")
    func liveIsDefault() {
        let state = ScrollbackState.live
        #expect(state == .live)
        #expect(!state.isScrolledBack)
    }

    @Test("loading indicates fetch in progress")
    func loadingState() {
        let state = ScrollbackState.loading
        #expect(state == .loading)
        #expect(!state.isScrolledBack)
    }

    @Test("scrolling tracks offset and total lines")
    func scrollingState() {
        let state = ScrollbackState.scrolling(offset: 50, totalLines: 500)
        #expect(state.isScrolledBack)
        if case .scrolling(let offset, let total) = state {
            #expect(offset == 50)
            #expect(total == 500)
        }
    }

    @Test("equatable compares correctly")
    func equatable() {
        #expect(ScrollbackState.live == .live)
        #expect(ScrollbackState.loading == .loading)
        #expect(ScrollbackState.scrolling(offset: 10, totalLines: 100)
            == .scrolling(offset: 10, totalLines: 100))
        #expect(ScrollbackState.scrolling(offset: 10, totalLines: 100)
            != .scrolling(offset: 20, totalLines: 100))
        #expect(ScrollbackState.live != .loading)
    }

    @Test("clampedOffset clamps to valid range")
    func clampedOffset() {
        #expect(ScrollbackState.clampedOffset(50, totalLines: 500, visibleRows: 24) == 50)
        #expect(ScrollbackState.clampedOffset(-5, totalLines: 500, visibleRows: 24) == 0)
        #expect(ScrollbackState.clampedOffset(600, totalLines: 500, visibleRows: 24) == 476)
    }

    @Test("startRow calculates correct render start")
    func startRow() {
        // 500 total, scrolled 50 back, 24 visible → start at row 426
        let start = ScrollbackState.startRow(offset: 50, totalLines: 500, visibleRows: 24)
        #expect(start == 426)
    }

    @Test("startRow clamps to zero")
    func startRowClampsToZero() {
        // 30 total, scrolled 50 back, 24 visible → start at 0 (can't go negative)
        let start = ScrollbackState.startRow(offset: 50, totalLines: 30, visibleRows: 24)
        #expect(start == 0)
    }
}
