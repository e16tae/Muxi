import SwiftUI
import UIKit

// MARK: - TerminalInputAccessor

/// An invisible `UIView` that conforms to `UIKeyInput` to summon
/// the iOS software keyboard.  It has zero frame and never draws —
/// its only purpose is to become first responder so the system
/// presents the keyboard, then forward each keystroke to closures.
final class TerminalInputAccessor: UIView, UIKeyInput {

    /// Called for every character (or string of characters) the keyboard produces.
    var onText: ((String) -> Void)?

    /// Called when the user taps backspace.
    var onDelete: (() -> Void)?

    // MARK: - First Responder

    override var canBecomeFirstResponder: Bool { true }

    // MARK: - UIKeyInput

    /// Always report text present to prevent iOS from disabling
    /// the backspace key on an "empty" field.
    var hasText: Bool { true }

    func insertText(_ text: String) {
        onText?(text)
    }

    func deleteBackward() {
        onDelete?()
    }

    // MARK: - Text Input Traits

    var keyboardType: UIKeyboardType = .asciiCapable
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var spellCheckingType: UITextSpellCheckingType = .no

    // MARK: - Activation

    func activate() {
        if !isFirstResponder {
            becomeFirstResponder()
        }
    }

    func deactivate() {
        if isFirstResponder {
            resignFirstResponder()
        }
    }
}

// MARK: - TerminalInputView

/// A zero-frame `UIViewRepresentable` wrapper around ``TerminalInputAccessor``.
///
/// SwiftUI controls whether the keyboard is visible via the `isActive` binding.
/// The coordinator observes `keyboardDidHideNotification` to keep the binding
/// in sync when the user swipes the keyboard away.
struct TerminalInputView: UIViewRepresentable {
    var onText: (String) -> Void
    var onDelete: () -> Void
    @Binding var isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isActive: $isActive)
    }

    func makeUIView(context: Context) -> TerminalInputAccessor {
        let view = TerminalInputAccessor(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.onText = onText
        view.onDelete = onDelete
        context.coordinator.inputView = view

        // Zero size — invisible, doesn't affect layout.
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 0),
            view.heightAnchor.constraint(equalToConstant: 0),
        ])

        context.coordinator.startObservingKeyboard()
        return view
    }

    func updateUIView(_ uiView: TerminalInputAccessor, context: Context) {
        uiView.onText = onText
        uiView.onDelete = onDelete

        // Only change responder state when binding diverges from UIKit reality.
        if isActive != uiView.isFirstResponder {
            if isActive {
                uiView.activate()
            } else {
                uiView.deactivate()
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator {
        @Binding var isActive: Bool
        weak var inputView: TerminalInputAccessor?
        private var keyboardObserver: Any?

        init(isActive: Binding<Bool>) {
            _isActive = isActive
        }

        func startObservingKeyboard() {
            keyboardObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardDidHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.isActive = false
            }
        }

        deinit {
            if let observer = keyboardObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
