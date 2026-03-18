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
/// - **iPhone** (compact width): shows the active pane (selected via
///   toolbar pills).
/// - **iPad** (regular width): arranges panes according to tmux layout
///   geometry, scaling each pane proportionally within the available space.
struct PaneContainerView: View {
    let panes: [PaneInfo]
    let theme: Theme
    var fontSize: CGFloat = 14
    @Binding var activePaneId: PaneID?
    /// Called when the user taps a pane.
    var onPaneTapped: ((PaneID) -> Void)?
    var onPaste: ((String) -> Void)?

    // Selection
    var selectionRelay: TerminalSelectionRelay?
    var onKeyboardReactivate: (() -> Void)?

    // Scrollback
    var scrollbackBuffer: TerminalBuffer?
    var scrollbackOffset: Int = 0
    var onScrollOffsetChanged: ((PaneID, Int) -> Void)?
    var showNewOutputIndicator: Bool = false
    var onReturnToLive: ((PaneID) -> Void)?

    @Environment(\.horizontalSizeClass) private var sizeClass

    // MARK: - PaneInfo

    /// Describes a single terminal pane and its layout geometry.
    struct PaneInfo: Identifiable, Equatable {
        let id: PaneID
        let buffer: TerminalBuffer
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
    }

    // MARK: - Compact (iPhone) Layout

    @ViewBuilder
    private var compactLayout: some View {
        if let pane = panes.first(where: { $0.id == activePaneId }) ?? panes.first {
            TerminalView(
                buffer: pane.buffer,
                theme: theme,
                onPaste: onPaste,
                fontSize: fontSize,
                isFocused: true,
                scrollbackBuffer: scrollbackBuffer,
                scrollOffset: scrollbackOffset,
                onScrollOffsetChanged: { delta in
                    onScrollOffsetChanged?(pane.id, delta)
                },
                selectionRelay: selectionRelay,
                onKeyboardReactivate: onKeyboardReactivate
            )
            .overlay(alignment: .bottom) {
                if showNewOutputIndicator,
                   scrollbackOffset > 0,
                   pane.id == activePaneId {
                    Button {
                        onReturnToLive?(pane.id)
                    } label: {
                        HStack(spacing: MuxiTokens.Spacing.xs) {
                            Image(systemName: "arrow.down")
                            Text("New output")
                        }
                        .font(MuxiTokens.Typography.caption)
                        .padding(.horizontal, MuxiTokens.Spacing.md)
                        .padding(.vertical, MuxiTokens.Spacing.sm)
                        .background(
                            RoundedRectangle(
                                cornerRadius: MuxiTokens.Radius.sm,
                                style: .continuous
                            )
                            .fill(MuxiTokens.Colors.accentDefault)
                        )
                        .foregroundStyle(MuxiTokens.Colors.textPrimary)
                    }
                    .padding(.bottom, MuxiTokens.Spacing.md)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                activePaneId = pane.id
                onPaneTapped?(pane.id)
            }
        }
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

                        let isActive = pane.id == activePaneId

                        TerminalView(
                            buffer: pane.buffer,
                            theme: theme,
                            onPaste: onPaste,
                            fontSize: fontSize,
                            isFocused: isActive,
                            scrollbackBuffer: isActive ? scrollbackBuffer : nil,
                            scrollOffset: isActive ? scrollbackOffset : 0,
                            onScrollOffsetChanged: { delta in
                                onScrollOffsetChanged?(pane.id, delta)
                            },
                            selectionRelay: isActive ? selectionRelay : nil,
                            onKeyboardReactivate: isActive ? onKeyboardReactivate : nil
                        )
                            .frame(width: frame.width, height: frame.height)
                            .overlay(
                                RoundedRectangle(cornerRadius: 0)
                                    .stroke(
                                        activePaneId == pane.id
                                            ? MuxiTokens.Colors.borderAccent
                                            : Color.clear,
                                        lineWidth: 2
                                    )
                            )
                            .overlay(alignment: .bottom) {
                                if showNewOutputIndicator,
                                   scrollbackOffset > 0,
                                   pane.id == activePaneId {
                                    Button {
                                        onReturnToLive?(pane.id)
                                    } label: {
                                        HStack(spacing: MuxiTokens.Spacing.xs) {
                                            Image(systemName: "arrow.down")
                                            Text("New output")
                                        }
                                        .font(MuxiTokens.Typography.caption)
                                        .padding(.horizontal, MuxiTokens.Spacing.md)
                                        .padding(.vertical, MuxiTokens.Spacing.sm)
                                        .background(
                                            RoundedRectangle(
                                                cornerRadius: MuxiTokens.Radius.sm,
                                                style: .continuous
                                            )
                                            .fill(MuxiTokens.Colors.accentDefault)
                                        )
                                        .foregroundStyle(MuxiTokens.Colors.textPrimary)
                                    }
                                    .padding(.bottom, MuxiTokens.Spacing.md)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                activePaneId = pane.id
                                onPaneTapped?(pane.id)
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
        let separatorColor = MuxiTokens.Colors.borderDefault

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
