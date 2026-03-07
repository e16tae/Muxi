import SwiftUI

// MARK: - QuickAction Model

/// Represents a tmux command that can be triggered from the quick action menu.
///
/// Each action has a display title, SF Symbol icon, the tmux command string
/// to execute, and a category for grouping in the palette UI.
struct QuickAction: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let command: String
    let category: Category
    /// Whether this action requires text input before execution (e.g. rename).
    let requiresInput: Bool
    /// Placeholder text shown in the input field for actions that require input.
    let inputPlaceholder: String?

    init(
        title: String,
        icon: String,
        command: String,
        category: Category,
        requiresInput: Bool = false,
        inputPlaceholder: String? = nil
    ) {
        self.title = title
        self.icon = icon
        self.command = command
        self.category = category
        self.requiresInput = requiresInput
        self.inputPlaceholder = inputPlaceholder
    }

    enum Category: String, CaseIterable {
        case pane = "Pane"
        case window = "Window"
    }
}

// MARK: - Predefined Actions

extension QuickAction {

    /// All predefined tmux quick actions grouped by category.
    static let allActions: [QuickAction] = paneActions + windowActions

    static let paneActions: [QuickAction] = [
        QuickAction(
            title: "Split Horizontal",
            icon: "rectangle.split.2x1",
            command: "split-window -h",
            category: .pane
        ),
        QuickAction(
            title: "Split Vertical",
            icon: "rectangle.split.1x2",
            command: "split-window -v",
            category: .pane
        ),
        QuickAction(
            title: "Close Pane",
            icon: "xmark.rectangle",
            command: "kill-pane",
            category: .pane
        ),
        QuickAction(
            title: "Next Pane",
            icon: "arrow.right.square",
            command: "select-pane -t :.+",
            category: .pane
        ),
        QuickAction(
            title: "Previous Pane",
            icon: "arrow.left.square",
            command: "select-pane -t :.-",
            category: .pane
        ),
        QuickAction(
            title: "Zoom/Unzoom",
            icon: "arrow.up.left.and.arrow.down.right",
            command: "resize-pane -Z",
            category: .pane
        ),
    ]

    static let windowActions: [QuickAction] = [
        QuickAction(
            title: "New Window",
            icon: "plus.rectangle",
            command: "new-window",
            category: .window
        ),
        QuickAction(
            title: "Close Window",
            icon: "xmark.rectangle.fill",
            command: "kill-window",
            category: .window
        ),
        QuickAction(
            title: "Next Window",
            icon: "arrow.right",
            command: "next-window",
            category: .window
        ),
        QuickAction(
            title: "Previous Window",
            icon: "arrow.left",
            command: "previous-window",
            category: .window
        ),
        QuickAction(
            title: "Rename Window",
            icon: "pencil",
            command: "rename-window",
            category: .window,
            requiresInput: true,
            inputPlaceholder: "Window name"
        ),
    ]


    /// Returns all predefined actions filtered to the given category.
    static func actions(for category: Category) -> [QuickAction] {
        allActions.filter { $0.category == category }
    }

    /// Builds a shell-safe rename command by escaping the user-supplied name.
    ///
    /// Returns `nil` when the trimmed name is empty so callers can bail out.
    /// The name is single-quote-escaped to prevent command injection.
    static func buildRenameCommand(base: String, name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "\(base) \(trimmed.shellEscaped())"
    }
}

// MARK: - QuickActionView

/// A categorized command palette for tmux operations.
///
/// Presents pane, window, and session commands in a sectioned list.
/// Tapping an action either executes it immediately via the `onAction`
/// callback or, for rename-type actions, prompts for text input first.
struct QuickActionView: View {
    /// Callback that receives the final tmux command string to execute.
    var onAction: ((String) -> Void)?

    /// Controls presentation from the parent.
    @Environment(\.dismiss) private var dismiss

    @State private var selectedAction: QuickAction?
    @State private var inputText = ""

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                ForEach(QuickAction.Category.allCases, id: \.rawValue) { category in
                    Section(category.rawValue) {
                        ForEach(QuickAction.actions(for: category)) { action in
                            Button {
                                handleTap(action)
                            } label: {
                                actionRow(action)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Quick Actions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                selectedAction?.title ?? "Rename",
                isPresented: Binding(
                    get: { selectedAction != nil },
                    set: { if !$0 { selectedAction = nil } }
                )
            ) {
                TextField(
                    selectedAction?.inputPlaceholder ?? "Name",
                    text: $inputText
                )
                Button("OK") {
                    submitRename()
                }
                Button("Cancel", role: .cancel) {
                    selectedAction = nil
                    inputText = ""
                }
            } message: {
                Text("Enter a name for the \(selectedAction?.category.rawValue.lowercased() ?? "item").")
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Subviews

    @ViewBuilder
    private func actionRow(_ action: QuickAction) -> some View {
        Label {
            Text(action.title)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: action.icon)
                .foregroundStyle(.tint)
        }
    }

    // MARK: - Actions

    private func handleTap(_ action: QuickAction) {
        if action.requiresInput {
            inputText = ""
            selectedAction = action
        } else {
            onAction?(action.command)
            dismiss()
        }
    }

    private func submitRename() {
        guard let action = selectedAction else { return }
        guard let command = QuickAction.buildRenameCommand(base: action.command, name: inputText) else {
            inputText = ""
            selectedAction = nil
            return
        }
        onAction?(command)
        selectedAction = nil
        inputText = ""
        dismiss()
    }
}
