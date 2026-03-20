import SwiftUI
import UIKit
import CoreText
import os

/// The terminal session screen that combines all terminal-related components
/// into a single view: pane container, bottom toolbar, and extended keyboard.
///
/// Displayed when ``ConnectionManager/state`` is `.attached(sessionName:)`.
struct TerminalSessionView: View {
    let connectionManager: ConnectionManager
    let sessionName: String
    let themeManager: ThemeManager

    @Environment(\.horizontalSizeClass) private var sizeClass

    private let logger = Logger(subsystem: "com.muxi.app", category: "TerminalSession")
    @State private var inputHandler = InputHandler()
    @State private var isKeyboardActive = true
    @State private var scrollbackManager = ScrollbackManager()
    @State private var showNewSessionAlert = false
    @State private var newSessionName = ""
    @State private var isKeyboardVisible = false
    @State private var isSessionMode = false
    @State private var showRenameAlert = false
    @State private var renameTarget: ToolbarView.RenameTarget?
    @State private var renameText = ""

    @State private var panes: [PaneContainerView.PaneInfo] = []

    private func buildPaneInfos() -> [PaneContainerView.PaneInfo] {
        connectionManager.currentPanes.map { pane in
            let buffer = connectionManager.paneBuffers[pane.id]
                ?? TerminalBuffer(cols: pane.frame.width, rows: pane.frame.height)
            return PaneContainerView.PaneInfo(
                id: pane.id,
                buffer: buffer,
                x: pane.frame.x,
                y: pane.frame.y,
                width: pane.frame.width,
                height: pane.frame.height
            )
        }
    }

    /// The scrollback cache for the active pane, if any.
    private var activeScrollbackBuffer: TerminalBuffer? {
        guard let id = connectionManager.activePaneId else { return nil }
        return scrollbackManager.cache(for: id)
    }

    /// The current scrollback offset for the active pane (0 = live).
    private var activeScrollbackOffset: Int {
        guard let id = connectionManager.activePaneId else { return 0 }
        if case .scrolling(let offset, _) = scrollbackManager.state(for: id) {
            return offset
        }
        return 0
    }

    /// Whether the active pane has new output while scrolled back.
    private var activeHasNewOutput: Bool {
        guard let id = connectionManager.activePaneId else { return false }
        return connectionManager.paneHasNewOutput.contains(id)
    }

    // MARK: - Body Subsections

