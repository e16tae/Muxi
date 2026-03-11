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

    /// Called for special keys (arrows, escape, tab) from hardware keyboard.
    var onSpecialKey: ((SpecialKey) -> Void)?

    /// Called for raw terminal bytes (Ctrl/Alt combos) from hardware keyboard.
    var onRawData: ((Data) -> Void)?

    // MARK: - Input Accessory View

    private var _inputAccessoryView: UIView?
    override var inputAccessoryView: UIView? { _inputAccessoryView }

    func setInputAccessoryView(_ view: UIView?) {
        _inputAccessoryView = view
    }

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

    // MARK: - Hardware Keyboard

    /// Cached key commands for hardware keyboard support.
    /// Arrows, Escape, Tab, Ctrl+a...z, Alt+a...z (~58 entries).
    private static let _keyCommands: [UIKeyCommand] = {
        var commands: [UIKeyCommand] = []
        let sel = #selector(handleKeyCommand(_:))

        // Arrow keys.
        commands.append(UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: sel))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: sel))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: sel))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: sel))

        // Escape.
        commands.append(UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: sel))

        // Tab — override iOS focus navigation.
        let tab = UIKeyCommand(input: "\t", modifierFlags: [], action: sel)
        tab.wantsPriorityOverSystemBehavior = true
        commands.append(tab)

        // Ctrl+letter (a-z).
        for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
            let char = String(UnicodeScalar(scalar)!)
            commands.append(UIKeyCommand(input: char, modifierFlags: .control, action: sel))
        }

        // Alt+letter (a-z).
        for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
            let char = String(UnicodeScalar(scalar)!)
            commands.append(UIKeyCommand(input: char, modifierFlags: .alternate, action: sel))
        }

        return commands
    }()

    override var keyCommands: [UIKeyCommand]? {
        Self._keyCommands
    }

    @objc private func handleKeyCommand(_ command: UIKeyCommand) {
        guard let input = command.input else { return }

        // Special keys (no modifier).
        if command.modifierFlags.isEmpty || command.modifierFlags == .numericPad {
            let specialKey: SpecialKey?
            switch input {
            case UIKeyCommand.inputUpArrow:    specialKey = .arrowUp
            case UIKeyCommand.inputDownArrow:  specialKey = .arrowDown
            case UIKeyCommand.inputLeftArrow:  specialKey = .arrowLeft
            case UIKeyCommand.inputRightArrow: specialKey = .arrowRight
            case UIKeyCommand.inputEscape:     specialKey = .escape
            case "\t":                         specialKey = .tab
            default:                           specialKey = nil
            }
            if let key = specialKey {
                onSpecialKey?(key)
                return
            }
        }

        // Ctrl+letter.
        if command.modifierFlags.contains(.control) {
            let data = InputHandler.terminalData(for: input, ctrl: true)
            onRawData?(data)
            return
        }

        // Alt+letter.
        if command.modifierFlags.contains(.alternate) {
            let data = InputHandler.terminalData(for: input, alt: true)
            onRawData?(data)
            return
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
    var onSpecialKey: ((SpecialKey) -> Void)?
    var onRawData: ((Data) -> Void)?
    @Binding var isActive: Bool

    // Extended keyboard params kept for API compatibility but no longer
    // used as inputAccessoryView — ExtendedKeyboardView is now placed
    // explicitly in the TerminalSessionView VStack.
    var theme: Theme?
    var inputHandler: InputHandler?
    var onExtendedInput: ((Data) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(isActive: $isActive)
    }

    func makeUIView(context: Context) -> TerminalInputAccessor {
        let view = TerminalInputAccessor(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.alpha = 0
        view.onText = onText
        view.onDelete = onDelete
        view.onSpecialKey = onSpecialKey
        view.onRawData = onRawData
        context.coordinator.inputView = view

        // 1×1pt invisible — iOS 26 requires non-zero frame for first responder.
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 1),
            view.heightAnchor.constraint(equalToConstant: 1),
        ])

        context.coordinator.startObservingKeyboard()
        return view
    }

    func updateUIView(_ uiView: TerminalInputAccessor, context: Context) {
        uiView.onText = onText
        uiView.onDelete = onDelete
        uiView.onSpecialKey = onSpecialKey
        uiView.onRawData = onRawData

        // Only change responder state when binding diverges from UIKit reality.
        if isActive != uiView.isFirstResponder {
            if isActive {
                uiView.activate()
            } else {
                uiView.deactivate()
            }
        }

        // Extended keyboard accessory view removed — now in VStack
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
                // Guard against view teardown: if the accessor has been removed
                // from the window, don't update the binding — its owning @State
                // may be mid-deallocation (causes crash on disconnect).
                guard let self, self.inputView?.window != nil else { return }
                self.isActive = false
            }
        }

        deinit {
            if let observer = keyboardObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
