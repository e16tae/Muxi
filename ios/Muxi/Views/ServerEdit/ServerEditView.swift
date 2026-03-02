import SwiftUI
import SwiftData
import os

struct ServerEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let server: Server?

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
                        .disabled(name.isEmpty || host.isEmpty || username.isEmpty)
                }
            }
            .onAppear { loadServer() }
        }
    }

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
