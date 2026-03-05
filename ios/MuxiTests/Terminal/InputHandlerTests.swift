import XCTest
@testable import Muxi

@MainActor
final class InputHandlerTests: XCTestCase {

    private var handler: InputHandler!

    override func setUp() {
        super.setUp()
        handler = InputHandler()
    }

    override func tearDown() {
        handler = nil
        super.tearDown()
    }

    // MARK: - Special Keys

    func testEscapeKey() {
        let data = handler.data(for: .escape)
        XCTAssertEqual(data, Data([0x1B]))
    }

    func testTabKey() {
        let data = handler.data(for: .tab)
        XCTAssertEqual(data, Data([0x09]))
    }

    // MARK: - Arrow Keys

    func testArrowUp() {
        let data = handler.data(for: .arrowUp)
        XCTAssertEqual(data, Data([0x1B, 0x5B, 0x41]))
    }

    func testArrowDown() {
        let data = handler.data(for: .arrowDown)
        XCTAssertEqual(data, Data([0x1B, 0x5B, 0x42]))
    }

    func testArrowRight() {
        let data = handler.data(for: .arrowRight)
        XCTAssertEqual(data, Data([0x1B, 0x5B, 0x43]))
    }

    func testArrowLeft() {
        let data = handler.data(for: .arrowLeft)
        XCTAssertEqual(data, Data([0x1B, 0x5B, 0x44]))
    }

    // MARK: - Navigation Keys

    func testHomeKey() {
        let data = handler.data(for: .home)
        XCTAssertEqual(data, Data([0x1B, 0x5B, 0x48]))
    }

    func testEndKey() {
        let data = handler.data(for: .end)
        XCTAssertEqual(data, Data([0x1B, 0x5B, 0x46]))
    }

    func testPageUp() {
        let data = handler.data(for: .pageUp)
        XCTAssertEqual(data, Data([0x1B, 0x5B, 0x35, 0x7E]))
    }

    func testPageDown() {
        let data = handler.data(for: .pageDown)
        XCTAssertEqual(data, Data([0x1B, 0x5B, 0x36, 0x7E]))
    }

    // MARK: - Regular Character (No Modifiers)

    func testRegularCharacter() {
        let data = handler.data(for: "a")
        XCTAssertEqual(data, "a".data(using: .utf8))
    }

    func testRegularCharacterUppercase() {
        let data = handler.data(for: "Z")
        XCTAssertEqual(data, "Z".data(using: .utf8))
    }

    // MARK: - Ctrl Modifier

    func testCtrlA() {
        handler.toggleCtrl()
        let data = handler.data(for: "a")
        XCTAssertEqual(data, Data([0x01]))
    }

    func testCtrlC() {
        handler.toggleCtrl()
        let data = handler.data(for: "c")
        XCTAssertEqual(data, Data([0x03]))
    }

    func testCtrlD() {
        handler.toggleCtrl()
        let data = handler.data(for: "d")
        XCTAssertEqual(data, Data([0x04]))
    }

    func testCtrlL() {
        handler.toggleCtrl()
        let data = handler.data(for: "l")
        XCTAssertEqual(data, Data([0x0C]))
    }

    func testCtrlZ() {
        handler.toggleCtrl()
        let data = handler.data(for: "z")
        XCTAssertEqual(data, Data([0x1A]))
    }

    func testCtrlUppercaseLetterProducesSameCode() {
        // Ctrl-C with uppercase 'C' should still produce 0x03.
        handler.toggleCtrl()
        let data = handler.data(for: "C")
        XCTAssertEqual(data, Data([0x03]))
    }

    func testCtrlAutoDeactivates() {
        handler.toggleCtrl()
        _ = handler.data(for: "a")
        XCTAssertFalse(handler.ctrlActive, "Ctrl should auto-deactivate after one character")
    }

    func testCtrlAllLetters() {
        // Verify Ctrl + each letter a-z produces the correct control code.
        for (index, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            handler.toggleCtrl()
            let data = handler.data(for: letter)
            let expected = UInt8(index + 1)
            XCTAssertEqual(data, Data([expected]), "Ctrl-\(letter) should produce 0x\(String(format: "%02X", expected))")
        }
    }

    // MARK: - Alt Modifier

    func testAltCharacter() {
        handler.toggleAlt()
        let data = handler.data(for: "x")
        // Alt wraps with ESC prefix: 0x1B + 'x'
        XCTAssertEqual(data, Data([0x1B, 0x78]))
    }

    func testAltAutoDeactivates() {
        handler.toggleAlt()
        _ = handler.data(for: "x")
        XCTAssertFalse(handler.altActive, "Alt should auto-deactivate after one character")
    }

    func testAltUppercaseLetter() {
        handler.toggleAlt()
        let data = handler.data(for: "A")
        XCTAssertEqual(data, Data([0x1B, 0x41]))
    }

    // MARK: - Toggle Helpers

    func testToggleCtrl() {
        XCTAssertFalse(handler.ctrlActive)
        handler.toggleCtrl()
        XCTAssertTrue(handler.ctrlActive)
        handler.toggleCtrl()
        XCTAssertFalse(handler.ctrlActive)
    }

