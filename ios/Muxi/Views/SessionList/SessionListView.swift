import SwiftUI

/// Displays the list of tmux sessions discovered on the remote server.
///
/// Users can create, delete, and attach to sessions from this screen.
struct SessionListView: View {
    @Bindable var viewModel: SessionListViewModel
    @State private var showingNewSession = false
    @State private var newSessionName = ""

    var body: some View {
        Group {
            if viewModel.sessions.isEmpty {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "terminal",
                    description: Text("Tap + to create a new tmux session.")
                )
            } else {
                List {
                    ForEach(viewModel.sessions) { session in
                        Button {
                            Task { await viewModel.attachSession(session) }
                        } label: {
                            SessionRowView(session: session)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await viewModel.deleteSession(session) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .refreshable {
                    await viewModel.refreshSessions()
                }
            }
        }
        .navigationTitle("Sessions")
        .toolbar {
            Button {
                newSessionName = ""
                showingNewSession = true
            } label: {
                Image(systemName: "plus")
            }
        }
        .alert("New Session", isPresented: $showingNewSession) {
            TextField("Session name", text: $newSessionName)
            Button("Create") {
                let name = newSessionName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task { await viewModel.createSession(name: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the new tmux session.")
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            if let msg = viewModel.errorMessage {
                Text(msg)
            }
        }
    }
}
