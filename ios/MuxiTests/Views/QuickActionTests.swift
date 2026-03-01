import Foundation
import Testing

@testable import Muxi

// MARK: - QuickAction Model Tests

@Suite("QuickAction Model Tests")
struct QuickActionModelTests {

    @Test("All predefined actions have non-empty titles")
    func allActionsHaveNonEmptyTitles() {
        for action in QuickAction.allActions {
            #expect(!action.title.isEmpty, "Action should have a non-empty title")
        }
    }

    @Test("All predefined actions have non-empty commands")
    func allActionsHaveNonEmptyCommands() {
        for action in QuickAction.allActions {
            #expect(!action.command.isEmpty, "Action should have a non-empty command")
        }
    }

    @Test("All predefined actions have non-empty icons")
    func allActionsHaveNonEmptyIcons() {
        for action in QuickAction.allActions {
            #expect(!action.icon.isEmpty, "Action should have a non-empty icon")
        }
    }

    @Test("All predefined actions have unique IDs")
    func allActionsHaveUniqueIDs() {
        let ids = QuickAction.allActions.map(\.id)
        let uniqueIDs = Set(ids)
        #expect(ids.count == uniqueIDs.count, "All action IDs should be unique")
    }

    @Test("Total predefined action count is 15")
    func totalActionCount() {
        #expect(QuickAction.allActions.count == 15)
    }
}

// MARK: - Category Grouping Tests

@Suite("QuickAction Category Tests")
struct QuickActionCategoryTests {

    @Test("Pane actions count is 6")
    func paneActionCount() {
        let pane = QuickAction.actions(for: .pane)
        #expect(pane.count == 6)
    }

    @Test("Window actions count is 5")
    func windowActionCount() {
        let window = QuickAction.actions(for: .window)
        #expect(window.count == 5)
    }

    @Test("Session actions count is 4")
    func sessionActionCount() {
        let session = QuickAction.actions(for: .session)
        #expect(session.count == 4)
    }

    @Test("Pane actions all have pane category")
    func paneActionsCorrectCategory() {
        for action in QuickAction.paneActions {
            #expect(action.category == .pane)
        }
    }

    @Test("Window actions all have window category")
    func windowActionsCorrectCategory() {
        for action in QuickAction.windowActions {
            #expect(action.category == .window)
        }
    }

    @Test("Session actions all have session category")
    func sessionActionsCorrectCategory() {
        for action in QuickAction.sessionActions {
            #expect(action.category == .session)
        }
    }

    @Test("Category allCases has three entries")
    func categoryAllCases() {
        #expect(QuickAction.Category.allCases.count == 3)
    }

    @Test("Category raw values match expected strings")
    func categoryRawValues() {
        #expect(QuickAction.Category.pane.rawValue == "Pane")
        #expect(QuickAction.Category.window.rawValue == "Window")
        #expect(QuickAction.Category.session.rawValue == "Session")
    }

    @Test("actions(for:) returns same result as static arrays")
    func actionsForMatchesStaticArrays() {
        #expect(
            QuickAction.actions(for: .pane).map(\.title) == QuickAction.paneActions.map(\.title)
        )
        #expect(
            QuickAction.actions(for: .window).map(\.title) == QuickAction.windowActions.map(\.title)
        )
        #expect(
            QuickAction.actions(for: .session).map(\.title) == QuickAction.sessionActions.map(\.title)
        )
    }
}

// MARK: - Specific Command Tests

@Suite("QuickAction Command Tests")
struct QuickActionCommandTests {

    @Test("Split horizontal command is correct")
    func splitHorizontal() {
        let action = QuickAction.paneActions.first { $0.title == "Split Horizontal" }
        #expect(action != nil)
        #expect(action?.command == "split-window -h")
    }

    @Test("Split vertical command is correct")
    func splitVertical() {
        let action = QuickAction.paneActions.first { $0.title == "Split Vertical" }
        #expect(action != nil)
        #expect(action?.command == "split-window -v")
    }

    @Test("Kill pane command is correct")
    func killPane() {
        let action = QuickAction.paneActions.first { $0.title == "Close Pane" }
        #expect(action != nil)
        #expect(action?.command == "kill-pane")
    }

    @Test("Next pane command is correct")
    func nextPane() {
        let action = QuickAction.paneActions.first { $0.title == "Next Pane" }
        #expect(action != nil)
        #expect(action?.command == "select-pane -t :.+")
    }

