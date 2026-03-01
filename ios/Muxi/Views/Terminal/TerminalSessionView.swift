import SwiftUI

/// The terminal session screen that combines all terminal-related components
/// into a single view: pane container, extended keyboard, quick action button,
/// and a detach toolbar button.
///
/// Displayed when ``ConnectionManager/state`` is `.attached(sessionName:)`.
struct TerminalSessionView: View {
    let connectionManager: ConnectionManager
    let sessionName: String
    let theme: Theme = .catppuccinMocha

    @State private var activePaneId: String?
    @State private var inputHandler = InputHandler()
    @State private var panes: [PaneContainerView.PaneInfo] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Terminal panes
                PaneContainerView(
                    panes: panes,
                    theme: theme,
                    activePaneId: $activePaneId
                )

                // Extended keyboard toolbar
                ExtendedKeyboardView(
                    theme: theme,
                    inputHandler: inputHandler,
                    onInput: { data in
                        sendToActivePane(data)
                    }
                )
            }
            .overlay(alignment: .bottomTrailing) {
                QuickActionButton(onAction: { command in
                    sendTmuxCommand(command)
                })
                .padding(.trailing, 16)
                .padding(.bottom, 60)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Detach") {
                        connectionManager.detach()
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(sessionName)
                        .font(.headline)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            setupPlaceholderPane()
        }
    }

    // MARK: - Setup

    /// Create a single placeholder pane for the MVP since the real pane data
    /// will come from tmux control mode output in a future version.
    private func setupPlaceholderPane() {
        guard panes.isEmpty else { return }
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        buffer.feed("$ Welcome to session: \(sessionName)\r\n")
        let pane = PaneContainerView.PaneInfo(
            id: "%0",
            buffer: buffer,
            channel: nil,
            x: 0,
            y: 0,
            width: 80,
            height: 24
        )
        panes = [pane]
        activePaneId = pane.id
    }

    // MARK: - Input Handling

    /// Send raw data to the active pane's SSH channel.
    private func sendToActivePane(_ data: Data) {
        guard let paneId = activePaneId,
              let pane = panes.first(where: { $0.id == paneId }),
              let channel = pane.channel else { return }
        try? channel.write(data)
    }

    /// Send a tmux command via the SSH exec channel.
    private func sendTmuxCommand(_ command: String) {
        // TODO: Send tmux command via control mode channel.
        // For now this is a stub; the real implementation will use
        // sshService.execCommand("tmux \(command)") once wired.
    }
}
