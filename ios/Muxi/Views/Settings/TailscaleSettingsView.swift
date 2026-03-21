import SwiftUI

/// Settings screen for configuring the embedded Tailscale node.
struct TailscaleSettingsView: View {
    let connectionManager: ConnectionManager

    @State private var controlURL: String = ""
    @State private var preAuthKey: String = ""
    @State private var hostname: String = ""

    private let configStore = TailscaleConfigStore()

    var body: some View {
        List {
            configSection
            connectionSection
        }
        .scrollContentBackground(.hidden)
        .background(MuxiTokens.Colors.surfaceBase)
        .navigationTitle("Tailscale")
        .onAppear { loadConfig() }
    }

    // MARK: - Config Section

    @ViewBuilder
    private var configSection: some View {
        Section("Headscale") {
            TextField("URL", text: $controlURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .listRowBackground(MuxiTokens.Colors.surfaceDefault)
                .foregroundStyle(MuxiTokens.Colors.textPrimary)
                .onSubmit { saveConfig() }

            SecureField("Pre-auth Key", text: $preAuthKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .listRowBackground(MuxiTokens.Colors.surfaceDefault)
                .foregroundStyle(MuxiTokens.Colors.textPrimary)
                .onSubmit { saveConfig() }

            TextField("Hostname", text: $hostname)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .listRowBackground(MuxiTokens.Colors.surfaceDefault)
                .foregroundStyle(MuxiTokens.Colors.textPrimary)
                .onSubmit { saveConfig() }
        }
    }

    // MARK: - Connection Section

    @ViewBuilder
    private var connectionSection: some View {
        Section("Connection") {
            HStack {
                Label("Status", systemImage: statusIcon)
                    .foregroundStyle(MuxiTokens.Colors.textPrimary)
                Spacer()
                Text(statusText)
                    .foregroundStyle(statusColor)
            }
            .listRowBackground(MuxiTokens.Colors.surfaceDefault)

            Button(action: toggleConnection) {
                Text(isConnected ? "Disconnect" : "Connect")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!configStore.isConfigured && !isConnected)
            .listRowBackground(MuxiTokens.Colors.surfaceDefault)
        }
    }

    // MARK: - Helpers

    private var isConnected: Bool {
        connectionManager.tailscaleState == .connected
    }

    private var statusText: String {
        switch connectionManager.tailscaleState {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .error(let msg): msg
        }
    }

    private var statusIcon: String {
        switch connectionManager.tailscaleState {
        case .disconnected: "circle"
        case .connecting: "circle.dotted"
        case .connected: "checkmark.circle.fill"
        case .error: "exclamationmark.circle"
        }
    }

    private var statusColor: Color {
        switch connectionManager.tailscaleState {
        case .disconnected: MuxiTokens.Colors.textSecondary
        case .connecting: MuxiTokens.Colors.textSecondary
        case .connected: .green
        case .error: .red
        }
    }

    private func loadConfig() {
        controlURL = configStore.controlURL
        preAuthKey = configStore.preAuthKey
        hostname = configStore.hostname
    }

    private func saveConfig() {
        configStore.controlURL = controlURL
        configStore.preAuthKey = preAuthKey
        configStore.hostname = hostname
    }

    private func toggleConnection() {
        saveConfig()
        Task {
            if isConnected {
                await connectionManager.stopTailscale()
            } else {
                await connectionManager.startTailscale(
                    controlURL: controlURL,
                    authKey: preAuthKey,
                    hostname: hostname
                )
            }
        }
    }
}
