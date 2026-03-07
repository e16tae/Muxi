import SwiftUI

/// A horizontal toolbar displayed above the software keyboard, providing
/// Esc, Tab, Ctrl, Alt, and arrow keys for terminal use.
///
/// `Ctrl` and `Alt` are sticky-toggle modifiers: tap to activate, tap again
/// to deactivate. They auto-deactivate after the next regular keypress sent
/// through the ``InputHandler``.
struct ExtendedKeyboardView: View {
    let theme: Theme
    let inputHandler: InputHandler

    /// Callback invoked with the raw bytes to send over the SSH channel.
    var onInput: ((Data) -> Void)?

    // MARK: - Body

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MuxiTokens.Spacing.sm) {
                // Immediate keys
                keyButton("Esc") { send(key: .escape) }
                keyButton("Tab") { send(key: .tab) }

                // Sticky modifiers — read directly from the @Observable InputHandler
                // so highlights automatically update when modifiers auto-deactivate.
                modifierButton("Ctrl", active: inputHandler.ctrlActive) {
                    inputHandler.toggleCtrl()
                }
                modifierButton("Alt", active: inputHandler.altActive) {
                    inputHandler.toggleAlt()
                }

                Divider()
                    .frame(height: 24)
                    .background(MuxiTokens.Colors.borderDefault)

                // Arrow keys
                keyButton("\u{2190}") { send(key: .arrowLeft) }
                    .accessibilityLabel("Arrow Left")
                keyButton("\u{2191}") { send(key: .arrowUp) }
                    .accessibilityLabel("Arrow Up")
                keyButton("\u{2193}") { send(key: .arrowDown) }
                    .accessibilityLabel("Arrow Down")
                keyButton("\u{2192}") { send(key: .arrowRight) }
                    .accessibilityLabel("Arrow Right")
            }
            .padding(.horizontal, MuxiTokens.Spacing.lg)
            .padding(.vertical, MuxiTokens.Spacing.xs)
        }
        .frame(height: 44)
        .background(theme.background.color)
    }

    // MARK: - Key Button

    @ViewBuilder
    private func keyButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(MuxiTokens.Typography.label.monospaced())
                .foregroundStyle(MuxiTokens.Colors.textPrimary)
                .frame(minWidth: 36, minHeight: 32)
                .background(MuxiTokens.Colors.accentMuted)
                .clipShape(RoundedRectangle(cornerRadius: MuxiTokens.Radius.sm))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Modifier Button

    @ViewBuilder
    private func modifierButton(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(MuxiTokens.Typography.label.monospaced())
                .foregroundStyle(active ? theme.background.color : MuxiTokens.Colors.textPrimary)
                .frame(minWidth: 36, minHeight: 32)
                .background(active ? MuxiTokens.Colors.accentDefault : MuxiTokens.Colors.accentMuted)
                .clipShape(RoundedRectangle(cornerRadius: MuxiTokens.Radius.sm))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func send(key: SpecialKey) {
        let data = inputHandler.data(for: key)
        onInput?(data)
    }
}