    @Test("Previous pane command is correct")
    func previousPane() {
        let action = QuickAction.paneActions.first { $0.title == "Previous Pane" }
        #expect(action != nil)
        #expect(action?.command == "select-pane -t :.-")
    }

    @Test("Zoom command is correct")
    func zoomUnzoom() {
        let action = QuickAction.paneActions.first { $0.title == "Zoom/Unzoom" }
        #expect(action != nil)
        #expect(action?.command == "resize-pane -Z")
    }

    @Test("New window command is correct")
    func newWindow() {
        let action = QuickAction.windowActions.first { $0.title == "New Window" }
        #expect(action != nil)
        #expect(action?.command == "new-window")
    }

    @Test("Kill window command is correct")
    func killWindow() {
        let action = QuickAction.windowActions.first { $0.title == "Close Window" }
        #expect(action != nil)
        #expect(action?.command == "kill-window")
    }

    @Test("New session command is correct")
    func newSession() {
        let action = QuickAction.sessionActions.first { $0.title == "New Session" }
        #expect(action != nil)
        #expect(action?.command == "new-session -d")
    }

    @Test("Detach command is correct")
    func detachClient() {
        let action = QuickAction.sessionActions.first { $0.title == "Detach" }
        #expect(action != nil)
        #expect(action?.command == "detach-client")
    }
}

// MARK: - Rename / Input Actions Tests

@Suite("QuickAction Input Tests")
struct QuickActionInputTests {

    @Test("Rename Window requires input")
    func renameWindowRequiresInput() {
        let action = QuickAction.windowActions.first { $0.title == "Rename Window" }
        #expect(action != nil)
        #expect(action?.requiresInput == true)
        #expect(action?.inputPlaceholder == "Window name")
        #expect(action?.command == "rename-window")
    }

    @Test("Rename Session requires input")
    func renameSessionRequiresInput() {
        let action = QuickAction.sessionActions.first { $0.title == "Rename Session" }
        #expect(action != nil)
        #expect(action?.requiresInput == true)
        #expect(action?.inputPlaceholder == "Session name")
        #expect(action?.command == "rename-session")
    }

    @Test("Only two actions require input")
    func onlyTwoActionsRequireInput() {
        let inputActions = QuickAction.allActions.filter(\.requiresInput)
        #expect(inputActions.count == 2)
    }

    @Test("Non-rename actions do not require input")
    func nonRenameActionsDontRequireInput() {
        let nonInput = QuickAction.allActions.filter { !$0.requiresInput }
        #expect(nonInput.count == 13)
        for action in nonInput {
            #expect(action.requiresInput == false)
        }
    }
}

// MARK: - buildRenameCommand Tests

@Suite("QuickAction buildRenameCommand Tests")
struct QuickActionBuildRenameCommandTests {

    @Test("Normal name produces correct shell-escaped command")
    func normalName() {
        let result = QuickAction.buildRenameCommand(base: "rename-window", name: "mywindow")
        #expect(result == "rename-window 'mywindow'")
    }

    @Test("Empty name returns nil")
    func emptyName() {
        let result = QuickAction.buildRenameCommand(base: "rename-window", name: "")
        #expect(result == nil)
    }

    @Test("Whitespace-only name returns nil")
    func whitespaceOnly() {
        let result = QuickAction.buildRenameCommand(base: "rename-window", name: "   ")
        #expect(result == nil)
    }

    @Test("Name with semicolons is properly escaped")
    func nameWithSemicolons() {
        let result = QuickAction.buildRenameCommand(base: "rename-window", name: "foo; kill-server")
        #expect(result == "rename-window 'foo; kill-server'")
    }

    @Test("Name with single quotes is properly escaped")
    func nameWithSingleQuotes() {
        let result = QuickAction.buildRenameCommand(base: "rename-session", name: "it's a test")
        #expect(result == "rename-session 'it'\\''s a test'")
    }

    @Test("Name with newlines returns nil after trimming")
    func newlinesOnly() {
        let result = QuickAction.buildRenameCommand(base: "rename-window", name: "\n\n")
        #expect(result == nil)
    }

    @Test("Name with embedded newlines is properly escaped")
    func nameWithEmbeddedNewlines() {
        let result = QuickAction.buildRenameCommand(base: "rename-window", name: "foo\nbar")
        #expect(result == "rename-window 'foo\nbar'")
    }

    @Test("Name with leading/trailing whitespace is trimmed")
    func nameWithSurroundingWhitespace() {
        let result = QuickAction.buildRenameCommand(base: "rename-window", name: "  hello  ")
        #expect(result == "rename-window 'hello'")
    }
}
