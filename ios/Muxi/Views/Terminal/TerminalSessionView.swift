import SwiftUI
import os

/// The terminal session screen that combines all terminal-related components
/// into a single view: pane container, extended keyboard, quick action button,
/// and a detach toolbar button.
///
/// Displayed when ``ConnectionManager/state`` is `.attached(sessionName:)`.
struct TerminalSessionView: View {
    let connectionManager: ConnectionManager
    let sessionName: String
    let themeManager: ThemeManager

    private let logger = Logger(subsystem: "com.muxi.app", category: "TerminalSession")
    @State private var activePaneId: String?
    @State private var inputHandler = InputHandler()

    /// Build pane info from ConnectionManager's live pane data.
    private var panes: [PaneContainerView.PaneInfo] {
        connectionManager.currentPanes.map { parsedPane in
            let paneId = "%\(parsedPane.paneId)"
            let buffer = connectionManager.paneBuffers[paneId]
                ?? TerminalBuffer(cols: parsedPane.width, rows: parsedPane.height)
            return PaneContainerView.PaneInfo(
                id: paneId,
                buffer: buffer,
                channel: connectionManager.activeChannel,
                x: parsedPane.x,
                y: parsedPane.y,
                width: parsedPane.width,
                height: parsedPane.height
            )
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if panes.isEmpty {
                    // Show placeholder while waiting for tmux layout data
                    placeholderView
                } else {
                    // Terminal panes
                    PaneContainerView(
                        panes: panes,
                        theme: themeManager.currentTheme,
                        activePaneId: $activePaneId
                    )
                }

                // Extended keyboard toolbar
                ExtendedKeyboardView(
                    theme: themeManager.currentTheme,
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
        .onChange(of: panes) { _, newPanes in
            // Auto-select first pane if none is active
            if activePaneId == nil, let first = newPanes.first {
                activePaneId = first.id
            }
        }
    }

    // MARK: - Placeholder

    private var placeholderView: some View {
        VStack {
            Spacer()
            ProgressView()
            Text("Attaching to \(sessionName)...")
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Input Handling

    /// Send raw data to the active pane via tmux control mode.
    ///
    /// In control mode, input to a pane is sent as a tmux `send-keys`
    /// command through the control channel, not directly to the pane.
    /// Writes are routed through the SSHService actor for thread safety.
    private func sendToActivePane(_ data: Data) {
        guard let paneId = activePaneId else { return }

        // Encode each byte as a hex key for send-keys
        let hexKeys = data.map { String(format: "0x%02x", $0) }.joined(separator: " ")
        let command = "send-keys -t \(paneId.shellEscaped()) \(hexKeys)\n"
        Task {
            do {
                try await connectionManager.sshServiceForWrites.writeToChannel(Data(command.utf8))
            } catch {
                logger.error("Failed to send keys to pane \(paneId): \(error.localizedDescription)")
            }
        }
    }

    /// Send a tmux command through the control mode channel.
    /// Writes are routed through the SSHService actor for thread safety.
    private func sendTmuxCommand(_ command: String) {
        let fullCommand = command + "\n"
        Task {
            do {
                try await connectionManager.sshServiceForWrites.writeToChannel(Data(fullCommand.utf8))
            } catch {
                logger.error("Failed to send tmux command: \(error.localizedDescription)")
            }
        }
    }
}
