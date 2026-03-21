import SwiftUI
import MetalKit

/// A single terminal pane rendered with Metal.
///
/// Wraps an ``MTKView`` and ``TerminalRenderer`` via `UIViewRepresentable`.
/// The ``TerminalTextOverlay`` subview serves as the sole first responder
/// for both keyboard input and text selection.
struct TerminalView: UIViewRepresentable {
    let buffer: TerminalBuffer
    let theme: Theme
    var onPaste: ((String) -> Void)?
    var fontSize: CGFloat = 14
    var isFocused: Bool = true

    // Scrollback
    var scrollbackBuffer: TerminalBuffer?
    var scrollOffset: Int = 0
    var onScrollOffsetChanged: ((Int) -> Void)?

    // Keyboard input (forwarded to overlay)
    var onText: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onSpecialKey: ((SpecialKey) -> Void)?
    var onRawData: ((Data) -> Void)?

    // Keyboard state
    var isKeyboardActive: Bool = false

    // MARK: - UIViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(
            buffer: buffer, theme: theme,
            onPaste: onPaste,
            onScrollOffsetChanged: onScrollOffsetChanged
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
        let font = UIFont(name: "Sarasa Term K Nerd Font", size: fontSize)
            ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        if let renderer = TerminalRenderer(device: device, font: font, theme: theme, scale: mtkView.contentScaleFactor) {
            renderer.buffer = buffer
            mtkView.delegate = renderer
            context.coordinator.renderer = renderer
            context.coordinator.mtkView = mtkView
            context.coordinator.cellHeight = renderer.cellHeight
            context.coordinator.cellWidth = renderer.cellWidth
            context.coordinator.currentFontSize = fontSize

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

        // Terminal overlay — sole first responder for input + selection.
        let overlay = TerminalTextOverlay(frame: mtkView.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.buffer = buffer
        overlay.cellWidth = coordinator.cellWidth
        overlay.cellHeight = coordinator.cellHeight
        overlay.onSelectionChanged = { [weak coordinator] range in
            coordinator?.renderer?.selectionRange = range
            coordinator?.requestRedraw()
        }
        overlay.onPaste = onPaste
        overlay.onText = onText
        overlay.onDelete = onDelete
        overlay.onSpecialKey = onSpecialKey
        overlay.onRawData = onRawData
        mtkView.addSubview(overlay)
        coordinator.textOverlay = overlay

        // Pan gesture for scrollback — delegate allows simultaneous recognition
        // with UITextInteraction's own gestures (selection handles/loupe).
        let pan = UIPanGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.delegate = coordinator
        overlay.addGestureRecognizer(pan)

        return mtkView
    }

    func updateUIView(_ mtkView: MTKView, context: Context) {
        // Update coordinator references in case they changed (e.g. after reconnect)
        context.coordinator.onPaste = onPaste

        // Update scrollback state on renderer.
        let offsetChanged = context.coordinator.renderer?.scrollOffset != scrollOffset
        context.coordinator.renderer?.scrollbackBuffer = scrollbackBuffer
        context.coordinator.renderer?.scrollOffset = scrollOffset
        context.coordinator.onScrollOffsetChanged = onScrollOffsetChanged

        if offsetChanged {
            context.coordinator.requestRedraw()
        }

        let bufferChanged = context.coordinator.renderer?.buffer !== buffer
        context.coordinator.renderer?.buffer = buffer
        context.coordinator.buffer = buffer

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

        // Update font if size changed.
        if context.coordinator.currentFontSize != fontSize {
            context.coordinator.currentFontSize = fontSize
            let newFont = UIFont(name: "Sarasa Term K Nerd Font", size: fontSize)
                ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            context.coordinator.renderer?.updateFont(newFont)
            context.coordinator.cellHeight = context.coordinator.renderer?.cellHeight ?? 0
            context.coordinator.cellWidth = context.coordinator.renderer?.cellWidth ?? 0
            context.coordinator.requestRedraw()
        }

        // Update focus state.
        context.coordinator.renderer?.isFocused = isFocused

        // Update atlas scale if contentScaleFactor changed (e.g. moved between displays).
        if let renderer = context.coordinator.renderer,
           renderer.currentScale != mtkView.contentScaleFactor {
            renderer.updateScale(mtkView.contentScaleFactor)
            context.coordinator.requestRedraw()
        }

        // Sync overlay state.
        let overlay = context.coordinator.textOverlay
        overlay?.buffer = buffer
        overlay?.scrollbackBuffer = scrollbackBuffer
        overlay?.scrollOffset = scrollOffset
        overlay?.cellWidth = context.coordinator.cellWidth
        overlay?.cellHeight = context.coordinator.cellHeight
        overlay?.onPaste = onPaste
        overlay?.onText = onText
        overlay?.onDelete = onDelete
        overlay?.onSpecialKey = onSpecialKey
        overlay?.onRawData = onRawData

        // Manage keyboard (overlay first responder) state.
        if let overlay, isKeyboardActive != overlay.isFirstResponder {
            if isKeyboardActive {
                overlay.activate()
            } else {
                overlay.deactivate()
            }
        }
    }

    // MARK: - Coordinator

    /// Keeps strong references to the renderer and manages scrollback
    /// pan gestures.
    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var buffer: TerminalBuffer
        var renderer: TerminalRenderer?
        weak var mtkView: MTKView?
        var currentTheme: Theme
        var onPaste: ((String) -> Void)?
        var onScrollOffsetChanged: ((Int) -> Void)?
        var cellHeight: CGFloat = 0
        var currentFontSize: CGFloat = 14
        var cellWidth: CGFloat = 0
        var textOverlay: TerminalTextOverlay?
        private var accumulatedPanDelta: CGFloat = 0

        init(buffer: TerminalBuffer, theme: Theme,
             onPaste: ((String) -> Void)?,
             onScrollOffsetChanged: ((Int) -> Void)?) {
            self.buffer = buffer
            self.currentTheme = theme
            self.onPaste = onPaste
            self.onScrollOffsetChanged = onScrollOffsetChanged
        }

        /// Request a redraw of the terminal view. Call this after feeding
        /// new data to the buffer.
        func requestRedraw() {
            renderer?.needsRedraw = true
            mtkView?.setNeedsDisplay()
        }

        // MARK: - Scroll

        // Allow scroll pan to coexist with UITextInteraction's selection gestures.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

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
    }
}
