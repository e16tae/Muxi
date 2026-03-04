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
    var onPaste: ((String) -> Void)?

    // Scrollback
    var scrollbackBuffer: TerminalBuffer?
    var scrollOffset: Int = 0
    var onScrollOffsetChanged: ((Int) -> Void)?
    var onScrollbackNeeded: (() -> Void)?

    // MARK: - UIViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(
            buffer: buffer, channel: channel, theme: theme,
            onPaste: onPaste,
            onScrollOffsetChanged: onScrollOffsetChanged,
            onScrollbackNeeded: onScrollbackNeeded
        )
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

        // Prefer bundled Sarasa Term K Nerd Font for Korean + CJK + icon coverage.
        // Font family name registered in the TTF: "Sarasa Term K Nerd Font"
        // PostScript name: "Sarasa-Term-K-Nerd-Font-Regular"
        // Download font: ./scripts/download-fonts.sh
        let font = UIFont(name: "Sarasa Term K Nerd Font", size: 14)
            ?? UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)

        if let renderer = TerminalRenderer(device: device, font: font, theme: theme) {
            renderer.buffer = buffer
            mtkView.delegate = renderer
            context.coordinator.renderer = renderer
            context.coordinator.mtkView = mtkView
            context.coordinator.cellHeight = renderer.cellHeight

            // Set the clear color to match the theme background.
            let bg = theme.background
            mtkView.clearColor = MTLClearColor(
                red: Double(bg.r) / 255,
                green: Double(bg.g) / 255,
                blue: Double(bg.b) / 255,
                alpha: 1
            )
        }

        // Redraw the Metal view whenever the buffer receives new data.
        let coordinator = context.coordinator
        buffer.onUpdate = { [weak coordinator] in
            coordinator?.requestRedraw()
        }

        // Trigger initial draw.
        mtkView.setNeedsDisplay()

        let editMenuInteraction = UIEditMenuInteraction(delegate: context.coordinator)
        mtkView.addInteraction(editMenuInteraction)
        context.coordinator.editMenuInteraction = editMenuInteraction

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        mtkView.addGestureRecognizer(longPress)

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        mtkView.addGestureRecognizer(pan)

        return mtkView
    }

    func updateUIView(_ mtkView: MTKView, context: Context) {
        // Update coordinator references in case they changed (e.g. after reconnect)
        context.coordinator.channel = channel
        context.coordinator.onPaste = onPaste

        // Update scrollback state on renderer.
        context.coordinator.renderer?.scrollbackBuffer = scrollbackBuffer
        context.coordinator.renderer?.scrollOffset = scrollOffset
        context.coordinator.onScrollOffsetChanged = onScrollOffsetChanged
        context.coordinator.onScrollbackNeeded = onScrollbackNeeded

        if context.coordinator.renderer?.scrollOffset != scrollOffset {
            context.coordinator.requestRedraw()
        }

        let bufferChanged = context.coordinator.renderer?.buffer !== buffer
        context.coordinator.renderer?.buffer = buffer

        // Re-wire the update callback when the buffer instance changes.
        if bufferChanged {
            let coordinator = context.coordinator
            buffer.onUpdate = { [weak coordinator] in
                coordinator?.requestRedraw()
            }
        }

        // Update theme if changed (e.g. user selected a new theme in settings).
        if context.coordinator.currentTheme.id != theme.id {
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
    /// provides methods for sending keyboard input and handling paste via
    /// the system edit menu.
    class Coordinator: NSObject, UIEditMenuInteractionDelegate {
        let buffer: TerminalBuffer
        var channel: SSHChannel?
        var renderer: TerminalRenderer?
        weak var mtkView: MTKView?
        var currentTheme: Theme
        var onPaste: ((String) -> Void)?
        var editMenuInteraction: UIEditMenuInteraction?
        var onScrollOffsetChanged: ((Int) -> Void)?
        var onScrollbackNeeded: (() -> Void)?
        var cellHeight: CGFloat = 0
        private var accumulatedPanDelta: CGFloat = 0

        init(buffer: TerminalBuffer, channel: SSHChannel?, theme: Theme,
             onPaste: ((String) -> Void)?,
             onScrollOffsetChanged: ((Int) -> Void)?,
             onScrollbackNeeded: (() -> Void)?) {
            self.buffer = buffer
            self.channel = channel
            self.currentTheme = theme
            self.onPaste = onPaste
            self.onScrollOffsetChanged = onScrollOffsetChanged
            self.onScrollbackNeeded = onScrollbackNeeded
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

        // MARK: - Scroll

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard cellHeight > 0 else { return }

            switch gesture.state {
            case .changed:
                let translation = gesture.translation(in: gesture.view)
                gesture.setTranslation(.zero, in: gesture.view)

                // Negative y = scrolling up (viewing history).
                accumulatedPanDelta += -translation.y
                let linesDelta = Int(accumulatedPanDelta / cellHeight)

                if linesDelta != 0 {
                    accumulatedPanDelta -= CGFloat(linesDelta) * cellHeight
                    onScrollOffsetChanged?(linesDelta)
                }

            case .ended, .cancelled:
                accumulatedPanDelta = 0

            default:
                break
            }
        }

        // MARK: - Paste

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let interaction = editMenuInteraction,
                  let view = gesture.view else { return }
            let location = gesture.location(in: view)
            let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: location)
            interaction.presentEditMenu(with: config)
        }

        func editMenuInteraction(
            _ interaction: UIEditMenuInteraction,
            menuFor configuration: UIEditMenuConfiguration,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard UIPasteboard.general.hasStrings else { return nil }
            let paste = UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                guard let text = UIPasteboard.general.string else { return }
                self?.onPaste?(text)
            }
            return UIMenu(children: [paste])
        }
    }
}
