import SwiftUI
import SwiftData

struct ServerListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Server.name) private var servers: [Server]
    @State private var showingAddServer = false
    @State private var editingServer: Server?

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
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        // Clean up Keychain secrets before deleting the model
                        let keychainService = KeychainService()
                        try? keychainService.deletePassword(account: server.id.uuidString)
                        if case .key(let keyId) = server.authMethod {
                            try? keychainService.deleteSSHKey(id: keyId)
                        }
                        modelContext.delete(server)
                        try? modelContext.save()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        editingServer = server
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.orange)
                }
            }
        }
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
}
