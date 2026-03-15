import Foundation
import MuxiCore
import os

private let tmuxLog = Logger(subsystem: "com.muxi.app", category: "TmuxControl")

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

    /// Called when a pane produces output (decoded from tmux octal escapes).
    var onPaneOutput: ((_ paneId: String, _ data: Data) -> Void)?

    /// Called when a window's layout changes.
    var onLayoutChange: ((_ windowId: String, _ panes: [ParsedPane], _ isZoomed: Bool) -> Void)?

    /// Called when a new window is added.
    var onWindowAdd: ((_ windowId: String) -> Void)?

    /// Called when a window is closed.
    var onWindowClose: ((_ windowId: String) -> Void)?

    /// Called when a window is renamed.
    var onWindowRenamed: ((_ windowId: String, _ name: String) -> Void)?

    /// Called when the active pane changes within a window.
    var onWindowPaneChanged: ((_ windowId: String, _ paneId: String) -> Void)?

    /// Called when the active window changes within a session.
    var onSessionWindowChanged: ((_ sessionId: String, _ windowId: String) -> Void)?

    /// Called when the active session changes.
    var onSessionChanged: ((_ sessionId: String, _ name: String) -> Void)?

    /// Called when the session list changes (session created or destroyed).
    var onSessionsChanged: (() -> Void)?

    /// Called when the tmux server exits.
    var onExit: (() -> Void)?

    /// Called when a tmux error is received.
    var onError: ((_ message: String) -> Void)?

    /// Called when a command response block (%begin ... %end) completes.
    var onCommandResponse: ((_ response: String) -> Void)?

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
    private var scanStart = 0

    /// Whether we have entered tmux control mode (seen the DCS prefix).
    /// Lines before this point are shell output and should be ignored.
    private var inControlMode = false

    /// Whether we are inside a %begin...%end response block.
    private var inResponseBlock = false

    /// Accumulated lines inside the current %begin...%end block.
    private var responseLines: [String] = []

    /// The DCS (Device Control String) prefix that tmux uses to start
    /// control mode output: ESC P 1000p
    private static let dcsPrefix = Data([0x1B, 0x50]) // ESC P
    private static let dcsMarker = "1000p".data(using: .utf8)!

    /// Accumulate raw data from SSH, split on newlines, and dispatch
    /// complete lines to handleLine().
    func feed(_ data: Data) {
        lineBuffer.append(data)

        while scanStart < lineBuffer.count {
            guard let newlineIndex = lineBuffer[scanStart...].firstIndex(of: 0x0A) else {
                break
            }

            var lineEnd = newlineIndex
            // Strip trailing \r (PTY adds CRLF translation)
            if lineEnd > scanStart && lineBuffer[lineEnd - 1] == 0x0D {
                lineEnd -= 1
            }

            let lineData = lineBuffer[scanStart..<lineEnd]
            scanStart = newlineIndex + 1

            // Detect DCS prefix that marks tmux control mode start.
            if !inControlMode {
                if let line = String(data: lineData, encoding: .utf8),
                   let range = line.range(of: "\u{1B}P1000p") {
                    inControlMode = true
                    let remainder = String(line[range.upperBound...])
                    if !remainder.isEmpty {
                        handleLine(remainder)
                    }
                    continue
                }
                continue
            }

            if let line = String(data: lineData, encoding: .utf8) {
                handleLine(line)
            }
        }

        // Compact buffer when consumed portion exceeds 64KB
        if scanStart > 65536 {
            lineBuffer.removeSubrange(..<scanStart)
            scanStart = 0
        }
    }

    /// Reset the line buffer (call on disconnect/reconnect).
    func resetLineBuffer() {
        lineBuffer = Data()
        scanStart = 0
        inControlMode = false
        inResponseBlock = false
        responseLines = []
    }

    // MARK: - Line Handling

    /// Parse a single line from tmux control mode output and dispatch
    /// to the appropriate callback.
    func handleLine(_ line: String) {
        // If we are inside a %begin...%end response block, accumulate
        // non-command lines. %end/%error lines end the block.
        if inResponseBlock {
            if line.hasPrefix("%end") {
                let response = responseLines.joined(separator: "\n")
                responseLines = []
                inResponseBlock = false
                tmuxLog.info("Command response: \(response.count) chars")
                onCommandResponse?(response)
                return
            } else if line.hasPrefix("%error") {
                // %error ends the response block just like %end, but signals
                // failure.  We must still call onCommandResponse so the
                // pending command entry is consumed — otherwise the FIFO
                // queue drifts and subsequent responses are mismatched.
                let response = responseLines.joined(separator: "\n")
                responseLines = []
                inResponseBlock = false
                onCommandResponse?(response)
                // Fall through to parse the %error normally
            } else if line.hasPrefix("%") {
                // Tmux notification interleaved within a %begin/%end block.
                // Fall through to parse as notification below.
            } else {
                // Data line inside %begin...%end block
                responseLines.append(line)
                return
            }
        }

        // The C parser's pointer fields (output_data, layout, etc.) point
        // directly into the input buffer.  We must keep the C string alive
        // while we read those fields, so everything lives inside withCString.
        line.withCString { cLine in
            var msg = TmuxMessage()
            let type = tmux_parse_line(cLine, &msg)

            switch type {
            case TMUX_MSG_OUTPUT:
                let paneId = extractString(from: &msg.pane_id, capacity: Int(TMUX_ID_MAX))
                let decoded: Data
                if let ptr = msg.output_data, msg.output_len > 0 {
                    let escaped = String(cString: ptr)
                    decoded = Self.decodeTmuxOutput(escaped)
                } else {
                    decoded = Data()
                }
                tmuxLog.info("Output: pane=\(paneId) len=\(decoded.count)")
                onPaneOutput?(paneId, decoded)

            case TMUX_MSG_LAYOUT_CHANGE:
                let windowId = extractString(from: &msg.window_id, capacity: Int(TMUX_ID_MAX))
                let isZoomed = msg.is_zoomed != 0
                // Use visible_layout (shows only the zoomed pane when zoomed).
                var layoutStr = ""
                if let ptr = msg.visible_layout, msg.visible_layout_len > 0 {
                    layoutStr = String(
                        bytes: UnsafeBufferPointer(start: ptr, count: Int(msg.visible_layout_len))
                            .map { UInt8(bitPattern: $0) },
                        encoding: .utf8
                    ) ?? ""
                }
                tmuxLog.info("Layout change: window=\(windowId) layout=\(layoutStr) zoomed=\(isZoomed)")
                let panes = parseLayout(layoutStr)
                tmuxLog.info("Parsed \(panes.count) panes from layout")
                onLayoutChange?(windowId, panes, isZoomed)

            case TMUX_MSG_WINDOW_ADD:
                let windowId = extractString(from: &msg.window_id, capacity: Int(TMUX_ID_MAX))
                onWindowAdd?(windowId)

            case TMUX_MSG_WINDOW_CLOSE:
                let windowId = extractString(from: &msg.window_id, capacity: Int(TMUX_ID_MAX))
                onWindowClose?(windowId)

            case TMUX_MSG_WINDOW_RENAMED:
                let windowId = extractString(from: &msg.window_id, capacity: Int(TMUX_ID_MAX))
                let name = extractString(from: &msg.window_name, capacity: Int(TMUX_NAME_MAX))
                onWindowRenamed?(windowId, name)

            case TMUX_MSG_UNLINKED_WINDOW_CLOSE:
                let windowId = extractString(from: &msg.window_id, capacity: Int(TMUX_ID_MAX))
                onWindowClose?(windowId)

            case TMUX_MSG_WINDOW_PANE_CHANGED:
                let windowId = extractString(from: &msg.window_id, capacity: Int(TMUX_ID_MAX))
                let paneId = extractString(from: &msg.pane_id, capacity: Int(TMUX_ID_MAX))
                onWindowPaneChanged?(windowId, paneId)

            case TMUX_MSG_SESSION_WINDOW_CHANGED:
                let sessionId = extractString(from: &msg.session_id, capacity: Int(TMUX_ID_MAX))
                let windowId = extractString(from: &msg.window_id, capacity: Int(TMUX_ID_MAX))
                onSessionWindowChanged?(sessionId, windowId)

            case TMUX_MSG_SESSION_CHANGED:
                let sessionId = extractString(from: &msg.session_id, capacity: Int(TMUX_ID_MAX))
                let name = extractString(from: &msg.session_name, capacity: Int(TMUX_NAME_MAX))
                onSessionChanged?(sessionId, name)

            case TMUX_MSG_SESSIONS_CHANGED:
                onSessionsChanged?()

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

            case TMUX_MSG_BEGIN:
                inResponseBlock = true
                responseLines = []

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

        return (0..<min(Int(count), 64)).map { i in
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

    /// Decode tmux control-mode octal escapes in `%output` data.
    ///
    /// tmux encodes non-printable bytes (< 0x20) and backslash as `\` followed
    /// by exactly 3 octal digits (e.g. `\033` for ESC, `\134` for `\`).
    /// All other characters are passed through literally.
    static func decodeTmuxOutput(_ escaped: String) -> Data {
        let utf8 = Array(escaped.utf8)
        var result = Data()
        result.reserveCapacity(utf8.count)

        var i = 0
        while i < utf8.count {
            if utf8[i] == UInt8(ascii: "\\"), i + 3 < utf8.count {
                let d1 = utf8[i + 1]
                let d2 = utf8[i + 2]
                let d3 = utf8[i + 3]
                if d1 >= UInt8(ascii: "0"), d1 <= UInt8(ascii: "7"),
                   d2 >= UInt8(ascii: "0"), d2 <= UInt8(ascii: "7"),
                   d3 >= UInt8(ascii: "0"), d3 <= UInt8(ascii: "7") {
                    let value = ((d1 - UInt8(ascii: "0")) << 6)
                              | ((d2 - UInt8(ascii: "0")) << 3)
                              | (d3 - UInt8(ascii: "0"))
                    result.append(value)
                    i += 4
                    continue
                }
            }
            result.append(utf8[i])
            i += 1
        }

        return result
    }

    /// Convert a C fixed-size char array (imported as a tuple) to a Swift String.
    private func extractString<T>(from tuple: inout T, capacity: Int) -> String {
        withUnsafePointer(to: &tuple) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { cStr in
                String(cString: cStr)
            }
        }
    }
}
