import SwiftUI
import CoreText
import os

/// The terminal session screen that combines all terminal-related components
/// into a single view: pane container, extended keyboard, quick action button,
/// and a detach toolbar button.
///
/// Displayed when ``ConnectionManager/state`` is `.attached(sessionName:)`.
struct TerminalSessionView: View {
    let connectionManager: ConnectionManager
    let sessionName: String
    let themeManager: ThemeManager

    private let logger = Logger(subsystem: "com.muxi.app", category: "TerminalSession")
    @State private var activePaneId: String?
    @State private var inputHandler = InputHandler()
    @State private var isKeyboardActive = false
    @State private var scrollbackState: [String: ScrollbackState] = [:]
    @State private var scrollbackCaches: [String: TerminalBuffer] = [:]

    /// Build pane info from ConnectionManager's live pane data.
    private var panes: [PaneContainerView.PaneInfo] {
        connectionManager.currentPanes.map { parsedPane in
            let paneId = "%\(parsedPane.paneId)"
            let buffer = connectionManager.paneBuffers[paneId]
                ?? TerminalBuffer(cols: parsedPane.width, rows: parsedPane.height)
            return PaneContainerView.PaneInfo(
                id: paneId,
                buffer: buffer,
                channel: connectionManager.activeChannel,
                x: parsedPane.x,
                y: parsedPane.y,
                width: parsedPane.width,
                height: parsedPane.height
            )
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if panes.isEmpty {
                    placeholderView
                } else {
                    GeometryReader { geometry in
                        PaneContainerView(
                            panes: panes,
                            theme: themeManager.currentTheme,
                            fontSize: themeManager.fontSize,
                            activePaneId: $activePaneId,
                            onPaneTapped: { _ in
                                isKeyboardActive = true
                            },
                            onPaste: { text in
                                pasteToActivePane(text)
                            },
                            scrollbackBuffer: activePaneId.flatMap { scrollbackCaches[$0] },
                            scrollbackOffset: activePaneId.flatMap {
                                if case .scrolling(let offset, _) = scrollbackState[$0] {
                                    return offset
                                }
                                return nil
                            } ?? 0,
                            onScrollOffsetChanged: { paneId, delta in
                                handleScrollDelta(paneId: paneId, delta: delta)
                            },
                            showNewOutputIndicator: activePaneId.map { connectionManager.paneHasNewOutput.contains($0) } ?? false,
                            onReturnToLive: { paneId in
                                returnToLive(paneId: paneId)
                            }
                        )
                        .onChange(of: geometry.size) { _, newSize in
                            updateTerminalSize(newSize)
                        }
                        .onChange(of: themeManager.fontSize) { _, _ in
                            updateTerminalSize(geometry.size)
                        }
                        .onAppear {
                            updateTerminalSize(geometry.size)
                        }
                    }
                }

                TerminalInputView(
                    onText: { text in
                        for char in text {
                            let data = inputHandler.data(for: char)
                            sendToActivePane(data)
                        }
                    },
                    onDelete: {
                        sendToActivePane(Data([0x7F]))
                    },
                    onSpecialKey: { key in
                        let data = inputHandler.data(for: key)
                        sendToActivePane(data)
                    },
                    onRawData: { data in
                        sendToActivePane(data)
                    },
                    isActive: $isKeyboardActive
                )
                .frame(width: 1, height: 1)
                .opacity(0)

                ExtendedKeyboardView(
                    theme: themeManager.currentTheme,
                    inputHandler: inputHandler,
                    onInput: { data in
                        sendToActivePane(data)
                    },
                    onDismissKeyboard: {
                        isKeyboardActive = false
                    }
                )
            }
            .overlay(alignment: .bottomTrailing) {
                QuickActionButton(onAction: { command in
                    sendTmuxCommand(command)
                })
                .padding(.trailing, 16)
                .padding(.bottom, 60)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Detach") {
                        connectionManager.detach()
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(sessionName)
                        .font(.headline)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: panes) { _, newPanes in
            if activePaneId == nil, let first = newPanes.first {
                activePaneId = first.id
                isKeyboardActive = true
            }
        }
    }

