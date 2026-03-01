import Foundation
import Observation

// MARK: - SpecialKey

/// Keys available on the extended keyboard toolbar.
enum SpecialKey: Equatable {
    case escape
    case tab
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case home
    case end
    case pageUp
    case pageDown
}

// MARK: - InputHandler

/// Translates extended-keyboard key presses into terminal escape sequences.
///
/// This is an `@Observable` class so SwiftUI views automatically track changes
/// to `ctrlActive` and `altActive`. Modifiers auto-deactivate after the next
/// regular character input (sticky-toggle behaviour).
@Observable
final class InputHandler {

    // MARK: - Modifier State

    /// When `true`, the next character input will be translated to a control
    /// code (Ctrl-A = 0x01, Ctrl-C = 0x03, etc.) and the flag will auto-reset.
    private(set) var ctrlActive: Bool = false

    /// When `true`, the next character input will be prefixed with ESC (0x1B)
    /// and the flag will auto-reset.
    private(set) var altActive: Bool = false

    // MARK: - Special Key Data

    /// Returns the escape-sequence `Data` for a special key press.
    ///
    /// Special keys ignore the Ctrl/Alt modifiers; they always produce the
    /// same sequence regardless of modifier state.
    func data(for key: SpecialKey) -> Data {
        let bytes: [UInt8]
        switch key {
        case .escape:
            bytes = [0x1B]
        case .tab:
            bytes = [0x09]
        case .arrowUp:
            bytes = [0x1B, 0x5B, 0x41]        // ESC [ A
        case .arrowDown:
            bytes = [0x1B, 0x5B, 0x42]        // ESC [ B
        case .arrowRight:
            bytes = [0x1B, 0x5B, 0x43]        // ESC [ C
        case .arrowLeft:
            bytes = [0x1B, 0x5B, 0x44]        // ESC [ D
        case .home:
            bytes = [0x1B, 0x5B, 0x48]        // ESC [ H
        case .end:
            bytes = [0x1B, 0x5B, 0x46]        // ESC [ F
        case .pageUp:
            bytes = [0x1B, 0x5B, 0x35, 0x7E]  // ESC [ 5 ~
        case .pageDown:
            bytes = [0x1B, 0x5B, 0x36, 0x7E]  // ESC [ 6 ~
        }
        return Data(bytes)
    }

    // MARK: - Character Data

    /// Returns the `Data` for a regular character, applying active modifiers.
    ///
    /// - When `ctrlActive` is set and the character is an ASCII letter (a-z),
    ///   the control code (0x01-0x1A) is returned and `ctrlActive` is cleared.
    /// - When `altActive` is set, ESC (0x1B) is prepended to the character's
    ///   UTF-8 encoding, and `altActive` is cleared.
    /// - Otherwise the character's UTF-8 encoding is returned as-is.
    func data(for character: Character) -> Data {
        if ctrlActive, let scalar = character.unicodeScalars.first {
            if let upper = Character(scalar).uppercased().first,
               let ascii = upper.asciiValue, ascii >= 0x40, ascii <= 0x5F {
                // Control code = ASCII value of uppercase letter - 0x40
                // A(0x41) -> 0x01, C(0x43) -> 0x03, Z(0x5A) -> 0x1A
                ctrlActive = false
                return Data([ascii - 0x40])
            }
            // Character is not in Ctrl range — do NOT consume ctrlActive
        }

        let charData: Data
        if let data = String(character).data(using: .utf8) {
            charData = data
        } else {
            charData = Data()
        }

        if altActive {
            altActive = false
            return Data([0x1B]) + charData
        }

        return charData
    }

    // MARK: - Toggle Helpers

    /// Toggle the Ctrl modifier on or off.
    func toggleCtrl() {
        ctrlActive.toggle()
    }

    /// Toggle the Alt modifier on or off.
    func toggleAlt() {
        altActive.toggle()
    }
}