    func testToggleAlt() {
        XCTAssertFalse(handler.altActive)
        handler.toggleAlt()
        XCTAssertTrue(handler.altActive)
        handler.toggleAlt()
        XCTAssertFalse(handler.altActive)
    }

    // MARK: - Modifier Interaction

    func testCtrlTakesPriorityOverAlt() {
        // When both are active, Ctrl is applied first (producing a control
        // code), and Alt is not consumed. This matches the implementation
        // where Ctrl is checked before Alt.
        handler.toggleCtrl()
        handler.toggleAlt()
        let data = handler.data(for: "c")
        // Ctrl-C = 0x03; Alt is not applied because Ctrl short-circuits.
        XCTAssertEqual(data, Data([0x03]))
        XCTAssertFalse(handler.ctrlActive)
        // Alt remains active since it was not consumed.
        XCTAssertTrue(handler.altActive)
    }

    // MARK: - Initial State

    func testInitialModifiersAreInactive() {
        XCTAssertFalse(handler.ctrlActive)
        XCTAssertFalse(handler.altActive)
    }

    // MARK: - Edge Cases

    func testCtrlWithNonLetterCharacterPassesThroughAndKeepsCtrl() {
        // Ctrl + digit "3" — not in the A-Z/0x40-0x5F range, so the character
        // is passed through as plain UTF-8 and Ctrl remains active for the
        // next valid character input.
        handler.toggleCtrl()
        let data = handler.data(for: "3")
        XCTAssertEqual(data, "3".data(using: .utf8))
        XCTAssertTrue(handler.ctrlActive, "Ctrl should remain active for non-letter characters")

        // Now type a valid Ctrl character — Ctrl should be consumed
        let ctrlA = handler.data(for: "a")
        XCTAssertEqual(ctrlA, Data([0x01]))
        XCTAssertFalse(handler.ctrlActive, "Ctrl should auto-deactivate after valid control character")
    }

    func testAltWithMultiByteCharacterPrependsESC() {
        // Alt + emoji — ESC should be prepended to the full UTF-8 encoding.
        handler.toggleAlt()
        let emoji: Character = "\u{1F600}"  // grinning face
        let data = handler.data(for: emoji)
        let expected = Data([0x1B]) + (String(emoji).data(using: .utf8) ?? Data())
        XCTAssertEqual(data, expected)
        XCTAssertFalse(handler.altActive, "Alt should auto-deactivate after multi-byte character")
    }

    func testAltWithCJKCharacterPrependsESC() {
        // Alt + CJK character — ESC should be prepended to the UTF-8 bytes.
        handler.toggleAlt()
        let cjk: Character = "\u{4E16}"  // CJK character "shi" (world)
        let data = handler.data(for: cjk)
        let expected = Data([0x1B]) + (String(cjk).data(using: .utf8) ?? Data())
        XCTAssertEqual(data, expected)
        XCTAssertFalse(handler.altActive, "Alt should auto-deactivate after CJK character")
    }

    // MARK: - Hardware Keyboard (terminalData)

    func testTerminalDataCtrlA() {
        let data = InputHandler.terminalData(for: "a", ctrl: true)
        XCTAssertEqual(data, Data([0x01]))
    }

    func testTerminalDataCtrlC() {
        let data = InputHandler.terminalData(for: "c", ctrl: true)
        XCTAssertEqual(data, Data([0x03]))
    }

    func testTerminalDataCtrlZ() {
        let data = InputHandler.terminalData(for: "z", ctrl: true)
        XCTAssertEqual(data, Data([0x1A]))
    }

    func testTerminalDataCtrlUppercaseLetter() {
        let data = InputHandler.terminalData(for: "C", ctrl: true)
        XCTAssertEqual(data, Data([0x03]))
    }

    func testTerminalDataAltA() {
        let data = InputHandler.terminalData(for: "a", alt: true)
        XCTAssertEqual(data, Data([0x1B, 0x61]))
    }

    func testTerminalDataAltZ() {
        let data = InputHandler.terminalData(for: "z", alt: true)
        XCTAssertEqual(data, Data([0x1B, 0x7A]))
    }

    func testTerminalDataPlainCharacter() {
        let data = InputHandler.terminalData(for: "x")
        XCTAssertEqual(data, "x".data(using: .utf8))
    }

    func testTerminalDataDoesNotAffectToggleState() {
        XCTAssertFalse(handler.ctrlActive)
        XCTAssertFalse(handler.altActive)
        _ = InputHandler.terminalData(for: "a", ctrl: true)
        XCTAssertFalse(handler.ctrlActive)
        XCTAssertFalse(handler.altActive)
    }

    func testTerminalDataCtrlNonLetterFallsThrough() {
        let data = InputHandler.terminalData(for: "3", ctrl: true)
        XCTAssertEqual(data, "3".data(using: .utf8))
    }

    func testTerminalDataCtrlAndAltLetterCtrlWins() {
        let data = InputHandler.terminalData(for: "c", ctrl: true, alt: true)
        XCTAssertEqual(data, Data([0x03]))
    }

    func testTerminalDataCtrlAndAltNonLetterAltApplied() {
        let data = InputHandler.terminalData(for: "3", ctrl: true, alt: true)
        XCTAssertEqual(data, Data([0x1B]) + "3".data(using: .utf8)!)
    }
}
