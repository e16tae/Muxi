import SwiftUI
import SwiftData
import os

struct ServerEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(TailscaleAccountManager.self) private var tailscaleAccountManager
    @Environment(ConnectionManager.self) private var connectionManager

    let server: Server?

    enum ConnectionMethod { case direct, tailscale }

    @State private var connectionMethod: ConnectionMethod = .direct
    @State private var selectedDevice: TailscaleDevice?
    @State private var showSetupSheet = false

    @State private var name = ""
    @State private var host = ""
    @State private var port: UInt16 = 22
    @State private var username = ""
    @State private var useKeyAuth = false
    @State private var agentForwarding = false
    @State private var password = ""
    private var isEditing: Bool { server != nil }
    private let keychainService = KeychainService()
    private let logger = Logger(subsystem: "com.muxi.app", category: "ServerEditView")

    var body: some View {
        NavigationStack {
            Form {
                connectionSection

                Section("Server") {
                    TextField("Name", text: $name)
                    TextField("Host", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("22", value: $port, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Authentication") {
                    Picker("Method", selection: $useKeyAuth) {
                        Text("Password").tag(false)
                        Text("SSH Key").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if !useKeyAuth {
                        SecureField("Password", text: $password)
                    }

                    Toggle("Agent Forwarding", isOn: $agentForwarding)
                }

            }
            .navigationTitle(isEditing ? "Edit Server" : "New Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(
                            name.isEmpty || host.isEmpty || username.isEmpty
                            || port == 0
                            || host.count > 253
                            || username.contains(" ")
                        )
                }
            }
            .onAppear { loadServer() }
            .scrollContentBackground(.hidden)
            .background(MuxiTokens.Colors.surfaceBase)
            .sheet(isPresented: $showSetupSheet) {
                TailscaleSetupSheet(
                    accountManager: tailscaleAccountManager,
                    connectionManager: connectionManager
                ) {
                    showSetupSheet = false
                }
            }
        }
    }

    // MARK: - Connection Section

    @ViewBuilder
    private var connectionSection: some View {
        Section("Connection") {
            Picker("Method", selection: $connectionMethod) {
                Text("Direct").tag(ConnectionMethod.direct)
                Text("Tailscale").tag(ConnectionMethod.tailscale)
            }
            .pickerStyle(.segmented)
            .listRowBackground(MuxiTokens.Colors.surfaceDefault)
        }

        if connectionMethod == .tailscale {
            if tailscaleAccountManager.isConfigured {
                if tailscaleAccountManager.apiKey() != nil {
                    // API key 있음 → 기기 목록 표시
                    Section("Tailscale Device") {
                        TailscaleDeviceListView(accountManager: tailscaleAccountManager) { device in
                            selectedDevice = device
                            host = device.ipv4Address ?? ""
                            name = name.isEmpty ? device.name : name
                        }
                    }

                    if let device = selectedDevice {
                        Section("Selected") {
                            HStack {
                                Text(device.name)
                                    .foregroundStyle(MuxiTokens.Colors.textPrimary)
                                Spacer()
                                Text(device.ipv4Address ?? "")
                                    .foregroundStyle(MuxiTokens.Colors.textSecondary)
                            }
                            .listRowBackground(MuxiTokens.Colors.surfaceDefault)
                        }
                    }
                } else {
                    // API key 없음 → 수동 IP 입력
                    Section {
                        Text("API Key가 없어 기기 목록을 조회할 수 없습니다. Tailscale IP를 직접 입력하세요.")
                            .font(.caption)
                            .foregroundStyle(MuxiTokens.Colors.textSecondary)
                            .listRowBackground(MuxiTokens.Colors.surfaceDefault)
                    } header: {
                        Text("Tailscale")
                    }
                }
            } else {
                Section("Tailscale") {
                    Button("Set up Tailscale") { showSetupSheet = true }
                        .frame(maxWidth: .infinity)
                        .listRowBackground(MuxiTokens.Colors.surfaceDefault)
                }
            }
        }
    }

    // MARK: - Load / Save

    private func loadServer() {
        guard let server else { return }
        name = server.name
        host = server.host
        port = server.port
        username = server.username
        agentForwarding = server.agentForwarding
        if case .key = server.authMethod {
            useKeyAuth = true
        }
        if server.isTailscale {
            connectionMethod = .tailscale
            if let deviceName = server.tailscaleDeviceName {
                selectedDevice = TailscaleDevice(
                    id: server.tailscaleDeviceID ?? "",
                    name: deviceName,
                    addresses: [server.host],
                    isOnline: true,
                    os: nil,
                    lastSeen: nil
                )
            }
        }
    }

    private func save() {
        let authMethod: AuthMethod
        if useKeyAuth {
            // Preserve existing keyId when editing, generate new one only for new key associations
            if case .key(let existingKeyId) = server?.authMethod {
                authMethod = .key(keyId: existingKeyId)
            } else {
                authMethod = .key(keyId: UUID())
            }
        } else {
            authMethod = .password
        }

        // Capture original auth method BEFORE mutation (Server is a reference type)
        let previousAuthMethod = server?.authMethod

        let targetServer: Server
        if let server {
            server.name = name
            server.host = host
            server.port = port
            server.username = username
            server.authMethod = authMethod
            server.agentForwarding = agentForwarding
            targetServer = server
        } else {
            let newServer = Server(
                name: name, host: host, port: port,
                username: username, authMethod: authMethod,
                agentForwarding: agentForwarding
            )
            modelContext.insert(newServer)
            targetServer = newServer
        }

        // Set Tailscale fields based on connection method
        if connectionMethod == .tailscale {
            if let device = selectedDevice {
                targetServer.tailscaleDeviceID = device.id
                targetServer.tailscaleDeviceName = device.name
            } else {
                // API key 없이 수동 IP 입력 — host를 ID로 사용
                targetServer.tailscaleDeviceID = "manual-\(host)"
                targetServer.tailscaleDeviceName = host
            }
        } else {
            targetServer.tailscaleDeviceID = nil
            targetServer.tailscaleDeviceName = nil
        }

        // Clean up stale Keychain password when switching from password to key auth
        if useKeyAuth, case .password = previousAuthMethod {
            try? keychainService.deletePassword(account: targetServer.id.uuidString)
        }

        if !useKeyAuth && !password.isEmpty {
            do {
                try keychainService.savePassword(password, account: targetServer.id.uuidString)
            } catch {
                logger.error("Failed to save password to Keychain: \(error.localizedDescription)")
            }
        }

        do {
            try modelContext.save()
            dismiss()
        } catch {
            logger.error("Failed to save server: \(error.localizedDescription)")
        }
    }
}
