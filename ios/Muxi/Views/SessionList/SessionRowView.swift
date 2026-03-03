import SwiftUI

/// A single row in the session list, displaying the session name,
/// identifier, and window count.
struct SessionRowView: View {
    let session: TmuxSession

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: MuxiTokens.Spacing.xs) {
                Text(session.name)
                    .font(MuxiTokens.Typography.title)
                    .foregroundStyle(MuxiTokens.Colors.textPrimary)
                HStack(spacing: MuxiTokens.Spacing.sm) {
                    Text(session.id)
                        .font(MuxiTokens.Typography.caption)
                        .foregroundStyle(MuxiTokens.Colors.textSecondary)
                    if !session.windows.isEmpty {
                        Text("\(session.windows.count) window\(session.windows.count == 1 ? "" : "s")")
                            .font(MuxiTokens.Typography.caption)
                            .foregroundStyle(MuxiTokens.Colors.textSecondary)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(MuxiTokens.Typography.caption)
                .foregroundStyle(MuxiTokens.Colors.textTertiary)
        }
        .padding(.vertical, MuxiTokens.Spacing.xs)
    }
}
