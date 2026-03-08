import SwiftUI
import CoreText
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
    @State private var isKeyboardActive = false

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
                    placeholderView
                } else {
                    GeometryReader { geometry in
                        PaneContainerView(
                            panes: panes,
                            theme: themeManager.currentTheme,
                            activePaneId: $activePaneId,
                            onPaneTapped: { _ in
                                isKeyboardActive = true
                            },
                            onPaste: { text in
                                pasteToActivePane(text)
                            }
                        )
                        .onChange(of: geometry.size) { _, newSize in
                            updateTerminalSize(newSize)
                        }
                        .onAppear {
                            updateTerminalSize(geometry.size)
                        }
                    }
                }

                TerminalInputView(
                    onText: { text in
                        for char in text {
                            let data = inputHandler.data(for: char)
                            sendToActivePane(data)
                        }
                    },
                    onDelete: {
                        sendToActivePane(Data([0x7F]))
                    },
                    isActive: $isKeyboardActive
                )
                .frame(width: 0, height: 0)

                ExtendedKeyboardView(
                    theme: themeManager.currentTheme,
                    inputHandler: inputHandler,
                    onInput: { data in
                        sendToActivePane(data)
                    },
                    onDismissKeyboard: {
                        isKeyboardActive = false
                    }
                )
            }
            .overlay(alignment: .bottomTrailing) {
                QuickActionButton(onAction: { command in
                    sendTmuxCommand(command)
                })
                .padding(.trailing, MuxiTokens.Spacing.lg)
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
            if activePaneId == nil, let first = newPanes.first {
                activePaneId = first.id
                isKeyboardActive = true
            }
        }
    }

    // MARK: - Terminal Sizing

    /// Calculate terminal columns and rows from the available view size
    /// and notify tmux so TUI apps can adapt.
    private func updateTerminalSize(_ size: CGSize) {
        let (cellW, cellH) = Self.terminalCellSize()
        guard cellW > 0, cellH > 0 else { return }

        let cols = max(Int(size.width / cellW), 1)
        let rows = max(Int(size.height / cellH), 1)
        connectionManager.resizeTerminal(cols: cols, rows: rows)
    }

    /// Calculate monospace cell dimensions using the same font the
    /// renderer uses. This avoids coupling the view to the renderer.
    static func terminalCellSize() -> (width: CGFloat, height: CGFloat) {
        let font = UIFont(name: "Sarasa Term K Nerd Font", size: 14)
            ?? UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let ctFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        var glyph = CTFontGetGlyphWithName(ctFont, "M" as CFString)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
        let w = ceil(advance.width)
        let h = ceil(CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont))
        return (w, h)
    }

    // MARK: - Placeholder

    private var placeholderView: some View {
        VStack {
            Spacer()
            ProgressView()
            Text("Attaching to \(sessionName)...")
                .font(MuxiTokens.Typography.caption)
                .foregroundStyle(MuxiTokens.Colors.textSecondary)
                .padding(.top, MuxiTokens.Spacing.sm)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Input Handling

    /// Send raw data to the active pane via tmux control mode.
    private func sendToActivePane(_ data: Data) {
        guard let paneId = activePaneId else { return }

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

    /// Paste clipboard text to the active pane via tmux set-buffer + paste-buffer.
    /// Uses a named buffer ("ios_paste") to avoid clobbering the user's global
    /// paste buffer. tmux automatically wraps with bracketed paste sequences
    /// if the pane's application has enabled bracketed paste mode.
    private func pasteToActivePane(_ text: String) {
        guard let paneId = activePaneId, !text.isEmpty else { return }
        let escaped = text.tmuxQuoted()
        let command = "set-buffer -b ios_paste -- \(escaped)\npaste-buffer -b ios_paste -t \(paneId.shellEscaped()) -d\n"
        Task {
            do {
                try await connectionManager.sshServiceForWrites.writeToChannel(Data(command.utf8))
            } catch {
                logger.error("Failed to paste to pane \(paneId): \(error.localizedDescription)")
            }
        }
    }
}
