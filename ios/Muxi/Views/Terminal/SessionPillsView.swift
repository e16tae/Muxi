import SwiftUI

/// Horizontally scrolling session pills for session mode.
///
/// Tap to switch session, long-press for rename/close.
struct SessionPillsView: View {
    let sessions: [TmuxSession]
    let activeSessionName: String

    var onSelectSession: ((String) -> Void)?
    var onRenameSession: ((String) -> Void)?
    var onCloseSession: ((String) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MuxiTokens.Spacing.sm) {
                ForEach(sessions) { session in
                    sessionPill(session)
                }
            }
        }
    }

    @ViewBuilder
    private func sessionPill(_ session: TmuxSession) -> some View {
        let isActive = session.name == activeSessionName

        Text(session.name)
            .font(MuxiTokens.Typography.label).fontWeight(.semibold)
            .foregroundStyle(isActive
                ? MuxiTokens.Colors.textInverse
                : MuxiTokens.Colors.textTertiary)
            .padding(.horizontal, MuxiTokens.Spacing.md)
            .padding(.vertical, MuxiTokens.Spacing.xs)
            .background(isActive
                ? MuxiTokens.Colors.accentDefault
                : MuxiTokens.Colors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: MuxiTokens.Radius.md))
            .contentShape(Rectangle())
            .onTapGesture {
                onSelectSession?(session.name)
            }
            .contextMenu {
                Button("Rename Session") {
                    onRenameSession?(session.name)
                }
                Button("Close Session", role: .destructive) {
                    onCloseSession?(session.name)
                }
            }
    }
}
