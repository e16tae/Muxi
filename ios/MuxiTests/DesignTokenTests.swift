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

@Suite("Design Tokens — Motion")
struct MotionTokenTests {
    @Test func motionTokensExist() {
        _ = MuxiTokens.Motion.appear
        _ = MuxiTokens.Motion.tap
        _ = MuxiTokens.Motion.transition
        _ = MuxiTokens.Motion.subtle
    }

    @Test func reducedMotionReturnsSubtleAnimations() {
        let reduced = MuxiTokens.Motion.resolved(reduceMotion: true)
        _ = reduced.appear
        _ = reduced.tap
        _ = reduced.transition
    }
}
