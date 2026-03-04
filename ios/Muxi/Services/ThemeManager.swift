import SwiftUI
import os

/// Manages theme selection with UserDefaults persistence.
///
/// Inject this into the SwiftUI environment or pass it directly to views
/// that need to react to theme changes.  Uses the ``@Observable`` macro
/// so SwiftUI views automatically re-render when the selection changes.
@MainActor
@Observable
final class ThemeManager {
    private let logger = Logger(subsystem: "com.muxi.app", category: "ThemeManager")

    /// All available themes (loaded from bundle).
    private(set) var themes: [Theme] = []

    /// The currently selected theme.
    private(set) var currentTheme: Theme = .catppuccinMocha

    private let selectedThemeKey = "selectedThemeId"
    private let fontSizeKey = "terminalFontSize"
    static let defaultFontSize: CGFloat = 14
    static let minFontSize: CGFloat = 10
    static let maxFontSize: CGFloat = 24
    static let fontSizeStep: CGFloat = 2

    /// Terminal font size in points. Persisted via UserDefaults.
    private(set) var fontSize: CGFloat = defaultFontSize

    init() {
        themes = Theme.loadBundledThemes()

        // Restore saved theme selection.
        if let savedId = UserDefaults.standard.string(forKey: selectedThemeKey),
           let saved = themes.first(where: { $0.id == savedId }) {
            currentTheme = saved
            logger.debug("Restored saved theme: \(saved.name)")
        } else if let first = themes.first {
            currentTheme = first
        }

        // Restore saved font size.
        let savedSize = UserDefaults.standard.double(forKey: fontSizeKey)
        if savedSize > 0 {
            fontSize = max(Self.minFontSize, min(savedSize, Self.maxFontSize))
        }
    }

    /// Select a new theme and persist the choice.
    func selectTheme(_ theme: Theme) {
        currentTheme = theme
        UserDefaults.standard.set(theme.id, forKey: selectedThemeKey)
        logger.info("Theme changed to: \(theme.name)")
    }

    /// Set the terminal font size and persist the choice.
    /// Clamps to the valid range (10--24pt).
    func setFontSize(_ size: CGFloat) {
        let clamped = max(Self.minFontSize, min(size, Self.maxFontSize))
        fontSize = clamped
        UserDefaults.standard.set(clamped, forKey: fontSizeKey)
        logger.info("Font size changed to: \(clamped)")
    }
}
