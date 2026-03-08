import Foundation
import SwiftUI
import Testing

@testable import Muxi

// MARK: - BannerStyle Tests

@Suite("BannerStyle Tests")
struct BannerStyleTests {

    @Test("Error style has error color")
    func errorColor() {
        #expect(BannerStyle.error.color == MuxiTokens.Colors.error)
    }

    @Test("Warning style has warning color")
    func warningColor() {
        #expect(BannerStyle.warning.color == MuxiTokens.Colors.warning)
    }

    @Test("Info style has info color")
    func infoColor() {
        #expect(BannerStyle.info.color == MuxiTokens.Colors.info)
    }

    @Test("Error style uses exclamationmark.triangle.fill icon")
    func errorIcon() {
        #expect(BannerStyle.error.icon == "exclamationmark.triangle.fill")
    }

    @Test("Warning style uses exclamationmark.circle.fill icon")
    func warningIcon() {
        #expect(BannerStyle.warning.icon == "exclamationmark.circle.fill")
    }

    @Test("Info style uses info.circle.fill icon")
    func infoIcon() {
        #expect(BannerStyle.info.icon == "info.circle.fill")
    }

    @Test("Error style accessibility label is Error")
    func errorAccessibilityLabel() {
        #expect(BannerStyle.error.accessibilityLabel == "Error")
    }

    @Test("Warning style accessibility label is Warning")
    func warningAccessibilityLabel() {
        #expect(BannerStyle.warning.accessibilityLabel == "Warning")
    }

    @Test("Info style accessibility label is Information")
    func infoAccessibilityLabel() {
        #expect(BannerStyle.info.accessibilityLabel == "Information")
    }
}

// MARK: - ErrorBannerView Initialization Tests

@Suite("ErrorBannerView Tests")
struct ErrorBannerViewTests {

    @Test("Can be initialized with message and style only")
    func initMinimal() {
        let banner = ErrorBannerView(message: "Test error", style: .error)
        #expect(banner.message == "Test error")
        #expect(banner.onDismiss == nil)
        #expect(banner.onRetry == nil)
    }

    @Test("Can be initialized with all properties")
    func initFull() {
        var dismissCalled = false
        var retryCalled = false

        let banner = ErrorBannerView(
            message: "Connection lost",
            style: .warning,
            onDismiss: { dismissCalled = true },
            onRetry: { retryCalled = true }
        )

        #expect(banner.message == "Connection lost")
        banner.onDismiss?()
        banner.onRetry?()
        #expect(dismissCalled)
        #expect(retryCalled)
    }

    @Test("Error style is preserved")
    func stylePreserved() {
        let banner = ErrorBannerView(message: "test", style: .info)
        #expect(banner.style.color == MuxiTokens.Colors.info)
        #expect(banner.style.icon == "info.circle.fill")
    }
}

// MARK: - ReconnectingOverlay Tests

@Suite("ReconnectingOverlay Tests")
struct ReconnectingOverlayTests {

    @Test("Attempt text formats correctly for attempt 1 of 5")
    func attemptTextFirstAttempt() {
        let overlay = ReconnectingOverlay(attempt: 1, maxAttempts: 5)
        #expect(overlay.attemptText == "Attempt 1 of 5")
    }

    @Test("Attempt text formats correctly for attempt 3 of 10")
    func attemptTextMiddle() {
        let overlay = ReconnectingOverlay(attempt: 3, maxAttempts: 10)
        #expect(overlay.attemptText == "Attempt 3 of 10")
    }

    @Test("Attempt text formats correctly for final attempt")
    func attemptTextFinal() {
        let overlay = ReconnectingOverlay(attempt: 5, maxAttempts: 5)
        #expect(overlay.attemptText == "Attempt 5 of 5")
    }

    @Test("Can be initialized without cancel handler")
    func initWithoutCancel() {
        let overlay = ReconnectingOverlay(attempt: 1, maxAttempts: 3)
        #expect(overlay.onCancel == nil)
    }

    @Test("Cancel callback is invoked")
    func cancelCallback() {
        var cancelled = false
        let overlay = ReconnectingOverlay(
            attempt: 2,
            maxAttempts: 5,
            onCancel: { cancelled = true }
        )
        overlay.onCancel?()
        #expect(cancelled)
    }
}

// MARK: - TmuxInstallGuideView Tests

@Suite("TmuxInstallGuideView Tests")
struct TmuxInstallGuideViewTests {

    @Test("Minimum version is 1.8")
    func minimumVersion() {
        #expect(TmuxInstallGuideView.minimumVersion == "1.8")
    }

    @Test("Reason.notInstalled is equatable")
    func reasonNotInstalledEquatable() {
        #expect(TmuxInstallGuideView.Reason.notInstalled == .notInstalled)
    }

    @Test("Reason.versionTooOld is equatable with same version")
    func reasonVersionTooOldEquatable() {
        let a = TmuxInstallGuideView.Reason.versionTooOld(detected: "1.6")
        let b = TmuxInstallGuideView.Reason.versionTooOld(detected: "1.6")
        #expect(a == b)
    }

    @Test("Reason.versionTooOld differs for different versions")
    func reasonVersionTooOldDiffers() {
        let a = TmuxInstallGuideView.Reason.versionTooOld(detected: "1.6")
        let b = TmuxInstallGuideView.Reason.versionTooOld(detected: "1.7")
        #expect(a != b)
    }

    @Test("Reason.notInstalled differs from versionTooOld")
    func reasonDifferentCases() {
        let a = TmuxInstallGuideView.Reason.notInstalled
        let b = TmuxInstallGuideView.Reason.versionTooOld(detected: "1.6")
        #expect(a != b)
    }

    @Test("Can be initialized with notInstalled reason")
    func initNotInstalled() {
        let guide = TmuxInstallGuideView(
            reason: .notInstalled,
            serverName: "prod-server"
        )
        #expect(guide.serverName == "prod-server")
    }

    @Test("Can be initialized with versionTooOld reason")
    func initVersionTooOld() {
        let guide = TmuxInstallGuideView(
            reason: .versionTooOld(detected: "1.5"),
            serverName: "staging"
        )
        #expect(guide.serverName == "staging")
    }
}
