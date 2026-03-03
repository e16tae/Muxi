import SwiftUI

/// A floating circular button positioned at the bottom-right corner of its
/// parent container.
///
/// Tapping the button presents the ``QuickActionView`` as a half-sheet.
/// The `onAction` callback passes the selected tmux command string to the
/// parent so it can be dispatched to the SSH connection.
struct QuickActionButton: View {
    /// Callback that receives the tmux command string when an action is selected.
    var onAction: ((String) -> Void)?

    @State private var showingActions = false

    // MARK: - Body

    var body: some View {
        Button {
            showingActions = true
        } label: {
            Image(systemName: "bolt.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(MuxiTokens.Colors.textPrimary)
                .frame(width: 52, height: 52)
                .background(Circle().fill(MuxiTokens.Colors.accentDefault))
        }
        .accessibilityLabel("Quick Actions")
        .sheet(isPresented: $showingActions) {
            QuickActionView(onAction: onAction)
        }
    }
}
