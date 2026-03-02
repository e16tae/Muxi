import Foundation
import Testing
@testable import Muxi

@Suite("ThemeManager")
struct ThemeManagerTests {

    @Test("Loads bundled themes")
    @MainActor func loadBundledThemes() {
        let manager = ThemeManager()
        #expect(!manager.themes.isEmpty)
    }

    @Test("Default theme is set")
    @MainActor func defaultTheme() {
        let manager = ThemeManager()
        #expect(
            manager.currentTheme.id == manager.themes.first?.id
            || manager.currentTheme.id == "catppuccin-mocha"
        )
    }

    @Test("Select theme updates currentTheme")
    @MainActor func selectTheme() {
        let manager = ThemeManager()
        guard manager.themes.count > 1 else { return }
        let secondTheme = manager.themes[1]
        manager.selectTheme(secondTheme)
        #expect(manager.currentTheme.id == secondTheme.id)
    }

    @Test("Select theme persists to UserDefaults")
    @MainActor func selectThemePersists() {
        defer {
            UserDefaults.standard.removeObject(forKey: "selectedThemeId")
        }
        let manager = ThemeManager()
        guard manager.themes.count > 1 else { return }
        let secondTheme = manager.themes[1]
        manager.selectTheme(secondTheme)
        let savedId = UserDefaults.standard.string(forKey: "selectedThemeId")
        #expect(savedId == secondTheme.id)
    }
}
