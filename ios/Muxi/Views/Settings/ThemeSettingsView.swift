import SwiftUI

/// Displays a list of available terminal color themes for the user to choose
/// from.  Each row shows the theme name, a preview strip of its first 8 ANSI
/// colors, and a checkmark for the currently active theme.
struct ThemeSettingsView: View {
    let themeManager: ThemeManager

    var body: some View {
        List(themeManager.themes) { theme in
            Button {
                themeManager.selectTheme(theme)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(theme.name)
                            .font(.body)
                            .foregroundStyle(.primary)

                        // Color preview: show first 8 ANSI colors as swatches.
                        HStack(spacing: 2) {
                            ForEach(0..<min(8, theme.ansiColors.count), id: \.self) { i in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(theme.ansiColors[i].color)
                                    .frame(width: 20, height: 12)
                            }
                        }
                    }

                    Spacer()

                    if theme.id == themeManager.currentTheme.id {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
        .navigationTitle("Theme")
    }
}
