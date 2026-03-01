import Foundation
import Testing

@testable import Muxi

// MARK: - PaneLayout.computeFrames Tests

@Suite("PaneLayout.computeFrames Tests")
struct PaneLayoutComputeFramesTests {

    @Test("Single pane fills entire container")
    func singlePaneFillsContainer() {
        let frames = PaneLayout.computeFrames(
            panes: [(x: 0, y: 0, width: 80, height: 24)],
            containerSize: CGSize(width: 800, height: 480)
        )

        #expect(frames.count == 1)
        let f = frames[0]
        #expect(f.x == 0)
        #expect(f.y == 0)
        #expect(f.width == 800)
        #expect(f.height == 480)
    }

    @Test("Two side-by-side panes divide width proportionally")
    func horizontalSplit() {
        // Left pane: 40 cols, Right pane: 40 cols (total = 80)
        let frames = PaneLayout.computeFrames(
            panes: [
                (x: 0, y: 0, width: 40, height: 24),
                (x: 40, y: 0, width: 40, height: 24),
            ],
            containerSize: CGSize(width: 800, height: 480)
        )

        #expect(frames.count == 2)

        // Left pane
        #expect(frames[0].x == 0)
        #expect(frames[0].y == 0)
        #expect(frames[0].width == 400)
        #expect(frames[0].height == 480)

        // Right pane
        #expect(frames[1].x == 400)
        #expect(frames[1].y == 0)
        #expect(frames[1].width == 400)
        #expect(frames[1].height == 480)
    }

    @Test("Two stacked panes divide height proportionally")
    func verticalSplit() {
        // Top pane: 12 rows, Bottom pane: 12 rows (total = 24)
        let frames = PaneLayout.computeFrames(
            panes: [
                (x: 0, y: 0, width: 80, height: 12),
                (x: 0, y: 12, width: 80, height: 12),
            ],
            containerSize: CGSize(width: 800, height: 480)
        )

        #expect(frames.count == 2)

        // Top pane
        #expect(frames[0].x == 0)
        #expect(frames[0].y == 0)
        #expect(frames[0].width == 800)
        #expect(frames[0].height == 240)

        // Bottom pane
        #expect(frames[1].x == 0)
        #expect(frames[1].y == 240)
        #expect(frames[1].width == 800)
        #expect(frames[1].height == 240)
    }

    @Test("Empty panes array returns empty frames")
    func emptyPanes() {
        let frames = PaneLayout.computeFrames(
            panes: [],
            containerSize: CGSize(width: 800, height: 480)
        )
        #expect(frames.isEmpty)
    }

    @Test("Zero container size returns zero-size frames")
    func zeroContainerSize() {
        let frames = PaneLayout.computeFrames(
            panes: [(x: 0, y: 0, width: 80, height: 24)],
            containerSize: CGSize.zero
        )

        #expect(frames.count == 1)
        #expect(frames[0].x == 0)
        #expect(frames[0].y == 0)
        #expect(frames[0].width == 0)
        #expect(frames[0].height == 0)
    }

    @Test("Complex 3-pane layout computes correct geometry")
    func threePaneLayout() {
        // 1 left pane (40 cols x 24 rows) + 2 stacked right panes (40 cols x 12 rows each)
        // Total bounding box: 80 x 24
        let frames = PaneLayout.computeFrames(
            panes: [
                (x: 0, y: 0, width: 40, height: 24),   // left full-height
                (x: 40, y: 0, width: 40, height: 12),   // top-right
                (x: 40, y: 12, width: 40, height: 12),  // bottom-right
            ],
            containerSize: CGSize(width: 800, height: 480)
        )

        #expect(frames.count == 3)

        // Left pane – full height, half width
        #expect(frames[0].x == 0)
        #expect(frames[0].y == 0)
        #expect(frames[0].width == 400)
        #expect(frames[0].height == 480)

        // Top-right pane – half width, half height
        #expect(frames[1].x == 400)
        #expect(frames[1].y == 0)
        #expect(frames[1].width == 400)
        #expect(frames[1].height == 240)

        // Bottom-right pane – half width, half height
        #expect(frames[2].x == 400)
        #expect(frames[2].y == 240)
        #expect(frames[2].width == 400)
        #expect(frames[2].height == 240)
    }

    @Test("Asymmetric split produces correct proportions")
    func asymmetricSplit() {
        // 60/20 column split in an 800-wide container (total = 80)
        let frames = PaneLayout.computeFrames(
            panes: [
                (x: 0, y: 0, width: 60, height: 24),
                (x: 60, y: 0, width: 20, height: 24),
            ],
            containerSize: CGSize(width: 800, height: 480)
        )

        #expect(frames.count == 2)
        #expect(frames[0].width == 600)
        #expect(frames[1].width == 200)
        #expect(frames[1].x == 600)
    }

    @Test("Frame equality works correctly")
    func frameEquality() {
        let a = PaneLayout.Frame(x: 10, y: 20, width: 100, height: 200)
        let b = PaneLayout.Frame(x: 10, y: 20, width: 100, height: 200)
        let c = PaneLayout.Frame(x: 10, y: 20, width: 100, height: 201)

        #expect(a == b)
        #expect(a != c)
    }
}
