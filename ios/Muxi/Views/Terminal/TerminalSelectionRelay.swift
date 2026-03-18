/// Bridges ⌘C / ⌘A key commands from ``TerminalInputAccessor``
/// to the ``TerminalTextOverlay`` that owns the UITextInput selection.
@MainActor
final class TerminalSelectionRelay {
    var performCopy: (() -> Void)?
    var performSelectAll: (() -> Void)?
}
