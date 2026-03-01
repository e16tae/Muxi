import XCTest
@testable import Muxi

final class ThemeTests: XCTestCase {

    // MARK: - Default Theme Properties

    func testDefaultThemeHas16AnsiColors() {
        let theme = Theme.default
        XCTAssertEqual(theme.ansiColors.count, 16)
    }

    func testDefaultThemeIdentifiableId() {
        let theme = Theme.default
        XCTAssertEqual(theme.id, "catppuccin-mocha")
    }

    func testDefaultThemeName() {
        let theme = Theme.default
        XCTAssertEqual(theme.name, "Catppuccin Mocha")
    }

    // MARK: - Codable Round-Trip

    func testCodableRoundTrip() throws {
        let original = Theme.catppuccinMocha
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Theme.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testThemeColorCodableRoundTrip() throws {
        let original = ThemeColor(r: 128, g: 64, b: 255)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ThemeColor.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - resolve(.default, ...)

    func testResolveDefaultForeground() {
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.default, isForeground: true)
        XCTAssertEqual(resolved, theme.foreground)
    }

    func testResolveDefaultBackground() {
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.default, isForeground: false)
        XCTAssertEqual(resolved, theme.background)
    }

    // MARK: - resolve(.ansi(...), ...) for indices 0-15

    func testResolveAnsi0() {
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.ansi(0), isForeground: true)
        XCTAssertEqual(resolved, theme.ansiColors[0])
    }

    func testResolveAnsi1ReturnsRed() {
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.ansi(1), isForeground: true)
        // Catppuccin Mocha red: #F38BA8
        XCTAssertEqual(resolved, ThemeColor(r: 243, g: 139, b: 168))
    }

    func testResolveAnsi15() {
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.ansi(15), isForeground: true)
        XCTAssertEqual(resolved, theme.ansiColors[15])
    }

    // MARK: - resolve(.ansi(...), ...) for 256-color cube (16-231)

    func testResolveAnsi16IsBlack() {
        // Index 16 = first entry of the 6x6x6 cube = (0,0,0)
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.ansi(16), isForeground: true)
        XCTAssertEqual(resolved, ThemeColor(r: 0, g: 0, b: 0))
    }

    func testResolveAnsi21() {
        // Index 21 = adjusted 5 -> r=0, g=0, b=5*51=255
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.ansi(21), isForeground: true)
        XCTAssertEqual(resolved, ThemeColor(r: 0, g: 0, b: 255))
    }

    func testResolveAnsi196() {
        // Index 196: adjusted = 180; r = (180/36)*51 = 5*51=255, g = ((180/6)%6)*51 = 0*51=0, b = (180%6)*51 = 0*51=0
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.ansi(196), isForeground: true)
        XCTAssertEqual(resolved, ThemeColor(r: 255, g: 0, b: 0))
    }

    func testResolveAnsi231() {
        // Index 231: adjusted = 215; r = (215/36)*51 = 5*51=255, g = ((215/6)%6)*51 = 5*51=255, b = (215%6)*51 = 5*51=255
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.ansi(231), isForeground: true)
        XCTAssertEqual(resolved, ThemeColor(r: 255, g: 255, b: 255))
    }

    // MARK: - resolve(.ansi(...), ...) for grayscale (232-255)

    func testResolveAnsi232IsNearBlack() {
        // Index 232: gray = 8 + (0)*10 = 8
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.ansi(232), isForeground: true)
        XCTAssertEqual(resolved, ThemeColor(r: 8, g: 8, b: 8))
    }

    func testResolveAnsi255IsNearWhite() {
        // Index 255: gray = 8 + (23)*10 = 238
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.ansi(255), isForeground: true)
        XCTAssertEqual(resolved, ThemeColor(r: 238, g: 238, b: 238))
    }

    func testResolveAnsi244IsMidGray() {
        // Index 244: gray = 8 + (12)*10 = 128
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.ansi(244), isForeground: true)
        XCTAssertEqual(resolved, ThemeColor(r: 128, g: 128, b: 128))
    }

    // MARK: - resolve(.rgb(...), ...)

    func testResolveRGBReturnsExactColor() {
        let theme = Theme.catppuccinMocha
        let resolved = theme.resolve(.rgb(100, 200, 50), isForeground: true)
        XCTAssertEqual(resolved, ThemeColor(r: 100, g: 200, b: 50))
    }

    func testResolveRGBIgnoresIsForeground() {
        let theme = Theme.catppuccinMocha
        let fg = theme.resolve(.rgb(10, 20, 30), isForeground: true)
        let bg = theme.resolve(.rgb(10, 20, 30), isForeground: false)
        XCTAssertEqual(fg, bg)
    }

    // MARK: - load(from:) JSON Parsing

    func testLoadFromValidJSON() {
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
        XCTAssertNotNil(theme)
        XCTAssertEqual(theme?.id, "test-theme")
        XCTAssertEqual(theme?.name, "Test Theme")
        XCTAssertEqual(theme?.foreground, ThemeColor(r: 255, g: 255, b: 255))
        XCTAssertEqual(theme?.background, ThemeColor(r: 0, g: 0, b: 0))
        XCTAssertEqual(theme?.cursor, ThemeColor(r: 128, g: 128, b: 128))
        XCTAssertEqual(theme?.selection, ThemeColor(r: 64, g: 64, b: 64))
        XCTAssertEqual(theme?.ansiColors.count, 16)
        XCTAssertEqual(theme?.ansiColors[1], ThemeColor(r: 255, g: 0, b: 0))
    }

    func testLoadFromInvalidJSONReturnsNil() {
        let badJSON = "{ not valid json".data(using: .utf8)!
        let theme = Theme.load(from: badJSON)
        XCTAssertNil(theme)
    }

    func testLoadFromIncompleteJSONReturnsNil() {
        // Missing required fields
        let incompleteJSON = """
        {
            "id": "incomplete",
            "name": "Incomplete Theme"
        }
        """.data(using: .utf8)!
        let theme = Theme.load(from: incompleteJSON)
        XCTAssertNil(theme)
    }

    // MARK: - Equatable

    func testThemeEquatable() {
        let theme1 = Theme.catppuccinMocha
        let theme2 = Theme.catppuccinMocha
        XCTAssertEqual(theme1, theme2)
    }

    func testThemeNotEqual() {
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
        XCTAssertNotEqual(theme1, theme2)
    }

    func testThemeColorEquatable() {
        let c1 = ThemeColor(r: 10, g: 20, b: 30)
        let c2 = ThemeColor(r: 10, g: 20, b: 30)
        let c3 = ThemeColor(r: 10, g: 20, b: 31)
        XCTAssertEqual(c1, c2)
        XCTAssertNotEqual(c1, c3)
    }

    // MARK: - ThemeColor SwiftUI Color

    func testThemeColorToSwiftUIColor() {
        // Verify the computed property doesn't crash and returns a valid Color.
        let themeColor = ThemeColor(r: 128, g: 64, b: 255)
        let color = themeColor.color
        // SwiftUI Color is opaque so we just verify it exists.
        XCTAssertNotNil(color)
    }

    // MARK: - Catppuccin Mocha JSON Consistency

    func testCatppuccinMochaJSONMatchesHardcoded() throws {
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

        let fromJSON = try XCTUnwrap(Theme.load(from: json))
        XCTAssertEqual(fromJSON, Theme.catppuccinMocha)
    }
}
