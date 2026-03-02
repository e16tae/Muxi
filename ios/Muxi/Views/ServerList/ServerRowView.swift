import SwiftUI

struct ServerRowView: View {
    let server: Server

    var body: some View {
        VStack(alignment: .leading, spacing: MuxiTokens.Spacing.xs) {
            Text(server.name)
                .font(MuxiTokens.Typography.title)
                .foregroundStyle(MuxiTokens.Colors.textPrimary)
            Text("\(server.username)@\(server.host):\(server.port)")
                .font(MuxiTokens.Typography.caption)
                .foregroundStyle(MuxiTokens.Colors.textSecondary)
        }
        .padding(.vertical, MuxiTokens.Spacing.xs)
    }
}
