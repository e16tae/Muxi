@_exported import CVTParser
@_exported import CTmuxProtocol

/// MuxiCore provides Swift access to the shared C libraries
/// (VT parser and tmux control-mode protocol handler).
public enum MuxiCore {

    /// Library version string.
    public static let version = "0.1.0"

    /// Quick sanity check that the C libraries link and function.
    public static func healthCheck() -> Bool {
        // VT Parser round-trip
        var vtParser = VTParserState()
        vt_parser_init(&vtParser, 80, 24)
        let text = "OK"
        vt_parser_feed(&vtParser, text, Int32(text.utf8.count))
        vt_parser_destroy(&vtParser)

        // Tmux Protocol round-trip
        guard let proto = tmux_protocol_create() else { return false }
        tmux_protocol_reset(proto)
        tmux_protocol_destroy(proto)

        return true
    }
}
