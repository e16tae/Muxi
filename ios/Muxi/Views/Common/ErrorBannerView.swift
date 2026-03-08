import SwiftUI

// MARK: - BannerStyle

/// Visual style for an ``ErrorBannerView``.
enum BannerStyle {
    case error
    case warning
    case info

    /// Tint color associated with this style.
    var color: Color {
        switch self {
        case .error:   return MuxiTokens.Colors.error
        case .warning: return MuxiTokens.Colors.warning
        case .info:    return MuxiTokens.Colors.info
        }
    }

    /// SF Symbol name for the leading icon.
    var icon: String {
        switch self {
        case .error:   return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .info:    return "info.circle.fill"
        }
    }

    /// Accessible description for VoiceOver.
    var accessibilityLabel: String {
        switch self {
        case .error:   return "Error"
        case .warning: return "Warning"
        case .info:    return "Information"
        }
    }
}

// MARK: - ErrorBannerView

/// A compact, dismissible banner that slides in from the top of the screen.
///
/// Usage:
/// ```swift
/// ErrorBannerView(
///     message: "SSH connection failed: Server unreachable",
///     style: .error,
///     onDismiss: { /* hide banner */ },
///     onRetry: { /* retry connection */ }
/// )
/// ```
struct ErrorBannerView: View {
    let message: String
    let style: BannerStyle
    var onDismiss: (() -> Void)?
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: MuxiTokens.Spacing.sm) {
            HStack(alignment: .top, spacing: MuxiTokens.Spacing.md) {
                // Leading icon
                Image(systemName: style.icon)
                    .foregroundStyle(style.color)
                    .font(MuxiTokens.Typography.body)
                    .accessibilityHidden(true)

                // Message text
                Text(message)
                    .font(MuxiTokens.Typography.label)
                    .foregroundStyle(MuxiTokens.Colors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Dismiss button
                if let onDismiss {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(MuxiTokens.Typography.caption).fontWeight(.semibold)
                            .foregroundStyle(MuxiTokens.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
            }

            // Optional retry button
            if let onRetry {
                Button {
                    onRetry()
                } label: {
                    Text("Retry")
                        .font(MuxiTokens.Typography.label).fontWeight(.medium)
                        .foregroundStyle(style.color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry")
            }
        }
        .padding(MuxiTokens.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MuxiTokens.Radius.md, style: .continuous)
                .fill(style.color.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MuxiTokens.Radius.md, style: .continuous)
                .strokeBorder(style.color.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, MuxiTokens.Spacing.lg)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(style.accessibilityLabel): \(message)")
    }
}

// MARK: - View Modifier for Banner Presentation

/// A view modifier that overlays an ``ErrorBannerView`` at the top of its
/// content, animating it in and out based on a boolean binding.
struct ErrorBannerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let message: String
    let style: BannerStyle
    var onDismiss: (() -> Void)?
    var onRetry: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if isPresented {
                ErrorBannerView(
                    message: message,
                    style: style,
                    onDismiss: {
                        withAnimation(MuxiTokens.Motion.resolved(reduceMotion: reduceMotion).subtle) {
                            isPresented = false
                        }
                        onDismiss?()
                    },
                    onRetry: onRetry
                )
                .padding(.top, MuxiTokens.Spacing.sm)
            }
        }
        .muxiAnimation(\.subtle, value: isPresented)
    }
}

extension View {
    /// Presents an ``ErrorBannerView`` at the top of this view.
    func errorBanner(
        isPresented: Binding<Bool>,
        message: String,
        style: BannerStyle = .error,
        onDismiss: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil
    ) -> some View {
        modifier(
            ErrorBannerModifier(
                isPresented: isPresented,
                message: message,
                style: style,
                onDismiss: onDismiss,
                onRetry: onRetry
            )
        )
    }
}

// MARK: - Previews

#Preview("Error Banner") {
    VStack {
        ErrorBannerView(
            message: "SSH connection failed: Server unreachable",
            style: .error,
            onDismiss: {},
            onRetry: {}
        )

        ErrorBannerView(
            message: "tmux version 1.6 detected. Version 1.8+ required.",
            style: .warning,
            onDismiss: {}
        )

        ErrorBannerView(
            message: "Reconnected to server successfully.",
            style: .info,
            onDismiss: {}
        )

        Spacer()
    }
    .padding(.top)
}
