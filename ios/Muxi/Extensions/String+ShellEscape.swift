import Foundation

extension String {
    /// Wraps the string in single quotes with proper escaping so it is safe
    /// to interpolate into a shell command.  Any embedded single-quote
    /// characters are escaped using the `'\''` idiom.
    func shellEscaped() -> String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
