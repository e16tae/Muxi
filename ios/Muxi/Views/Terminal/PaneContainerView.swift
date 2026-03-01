import SwiftUI

// MARK: - PaneLayout

/// Pure-value helper that converts tmux cell coordinates into pixel frames
/// for a given container size.  Extracted from the view so it can be unit-tested
/// without any SwiftUI dependency.
struct PaneLayout {

    /// A computed pixel frame for a single pane.
    struct Frame: Equatable {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    /// Compute pixel frames for a set of panes by scaling tmux cell coordinates
    /// to fill `containerSize`.
    ///
    /// The bounding box of all panes (max x+width, max y+height) is used as
    /// the reference coordinate space; each pane is then proportionally scaled.
    ///
    /// - Parameters:
    ///   - panes: Array of tmux cell-coordinate tuples.
    ///   - containerSize: The available pixel area.
    /// - Returns: An array of ``Frame`` values, one per input pane.
    static func computeFrames(
        panes: [(x: Int, y: Int, width: Int, height: Int)],
        containerSize: CGSize
    ) -> [Frame] {
        guard !panes.isEmpty else { return [] }

        let totalWidth  = panes.map { $0.x + $0.width  }.max() ?? 1
        let totalHeight = panes.map { $0.y + $0.height }.max() ?? 1

        let scaleX = containerSize.width  / CGFloat(max(totalWidth, 1))
        let scaleY = containerSize.height / CGFloat(max(totalHeight, 1))

        return panes.map { pane in
            Frame(
                x: CGFloat(pane.x) * scaleX,
                y: CGFloat(pane.y) * scaleY,
                width:  CGFloat(pane.width)  * scaleX,
                height: CGFloat(pane.height) * scaleY
            )
        }
    }
}

// MARK: - PaneContainerView

/// Container that manages one or more terminal panes.
///
/// - **iPhone** (compact width): shows a single pane at a time with a tab
///   selector along the bottom edge.
/// - **iPad** (regular width): arranges panes according to tmux layout
///   geometry, scaling each pane proportionally within the available space.
struct PaneContainerView: View {
    let panes: [PaneInfo]
    let theme: Theme
    @Binding var activePaneId: String?
    @State private var selectedPaneIndex: Int = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    // MARK: - PaneInfo

    /// Describes a single terminal pane and its layout geometry.
    struct PaneInfo: Identifiable, Equatable {
        /// tmux pane identifier, e.g. "%0", "%1".
        let id: String
        let buffer: TerminalBuffer
        var channel: SSHChannel?
        // Layout from tmux (used for iPad split view positioning).
        var x: Int = 0
        var y: Int = 0
        var width: Int = 0
        var height: Int = 0

        static func == (lhs: PaneInfo, rhs: PaneInfo) -> Bool {
            lhs.id == rhs.id
                && lhs.x == rhs.x
                && lhs.y == rhs.y
                && lhs.width == rhs.width
                && lhs.height == rhs.height
        }
    }

    // MARK: - Body

    var body: some View {
        Group {
            if sizeClass == .compact || panes.count <= 1 {
                compactLayout
            } else {
                regularLayout
            }
        }
        .onChange(of: panes.count) {
            // Clamp selectedPaneIndex when panes are added / removed.
            if panes.isEmpty {
                selectedPaneIndex = 0
            } else if selectedPaneIndex >= panes.count {
                selectedPaneIndex = panes.count - 1
            }
        }
    }

    // MARK: - Compact (iPhone) Layout

    @ViewBuilder
    private var compactLayout: some View {
        VStack(spacing: 0) {
            if let pane = panes[safe: selectedPaneIndex] {
                TerminalView(buffer: pane.buffer, theme: theme, channel: pane.channel)
                    .onAppear { activePaneId = pane.id }
            }

            if panes.count > 1 {
                paneTabBar
            }
        }
    }

    /// Horizontal scrolling tab bar for switching between panes on iPhone.
    @ViewBuilder
    private var paneTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(panes.indices, id: \.self) { index in
                    Button {
                        selectedPaneIndex = index
                        activePaneId = panes[index].id
                    } label: {
                        Text("Pane \(index + 1)")
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                index == selectedPaneIndex
                                    ? Color.accentColor.opacity(0.3)
                                    : Color.clear
                            )
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 36)
        .background(Color(UIColor.systemBackground))
    }

    // MARK: - Regular (iPad) Layout

    @ViewBuilder
    private var regularLayout: some View {
        GeometryReader { geometry in
            let frames = PaneLayout.computeFrames(
                panes: panes.map { (x: $0.x, y: $0.y, width: $0.width, height: $0.height) },
                containerSize: geometry.size
            )

            ZStack(alignment: .topLeading) {
                // Pane views
                ForEach(Array(zip(panes.indices, panes)), id: \.1.id) { index, pane in
                    if index < frames.count {
                        let frame = frames[index]

                        TerminalView(buffer: pane.buffer, theme: theme, channel: pane.channel)
                            .frame(width: frame.width, height: frame.height)
                            .overlay(
                                RoundedRectangle(cornerRadius: 0)
                                    .stroke(
                                        Color.accentColor.opacity(activePaneId == pane.id ? 0.5 : 0),
                                        lineWidth: 2
                                    )
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                activePaneId = pane.id
                            }
                            .offset(x: frame.x, y: frame.y)
                    }
                }

                // Separator lines between panes
                separatorLines(frames: frames, containerSize: geometry.size)
            }
        }
    }

    // MARK: - Separator Lines

    /// Draw 1pt separator lines along the edges where two panes meet.
    @ViewBuilder
    private func separatorLines(frames: [PaneLayout.Frame], containerSize: CGSize) -> some View {
        let separatorColor = theme.foreground.color.opacity(0.2)

        ForEach(0..<frames.count, id: \.self) { i in
            let frame = frames[i]

            // Right edge separator (vertical line) — draw if pane doesn't extend to container right edge
            if frame.x + frame.width < containerSize.width - 1 {
                Rectangle()
                    .fill(separatorColor)
                    .frame(width: 1, height: frame.height)
                    .offset(x: frame.x + frame.width, y: frame.y)
            }

            // Bottom edge separator (horizontal line) — draw if pane doesn't extend to container bottom edge
            if frame.y + frame.height < containerSize.height - 1 {
                Rectangle()
                    .fill(separatorColor)
                    .frame(width: frame.width, height: 1)
                    .offset(x: frame.x, y: frame.y + frame.height)
            }
        }
    }
}

// MARK: - Safe Array Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
