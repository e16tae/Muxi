import SwiftUI
import SwiftData
import os

struct ServerListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Server.name) private var servers: [Server]
    @State private var showingAddServer = false
    @State private var editingServer: Server?

    private let logger = Logger(subsystem: "com.muxi.app", category: "ServerListView")

    /// Callback invoked when the user taps a server row to initiate a connection.
    var onServerTap: ((Server) -> Void)?

    var body: some View {
        List {
            ForEach(servers) { server in
                Button {
                    onServerTap?(server)
                } label: {
                    ServerRowView(server: server)
                }
                .listRowBackground(MuxiTokens.Colors.surfaceDefault)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteServer(server)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        editingServer = server
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(MuxiTokens.Colors.warning)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(MuxiTokens.Colors.surfaceBase)
        .navigationTitle("Servers")
        .toolbar {
            Button {
                showingAddServer = true
            } label: {
                Image(systemName: "plus")
            }
        }
        .sheet(isPresented: $showingAddServer) {
            ServerEditView(server: nil)
        }
        .sheet(item: $editingServer) { server in
            ServerEditView(server: server)
        }
    }

    // MARK: - Helpers

    /// Delete a server and clean up its Keychain secrets.
    private func deleteServer(_ server: Server) {
        let keychainService = KeychainService()
        do {
            try keychainService.deletePassword(account: server.id.uuidString)
        } catch {
            logger.error("Failed to delete Keychain password for server \(server.name): \(error.localizedDescription)")
        }
        if case .key(let keyId) = server.authMethod {
            do {
                try keychainService.deleteSSHKey(id: keyId)
            } catch {
                logger.error("Failed to delete SSH key for server \(server.name): \(error.localizedDescription)")
            }
        }
        modelContext.delete(server)
        do {
            try modelContext.save()
        } catch {
            logger.error("Failed to save after deleting server \(server.name): \(error.localizedDescription)")
        }
    }
}
