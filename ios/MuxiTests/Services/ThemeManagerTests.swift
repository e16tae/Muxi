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
        // Remove any stale theme selection from previous test runs
        // so init() falls through to the default path.
        UserDefaults.standard.removeObject(forKey: "selectedThemeId")
        defer { UserDefaults.standard.removeObject(forKey: "selectedThemeId") }
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

    @Test("Default font size is 14")
    @MainActor func defaultFontSize() {
        defer {
            UserDefaults.standard.removeObject(forKey: "terminalFontSize")
        }
        let manager = ThemeManager()
        #expect(manager.fontSize == 14)
    }

    @Test("Set font size updates value")
    @MainActor func setFontSize() {
        defer {
            UserDefaults.standard.removeObject(forKey: "terminalFontSize")
        }
        let manager = ThemeManager()
        manager.setFontSize(18)
        #expect(manager.fontSize == 18)
    }

    @Test("Font size clamps to valid range")
    @MainActor func fontSizeClamps() {
        defer {
            UserDefaults.standard.removeObject(forKey: "terminalFontSize")
        }
        let manager = ThemeManager()
        manager.setFontSize(6)
        #expect(manager.fontSize == 10)
        manager.setFontSize(30)
        #expect(manager.fontSize == 24)
    }

    @Test("Font size persists to UserDefaults")
    @MainActor func fontSizePersists() {
        defer {
            UserDefaults.standard.removeObject(forKey: "terminalFontSize")
        }
        let manager = ThemeManager()
        manager.setFontSize(20)
        let saved = UserDefaults.standard.double(forKey: "terminalFontSize")
        #expect(saved == 20)
    }

    @Test("Font size restores from UserDefaults")
    @MainActor func fontSizeRestores() {
        defer {
            UserDefaults.standard.removeObject(forKey: "terminalFontSize")
        }
        UserDefaults.standard.set(Double(20), forKey: "terminalFontSize")
        let manager = ThemeManager()
        #expect(manager.fontSize == 20)
    }

    @Test("Font size clamps on restore from UserDefaults")
    @MainActor func fontSizeRestoreClamps() {
        defer {
            UserDefaults.standard.removeObject(forKey: "terminalFontSize")
        }
        UserDefaults.standard.set(Double(50), forKey: "terminalFontSize")
        let manager = ThemeManager()
        #expect(manager.fontSize == 24)
    }
}
