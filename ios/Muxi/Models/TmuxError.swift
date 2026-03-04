import Foundation

/// Errors thrown when tmux is not available or does not meet
/// the minimum version requirement on the connected server.
enum TmuxError: Error, LocalizedError, Equatable {
    /// tmux is not installed on the server (command not found).
    case notInstalled
    /// tmux is installed but the version is below the minimum (1.8).
    case versionTooOld(detected: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "tmux is not installed on this server."
        case .versionTooOld(let detected):
            return "tmux \(detected) is too old. Muxi requires tmux \(TmuxInstallGuideView.minimumVersion) or later."
        }
    }

    /// Parse the output of `tmux -V` and return the version string.
    ///
    /// Expected format: `"tmux 3.4\n"` or `"tmux 3.3a\n"`.
    /// Returns `nil` if the output doesn't start with `"tmux "`.
    static func parseTmuxVersion(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("tmux ") else { return nil }
        let version = String(trimmed.dropFirst("tmux ".count))
        guard !version.isEmpty else { return nil }
        return version
    }

    /// Check whether a parsed version string meets the minimum (1.8).
    ///
    /// Extracts the numeric major.minor from strings like `"3.4"` or
    /// `"3.3a"`, stripping any trailing letter suffix. Returns `false`
    /// if the version cannot be parsed as a number.
    static func versionMeetsMinimum(_ version: String) -> Bool {
        // Strip trailing non-numeric characters (e.g., "3.3a" -> "3.3").
        let numeric = String(version.prefix(while: { $0.isNumber || $0 == "." }))
        guard let detected = Double(numeric) else { return false }
        guard let minimum = Double(TmuxInstallGuideView.minimumVersion) else { return false }
        return detected >= minimum
    }
}
