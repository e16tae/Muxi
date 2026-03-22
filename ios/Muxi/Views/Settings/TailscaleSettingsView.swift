import SwiftUI

/// Account management view for the Tailscale integration.
/// Configuration (setup wizard) happens in ``ServerEditView``; this view
/// only shows current account status and provides connect / sign-out actions.
struct TailscaleSettingsView: View {
    @Environment(TailscaleAccountManager.self) private var accountManager
    @Environment(ConnectionManager.self) private var connectionManager

    var body: some View {
        List {
            if accountManager.provider != nil {
                accountSection
                actionsSection
            } else {
                noAccountSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(MuxiTokens.Colors.surfaceBase)
        .navigationTitle("Tailscale")
    }

    // MARK: - Account Section

    @ViewBuilder
    private var accountSection: some View {
        Section("Account") {
            row(label: "Provider", value: providerText)

            HStack {
                Text("Status")
                    .foregroundStyle(MuxiTokens.Colors.textPrimary)
                Spacer()
                Text(statusText)
                    .foregroundStyle(statusColor)
            }
            .listRowBackground(MuxiTokens.Colors.surfaceDefault)

            row(label: "This device", value: accountManager.hostname)

            if accountManager.provider == .headscale {
                row(label: "Control URL", value: accountManager.controlURL)
            }
        }
    }

    // MARK: - Actions Section

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            Button {
                toggleConnection()
            } label: {
                Text(isConnected ? "Disconnect" : "Connect")
                    .frame(maxWidth: .infinity)
            }
            .listRowBackground(MuxiTokens.Colors.surfaceDefault)

            Button(role: .destructive) {
                Task {
                    if isConnected {
                        await connectionManager.stopTailscale()
                    }
                    accountManager.signOut()
                }
            } label: {
                Text("Sign Out")
                    .frame(maxWidth: .infinity)
            }
            .listRowBackground(MuxiTokens.Colors.surfaceDefault)
        }
    }

    // MARK: - No Account Section

    @ViewBuilder
    private var noAccountSection: some View {
        Section {
            Text("서버 추가 시 Tailscale을 선택하면 설정할 수 있습니다.")
                .foregroundStyle(MuxiTokens.Colors.textSecondary)
                .listRowBackground(MuxiTokens.Colors.surfaceDefault)
        }
    }

    // MARK: - Helpers

    private var isConnected: Bool {
        connectionManager.tailscaleState == .connected
    }

    private var providerText: String {
        switch accountManager.provider {
        case .official: "Tailscale"
        case .headscale: "Headscale"
        case nil: "—"
        }
    }

    private var statusText: String {
        switch connectionManager.tailscaleState {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting..."
        case .connected: "Connected"
        case .error(let msg): msg
        }
    }

    private var statusColor: Color {
        switch connectionManager.tailscaleState {
        case .disconnected: MuxiTokens.Colors.textSecondary
        case .connecting: MuxiTokens.Colors.textSecondary
        case .connected: MuxiTokens.Colors.success
        case .error: MuxiTokens.Colors.error
        }
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(MuxiTokens.Colors.textPrimary)
            Spacer()
            Text(value)
                .foregroundStyle(MuxiTokens.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .listRowBackground(MuxiTokens.Colors.surfaceDefault)
    }

    private func toggleConnection() {
        Task {
            if isConnected {
                await connectionManager.stopTailscale()
            } else {
                guard let account = accountManager.account else { return }
                await connectionManager.startTailscale(
                    controlURL: account.controlURL,
                    authKey: accountManager.preAuthKey() ?? "",
                    hostname: account.hostname
                )
            }
        }
    }
}
