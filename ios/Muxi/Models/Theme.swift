import SwiftUI

// MARK: - ThemeColor

/// An RGB color value used within a terminal theme.
struct ThemeColor: Codable, Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8

    /// Convert to a SwiftUI `Color`.
    var color: Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

// MARK: - Theme

/// A terminal color theme that maps ANSI color indices (0-15) to RGB values
/// and provides default foreground, background, cursor, and selection colors.
struct Theme: Codable, Identifiable, Equatable {
    /// Unique identifier, e.g. "catppuccin-mocha".
    let id: String
    /// Human-readable name, e.g. "Catppuccin Mocha".
    let name: String
    /// Default foreground color for text.
    let foreground: ThemeColor
    /// Default background color.
    let background: ThemeColor
    /// Cursor color.
    let cursor: ThemeColor
    /// Selection highlight color.
    let selection: ThemeColor
    /// The 16 ANSI colors (indices 0-15).
    let ansiColors: [ThemeColor]

    // MARK: - Color Resolution

    /// Resolve a `TerminalColor` to a concrete `ThemeColor` using this theme.
    ///
    /// - Parameters:
    ///   - color: The terminal color to resolve.
    ///   - isForeground: Whether this color is used as a foreground or background.
    /// - Returns: The resolved `ThemeColor`.
    func resolve(_ color: TerminalColor, isForeground: Bool) -> ThemeColor {
        switch color {
        case .default:
            return isForeground ? foreground : background
        case .ansi(let index):
            if index < 16 {
                return ansiColors[Int(index)]
            }
            // 256-color: indices 16-231 form a 6x6x6 color cube.
            if index < 232 {
                let adjusted = Int(index) - 16
                let r = UInt8((adjusted / 36) * 51)
                let g = UInt8(((adjusted / 6) % 6) * 51)
                let b = UInt8((adjusted % 6) * 51)
                return ThemeColor(r: r, g: g, b: b)
            }
            // 256-color: indices 232-255 are a grayscale ramp.
            let gray = UInt8(8 + (Int(index) - 232) * 10)
            return ThemeColor(r: gray, g: gray, b: gray)
        case .rgb(let r, let g, let b):
            return ThemeColor(r: r, g: g, b: b)
        }
    }

    // MARK: - Loading

    /// Load a theme from a bundled JSON file in the Themes subdirectory.
    ///
    /// - Parameter fileName: The file name without extension, e.g. "catppuccin-mocha".
    /// - Returns: The decoded `Theme`, or `nil` if loading or decoding fails.
    static func load(named fileName: String) -> Theme? {
        guard let url = Bundle.main.url(
            forResource: fileName,
            withExtension: "json",
            subdirectory: "Themes"
        ) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Theme.self, from: data)
    }

    /// Load a theme from raw JSON data (useful for testing).
    ///
    /// - Parameter data: The JSON data to decode.
    /// - Returns: The decoded `Theme`, or `nil` if decoding fails.
    static func load(from data: Data) -> Theme? {
        try? JSONDecoder().decode(Theme.self, from: data)
    }

    // MARK: - Bundle Loading

    /// Load all bundled theme JSON files from the Themes directory.
    ///
    /// Scans the app bundle's `Themes` folder for `.json` files, decodes each
    /// one into a ``Theme``, and returns them sorted by name.  Falls back to
    /// ``catppuccinMocha`` if the folder is missing or contains no valid themes.
    static func loadBundledThemes() -> [Theme] {
        guard let themesURL = Bundle.main.url(
            forResource: "Themes",
            withExtension: nil
        ) else { return [.catppuccinMocha] }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: themesURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [.catppuccinMocha] }

        let themes = contents
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Theme? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(Theme.self, from: data)
            }
            .sorted { $0.name < $1.name }

        return themes.isEmpty ? [.catppuccinMocha] : themes
    }

    // MARK: - Built-in Themes

    /// The default theme (Catppuccin Mocha).
    static let `default` = catppuccinMocha

    /// Catppuccin Mocha theme (hardcoded fallback).
    static let catppuccinMocha = Theme(
        id: "catppuccin-mocha",
        name: "Catppuccin Mocha",
        foreground: ThemeColor(r: 205, g: 214, b: 244),   // #CDD6F4
        background: ThemeColor(r: 30, g: 30, b: 46),      // #1E1E2E
        cursor: ThemeColor(r: 245, g: 224, b: 220),       // #F5E0DC
        selection: ThemeColor(r: 88, g: 91, b: 112),      // #585B70
        ansiColors: [
            ThemeColor(r: 69, g: 71, b: 90),              //  0: Surface1  #45475A
            ThemeColor(r: 243, g: 139, b: 168),            //  1: Red       #F38BA8
            ThemeColor(r: 166, g: 227, b: 161),            //  2: Green     #A6E3A1
            ThemeColor(r: 249, g: 226, b: 175),            //  3: Yellow    #F9E2AF
            ThemeColor(r: 137, g: 180, b: 250),            //  4: Blue      #89B4FA
            ThemeColor(r: 245, g: 194, b: 231),            //  5: Pink      #F5C2E7
            ThemeColor(r: 148, g: 226, b: 213),            //  6: Teal      #94E2D5
            ThemeColor(r: 186, g: 194, b: 222),            //  7: Subtext1  #BAC2DE
            ThemeColor(r: 88, g: 91, b: 112),              //  8: Surface2  #585B70
            ThemeColor(r: 243, g: 139, b: 168),            //  9: Red       #F38BA8
            ThemeColor(r: 166, g: 227, b: 161),            // 10: Green     #A6E3A1
            ThemeColor(r: 249, g: 226, b: 175),            // 11: Yellow    #F9E2AF
            ThemeColor(r: 137, g: 180, b: 250),            // 12: Blue      #89B4FA
            ThemeColor(r: 245, g: 194, b: 231),            // 13: Pink      #F5C2E7
            ThemeColor(r: 148, g: 226, b: 213),            // 14: Teal      #94E2D5
            ThemeColor(r: 205, g: 214, b: 244),            // 15: Text      #CDD6F4
        ]
    )
}
