import Foundation

extension String {
    /// Wraps the string in double quotes with escaping for tmux's command
    /// parser.  This is NOT the same as shell escaping — tmux control mode
    /// commands go directly to tmux's parser, not through a shell.
    ///
    /// Escapes: `\` `"` `$` newline CR tab ESC, plus any other C0/DEL
    /// control characters via `\uXXXX`.  UTF-8 text passes through
    /// unchanged (tmux handles UTF-8 natively).
    ///
    /// Safe for `set-buffer` and `send-keys -l` — neither expands format strings.
    /// `#` is intentionally NOT escaped because these commands pass text through literally.
    /// DO NOT use this function with format-expanding commands (display-message, set-option, etc.)
    /// — for those, `#` must be escaped as `##` to prevent format string injection.
    func tmuxQuoted() -> String {
        var result = "\""
        for scalar in unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "$":  result += "\\$"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{1B}": result += "\\e"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result += String(scalar)
                }
            }
        }
        result += "\""
        return result
    }
}
