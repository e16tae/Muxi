import SwiftUI

/// Horizontally scrolling grouped pills showing windows and their panes.
///
/// Each window is a capsule containing the window name + pane indices.
/// Active pane has accent background; active window has accent outline.
///
/// Tap pane -> selectWindowAndPane. Tap window name -> selectWindow.
/// Long-press pane -> Zoom/Close. Long-press window -> Rename/Close.
struct WindowPanePillsView: View {
    let windows: [ConnectionManager.TmuxWindowInfo]
    let activeWindowId: String?
    let activePaneId: String?
    let currentPanes: [TmuxControlService.ParsedPane]
    let isZoomed: Bool
    let hideZoomToggle: Bool

    var onSelectWindow: ((String) -> Void)?
    var onSelectWindowAndPane: ((String, String) -> Void)?
    var onRenameWindow: ((String) -> Void)?
    var onCloseWindow: ((String) -> Void)?
    var onZoomPane: (() -> Void)?
    var onClosePane: ((String) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MuxiTokens.Spacing.sm) {
                ForEach(windows) { window in
                    windowPill(window)
                }
            }
        }
    }

    // MARK: - Window Pill

    @ViewBuilder
    private func windowPill(_ window: ConnectionManager.TmuxWindowInfo) -> some View {
        let isActiveWindow = window.id == activeWindowId

        HStack(spacing: 0) {
            // Window name segment
            Menu {
                Button("Rename Window") {
                    onRenameWindow?(window.id)
                }
                Button("Close Window", role: .destructive) {
                    onCloseWindow?(window.id)
                }
            } label: {
                Text(window.name)
                    .font(MuxiTokens.Typography.label).fontWeight(.semibold)
                    .foregroundStyle(isActiveWindow
                        ? MuxiTokens.Colors.textPrimary
                        : MuxiTokens.Colors.textTertiary)
                    .padding(.horizontal, MuxiTokens.Spacing.sm)
                    .padding(.vertical, MuxiTokens.Spacing.xs)
            } primaryAction: {
                onSelectWindow?(window.id)
            }

            // Pane segments
            let paneIds = panesToShow(for: window)
            ForEach(Array(paneIds.enumerated()), id: \.offset) { index, paneId in
                let isActivePane = paneId == activePaneId

                Rectangle()
                    .fill(MuxiTokens.Colors.borderDefault)
                    .frame(width: 1)

                Menu {
                    if !hideZoomToggle {
                        Button(isZoomed ? "Unzoom" : "Zoom") {
                            onZoomPane?()
                        }
                    }
                    Button("Close Pane", role: .destructive) {
                        onClosePane?(paneId)
                    }
                } label: {
                    Text("\(index)")
                    .font(MuxiTokens.Typography.label).fontWeight(.semibold)
                    .foregroundStyle(isActivePane
                        ? MuxiTokens.Colors.textInverse
                        : MuxiTokens.Colors.textTertiary)
                    .padding(.horizontal, MuxiTokens.Spacing.sm)
                    .padding(.vertical, MuxiTokens.Spacing.xs)
                    .background(isActivePane
                        ? MuxiTokens.Colors.accentDefault
                        : Color.clear)
                } primaryAction: {
                    onSelectWindowAndPane?(window.id, paneId)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(MuxiTokens.Colors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: MuxiTokens.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: MuxiTokens.Radius.md)
                .stroke(
                    isActiveWindow ? MuxiTokens.Colors.accentDefault : Color.clear,
                    lineWidth: 1.5
                )
        )
    }

    /// Get pane IDs for a window.
    /// Normally populated by `list-panes -a` response. Falls back to
    /// ``currentPanes`` for the active window during the brief interval
    /// between `list-windows` and `list-panes` responses.
    private func panesToShow(for window: ConnectionManager.TmuxWindowInfo) -> [String] {
        if !window.paneIds.isEmpty {
            return window.paneIds
        }
        if window.id == activeWindowId {
            return currentPanes.map { "%\($0.paneId)" }
        }
        return []
    }
}
