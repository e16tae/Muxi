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
    var onPaste: ((String) -> Void)?
    var fontSize: CGFloat = 14

    // Scrollback
    var scrollbackBuffer: TerminalBuffer?
    var scrollOffset: Int = 0
    var onScrollOffsetChanged: ((Int) -> Void)?

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

        if let renderer = TerminalRenderer(device: device, font: font, theme: theme) {
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

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.require(toFail: pan)
        mtkView.addGestureRecognizer(tap)

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
    }

    // MARK: - Coordinator

    /// Keeps strong references to the renderer and SSH channel, and
    /// provides methods for sending keyboard input and handling paste via
    /// the system edit menu.
    class Coordinator: NSObject, UIEditMenuInteractionDelegate {
        var buffer: TerminalBuffer
        var renderer: TerminalRenderer?
        weak var mtkView: MTKView?
        var currentTheme: Theme
        var onPaste: ((String) -> Void)?
        var editMenuInteraction: UIEditMenuInteraction?
        var onScrollOffsetChanged: ((Int) -> Void)?
        var cellHeight: CGFloat = 0
        var currentFontSize: CGFloat = 14
        /// Selection anchor (where long press started), in screen-space row/col.
        var selectionStart: (row: Int, col: Int)?
        /// Selection end (current drag position), in screen-space row/col.
        var selectionEnd: (row: Int, col: Int)?
        /// Cached cell width for coordinate mapping.
        var cellWidth: CGFloat = 0
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

        /// Convert a touch point (in the MTKView's coordinate space) to
        /// a terminal grid position (row, col).
        func gridPosition(from point: CGPoint) -> (row: Int, col: Int) {
            guard cellWidth > 0, cellHeight > 0 else { return (0, 0) }
            let col = max(0, min(Int(point.x / cellWidth), buffer.cols - 1))
            let row = max(0, min(Int(point.y / cellHeight), buffer.rows - 1))
            return (row, col)
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

        // MARK: - Selection & Paste

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view else { return }
            let point = gesture.location(in: view)
            let pos = gridPosition(from: point)

            switch gesture.state {
            case .began:
                // v1: selection only works in live mode (not scrollback).
                guard renderer?.scrollOffset == 0 else { return }
                // Start selection at the long-press anchor.
                selectionStart = pos
                selectionEnd = pos
                updateRendererSelection()

            case .changed:
                guard selectionStart != nil else { return }
                // Extend selection as finger drags.
                selectionEnd = pos
                updateRendererSelection()

            case .ended:
                guard selectionStart != nil else { return }
                // Show edit menu at the touch location.
                selectionEnd = pos
                updateRendererSelection()
                if let interaction = editMenuInteraction {
                    let config = UIEditMenuConfiguration(
                        identifier: nil, sourcePoint: point
                    )
                    interaction.presentEditMenu(with: config)
                }

            case .cancelled, .failed:
                clearSelection()

            default:
                break
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            if selectionStart != nil {
                clearSelection()
            }
        }

        private func clearSelection() {
            selectionStart = nil
            selectionEnd = nil
            renderer?.selectionRange = nil
            requestRedraw()
        }

        private func updateRendererSelection() {
            guard let start = selectionStart, let end = selectionEnd else {
                renderer?.selectionRange = nil
                return
            }
            renderer?.selectionRange = (start: start, end: end)
            requestRedraw()
        }

        func editMenuInteraction(
            _ interaction: UIEditMenuInteraction,
            menuFor configuration: UIEditMenuConfiguration,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            var actions: [UIAction] = []

            // Copy action — available when text is selected.
            if let start = selectionStart, let end = selectionEnd {
                let copy = UIAction(
                    title: "Copy",
                    image: UIImage(systemName: "doc.on.doc")
                ) { [weak self] _ in
                    let text = self?.buffer.text(from: start, to: end) ?? ""
                    UIPasteboard.general.string = text
                    self?.clearSelection()
                }
                actions.append(copy)
            }

            // Paste action — available when clipboard has text.
            if UIPasteboard.general.hasStrings {
                let paste = UIAction(
                    title: "Paste",
                    image: UIImage(systemName: "doc.on.clipboard")
                ) { [weak self] _ in
                    guard let text = UIPasteboard.general.string else { return }
                    self?.onPaste?(text)
                }
                actions.append(paste)
            }

            return actions.isEmpty ? nil : UIMenu(children: actions)
        }
    }
}
