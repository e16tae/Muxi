import SwiftUI

// MARK: - Design Tokens

/// Muxi semantic design token system.
/// All visual constants (colors, spacing, radii, typography, motion) live here.
/// Views reference tokens by role, never by raw value.
enum MuxiTokens {

    // MARK: - Colors

    enum Colors {
        // Surface (background layers) — purple undertone, ~6% lightness steps
        static let surfaceBase     = Color(red: 0.071, green: 0.055, blue: 0.094)  // #120E18
        static let surfaceDefault  = Color(red: 0.102, green: 0.082, blue: 0.125)  // #1A1520
        static let surfaceRaised   = Color(red: 0.141, green: 0.118, blue: 0.173)  // #241E2C
        static let surfaceElevated = Color(red: 0.180, green: 0.153, blue: 0.220)  // #2E2738

        // Accent (Lavender)
        static let accentDefault   = Color(red: 0.710, green: 0.659, blue: 0.835)  // #B5A8D5
        static let accentBright    = Color(red: 0.831, green: 0.784, blue: 0.941)  // #D4C8F0
        static let accentSubtle    = accentDefault.opacity(0.12)
        static let accentMuted     = accentDefault.opacity(0.06)

        // Text
        static let textPrimary     = Color(red: 0.918, green: 0.878, blue: 0.949)  // #EAE0F2
        static let textSecondary   = Color(red: 0.608, green: 0.565, blue: 0.659)  // #9B90A8
        static let textTertiary    = Color(red: 0.420, green: 0.380, blue: 0.471)  // #6B6178
        static let textInverse     = surfaceBase

        // Border / Divider
        static let borderDefault   = Color.white.opacity(0.08)
        static let borderStrong    = Color.white.opacity(0.15)
        static let borderAccent    = accentDefault.opacity(0.30)

        // Semantic (status)
        static let error           = Color(red: 1.000, green: 0.420, blue: 0.420)  // #FF6B6B
        static let success         = Color(red: 0.420, green: 0.796, blue: 0.467)  // #6BCB77
        static let warning         = Color(red: 1.000, green: 0.851, blue: 0.239)  // #FFD93D
        static let info            = Color(red: 0.455, green: 0.725, blue: 1.000)  // #74B9FF
    }

    // MARK: - Spacing (4pt grid)

    enum Spacing {
        static let xs:  CGFloat = 4
        static let sm:  CGFloat = 8
        static let md:  CGFloat = 12
        static let lg:  CGFloat = 16
        static let xl:  CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Radius

    enum Radius {
        static let sm:   CGFloat = 8
        static let md:   CGFloat = 12
        static let lg:   CGFloat = 16
        static let full: CGFloat = 9999
    }

    // MARK: - Typography

    enum Typography {
        static let largeTitle  = Font.system(.title2, weight: .semibold)
        static let title       = Font.system(.headline, weight: .semibold)
        static let body        = Font.system(.body)
        static let caption     = Font.system(.caption)
        static let label       = Font.system(.footnote, weight: .medium)
        /// Pill typography — larger than label for session/window/pane pills
        static let pill        = Font.system(.subheadline, weight: .semibold)
        /// Monospaced caption — for command display, code snippets
        static let monoCaption = Font.system(.caption, design: .monospaced)
    }

    // MARK: - Motion

    enum Motion {
        // Semantic tokens — primary API for view animations
        static let appear     = Animation.spring(duration: 0.4, bounce: 0.15)
        static let tap        = Animation.spring(duration: 0.2, bounce: 0.2)
        static let transition = Animation.spring(duration: 0.35, bounce: 0.1)
        static let subtle     = Animation.easeInOut(duration: 0.2)

        // Directional tokens — asymmetric enter/exit
        static let entrance   = Animation.spring(duration: 0.4, bounce: 0.1)
        static let exit       = Animation.spring(duration: 0.2, bounce: 0)

        // Weight tokens — element mass
        static let heavy      = Animation.spring(duration: 0.5, bounce: 0.15)
        static let light      = Animation.spring(duration: 0.25, bounce: 0)

        // Stagger timing
        static let staggerInterval: TimeInterval = 0.04

        static func staggerDelay(index: Int) -> Animation {
            transition.delay(Double(index) * staggerInterval)
        }

        /// Resolved motion set respecting accessibility preferences
        static func resolved(reduceMotion: Bool) -> ResolvedMotion {
            ResolvedMotion(reduceMotion: reduceMotion)
        }
    }

    struct ResolvedMotion {
        let reduceMotion: Bool

