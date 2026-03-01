import Foundation
import MuxiCore

/// Bridges the C tmux control-mode protocol parser to Swift.
///
/// Feed raw lines from tmux control mode (``handleLine(_:)``) and the
/// service dispatches parsed messages to the registered Swift callbacks.
///
/// - Note: Marked `@MainActor` because all consumers (``ConnectionManager``,
///   UI callbacks) operate on the main actor. This ensures callback closures
///   are invoked on the main thread, making UI updates safe.
@MainActor
final class TmuxControlService {

    // MARK: - Callbacks

    /// Called when a pane produces output.
    var onPaneOutput: ((_ paneId: String, _ data: String) -> Void)?

    /// Called when a window's layout changes.
    var onLayoutChange: ((_ windowId: String, _ panes: [ParsedPane]) -> Void)?

    /// Called when a new window is added.
    var onWindowAdd: ((_ windowId: String) -> Void)?

    /// Called when a window is closed.
    var onWindowClose: ((_ windowId: String) -> Void)?

    /// Called when the active session changes.
    var onSessionChanged: ((_ sessionId: String, _ name: String) -> Void)?

    /// Called when the tmux server exits.
    var onExit: (() -> Void)?

    /// Called when a tmux error is received.
    var onError: ((_ message: String) -> Void)?

    // MARK: - ParsedPane

    /// A single leaf pane extracted from a tmux layout string.
    struct ParsedPane {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let paneId: Int
    }

    // MARK: - Line Accumulator

    private var lineBuffer = Data()

    /// Accumulate raw data from SSH, split on newlines, and dispatch
    /// complete lines to handleLine().
    func feed(_ data: Data) {
        lineBuffer.append(data)

        // Split on \n (0x0A), processing each complete line
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
            lineBuffer = Data(lineBuffer[(newlineIndex + 1)...])

            if let line = String(data: lineData, encoding: .utf8) {
                handleLine(line)
            }
        }
    }

    /// Reset the line buffer (call on disconnect/reconnect).
    func resetLineBuffer() {
        lineBuffer = Data()
    }

    // MARK: - Line Handling

    /// Parse a single line from tmux control mode output and dispatch
    /// to the appropriate callback.
    func handleLine(_ line: String) {
        // The C parser's pointer fields (output_data, layout, etc.) point
        // directly into the input buffer.  We must keep the C string alive
        // while we read those fields, so everything lives inside withCString.
        line.withCString { cLine in
            var msg = TmuxMessage()
            let type = tmux_parse_line(cLine, &msg)

            switch type {
            case TMUX_MSG_OUTPUT:
                let paneId = extractString(from: &msg.pane_id, capacity: Int(TMUX_ID_MAX))
                let data: String
                if let ptr = msg.output_data {
                    data = String(cString: ptr)
                } else {
                    data = ""
                }
                onPaneOutput?(paneId, data)

            case TMUX_MSG_LAYOUT_CHANGE:
                let windowId = extractString(from: &msg.window_id, capacity: Int(TMUX_ID_MAX))
                var layoutStr = ""
                if let ptr = msg.layout {
                    layoutStr = String(cString: ptr)
                }
                let panes = parseLayout(layoutStr)
                onLayoutChange?(windowId, panes)

            case TMUX_MSG_WINDOW_ADD:
                let windowId = extractString(from: &msg.window_id, capacity: Int(TMUX_ID_MAX))
                onWindowAdd?(windowId)

            case TMUX_MSG_WINDOW_CLOSE:
                let windowId = extractString(from: &msg.window_id, capacity: Int(TMUX_ID_MAX))
                onWindowClose?(windowId)

            case TMUX_MSG_SESSION_CHANGED:
                let sessionId = extractString(from: &msg.session_id, capacity: Int(TMUX_ID_MAX))
                let name = extractString(from: &msg.session_name, capacity: Int(TMUX_NAME_MAX))
                onSessionChanged?(sessionId, name)

            case TMUX_MSG_EXIT:
                onExit?()

            case TMUX_MSG_ERROR:
                let errorMsg: String
                if let ptr = msg.error_message, msg.error_message_len > 0 {
                    errorMsg = String(cString: ptr)
                } else {
                    errorMsg = "Unknown tmux error"
                }
                onError?(errorMsg)

            default:
                break
            }
        }
    }

    // MARK: - Layout Parsing

    /// Parse a tmux layout string into an array of ``ParsedPane`` values.
    private func parseLayout(_ layout: String) -> [ParsedPane] {
        var cPanes = [TmuxLayoutPane](repeating: TmuxLayoutPane(), count: 64)
        var count: Int32 = 0

        let result = tmux_parse_layout(layout, &cPanes, 64, &count)
        guard result == 0 else { return [] }

        return (0..<Int(count)).map { i in
            ParsedPane(
                x: Int(cPanes[i].x),
                y: Int(cPanes[i].y),
                width: Int(cPanes[i].width),
                height: Int(cPanes[i].height),
                paneId: Int(cPanes[i].pane_id)
            )
        }
    }

    // MARK: - Session List Parsing

    /// Parse the output of `tmux list-sessions` (unformatted).
    ///
    /// Each line is expected to look like:
    ///   `main: 2 windows (created Fri Feb 28 10:00:00 2026)`
    static func parseSessionList(_ output: String) -> [TmuxSession] {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let parts = trimmed.split(separator: ":", maxSplits: 1)
                guard let name = parts.first else { return nil }
                let nameStr = String(name).trimmingCharacters(in: .whitespaces)
                return TmuxSession(
                    id: "$\(nameStr)",
                    name: nameStr,
                    windows: [],
                    createdAt: Date(),
                    lastActivity: Date()
                )
            }
    }

    /// Parse the output of `tmux list-sessions -F '#{session_id}:#{session_name}:#{session_windows}:#{session_activity}'`.
    ///
    /// Each line is expected to look like:
    ///   `$0:main:2:1740700800`
    static func parseFormattedSessionList(_ output: String) -> [TmuxSession] {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let parts = trimmed.split(separator: ":", maxSplits: 3)
                guard parts.count >= 3 else { return nil }
                let id = String(parts[0])
                let name = String(parts[1])
                return TmuxSession(
                    id: id,
                    name: name,
                    windows: [],
                    createdAt: Date(),
                    lastActivity: Date()
                )
            }
    }

    // MARK: - Private Helpers

    /// Convert a C fixed-size char array (imported as a tuple) to a Swift String.
    private func extractString<T>(from tuple: inout T, capacity: Int) -> String {
        withUnsafePointer(to: &tuple) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { cStr in
                String(cString: cStr)
            }
        }
    }
}
