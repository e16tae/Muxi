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

    /// Callback to dismiss the software keyboard.
    var onDismissKeyboard: (() -> Void)?

    // MARK: - Body

    var body: some View {
        HStack(spacing: 6) {
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
                .background(theme.foreground.color.opacity(0.3))

            // Arrow keys
            keyButton("\u{2190}") { send(key: .arrowLeft) }   // left arrow
                .accessibilityLabel("Arrow Left")
            keyButton("\u{2191}") { send(key: .arrowUp) }     // up arrow
                .accessibilityLabel("Arrow Up")
            keyButton("\u{2193}") { send(key: .arrowDown) }   // down arrow
                .accessibilityLabel("Arrow Down")
            keyButton("\u{2192}") { send(key: .arrowRight) }  // right arrow
                .accessibilityLabel("Arrow Right")

            if onDismissKeyboard != nil {
                Spacer()

                Button { onDismissKeyboard?() } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.foreground.color)
                        .frame(minWidth: 36, minHeight: 32)
                        .background(theme.foreground.color.opacity(0.1))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss Keyboard")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: 44)
        .background(theme.background.color)
    }

    // MARK: - Key Button

    @ViewBuilder
    private func keyButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.foreground.color)
                .frame(minWidth: 36, minHeight: 32)
                .background(theme.foreground.color.opacity(0.1))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Modifier Button

    @ViewBuilder
    private func modifierButton(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(active ? theme.background.color : theme.foreground.color)
                .frame(minWidth: 36, minHeight: 32)
                .background(active ? theme.foreground.color : theme.foreground.color.opacity(0.1))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func send(key: SpecialKey) {
        let data = inputHandler.data(for: key)
        onInput?(data)
    }
}