    // MARK: - Terminal Sizing

    /// Calculate terminal columns and rows from the available view size
    /// and notify tmux so TUI apps can adapt.
    private func updateTerminalSize(_ size: CGSize) {
        let (cellW, cellH) = Self.terminalCellSize(fontSize: themeManager.fontSize)
        guard cellW > 0, cellH > 0 else { return }

        let cols = max(Int(size.width / cellW), 1)
        let rows = max(Int(size.height / cellH), 1)
        connectionManager.resizeTerminal(cols: cols, rows: rows)

        // Exit scrollback on resize — terminal content reflows.
        let scrolledPanes = scrollbackState.filter { $0.value != .live }.map(\.key)
        for paneId in scrolledPanes {
            returnToLive(paneId: paneId)
        }
    }

    /// Calculate monospace cell dimensions using the same font the
    /// renderer uses. This avoids coupling the view to the renderer.
    static func terminalCellSize(fontSize: CGFloat = 14) -> (width: CGFloat, height: CGFloat) {
        let font = UIFont(name: "Sarasa Term K Nerd Font", size: fontSize)
            ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let ctFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        var glyph = CTFontGetGlyphWithName(ctFont, "M" as CFString)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
        let w = ceil(advance.width)
        let h = ceil(CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont))
        return (w, h)
    }

    // MARK: - Placeholder

    private var placeholderView: some View {
        VStack {
            Spacer()
            ProgressView()
            Text("Attaching to \(sessionName)...")
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Input Handling

    /// Send raw data to the active pane via tmux control mode.
    private func sendToActivePane(_ data: Data) {
        guard let paneId = activePaneId else { return }

        let hexKeys = data.map { String(format: "0x%02x", $0) }.joined(separator: " ")
        let command = "send-keys -t \(paneId.shellEscaped()) \(hexKeys)\n"
        Task {
            do {
                try await connectionManager.sshServiceForWrites.writeToChannel(Data(command.utf8))
            } catch {
                logger.error("Failed to send keys to pane \(paneId): \(error.localizedDescription)")
            }
        }
    }

    /// Send a tmux command through the control mode channel.
    private func sendTmuxCommand(_ command: String) {
        let fullCommand = command + "\n"
        Task {
            do {
                try await connectionManager.sshServiceForWrites.writeToChannel(Data(fullCommand.utf8))
            } catch {
                logger.error("Failed to send tmux command: \(error.localizedDescription)")
            }
        }
    }

    /// Paste clipboard text to the active pane via tmux set-buffer + paste-buffer.
    /// Uses a named buffer ("ios_paste") to avoid clobbering the user's global
    /// paste buffer. tmux automatically wraps with bracketed paste sequences
    /// if the pane's application has enabled bracketed paste mode.
    private func pasteToActivePane(_ text: String) {
        guard let paneId = activePaneId, !text.isEmpty else { return }
        let escaped = text.tmuxQuoted()
        let command = "set-buffer -b ios_paste -- \(escaped)\npaste-buffer -b ios_paste -t \(paneId.shellEscaped()) -d\n"
        Task {
            do {
                try await connectionManager.sshServiceForWrites.writeToChannel(Data(command.utf8))
            } catch {
                logger.error("Failed to paste to pane \(paneId): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Scrollback

    private func handleScrollDelta(paneId: String, delta: Int) {
        let currentState = scrollbackState[paneId] ?? .live

        switch currentState {
        case .live where delta > 0:
            fetchScrollbackIfNeeded(paneId: paneId)

        case .scrolling(let offset, let totalLines):
            let buffer = connectionManager.paneBuffers[paneId]
            let visibleRows = buffer?.rows ?? 24
            let newOffset = ScrollbackState.clampedOffset(
                offset + delta, totalLines: totalLines, visibleRows: visibleRows
            )
            if newOffset == 0 {
                returnToLive(paneId: paneId)
            } else {
                scrollbackState[paneId] = .scrolling(
                    offset: newOffset, totalLines: totalLines
                )
                // Fetch more history when user reaches the top of the cache.
                let maxOffset = totalLines - visibleRows
                if newOffset >= maxOffset && totalLines < 2000 {
                    fetchMoreScrollback(paneId: paneId, currentTotal: totalLines)
                }
            }

        default:
            break
        }
    }

    private func fetchScrollbackIfNeeded(paneId: String) {
        guard scrollbackState[paneId] != .loading else { return }
        scrollbackState[paneId] = .loading
        connectionManager.scrolledBackPanes.insert(paneId)

        Task {
            do {
                let response = try await connectionManager.fetchScrollback(paneId: paneId)
                guard !response.isEmpty else {
                    scrollbackState[paneId] = .live
                    connectionManager.scrolledBackPanes.remove(paneId)
                    return
                }

                // capture-pane output ends with a trailing newline; drop the
                // resulting empty element so the buffer isn't oversized by 1.
                var lines = response.components(separatedBy: "\n")
                if lines.last?.isEmpty == true { lines.removeLast() }

                let liveBuffer = connectionManager.paneBuffers[paneId]
                let cols = liveBuffer?.cols ?? 80
                let totalLines = lines.count
                let cacheBuffer = TerminalBuffer(cols: cols, rows: totalLines)
                cacheBuffer.feed(response)

                scrollbackCaches[paneId] = cacheBuffer
                scrollbackState[paneId] = .scrolling(
                    offset: 1, totalLines: totalLines
                )
            } catch {
                logger.error("Scrollback fetch failed: \(error.localizedDescription)")
                scrollbackState[paneId] = .live
                connectionManager.scrolledBackPanes.remove(paneId)
            }
        }
    }

    /// Fetch more history when the user scrolls to the top of the current cache.
    /// Doubles the fetch range (capped at 2000) and replaces the cache entirely,
    /// adjusting the scroll offset to preserve the user's position.
    private func fetchMoreScrollback(paneId: String, currentTotal: Int) {
        let newLineCount = min(currentTotal * 2, 2000)
        guard newLineCount > currentTotal else { return }

        Task {
            do {
                let response = try await connectionManager.fetchScrollback(
                    paneId: paneId, lineCount: newLineCount
                )
                guard !response.isEmpty else { return }

                var lines = response.components(separatedBy: "\n")
                if lines.last?.isEmpty == true { lines.removeLast() }

                let liveBuffer = connectionManager.paneBuffers[paneId]
                let cols = liveBuffer?.cols ?? 80
                let totalLines = lines.count

                guard totalLines > currentTotal else { return }

                let cacheBuffer = TerminalBuffer(cols: cols, rows: totalLines)
                cacheBuffer.feed(response)

                // Preserve user's scroll position relative to the bottom.
                let previousOffset: Int
                if case .scrolling(let offset, _) = scrollbackState[paneId] {
                    previousOffset = offset
                } else {
                    previousOffset = 1
                }
                let addedLines = totalLines - currentTotal

                scrollbackCaches[paneId] = cacheBuffer
                scrollbackState[paneId] = .scrolling(
                    offset: previousOffset + addedLines, totalLines: totalLines
                )
            } catch {
                logger.error("Fetch more scrollback failed: \(error.localizedDescription)")
            }
        }
    }

    private func returnToLive(paneId: String) {
        scrollbackState[paneId] = .live
        scrollbackCaches[paneId] = nil
        connectionManager.scrolledBackPanes.remove(paneId)
        connectionManager.paneHasNewOutput.remove(paneId)
    }
}
