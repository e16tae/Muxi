import SwiftUI

/// Bottom toolbar above the extended keyboard.
///
/// Layout: `⊞ │ [pills] │ + ⌨`
///
/// `⊞` (square.stack) toggles session mode. In session mode, changes to `✕` (xmark).
/// Pills show window/pane capsules (normal) or session pills (session mode).
/// `+` shows context-dependent creation menu.
/// `⌨` toggles system keyboard.
struct ToolbarView: View {
    let connectionManager: ConnectionManager
    let sessionName: String
    @Binding var isKeyboardActive: Bool
    @Binding var isSessionMode: Bool

    // Rename alert state
    @Binding var showRenameAlert: Bool
    @Binding var renameTarget: RenameTarget?
    @Binding var renameText: String

    /// What we're renaming.
    enum RenameTarget: Equatable {
        case window(id: String)
        case session(name: String)
    }

    // Callbacks for tmux commands
    var onSendCommand: ((String) -> Void)?
    var onSelectWindow: ((String) -> Void)?
    var onSelectWindowAndPane: ((String, String) -> Void)?
    var onNewSession: (() -> Void)?
    var onSwitchSession: ((String) -> Void)?
    var onKillSession: ((String) -> Void)?

    var body: some View {
        HStack(spacing: MuxiTokens.Spacing.sm) {
            // Session mode toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSessionMode.toggle()
                }
            } label: {
                Image(systemName: isSessionMode ? "rectangle.split.2x2" : "square.stack")
                    .font(MuxiTokens.Typography.body)
                    .foregroundStyle(MuxiTokens.Colors.accentDefault)
                    .frame(width: 40, height: 40)
                    .background(MuxiTokens.Colors.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: MuxiTokens.Radius.sm))
            }
            .buttonStyle(.plain)

            // Pill area (fills remaining space)
            Group {
                if isSessionMode {
                    SessionPillsView(
                        sessions: connectionManager.sessions,
                        activeSessionName: sessionName,
                        onSelectSession: { name in
                            onSwitchSession?(name)
                        },
                        onRenameSession: { name in
                            renameTarget = .session(name: name)
                            renameText = name
                            showRenameAlert = true
                        },
                        onCloseSession: { name in
                            onKillSession?(name)
                        }
                    )
                } else {
                    if connectionManager.currentWindows.isEmpty {
                        Text(sessionName)
                            .font(MuxiTokens.Typography.label).fontWeight(.semibold)
                            .foregroundStyle(MuxiTokens.Colors.textPrimary)
                            .padding(.horizontal, MuxiTokens.Spacing.md)
                            .padding(.vertical, MuxiTokens.Spacing.xs)
                    } else {
                        WindowPanePillsView(
                            windows: connectionManager.currentWindows,
                            activeWindowId: connectionManager.activeWindowId,
                            activePaneId: connectionManager.activePaneId,
                            currentPanes: connectionManager.currentPanes,
                            onSelectWindow: { windowId in
                                onSelectWindow?(windowId)
                            },
                            onSelectWindowAndPane: { windowId, paneId in
                                onSelectWindowAndPane?(windowId, paneId)
                            },
                            onRenameWindow: { windowId in
                                let currentName = connectionManager.currentWindows
                                    .first(where: { $0.id == windowId })?.name ?? ""
                                renameTarget = .window(id: windowId)
                                renameText = currentName
                                showRenameAlert = true
                            },
                            onCloseWindow: { windowId in
                                onSendCommand?("kill-window -t \(windowId.shellEscaped())")
                            },
                            onZoomPane: {
                                onSendCommand?("resize-pane -Z")
                            },
                            onClosePane: { paneId in
                                onSendCommand?("kill-pane -t \(paneId.shellEscaped())")
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, MuxiTokens.Spacing.md)
            .padding(.vertical, MuxiTokens.Spacing.sm)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background(MuxiTokens.Colors.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuxiTokens.Radius.md))

            // + menu
            PlusMenuView(
                isSessionMode: isSessionMode,
                onNewWindow: {
                    onSendCommand?("new-window")
                },
                onSplitHorizontal: {
                    onSendCommand?("split-window -h")
                },
                onSplitVertical: {
                    onSendCommand?("split-window -v")
                },
                onNewSession: {
                    onNewSession?()
                }
            )
            .background(MuxiTokens.Colors.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuxiTokens.Radius.sm))

            // Keyboard toggle
            Button {
                isKeyboardActive.toggle()
            } label: {
                Image(systemName: isKeyboardActive
                    ? "keyboard.chevron.compact.down"
                    : "keyboard")
                    .font(MuxiTokens.Typography.body)
                    .foregroundStyle(MuxiTokens.Colors.accentDefault)
                    .frame(width: 40, height: 40)
                    .background(MuxiTokens.Colors.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: MuxiTokens.Radius.sm))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, MuxiTokens.Spacing.sm)
        .padding(.vertical, MuxiTokens.Spacing.sm)
    }
}
