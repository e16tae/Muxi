import SwiftUI
import Testing
@testable import Muxi

@Suite("Design Tokens — Colors")
struct ColorTokenTests {
    @Test func surfaceLayersHaveIncreasingLightness() {
        let surfaces = [
            MuxiTokens.Colors.surfaceBase,
            MuxiTokens.Colors.surfaceDefault,
            MuxiTokens.Colors.surfaceRaised,
            MuxiTokens.Colors.surfaceElevated
        ]
        for i in 0..<surfaces.count - 1 {
            let (_, _, bCurrent) = surfaces[i].rgbComponents
            let (_, _, bNext) = surfaces[i + 1].rgbComponents
            #expect(bNext > bCurrent, "Surface layer \(i+1) should be lighter than \(i)")
        }
    }

    @Test func accentColorIsDefined() {
        let accent = MuxiTokens.Colors.accentDefault
        let (r, g, b) = accent.rgbComponents
        #expect(r > 0.6 && r < 0.8)
        #expect(g > 0.5 && g < 0.75)
        #expect(b > 0.75 && b < 0.95)
    }

    @Test func semanticColorsAreDefined() {
        _ = MuxiTokens.Colors.error
        _ = MuxiTokens.Colors.success
        _ = MuxiTokens.Colors.warning
        _ = MuxiTokens.Colors.info
    }
}

@Suite("Design Tokens — Spacing")
struct SpacingTokenTests {
    @Test func allSpacingsAreMultiplesOf4() {
        let spacings: [CGFloat] = [
            MuxiTokens.Spacing.xs,
            MuxiTokens.Spacing.sm,
            MuxiTokens.Spacing.md,
            MuxiTokens.Spacing.lg,
            MuxiTokens.Spacing.xl,
            MuxiTokens.Spacing.xxl
        ]
        for spacing in spacings {
            #expect(spacing.truncatingRemainder(dividingBy: 4) == 0,
                    "\(spacing) is not a multiple of 4")
        }
    }

    @Test func spacingsAreStrictlyIncreasing() {
        let spacings: [CGFloat] = [
            MuxiTokens.Spacing.xs,
            MuxiTokens.Spacing.sm,
            MuxiTokens.Spacing.md,
            MuxiTokens.Spacing.lg,
            MuxiTokens.Spacing.xl,
            MuxiTokens.Spacing.xxl
        ]
        for i in 0..<spacings.count - 1 {
            #expect(spacings[i] < spacings[i + 1])
        }
    }
}

@Suite("Design Tokens — Radius")
struct RadiusTokenTests {
    @Test func radiiAreStrictlyIncreasing() {
        #expect(MuxiTokens.Radius.sm < MuxiTokens.Radius.md)
        #expect(MuxiTokens.Radius.md < MuxiTokens.Radius.lg)
        #expect(MuxiTokens.Radius.lg < MuxiTokens.Radius.full)
    }

    @Test func noZeroRadius() {
        #expect(MuxiTokens.Radius.sm >= 8)
    }
}

@Suite("Design Tokens — Typography")
struct TypographyTokenTests {
    @Test func allTypographyTokensExist() {
        _ = MuxiTokens.Typography.largeTitle
        _ = MuxiTokens.Typography.title
        _ = MuxiTokens.Typography.body
        _ = MuxiTokens.Typography.caption
        _ = MuxiTokens.Typography.label
        _ = MuxiTokens.Typography.pill
        _ = MuxiTokens.Typography.monoCaption
    }
}

@Suite("Design Tokens — Motion")
struct MotionTokenTests {
    @Test func motionTokensExist() {
        _ = MuxiTokens.Motion.appear
        _ = MuxiTokens.Motion.tap
        _ = MuxiTokens.Motion.transition
        _ = MuxiTokens.Motion.subtle
    }

    @Test func directionalMotionTokensExist() {
        _ = MuxiTokens.Motion.entrance
        _ = MuxiTokens.Motion.exit
    }

    @Test func weightMotionTokensExist() {
        _ = MuxiTokens.Motion.heavy
        _ = MuxiTokens.Motion.light
    }

    @Test func staggerDelayIncreases() {
        // Each successive child should have a longer delay
        let delay0 = MuxiTokens.Motion.staggerInterval * 0
        let delay1 = MuxiTokens.Motion.staggerInterval * 1
        let delay2 = MuxiTokens.Motion.staggerInterval * 2
        #expect(delay0 < delay1)
        #expect(delay1 < delay2)
    }

    @Test func resolvedMotionBothPaths() {
        let reduced = MuxiTokens.Motion.resolved(reduceMotion: true)
        let normal = MuxiTokens.Motion.resolved(reduceMotion: false)

        // Verify all properties resolve without crashing
        _ = reduced.appear
        _ = reduced.tap
        _ = reduced.transition
        _ = reduced.subtle
        _ = reduced.entrance
        _ = reduced.exit
        _ = reduced.heavy
        _ = reduced.light
        _ = normal.appear
        _ = normal.tap
        _ = normal.transition
        _ = normal.subtle
        _ = normal.entrance
        _ = normal.exit
        _ = normal.heavy
        _ = normal.light
    }
}

@Suite("Design Tokens — Accessibility")
struct AccessibilityTokenTests {
    @Test func minimumHitTargetIsAppleCompliant() {
        #expect(MuxiTokens.Accessibility.minimumHitTarget >= 44)
    }
}

@Suite("Design Tokens — ShapeStyle Dot-Syntax")
struct ShapeStyleTokenTests {
    @Test func dotSyntaxColorsMatchMuxiTokensColors() {
        // Verify dot-syntax returns the same colors as MuxiTokens.Colors
        let dotSurface: Color = .surfaceBase
        let tokenSurface = MuxiTokens.Colors.surfaceBase
        let (dr, dg, db) = dotSurface.rgbComponents
        let (tr, tg, tb) = tokenSurface.rgbComponents
        #expect(abs(dr - tr) < 0.01)
        #expect(abs(dg - tg) < 0.01)
        #expect(abs(db - tb) < 0.01)
    }
}
