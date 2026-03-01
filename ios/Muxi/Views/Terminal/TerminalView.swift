import SwiftUI
import MetalKit

/// A single terminal pane rendered with Metal.
///
/// Wraps an ``MTKView`` and ``TerminalRenderer`` via `UIViewRepresentable`.
/// The Metal renderer is stored in the ``Coordinator`` to maintain a strong
/// reference for the lifetime of the view.
struct TerminalView: UIViewRepresentable {
    let buffer: TerminalBuffer
    let theme: Theme
    var channel: SSHChannel?

    // MARK: - UIViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(buffer: buffer, channel: channel, theme: theme)
    }

    func makeUIView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            // Graceful fallback: return a blank MTKView when Metal is unavailable
            // (e.g. on Intel-based iOS Simulator)
            let fallback = MTKView(frame: .zero)
            fallback.isPaused = true
            return fallback
        }

        let mtkView = MTKView(frame: .zero, device: device)
        // On-demand rendering: the view only redraws when explicitly
        // requested via setNeedsDisplay(), saving battery when idle.
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true

        // Prefer bundled Sarasa Mono SC Nerd Font for CJK + icon coverage.
        // NOTE: The font name below must match the PostScript name or family
        // name registered in the TTF. Adjust after verifying with the actual
        // font file (run: scripts/download-fonts.sh, then check in Font Book).
        let font = UIFont(name: "Sarasa Mono SC Nerd Font", size: 14)
            ?? UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)

        if let renderer = TerminalRenderer(device: device, font: font, theme: theme) {
            renderer.buffer = buffer
            mtkView.delegate = renderer
            context.coordinator.renderer = renderer
            context.coordinator.mtkView = mtkView

            // Set the clear color to match the theme background.
            let bg = theme.background
            mtkView.clearColor = MTLClearColor(
                red: Double(bg.r) / 255,
                green: Double(bg.g) / 255,
                blue: Double(bg.b) / 255,
                alpha: 1
            )
        }

        // Trigger initial draw.
        mtkView.setNeedsDisplay()
        return mtkView
    }

    func updateUIView(_ mtkView: MTKView, context: Context) {
        // Update coordinator references in case they changed (e.g. after reconnect)
        context.coordinator.channel = channel
        let bufferChanged = context.coordinator.renderer?.buffer !== buffer
        context.coordinator.renderer?.buffer = buffer

        // Update theme if changed (e.g. user selected a new theme in settings).
        if context.coordinator.currentTheme != theme {
            context.coordinator.currentTheme = theme
            context.coordinator.renderer?.updateTheme(theme)
            let bg = theme.background
            mtkView.clearColor = MTLClearColor(
                red: Double(bg.r) / 255,
                green: Double(bg.g) / 255,
                blue: Double(bg.b) / 255,
                alpha: 1
            )
            context.coordinator.requestRedraw()
        }

        if bufferChanged {
            context.coordinator.requestRedraw()
        }
    }

    // MARK: - Coordinator

    /// Keeps strong references to the renderer and SSH channel, and
    /// provides a method for sending keyboard input to the remote.
    class Coordinator: NSObject {
        let buffer: TerminalBuffer
        var channel: SSHChannel?
        var renderer: TerminalRenderer?
        weak var mtkView: MTKView?
        var currentTheme: Theme

        init(buffer: TerminalBuffer, channel: SSHChannel?, theme: Theme) {
            self.buffer = buffer
            self.channel = channel
            self.currentTheme = theme
        }

        /// Send text input to the SSH channel.
        func sendInput(_ text: String) {
            guard let data = text.data(using: .utf8) else { return }
            try? channel?.write(data)
        }

        /// Request a redraw of the terminal view. Call this after feeding
        /// new data to the buffer.
        func requestRedraw() {
            renderer?.needsRedraw = true
            mtkView?.setNeedsDisplay()
        }
    }
}
