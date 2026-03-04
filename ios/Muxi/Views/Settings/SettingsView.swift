import SwiftUI

/// Root settings screen with sections for appearance and app info.
struct SettingsView: View {
    let themeManager: ThemeManager

    var body: some View {
        List {
            appearanceSection
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
                Stepper("", value: fontSizeBinding, in: 10...24, step: 2)
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
