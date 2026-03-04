import Testing

@testable import Muxi

@Suite("TmuxError Tests")
struct TmuxErrorTests {

    // MARK: - Version Parsing

    @Test("Parses standard version: tmux 3.4")
    func standardVersion() {
        let result = TmuxError.parseTmuxVersion("tmux 3.4\n")
        #expect(result == "3.4")
    }

    @Test("Parses version with letter suffix: tmux 3.3a")
    func versionWithLetterSuffix() {
        let result = TmuxError.parseTmuxVersion("tmux 3.3a\n")
        #expect(result == "3.3a")
    }

    @Test("Parses version with 'next' suffix: tmux next-3.4")
    func nextVersion() {
        let result = TmuxError.parseTmuxVersion("tmux next-3.4\n")
        #expect(result == "next-3.4")
    }

    @Test("Returns nil for empty string")
    func emptyString() {
        let result = TmuxError.parseTmuxVersion("")
        #expect(result == nil)
    }

    @Test("Returns nil for command not found output")
    func commandNotFound() {
        let result = TmuxError.parseTmuxVersion("bash: tmux: command not found\n")
        #expect(result == nil)
    }

    @Test("Returns nil for garbage output")
    func garbageOutput() {
        let result = TmuxError.parseTmuxVersion("some random output")
        #expect(result == nil)
    }

    // MARK: - Version Comparison

    @Test("Version 3.4 meets minimum 1.8")
    func meetsMinimum() {
        #expect(TmuxError.versionMeetsMinimum("3.4"))
    }

    @Test("Version 1.8 meets minimum 1.8")
    func exactMinimum() {
        #expect(TmuxError.versionMeetsMinimum("1.8"))
    }

    @Test("Version 1.7 does not meet minimum 1.8")
    func belowMinimum() {
        #expect(!TmuxError.versionMeetsMinimum("1.7"))
    }

    @Test("Version 1.6 does not meet minimum 1.8")
    func wellBelowMinimum() {
        #expect(!TmuxError.versionMeetsMinimum("1.6"))
    }

    @Test("Version 3.3a meets minimum (strips letter suffix)")
    func letterSuffixMeetsMinimum() {
        #expect(TmuxError.versionMeetsMinimum("3.3a"))
    }

    @Test("Unparseable version returns false")
    func unparseableVersion() {
        #expect(!TmuxError.versionMeetsMinimum("next-3.4"))
    }

    // MARK: - Error Messages

    @Test("notInstalled has descriptive error message")
    func notInstalledMessage() {
        let error = TmuxError.notInstalled
        #expect(error.errorDescription?.contains("not installed") == true)
    }

    @Test("versionTooOld includes detected version in message")
    func versionTooOldMessage() {
        let error = TmuxError.versionTooOld(detected: "1.6")
        #expect(error.errorDescription?.contains("1.6") == true)
    }
}
