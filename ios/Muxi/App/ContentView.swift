import SwiftUI

/// The root view of the Muxi app.
///
/// Uses ``ConnectionManager/state`` to drive which screen is displayed,
/// ensuring the UI always reflects the true connection state:
///
/// ```
/// ServerListView  ->  (connecting)  ->  TerminalSessionView
///                                       + ReconnectingOverlay
/// ```
struct ContentView: View {
    @Environment(ConnectionManager.self) private var connectionManager
    @State private var themeManager = ThemeManager()
    @State private var errorMessage: String?
    @State private var showErrorBanner = false
    @State private var selectedServer: Server?
    @State private var passwordPrompt: String = ""
    @State private var showingPasswordPrompt = false
    @State private var previousAttachedSession: String?
    @State private var tmuxGuideReason: TmuxInstallGuideView.Reason?

    var body: some View {
        ZStack {
            MuxiTokens.Colors.surfaceBase
                .ignoresSafeArea()

            switch connectionManager.state {
            case .disconnected:
                serverListNavigation

            case .connecting:
                serverListNavigation
                    .overlay {
                        connectingOverlay
                    }

            case .attached(let sessionName):
                TerminalSessionView(
                    connectionManager: connectionManager,
                    sessionName: sessionName,
                    themeManager: themeManager
                )
                .onAppear {
                    previousAttachedSession = sessionName
                }

            case .reconnecting:
                // Show the terminal behind the reconnecting overlay if we were
                // previously attached; otherwise show a plain background.
                if let previousSession = previousAttachedSession {
                    TerminalSessionView(
                        connectionManager: connectionManager,
                        sessionName: previousSession,
                        themeManager: themeManager
                    )
                }
                ReconnectingOverlay(
                    attempt: connectionManager.reconnectAttempt,
                    maxAttempts: connectionManager.maxReconnectAttempts,
                    onCancel: {
                        connectionManager.disconnect()
                        previousAttachedSession = nil
                    }
                )
            }

            // Error banner overlay
            if showErrorBanner, let error = errorMessage {
                VStack {
                    ErrorBannerView(
                        message: error,
                        style: .error,
                        onDismiss: {
                            withAnimation {
                                showErrorBanner = false
                                errorMessage = nil
                            }
                        },
                        onRetry: selectedServer != nil ? {
                            if let server = selectedServer {
                                connectToServer(server)
                            }
                        } : nil
                    )
                    .padding(.top, 8)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: connectionManager.state)
        .animation(.easeInOut(duration: 0.25), value: showErrorBanner)
        .sheet(item: $tmuxGuideReason) { reason in
            TmuxInstallGuideView(
                reason: reason,
                serverName: selectedServer?.name ?? selectedServer?.host ?? "server",
                onDismiss: {
                    tmuxGuideReason = nil
                }
            )
        }
        .alert(
            "New Server Fingerprint",
            isPresented: Binding(
                get: { connectionManager.pendingFingerprint != nil },
                set: { newValue in
                    if !newValue {
                        connectionManager.pendingFingerprintAction?(false)
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                connectionManager.pendingFingerprintAction?(false)
            }
            Button("Trust") {
                connectionManager.pendingFingerprintAction?(true)
            }
        } message: {
            if let fingerprint = connectionManager.pendingFingerprint {
                Text("This is your first connection to \(selectedServer?.name ?? selectedServer?.host ?? "this server").\n\nVerify the server fingerprint:\n\(fingerprint)\n\nDo you trust this server?")
            }
        }
        .alert(
            "Host Key Changed",
            isPresented: Binding(
                get: { connectionManager.showFingerprintMismatchAlert },
                set: { newValue in
                    if !newValue {
                        connectionManager.pendingFingerprintAction?(false)
                    }
                }
            )
        ) {
            Button("Disconnect", role: .cancel) {
                connectionManager.pendingFingerprintAction?(false)
            }
            Button("Accept New Key", role: .destructive) {
                connectionManager.pendingFingerprintAction?(true)
            }
        } message: {
            if let mismatch = connectionManager.mismatchFingerprint {
                Text("The host key for \(selectedServer?.name ?? selectedServer?.host ?? "this server") has changed. This could indicate a man-in-the-middle attack.\n\nPrevious: \(mismatch.expected)\nCurrent: \(mismatch.actual)\n\nAccepting this change is dangerous unless you know the server was recently reinstalled.")
            }
        }
        .alert("Enter Password", isPresented: $showingPasswordPrompt) {
            SecureField("Password", text: $passwordPrompt)
            Button("Connect") {
                if let server = selectedServer {
                    let password = passwordPrompt
                    passwordPrompt = ""
                    connectToServer(server, password: password)
                }
            }
            Button("Cancel", role: .cancel) {
                passwordPrompt = ""
                selectedServer = nil
            }
        } message: {
            if let server = selectedServer {
                Text("Enter the password for \(server.username)@\(server.host)")
            }
        }
    }

    // MARK: - Server List

    @ViewBuilder
    private var serverListNavigation: some View {
        NavigationStack {
            ServerListView(onServerTap: { server in
                handleServerTap(server)
            })
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SettingsView(themeManager: themeManager)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
    }

    // MARK: - Connecting Overlay

    @ViewBuilder
    private var connectingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: MuxiTokens.Spacing.lg) {
                ProgressView()
                    .controlSize(.large)
                Text("Connecting...")
                    .font(MuxiTokens.Typography.title)
                    .foregroundStyle(MuxiTokens.Colors.textSecondary)

                Button("Cancel") {
                    connectionManager.disconnect()
                    selectedServer = nil
                }
                .buttonStyle(.bordered)
            }
            .padding(MuxiTokens.Spacing.xxl)
            .background(
                RoundedRectangle(cornerRadius: MuxiTokens.Radius.lg, style: .continuous)
                    .fill(MuxiTokens.Colors.surfaceElevated)
            )
        }
    }

    // MARK: - Connection Logic

    /// Handle a server row tap. If the server uses password auth, prompt for
    /// the password first; otherwise connect immediately.
    private func handleServerTap(_ server: Server) {
        selectedServer = server
        showErrorBanner = false
        errorMessage = nil

        switch server.authMethod {
        case .password:
            // Try Keychain first; fall back to password prompt if not saved.
            do {
                let keychain = KeychainService()
                let password = try keychain.retrievePassword(account: server.id.uuidString)
                // Password found in Keychain, connect directly.
                connectToServer(server, password: password)
            } catch {
                if case KeychainError.itemNotFound = error {
                    // No password in Keychain, prompt the user.
                    showingPasswordPrompt = true
                } else {
                    // Keychain error (corrupt data, OS error) — show error banner.
                    withAnimation {
                        errorMessage = "Keychain error: \(error.localizedDescription)"
                        showErrorBanner = true
                    }
                }
            }
        case .key(let keyId):
            // Verify SSH key exists before attempting connection.
            do {
                let keychain = KeychainService()
                _ = try keychain.retrieveSSHKey(id: keyId)
                connectToServer(server)
            } catch {
                if case KeychainError.itemNotFound = error {
                    withAnimation {
                        errorMessage = "SSH key not found. Import a key in Settings."
                        showErrorBanner = true
                    }
                } else {
                    withAnimation {
                        errorMessage = "Keychain error: \(error.localizedDescription)"
                        showErrorBanner = true
                    }
                }
            }
        }
    }

    /// Initiate an async connection to the given server.
    private func connectToServer(_ server: Server, password: String? = nil) {
        Task {
            do {
                try await connectionManager.connect(
                    server: server,
                    password: password
                )
                // Save password to Keychain on successful connection so the
                // user isn't prompted again next time.
                if let password, server.authMethod == .password {
                    try? KeychainService().savePassword(
                        password, account: server.id.uuidString
                    )
                }
            } catch let error as TmuxError {
                switch error {
                case .notInstalled:
                    tmuxGuideReason = .notInstalled
                case .versionTooOld(let detected):
                    tmuxGuideReason = .versionTooOld(detected: detected)
                }
            } catch is SSHHostKeyError {
                // Host key verification was handled (and rejected) via the
                // fingerprint alert. No additional error banner needed.
            } catch {
                withAnimation {
                    errorMessage = "Connection failed: \(error.localizedDescription)"
                    showErrorBanner = true
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(ConnectionManager())
}
