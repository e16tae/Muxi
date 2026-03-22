import SwiftUI

/// Root settings screen with sections for appearance and app info.
struct SettingsView: View {
    let themeManager: ThemeManager
    let connectionManager: ConnectionManager

    var body: some View {
        List {
            appearanceSection
            tailscaleSection
            aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(MuxiTokens.Colors.surfaceBase)
        .navigationTitle("Settings")
    }

    // MARK: - Appearance

    @ViewBuilder
    private var appearanceSection: some View {
        Section("Appearance") {
            NavigationLink {
                ThemeSettingsView(themeManager: themeManager)
            } label: {
                HStack {
                    Label("Theme", systemImage: "paintpalette")
                        .foregroundStyle(MuxiTokens.Colors.textPrimary)
                    Spacer()
                    Text(themeManager.currentTheme.name)
                        .foregroundStyle(MuxiTokens.Colors.textSecondary)
                }
            }
            .listRowBackground(MuxiTokens.Colors.surfaceDefault)

            HStack {
                Label("Font Size", systemImage: "textformat.size")
                    .foregroundStyle(MuxiTokens.Colors.textPrimary)
                Spacer()
                Text("\(Int(themeManager.fontSize))pt")
                    .foregroundStyle(MuxiTokens.Colors.textSecondary)
                    .monospacedDigit()
                Stepper("", value: fontSizeBinding,
                        in: ThemeManager.minFontSize...ThemeManager.maxFontSize,
                        step: ThemeManager.fontSizeStep)
                    .labelsHidden()
            }
            .listRowBackground(MuxiTokens.Colors.surfaceDefault)
        }
    }

    private var fontSizeBinding: Binding<CGFloat> {
        Binding(
            get: { themeManager.fontSize },
            set: { themeManager.setFontSize($0) }
        )
    }

    // MARK: - Tailscale

    @ViewBuilder
    private var tailscaleSection: some View {
        Section("Tailscale") {
            NavigationLink {
                TailscaleSettingsView()
            } label: {
                HStack {
                    Label("Tailscale", systemImage: "network")
                        .foregroundStyle(MuxiTokens.Colors.textPrimary)
                    Spacer()
                    Text(tailscaleStatusText)
                        .foregroundStyle(tailscaleStatusColor)
                }
            }
            .listRowBackground(MuxiTokens.Colors.surfaceDefault)
        }
    }

    private var tailscaleStatusText: String {
        switch connectionManager.tailscaleState {
        case .disconnected: "Off"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .error: "Error"
        }
    }

    private var tailscaleStatusColor: Color {
        switch connectionManager.tailscaleState {
        case .connected: .green
        case .error: .red
        default: MuxiTokens.Colors.textSecondary
        }
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        Section("About") {
            HStack {
                Label("Version", systemImage: "info.circle")
                    .foregroundStyle(MuxiTokens.Colors.textPrimary)
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    .foregroundStyle(MuxiTokens.Colors.textSecondary)
            }
            .listRowBackground(MuxiTokens.Colors.surfaceDefault)
        }
    }
}
