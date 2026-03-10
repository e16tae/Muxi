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

    @Test("Total predefined action count is 7")
    func totalActionCount() {
        #expect(QuickAction.allActions.count == 7)
    }
}

// MARK: - Category Grouping Tests

@Suite("QuickAction Category Tests")
struct QuickActionCategoryTests {

    @Test("Pane actions count is 4")
    func paneActionCount() {
        let pane = QuickAction.actions(for: .pane)
        #expect(pane.count == 4)
    }

    @Test("Window actions count is 3")
    func windowActionCount() {
        let window = QuickAction.actions(for: .window)
        #expect(window.count == 3)
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

    @Test("Category allCases has two entries")
    func categoryAllCases() {
        #expect(QuickAction.Category.allCases.count == 2)
    }

    @Test("Category raw values match expected strings")
    func categoryRawValues() {
        #expect(QuickAction.Category.pane.rawValue == "Pane")
        #expect(QuickAction.Category.window.rawValue == "Window")
    }

    @Test("actions(for:) returns same result as static arrays")
    func actionsForMatchesStaticArrays() {
        #expect(
            QuickAction.actions(for: .pane).map(\.title) == QuickAction.paneActions.map(\.title)
        )
        #expect(
            QuickAction.actions(for: .window).map(\.title) == QuickAction.windowActions.map(\.title)
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

    @Test("Only one action requires input")
    func onlyOneActionRequiresInput() {
        let inputActions = QuickAction.allActions.filter(\.requiresInput)
        #expect(inputActions.count == 1)
    }

    @Test("Non-rename actions do not require input")
    func nonRenameActionsDontRequireInput() {
        let nonInput = QuickAction.allActions.filter { !$0.requiresInput }
        #expect(nonInput.count == 6)
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
