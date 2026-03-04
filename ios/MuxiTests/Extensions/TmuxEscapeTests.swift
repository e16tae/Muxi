import XCTest
@testable import Muxi

final class TmuxEscapeTests: XCTestCase {

    // MARK: - Basic Escaping

    func testPlainASCII() {
        XCTAssertEqual("hello".tmuxQuoted(), "\"hello\"")
    }

    func testBackslash() {
        XCTAssertEqual("a\\b".tmuxQuoted(), "\"a\\\\b\"")
    }

    func testDoubleQuote() {
        XCTAssertEqual("say \"hi\"".tmuxQuoted(), "\"say \\\"hi\\\"\"")
    }

    func testDollarSign() {
        XCTAssertEqual("$HOME".tmuxQuoted(), "\"\\$HOME\"")
    }

    func testNewline() {
        XCTAssertEqual("line1\nline2".tmuxQuoted(), "\"line1\\nline2\"")
    }

    func testCarriageReturn() {
        XCTAssertEqual("a\rb".tmuxQuoted(), "\"a\\rb\"")
    }

    func testTab() {
        XCTAssertEqual("a\tb".tmuxQuoted(), "\"a\\tb\"")
    }

    func testEscape() {
        XCTAssertEqual("a\u{1B}b".tmuxQuoted(), "\"a\\eb\"")
    }

    // MARK: - Control Characters

    func testNullByte() {
        XCTAssertEqual("a\u{00}b".tmuxQuoted(), "\"a\\u0000b\"")
    }

    func testBellCharacter() {
        XCTAssertEqual("a\u{07}b".tmuxQuoted(), "\"a\\u0007b\"")
    }

    func testDEL() {
        XCTAssertEqual("a\u{7F}b".tmuxQuoted(), "\"a\\u007Fb\"")
    }

    // MARK: - Passthrough

    func testUTF8Passthrough() {
        XCTAssertEqual("한글テスト".tmuxQuoted(), "\"한글テスト\"")
    }

    func testHashNotEscaped() {
        XCTAssertEqual("#{window}".tmuxQuoted(), "\"#{window}\"")
    }

    func testEmoji() {
        XCTAssertEqual("hello 🌍".tmuxQuoted(), "\"hello 🌍\"")
    }

    // MARK: - Combined

    func testMixedSpecialChars() {
        let input = "echo \"$PATH\"\nls -la"
        let expected = "\"echo \\\"\\$PATH\\\"\\nls -la\""
        XCTAssertEqual(input.tmuxQuoted(), expected)
    }

    func testEmptyString() {
        XCTAssertEqual("".tmuxQuoted(), "\"\"")
    }
}