    @ViewBuilder
    private var terminalContentArea: some View {
        if panes.isEmpty {
            placeholderView
        } else {
            GeometryReader { geometry in
                PaneContainerView(
                    panes: panes,
                    theme: themeManager.currentTheme,
                    fontSize: themeManager.fontSize,
                    activePaneId: Binding(
                        get: { connectionManager.activePaneId },
                        set: { connectionManager.activePaneId = $0 }
                    ),
                    onPaneTapped: { paneId in
                        sendTmuxCommand("select-pane -t \(paneId.rawValue.shellEscaped()) -Z")
                    },
                    onPaste: { text in
                        pasteToActivePane(text)
                    },
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
                    isKeyboardActive: isKeyboardActive,
                    onKeyboardDismissed: {
                        isKeyboardActive = false
                    },
                    scrollbackBuffer: activeScrollbackBuffer,
                    scrollbackOffset: activeScrollbackOffset,
                    onScrollOffsetChanged: { paneId, delta in
                        handleScrollDelta(paneId: paneId, delta: delta)
                    },
                    showNewOutputIndicator: activeHasNewOutput,
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
            .padding(.horizontal, MuxiTokens.Spacing.sm)
        }
    }

    private var toolbarArea: some View {
        ToolbarView(
            connectionManager: connectionManager,
            sessionName: sessionName,
            isKeyboardActive: $isKeyboardActive,
            isSessionMode: $isSessionMode,
            showRenameAlert: $showRenameAlert,
            renameTarget: $renameTarget,
            renameText: $renameText,
            onSendCommand: { command in
                sendTmuxCommand(command)
            },
            onSelectWindow: { windowId in
                Task {
                    try? await connectionManager.selectWindow(windowId)
                }
            },
            onSelectWindowAndPane: { windowId, paneId in
                Task {
                    try? await connectionManager.selectWindowAndPane(
                        windowId: windowId, paneId: paneId)
                }
            },
            onNewSession: {
                showNewSessionAlert = true
            },
            onSwitchSession: { name in
                Task {
                    do {
                        try await connectionManager.switchSession(to: name)
                        logger.info("Switched to session: \(name)")
                    } catch {
                        logger.error("Failed to switch: \(error.localizedDescription)")
                    }
                }
            },
            onKillSession: { name in
                Task {
                    try? await connectionManager.killSession(name)
                }
            }
        )
    }

    @ViewBuilder
    private var keyboardArea: some View {
        if isKeyboardVisible {
            ExtendedKeyboardView(
                theme: themeManager.currentTheme,
                inputHandler: inputHandler,
                onInput: { data in
                    sendToActivePane(data)
                }
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            terminalContentArea
            toolbarArea
            keyboardArea
        }
        .background(
            themeManager.currentTheme.background.color
                .ignoresSafeArea()
        )
        .onAppear {
            connectionManager.mobileAutoZoom = (sizeClass == .compact)
            panes = buildPaneInfos()
        }
        .onChange(of: sizeClass) { _, newValue in
            connectionManager.mobileAutoZoom = (newValue == .compact)
            // Auto-zoom is triggered proactively by mobileAutoZoom's didSet
            // when transitioning false→true, and reactively by onLayoutChange
            // for subsequent layout events.  pendingAutoZoom prevents
            // double-toggling between the two paths.
        }
        // currentPanes is computed from windowPaneState, so @Observable
        // tracks the underlying stored property. This may fire on any
        // windowPaneState mutation (e.g. activePaneId change), but
        // buildPaneInfos() is lightweight — acceptable overhead.
        .onChange(of: connectionManager.currentPanes) { _, _ in
            panes = buildPaneInfos()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        // Rename alert (shared between window and session)
        .alert(
            renameAlertTitle,
            isPresented: $showRenameAlert
        ) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                switch renameTarget {
                case .window(let id):
                    Task {
                        try? await connectionManager.renameWindow(id, to: trimmed)
                    }
                case .session(let name):
                    Task {
                        try? await connectionManager.renameSession(name, to: trimmed)
                    }
                case nil:
                    break
                }
                renameTarget = nil
                renameText = ""
            }
            Button("Cancel", role: .cancel) {
                renameTarget = nil
                renameText = ""
            }
        }
        // New session alert (kept from existing code)
        .alert("New Session", isPresented: $showNewSessionAlert) {
            TextField("Optional name", text: $newSessionName)
            Button("Create") {
                let trimmed = newSessionName.trimmingCharacters(in: .whitespaces)
                let name: String? = trimmed.isEmpty ? nil : trimmed
                newSessionName = ""
                Task {
                    do {
                        try await connectionManager.createAndSwitchToNewSession(name: name)
                        logger.info("Created session: \(name ?? "(auto)")")
                    } catch {
                        logger.error("Failed to create session: \(error.localizedDescription)")
                    }
                }
            }
            Button("Cancel", role: .cancel) { newSessionName = "" }
        }
    }

    private var renameAlertTitle: String {
        switch renameTarget {
        case .window:
            return "Rename Window"
        case .session:
            return "Rename Session"
        case nil:
            return "Rename"
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
        let scrolledPanes = scrollbackManager.scrolledPaneIds
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
            Text(connectionManager.switchingToWindowId != nil
                ? "Switching window..."
                : "Attaching to \(sessionName)...")
                .font(MuxiTokens.Typography.caption)
                .foregroundStyle(MuxiTokens.Colors.textSecondary)
                .padding(.top, MuxiTokens.Spacing.sm)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Input Handling

    /// Send raw data to the active pane via tmux control mode.
    private func sendToActivePane(_ data: Data) {
        guard let paneId = connectionManager.activePaneId else { return }
        Task {
            do {
                try await connectionManager.sendKeysToPane(paneId, data: data)
            } catch {
                logger.error("Failed to send keys to pane \(paneId.rawValue): \(error.localizedDescription)")
            }
        }
    }

    /// Send a tmux command through the control mode channel.
    private func sendTmuxCommand(_ command: String) {
        Task {
            do {
                try await connectionManager.sendTmuxCommand(command)
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
        guard let paneId = connectionManager.activePaneId, !text.isEmpty else { return }
        Task {
            do {
                try await connectionManager.pasteToPane(paneId, text: text)
            } catch {
                logger.error("Failed to paste to pane \(paneId.rawValue): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Scrollback

    private func handleScrollDelta(paneId: PaneID, delta: Int) {
        let currentState = scrollbackManager.state(for: paneId)

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
                scrollbackManager.updateOffset(paneId: paneId, offset: newOffset, totalLines: totalLines)
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

    private func fetchScrollbackIfNeeded(paneId: PaneID) {
        guard scrollbackManager.state(for: paneId) != .loading else { return }
        scrollbackManager.setLoading(paneId: paneId)
        connectionManager.scrolledBackPanes.insert(paneId)

        Task {
            do {
                let response = try await connectionManager.fetchScrollback(paneId: paneId)
                guard !response.isEmpty else {
                    scrollbackManager.returnToLive(paneId: paneId)
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
                // capture-pane uses bare \n; normalize to \r\n for VT parser.
                let normalized = response.replacingOccurrences(of: "\n", with: "\r\n")
                cacheBuffer.feed(normalized)

                scrollbackManager.setScrolling(paneId: paneId, offset: 1, totalLines: totalLines, cache: cacheBuffer)
            } catch {
                logger.error("Scrollback fetch failed: \(error.localizedDescription)")
                scrollbackManager.returnToLive(paneId: paneId)
                connectionManager.scrolledBackPanes.remove(paneId)
            }
        }
    }

    /// Fetch more history when the user scrolls to the top of the current cache.
    /// Doubles the fetch range (capped at 2000) and replaces the cache entirely,
    /// adjusting the scroll offset to preserve the user's position.
    private func fetchMoreScrollback(paneId: PaneID, currentTotal: Int) {
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
                let normalized = response.replacingOccurrences(of: "\n", with: "\r\n")
                cacheBuffer.feed(normalized)

                // Preserve user's scroll position relative to the bottom.
                let previousOffset: Int
                if case .scrolling(let offset, _) = scrollbackManager.state(for: paneId) {
                    previousOffset = offset
                } else {
                    previousOffset = 1
                }
                let addedLines = totalLines - currentTotal

                scrollbackManager.setScrolling(paneId: paneId, offset: previousOffset + addedLines, totalLines: totalLines, cache: cacheBuffer)
            } catch {
                logger.error("Fetch more scrollback failed: \(error.localizedDescription)")
            }
        }
    }

    private func returnToLive(paneId: PaneID) {
        scrollbackManager.returnToLive(paneId: paneId)
        connectionManager.scrolledBackPanes.remove(paneId)
        connectionManager.paneHasNewOutput.remove(paneId)
    }
}
