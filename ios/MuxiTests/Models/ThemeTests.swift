import Foundation
import Testing
@testable import Muxi

@Suite("Theme")
struct ThemeTests {

    // MARK: - Default Theme Properties

    @Test("default theme has 16 ANSI colors")
    func defaultThemeHas16AnsiColors() {
        let theme = Theme.default
        #expect(theme.ansiColors.count == 16)
    }

    @Test("default theme identifiable id")
    func defaultThemeIdentifiableId() {
        let theme = Theme.default
        #expect(theme.id == "catppuccin-mocha")
    }

    @Test("default theme name")
    func defaultThemeName() {
        let theme = Theme.default
        #expect(theme.name == "Catppuccin Mocha")
    }

    // MARK: - Codable Round-Trip

    @Test("codable round-trip preserves theme")
    func codableRoundTrip() throws {
        let original = Theme.catppuccinMocha
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Theme.self, from: data)
        #expect(original == decoded)
    }

    @Test("ThemeColor codable round-trip")
    func themeColorCodableRoundTrip() throws {
        let original = ThemeColor(r: 128, g: 64, b: 255)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ThemeColor.self, from: data)
        #expect(original == decoded)
    }

    // MARK: - resolve(.default, ...)

    @Test("resolve default foreground returns theme foreground")
    func resolveDefaultForeground() {
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.default, isForeground: true)
        #expect(resolved == theme.foreground)
    }

    @Test("resolve default background returns theme background")
    func resolveDefaultBackground() {
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.default, isForeground: false)
        #expect(resolved == theme.background)
    }

    // MARK: - resolve(.ansi(...), ...) for indices 0-15

    @Test("resolve ANSI 0 returns first ANSI color")
    func resolveAnsi0() {
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.ansi(0), isForeground: true)
        #expect(resolved == theme.ansiColors[0])
    }

    @Test("resolve ANSI 1 returns red")
    func resolveAnsi1ReturnsRed() {
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.ansi(1), isForeground: true)
        #expect(resolved == ThemeColor(r: 243, g: 139, b: 168))
    }

    @Test("resolve ANSI 15 returns last ANSI color")
    func resolveAnsi15() {
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.ansi(15), isForeground: true)
        #expect(resolved == theme.ansiColors[15])
    }

    // MARK: - resolve(.ansi(...), ...) for 256-color cube (16-231)

    @Test("resolve ANSI 16 is black (start of color cube)")
    func resolveAnsi16IsBlack() {
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.ansi(16), isForeground: true)
        #expect(resolved == ThemeColor(r: 0, g: 0, b: 0))
    }

    @Test("resolve ANSI 21 is blue")
    func resolveAnsi21() {
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.ansi(21), isForeground: true)
        #expect(resolved == ThemeColor(r: 0, g: 0, b: 255))
    }

    @Test("resolve ANSI 196 is red")
    func resolveAnsi196() {
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.ansi(196), isForeground: true)
        #expect(resolved == ThemeColor(r: 255, g: 0, b: 0))
    }

    @Test("resolve ANSI 231 is white")
    func resolveAnsi231() {
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.ansi(231), isForeground: true)
        #expect(resolved == ThemeColor(r: 255, g: 255, b: 255))
    }

    // MARK: - resolve(.ansi(...), ...) for grayscale (232-255)

    @Test("resolve ANSI 232 is near black")
    func resolveAnsi232IsNearBlack() {
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.ansi(232), isForeground: true)
        #expect(resolved == ThemeColor(r: 8, g: 8, b: 8))
    }

    @Test("resolve ANSI 255 is near white")
    func resolveAnsi255IsNearWhite() {
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.ansi(255), isForeground: true)
        #expect(resolved == ThemeColor(r: 238, g: 238, b: 238))
    }

    @Test("resolve ANSI 244 is mid gray")
    func resolveAnsi244IsMidGray() {
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.ansi(244), isForeground: true)
        #expect(resolved == ThemeColor(r: 128, g: 128, b: 128))
    }

    // MARK: - resolve(.rgb(...), ...)

    @Test("resolve RGB returns exact color")
    func resolveRGBReturnsExactColor() {
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.rgb(100, 200, 50), isForeground: true)
        #expect(resolved == ThemeColor(r: 100, g: 200, b: 50))
    }

    @Test("resolve RGB ignores isForeground")
    func resolveRGBIgnoresIsForeground() {
        let theme = Theme.catppuccinMocha
        let fg = theme.resolve(.rgb(10, 20, 30), isForeground: true)
        let bg = theme.resolve(.rgb(10, 20, 30), isForeground: false)
        #expect(fg == bg)
    }

    // MARK: - load(from:) JSON Parsing

    @Test("load from valid JSON succeeds")
    func loadFromValidJSON() throws {
        let json = """
        {
            "id": "test-theme",
            "name": "Test Theme",
            "foreground": {"r": 255, "g": 255, "b": 255},
            "background": {"r": 0, "g": 0, "b": 0},
            "cursor": {"r": 128, "g": 128, "b": 128},
            "selection": {"r": 64, "g": 64, "b": 64},
            "ansiColors": [
                {"r": 0, "g": 0, "b": 0},
                {"r": 255, "g": 0, "b": 0},
                {"r": 0, "g": 255, "b": 0},
                {"r": 255, "g": 255, "b": 0},
                {"r": 0, "g": 0, "b": 255},
                {"r": 255, "g": 0, "b": 255},
                {"r": 0, "g": 255, "b": 255},
                {"r": 255, "g": 255, "b": 255},
                {"r": 128, "g": 128, "b": 128},
                {"r": 255, "g": 85, "b": 85},
                {"r": 85, "g": 255, "b": 85},
                {"r": 255, "g": 255, "b": 85},
                {"r": 85, "g": 85, "b": 255},
                {"r": 255, "g": 85, "b": 255},
                {"r": 85, "g": 255, "b": 255},
                {"r": 255, "g": 255, "b": 255}
            ]
        }
        """.data(using: .utf8)!

        let theme = Theme.load(from: json)
        let unwrapped = try #require(theme)
        #expect(unwrapped.id == "test-theme")
        #expect(unwrapped.name == "Test Theme")
        #expect(unwrapped.foreground == ThemeColor(r: 255, g: 255, b: 255))
        #expect(unwrapped.background == ThemeColor(r: 0, g: 0, b: 0))
        #expect(unwrapped.cursor == ThemeColor(r: 128, g: 128, b: 128))
        #expect(unwrapped.selection == ThemeColor(r: 64, g: 64, b: 64))
        #expect(unwrapped.ansiColors.count == 16)
        #expect(unwrapped.ansiColors[1] == ThemeColor(r: 255, g: 0, b: 0))
    }

    @Test("load from invalid JSON returns nil")
    func loadFromInvalidJSONReturnsNil() {
        let badJSON = "{ not valid json".data(using: .utf8)!
        let theme = Theme.load(from: badJSON)
        #expect(theme == nil)
    }

    @Test("load from incomplete JSON returns nil")
    func loadFromIncompleteJSONReturnsNil() {
        let incompleteJSON = """
        {
            "id": "incomplete",
            "name": "Incomplete Theme"
        }
        """.data(using: .utf8)!
        let theme = Theme.load(from: incompleteJSON)
        #expect(theme == nil)
    }

    // MARK: - Equatable

    @Test("same themes are equal")
    func themeEquatable() {
        let theme1 = Theme.catppuccinMocha
        let theme2 = Theme.catppuccinMocha
        #expect(theme1 == theme2)
    }

    @Test("different themes are not equal")
    func themeNotEqual() {
        let theme1 = Theme.catppuccinMocha
        let theme2 = Theme(
            id: "other-theme",
            name: "Other Theme",
            foreground: ThemeColor(r: 0, g: 0, b: 0),
            background: ThemeColor(r: 255, g: 255, b: 255),
            cursor: ThemeColor(r: 128, g: 128, b: 128),
            selection: ThemeColor(r: 64, g: 64, b: 64),
            ansiColors: Array(repeating: ThemeColor(r: 0, g: 0, b: 0), count: 16)
        )
        #expect(theme1 != theme2)
    }

    @Test("ThemeColor equatable")
    func themeColorEquatable() {
        let c1 = ThemeColor(r: 10, g: 20, b: 30)
        let c2 = ThemeColor(r: 10, g: 20, b: 30)
        let c3 = ThemeColor(r: 10, g: 20, b: 31)
        #expect(c1 == c2)
        #expect(c1 != c3)
    }

    // MARK: - ThemeColor SwiftUI Color

    @Test("ThemeColor converts to SwiftUI Color")
    func themeColorToSwiftUIColor() {
        let themeColor = ThemeColor(r: 128, g: 64, b: 255)
        let color = themeColor.color
        _ = color  // Verify it doesn't crash
    }

    // MARK: - Catppuccin Mocha JSON Consistency

    @Test("Catppuccin Mocha JSON matches hardcoded theme")
    func catppuccinMochaJSONMatchesHardcoded() throws {
        let json = """
        {
            "id": "catppuccin-mocha",
            "name": "Catppuccin Mocha",
            "foreground": {"r": 205, "g": 214, "b": 244},
            "background": {"r": 30, "g": 30, "b": 46},
            "cursor": {"r": 245, "g": 224, "b": 220},
            "selection": {"r": 88, "g": 91, "b": 112},
            "ansiColors": [
                {"r": 69, "g": 71, "b": 90},
                {"r": 243, "g": 139, "b": 168},
                {"r": 166, "g": 227, "b": 161},
                {"r": 249, "g": 226, "b": 175},
                {"r": 137, "g": 180, "b": 250},
                {"r": 245, "g": 194, "b": 231},
                {"r": 148, "g": 226, "b": 213},
                {"r": 186, "g": 194, "b": 222},
                {"r": 88, "g": 91, "b": 112},
                {"r": 243, "g": 139, "b": 168},
                {"r": 166, "g": 227, "b": 161},
                {"r": 249, "g": 226, "b": 175},
                {"r": 137, "g": 180, "b": 250},
                {"r": 245, "g": 194, "b": 231},
                {"r": 148, "g": 226, "b": 213},
                {"r": 205, "g": 214, "b": 244}
            ]
        }
        """.data(using: .utf8)!

        let fromJSON = try #require(Theme.load(from: json))
        #expect(fromJSON == Theme.catppuccinMocha)
    }

    // MARK: - ansiColors Validation

    @Test("decoding theme with wrong ansiColors count fails")
    func decodingThemeWithWrongAnsiColorsCountFails() {
        let json = """
        {
            "id": "bad-theme",
            "name": "Bad Theme",
            "foreground": {"r": 0, "g": 0, "b": 0},
            "background": {"r": 0, "g": 0, "b": 0},
            "cursor": {"r": 0, "g": 0, "b": 0},
            "selection": {"r": 0, "g": 0, "b": 0},
            "ansiColors": [{"r": 0, "g": 0, "b": 0}]
        }
        """.data(using: .utf8)!
        let theme = Theme.load(from: json)
        #expect(theme == nil)
    }
}
