import SwiftUI
import AuthenticationServices

struct TailscaleSetupSheet: View {
    let accountManager: TailscaleAccountManager
    let connectionManager: ConnectionManager
    let onComplete: () -> Void

    @State private var step: SetupStep = .providerPicker
    @State private var controlURL = ""
    @State private var preAuthKey = ""
    @State private var apiKey = ""
    @State private var hostname = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    enum SetupStep { case providerPicker, headscaleForm, oauthLogin, connecting }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .providerPicker: providerPickerView
                case .headscaleForm: headscaleFormView
                case .oauthLogin: oauthLoginView
                case .connecting: connectingView
                }
            }
            .navigationTitle("Set up Tailscale")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(MuxiTokens.Colors.surfaceBase)
        }
        .onAppear {
            hostname = accountManager.hostname
        }
    }

    // MARK: - Provider Picker

    @ViewBuilder
    private var providerPickerView: some View {
        List {
            Section {
                Button {
                    step = .oauthLogin
                } label: {
                    Label("Tailscale", systemImage: "globe")
                        .foregroundStyle(MuxiTokens.Colors.textPrimary)
                }
                .listRowBackground(MuxiTokens.Colors.surfaceDefault)

                Button {
                    step = .headscaleForm
                } label: {
                    Label("Headscale (Self-hosted)", systemImage: "server.rack")
                        .foregroundStyle(MuxiTokens.Colors.textPrimary)
                }
                .listRowBackground(MuxiTokens.Colors.surfaceDefault)
            } header: {
                Text("Provider")
            }
        }
    }

    // MARK: - Headscale Form

    @ViewBuilder
    private var headscaleFormView: some View {
        Form {
            Section("Server") {
                TextField("Control URL", text: $controlURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .foregroundStyle(MuxiTokens.Colors.textPrimary)
                    .listRowBackground(MuxiTokens.Colors.surfaceDefault)
            }

            Section("Authentication") {
                SecureField("Pre-auth Key", text: $preAuthKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(MuxiTokens.Colors.textPrimary)
                    .listRowBackground(MuxiTokens.Colors.surfaceDefault)
            }

            Section {
                SecureField("API Key (선택)", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(MuxiTokens.Colors.textPrimary)
                    .listRowBackground(MuxiTokens.Colors.surfaceDefault)
            } header: {
                Text("기기 목록 (선택)")
            } footer: {
                Text("API Key를 입력하면 tailnet 기기 목록을 조회할 수 있습니다. 없으면 IP를 직접 입력합니다.")
                    .foregroundStyle(MuxiTokens.Colors.textSecondary)
            }

            Section("Device") {
                TextField("Hostname", text: $hostname)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(MuxiTokens.Colors.textPrimary)
                    .listRowBackground(MuxiTokens.Colors.surfaceDefault)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(MuxiTokens.Colors.error)
                        .listRowBackground(MuxiTokens.Colors.surfaceDefault)
                }
            }

            Section {
                Button {
                    connectHeadscale()
                } label: {
                    Text("Connect")
                        .frame(maxWidth: .infinity)
                }
                .disabled(controlURL.isEmpty || preAuthKey.isEmpty || isConnecting)
                .listRowBackground(MuxiTokens.Colors.surfaceDefault)
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back") {
                    step = .providerPicker
                }
            }
        }
    }

    // MARK: - OAuth Login

    @ViewBuilder
    private var oauthLoginView: some View {
        List {
            Section {
                // TODO: Implement ASWebAuthenticationSession for Tailscale OAuth
                Button {
                    errorMessage = "Tailscale OAuth is not yet implemented"
                } label: {
                    Text("Sign in with Tailscale")
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(MuxiTokens.Colors.textPrimary)
                }
                .listRowBackground(MuxiTokens.Colors.surfaceDefault)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(MuxiTokens.Colors.error)
                        .listRowBackground(MuxiTokens.Colors.surfaceDefault)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back") {
                    errorMessage = nil
                    step = .providerPicker
                }
            }
        }
    }

    // MARK: - Connecting

    @ViewBuilder
    private var connectingView: some View {
        VStack(spacing: MuxiTokens.Spacing.lg) {
            ProgressView()
                .tint(MuxiTokens.Colors.textPrimary)
            Text("Tailscale에 연결 중...")
                .foregroundStyle(MuxiTokens.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func connectHeadscale() {
        isConnecting = true
        errorMessage = nil
        step = .connecting

        accountManager.configureHeadscale(
            controlURL: controlURL,
            preAuthKey: preAuthKey,
            apiKey: apiKey,
            hostname: hostname
        )

        Task {
            await connectionManager.startTailscale(
                controlURL: controlURL,
                authKey: preAuthKey,
                hostname: hostname
            )

            if connectionManager.tailscaleState == .connected {
                accountManager.markRegistered()
                onComplete()
            } else {
                isConnecting = false
                if case .error(let message) = connectionManager.tailscaleState {
                    errorMessage = message
                } else {
                    errorMessage = "연결에 실패했습니다"
                }
                step = .headscaleForm
            }
        }
    }
}