        var appear: Animation     { reduceMotion ? .easeInOut(duration: 0.2) : Motion.appear }
        var tap: Animation        { reduceMotion ? .easeInOut(duration: 0.15) : Motion.tap }
        var transition: Animation { reduceMotion ? .easeInOut(duration: 0.2) : Motion.transition }
        var subtle: Animation     { Motion.subtle }
        var entrance: Animation   { reduceMotion ? .easeInOut(duration: 0.2) : Motion.entrance }
        var exit: Animation       { reduceMotion ? .easeInOut(duration: 0.15) : Motion.exit }
        var heavy: Animation      { reduceMotion ? .easeInOut(duration: 0.25) : Motion.heavy }
        var light: Animation      { reduceMotion ? .easeInOut(duration: 0.15) : Motion.light }
    }

    // MARK: - Accessibility

    enum Accessibility {
        /// Minimum touch target size (Apple HIG: 44×44pt)
        static let minimumHitTarget: CGFloat = 44
    }
}

// MARK: - Reduce Motion View Modifier

struct MuxiAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: KeyPath<MuxiTokens.ResolvedMotion, Animation>
    let value: V

    func body(content: Content) -> some View {
        content.animation(
            MuxiTokens.Motion.resolved(reduceMotion: reduceMotion)[keyPath: animation],
            value: value
        )
    }
}

extension View {
    func muxiAnimation(
        _ animation: KeyPath<MuxiTokens.ResolvedMotion, Animation>,
        value: some Equatable
    ) -> some View {
        modifier(MuxiAnimationModifier(animation: animation, value: value))
    }
}

// MARK: - ShapeStyle Dot-Syntax

/// Enables `.foregroundStyle(.textPrimary)` instead of `MuxiTokens.Colors.textPrimary`.
/// Matches SwiftUI's native `.primary` / `.secondary` API ergonomics.
extension ShapeStyle where Self == Color {
    // Surface
    static var surfaceBase: Color     { MuxiTokens.Colors.surfaceBase }
    static var surfaceDefault: Color  { MuxiTokens.Colors.surfaceDefault }
    static var surfaceRaised: Color   { MuxiTokens.Colors.surfaceRaised }
    static var surfaceElevated: Color { MuxiTokens.Colors.surfaceElevated }

    // Accent
    static var accentDefault: Color   { MuxiTokens.Colors.accentDefault }
    static var accentBright: Color    { MuxiTokens.Colors.accentBright }
    static var accentSubtle: Color    { MuxiTokens.Colors.accentSubtle }
    static var accentMuted: Color     { MuxiTokens.Colors.accentMuted }

    // Text
    static var textPrimary: Color     { MuxiTokens.Colors.textPrimary }
    static var textSecondary: Color   { MuxiTokens.Colors.textSecondary }
    static var textTertiary: Color    { MuxiTokens.Colors.textTertiary }
    static var textInverse: Color     { MuxiTokens.Colors.textInverse }

    // Border
    static var borderDefault: Color   { MuxiTokens.Colors.borderDefault }
    static var borderStrong: Color    { MuxiTokens.Colors.borderStrong }
    static var borderAccent: Color    { MuxiTokens.Colors.borderAccent }

    // Status
    static var statusError: Color     { MuxiTokens.Colors.error }
    static var statusSuccess: Color   { MuxiTokens.Colors.success }
    static var statusWarning: Color   { MuxiTokens.Colors.warning }
    static var statusInfo: Color      { MuxiTokens.Colors.info }
}

// MARK: - EdgeInsets Constants

extension EdgeInsets {
    /// Toolbar content padding
    static let toolbar = EdgeInsets(
        top: MuxiTokens.Spacing.xs,
        leading: MuxiTokens.Spacing.sm,
        bottom: MuxiTokens.Spacing.xs,
        trailing: MuxiTokens.Spacing.sm
    )

    /// Card-style container padding
    static let card = EdgeInsets(
        top: MuxiTokens.Spacing.md,
        leading: MuxiTokens.Spacing.lg,
        bottom: MuxiTokens.Spacing.md,
        trailing: MuxiTokens.Spacing.lg
    )

    /// Screen-level content padding
    static let screenContent = EdgeInsets(
        top: MuxiTokens.Spacing.md,
        leading: MuxiTokens.Spacing.lg,
        bottom: MuxiTokens.Spacing.lg,
        trailing: MuxiTokens.Spacing.lg
    )

    /// List row padding
    static let listRow = EdgeInsets(
        top: MuxiTokens.Spacing.sm,
        leading: MuxiTokens.Spacing.lg,
        bottom: MuxiTokens.Spacing.sm,
        trailing: MuxiTokens.Spacing.lg
    )
}

// MARK: - Color Helpers

extension Color {
    /// Extract approximate RGB components (for testing)
    var rgbComponents: (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b)
    }
}
