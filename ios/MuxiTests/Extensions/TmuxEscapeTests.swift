import Testing
@testable import Muxi

@Suite("TmuxEscape")
struct TmuxEscapeTests {

    // MARK: - Basic Escaping

    @Test func plainASCII() {
        #expect("hello".tmuxQuoted() == "\"hello\"")
    }

    @Test func backslash() {
        #expect("a\\b".tmuxQuoted() == "\"a\\\\b\"")
    }

    @Test func doubleQuote() {
        #expect("say \"hi\"".tmuxQuoted() == "\"say \\\"hi\\\"\"")
    }

    @Test func dollarSign() {
        #expect("$HOME".tmuxQuoted() == "\"\\$HOME\"")
    }

    @Test func newline() {
        #expect("line1\nline2".tmuxQuoted() == "\"line1\\nline2\"")
    }

    @Test func carriageReturn() {
        #expect("a\rb".tmuxQuoted() == "\"a\\rb\"")
    }

    @Test func tab() {
        #expect("a\tb".tmuxQuoted() == "\"a\\tb\"")
    }

    @Test func escape() {
        #expect("a\u{1B}b".tmuxQuoted() == "\"a\\eb\"")
    }

    // MARK: - Control Characters

    @Test func nullByte() {
        #expect("a\u{00}b".tmuxQuoted() == "\"a\\u0000b\"")
    }

    @Test func bellCharacter() {
        #expect("a\u{07}b".tmuxQuoted() == "\"a\\u0007b\"")
    }

    @Test func del() {
        #expect("a\u{7F}b".tmuxQuoted() == "\"a\\u007Fb\"")
    }

    // MARK: - Passthrough

    @Test func utf8Passthrough() {
        #expect("한글テスト".tmuxQuoted() == "\"한글テスト\"")
    }

    @Test func hashNotEscaped() {
        #expect("#{window}".tmuxQuoted() == "\"#{window}\"")
    }

    @Test func emoji() {
        #expect("hello 🌍".tmuxQuoted() == "\"hello 🌍\"")
    }

    // MARK: - Combined

    @Test func mixedSpecialChars() {
        let input = "echo \"$PATH\"\nls -la"
        let expected = "\"echo \\\"\\$PATH\\\"\\nls -la\""
        #expect(input.tmuxQuoted() == expected)
    }

    @Test func emptyString() {
        #expect("".tmuxQuoted() == "\"\"")
    }
}
