import SwiftUI

/// The root view of the Muxi app.
///
/// Uses ``ConnectionManager/state`` to drive which screen is displayed,
/// ensuring the UI always reflects the true connection state:
///
/// ```
/// ServerListView  ->  (connecting)  ->  SessionListView  ->  TerminalSessionView
///                                                           + ReconnectingOverlay
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
    @State private var sessionListViewModel: SessionListViewModel?

    var body: some View {
        ZStack {
            switch connectionManager.state {
            case .disconnected:
                serverListNavigation

            case .connecting:
                serverListNavigation
                    .overlay {
                        connectingOverlay
                    }

            case .sessionList:
                sessionListNavigation

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
                        sessionListViewModel = nil
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
                        ThemeSettingsView(themeManager: themeManager)
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

    // MARK: - Session List

    @ViewBuilder
    private var sessionListNavigation: some View {
        NavigationStack {
            if let viewModel = sessionListViewModel {
                SessionListView(viewModel: viewModel)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Disconnect") {
                                connectionManager.disconnect()
                                previousAttachedSession = nil
                                sessionListViewModel = nil
                            }
                        }
                    }
            }
        }
        .onAppear {
            if sessionListViewModel == nil {
                sessionListViewModel = SessionListViewModel(
                    connectionManager: connectionManager
                )
            }
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
                _ = try await connectionManager.connect(
                    server: server,
                    password: password
                )
                // On success the state transitions to .sessionList automatically.
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
