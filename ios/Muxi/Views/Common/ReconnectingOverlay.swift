import SwiftUI

// MARK: - ReconnectingOverlay

/// A full-screen modal overlay that shows reconnection progress.
///
/// Displays a centered card with a spinner, attempt counter, and an
/// optional cancel button. Designed to be layered on top of a terminal
/// view when the SSH connection is being re-established.
///
/// Usage:
/// ```swift
/// TerminalView()
///     .overlay {
///         if connectionState == .reconnecting {
///             ReconnectingOverlay(
///                 attempt: currentAttempt,
///                 maxAttempts: 5,
///                 onCancel: { cancelReconnection() }
///             )
///         }
///     }
/// ```
struct ReconnectingOverlay: View {
    /// Current reconnection attempt number (1-based).
    let attempt: Int
    /// Maximum number of reconnection attempts.
    let maxAttempts: Int
    /// Called when the user taps Cancel. If `nil`, the cancel button is hidden.
    var onCancel: (() -> Void)?

    /// Human-readable attempt text, e.g. "Attempt 2 of 5".
    var attemptText: String {
        "Attempt \(attempt) of \(maxAttempts)"
    }

    var body: some View {
        ZStack {
            // Semi-transparent backdrop
            Color.black.opacity(0.5)
                .ignoresSafeArea()

            // Centered card
            VStack(spacing: 20) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .tint(.white)

                Text("Reconnecting...")
                    .font(.headline)
                    .foregroundStyle(.white)

                Text(attemptText)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))

                if let onCancel {
                    Button {
                        onCancel()
                    } label: {
                        Text("Cancel")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(.white.opacity(0.15))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel reconnection")
                }
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                    .environment(\.colorScheme, .dark)
            )
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reconnecting. \(attemptText)")
    }
}

// MARK: - TmuxInstallGuideView

/// A sheet view that guides users through installing tmux on their server.
///
/// Shown when a connection detects that tmux is not installed or the
/// version is below the minimum requirement.
struct TmuxInstallGuideView: View {
    /// The minimum tmux version required by Muxi.
    static let minimumVersion = "1.8"

    /// Whether the guide is being shown because tmux is missing entirely
    /// or because the version is too old.
    enum Reason: Equatable {
        case notInstalled
        case versionTooOld(detected: String)
    }

    let reason: Reason
    let serverName: String
    var onDismiss: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    installSection
                    verifySection
                }
                .padding()
            }
            .navigationTitle("tmux Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onDismiss?()
                    }
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                switch reason {
                case .notInstalled:
                    Text("tmux not found on \(serverName)")
                case .versionTooOld(let detected):
                    Text("tmux \(detected) found on \(serverName)")
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.headline)

            Text(descriptionText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var installSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install or Update tmux")
                .font(.subheadline.weight(.semibold))

            commandBlock(label: "Ubuntu / Debian", command: "sudo apt update && sudo apt install -y tmux")
            commandBlock(label: "CentOS / RHEL", command: "sudo yum install -y tmux")
            commandBlock(label: "macOS (Homebrew)", command: "brew install tmux")
            commandBlock(label: "Alpine", command: "sudo apk add tmux")
        }
    }

    @ViewBuilder
    private var verifySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Verify Installation")
                .font(.subheadline.weight(.semibold))

            commandBlock(label: "Check version", command: "tmux -V")

            Text("Muxi requires tmux \(Self.minimumVersion) or later.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var descriptionText: String {
        switch reason {
        case .notInstalled:
            return "Muxi needs tmux installed on your server to manage terminal sessions. Install it using one of the commands below."
        case .versionTooOld(let detected):
            return "Muxi requires tmux \(Self.minimumVersion)+, but version \(detected) was detected. Please upgrade tmux using one of the commands below."
        }
    }

    @ViewBuilder
    private func commandBlock(label: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(command)
                .font(.system(.caption, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.systemGray6))
                )
                .textSelection(.enabled)
        }
    }
}

// MARK: - Previews

#Preview("Reconnecting Overlay") {
    ZStack {
        Color(.systemBackground)
            .ignoresSafeArea()

        Text("Terminal Content Behind Overlay")

        ReconnectingOverlay(
            attempt: 2,
            maxAttempts: 5,
            onCancel: {}
        )
    }
}

#Preview("tmux Not Installed") {
    TmuxInstallGuideView(
        reason: .notInstalled,
        serverName: "prod-server-1",
        onDismiss: {}
    )
}

#Preview("tmux Version Too Old") {
    TmuxInstallGuideView(
        reason: .versionTooOld(detected: "1.6"),
        serverName: "staging-box",
        onDismiss: {}
    )
}
