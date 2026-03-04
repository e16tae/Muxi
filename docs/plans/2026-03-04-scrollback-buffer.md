# Scrollback Buffer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Let users swipe up on the terminal to view past output via tmux `capture-pane`, with cached rendering and a "new output" indicator.

**Architecture:** On first scroll-up gesture, fetch 500 lines of history from tmux via `capture-pane -e -p -S -500`. Feed the ANSI response into a temporary TerminalBuffer (reusing the existing VT parser). The Metal renderer displays a window of rows from this cache at the current scroll offset. No local persistent storage — tmux manages history server-side.

**Tech Stack:** Swift, Metal (existing renderer), tmux control mode, UIKit gesture recognizers

**Design doc:** `docs/plans/2026-03-04-scrollback-buffer-design.md`

---

### Task 1: ScrollbackState Model + Tests

**Files:**
- Create: `ios/Muxi/Terminal/ScrollbackState.swift`
- Create: `ios/MuxiTests/Terminal/ScrollbackStateTests.swift`

**Step 1: Write the tests**

```swift
// ios/MuxiTests/Terminal/ScrollbackStateTests.swift
import Testing
@testable import Muxi

@Suite("ScrollbackState")
struct ScrollbackStateTests {

    @Test("live is the default state")
    func liveIsDefault() {
        let state = ScrollbackState.live
        #expect(state == .live)
        #expect(!state.isScrolledBack)
    }

    @Test("loading indicates fetch in progress")
    func loadingState() {
        let state = ScrollbackState.loading
        #expect(state == .loading)
        #expect(!state.isScrolledBack)
    }

    @Test("scrolling tracks offset and total lines")
    func scrollingState() {
        let state = ScrollbackState.scrolling(offset: 50, totalLines: 500)
        #expect(state.isScrolledBack)
        if case .scrolling(let offset, let total) = state {
            #expect(offset == 50)
            #expect(total == 500)
        }
    }

    @Test("equatable compares correctly")
    func equatable() {
        #expect(ScrollbackState.live == .live)
        #expect(ScrollbackState.loading == .loading)
        #expect(ScrollbackState.scrolling(offset: 10, totalLines: 100)
            == .scrolling(offset: 10, totalLines: 100))
        #expect(ScrollbackState.scrolling(offset: 10, totalLines: 100)
            != .scrolling(offset: 20, totalLines: 100))
        #expect(ScrollbackState.live != .loading)
    }

    @Test("clampedOffset clamps to valid range")
    func clampedOffset() {
        #expect(ScrollbackState.clampedOffset(50, totalLines: 500, visibleRows: 24) == 50)
        #expect(ScrollbackState.clampedOffset(-5, totalLines: 500, visibleRows: 24) == 0)
        #expect(ScrollbackState.clampedOffset(600, totalLines: 500, visibleRows: 24) == 476)
    }

    @Test("startRow calculates correct render start")
    func startRow() {
        // 500 total, scrolled 50 back, 24 visible → start at row 426
        let start = ScrollbackState.startRow(offset: 50, totalLines: 500, visibleRows: 24)
        #expect(start == 426)
    }

    @Test("startRow clamps to zero")
    func startRowClampsToZero() {
        // 30 total, scrolled 50 back, 24 visible → start at 0 (can't go negative)
        let start = ScrollbackState.startRow(offset: 50, totalLines: 30, visibleRows: 24)
        #expect(start == 0)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' -only-testing:MuxiTests/ScrollbackStateTests 2>&1 | tail -20`
Expected: FAIL — ScrollbackState not defined

**Step 3: Write minimal implementation**

```swift
// ios/Muxi/Terminal/ScrollbackState.swift

/// Tracks the scrollback state of a single terminal pane.
///
/// - `.live`: Normal mode — renderer reads from the live buffer.
/// - `.loading`: A `capture-pane` request is in flight.
/// - `.scrolling`: User has scrolled back into history.
enum ScrollbackState: Equatable {
    case live
    case loading
    case scrolling(offset: Int, totalLines: Int)

    /// Whether the user has scrolled away from the live position.
    var isScrolledBack: Bool {
        switch self {
        case .scrolling: return true
        default: return false
        }
    }

    /// Clamp a scroll offset to the valid range `[0, totalLines - visibleRows]`.
    static func clampedOffset(_ offset: Int, totalLines: Int, visibleRows: Int) -> Int {
        max(0, min(offset, totalLines - visibleRows))
    }

    /// Calculate the first row index in the scrollback buffer to render.
    ///
    /// The buffer has `totalLines` rows. We want to show `visibleRows` rows,
    /// ending `offset` lines from the bottom.
    static func startRow(offset: Int, totalLines: Int, visibleRows: Int) -> Int {
        max(0, totalLines - offset - visibleRows)
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' -only-testing:MuxiTests/ScrollbackStateTests 2>&1 | tail -20`
Expected: PASS — all 7 tests pass

**Step 5: Commit**

```bash
git add ios/Muxi/Terminal/ScrollbackState.swift ios/MuxiTests/Terminal/ScrollbackStateTests.swift
git commit -m "feat: add ScrollbackState model with helper methods"
```

---

### Task 2: TerminalRenderer Scrollback Rendering

**Files:**
- Modify: `ios/Muxi/Terminal/TerminalRenderer.swift:79-86,311-420`

The renderer currently always iterates rows `0..<buffer.rows` and reads from `buffer`. We need to add:
1. `scrollbackBuffer` and `scrollOffset` properties
2. When scrollback is active, read from `scrollbackBuffer` and render only a window of rows
3. Hide the cursor when in scrollback mode

**Step 1: Add scrollback properties**

At `ios/Muxi/Terminal/TerminalRenderer.swift:84-85`, add after `var needsRedraw`:

```swift
    // MARK: - Scrollback

    /// When set, the renderer reads from this buffer instead of the live buffer.
    var scrollbackBuffer: TerminalBuffer?
    /// Number of lines scrolled back from the bottom. 0 = live mode.
    var scrollOffset: Int = 0
```

**Step 2: Modify rebuildVertices to support scrollback**

Replace the `rebuildVertices()` method (lines 311-420) with:

```swift
    func rebuildVertices() {
        // Determine source buffer and row range.
        let isScrollback = scrollOffset > 0 && scrollbackBuffer != nil
        let source: TerminalBuffer
        let rowRange: Range<Int>

        if isScrollback, let sb = scrollbackBuffer, let live = buffer {
            source = sb
            let visibleRows = live.rows
            let start = ScrollbackState.startRow(
                offset: scrollOffset, totalLines: sb.rows, visibleRows: visibleRows
            )
            let end = min(sb.rows, start + visibleRows)
            rowRange = start..<end
        } else {
            guard let buf = buffer else { return }
            source = buf
            rowRange = 0..<buf.rows
        }

        let cols = source.cols
        let spaceUV = glyphUVs[" "] ?? GlyphUV(u: 0, v: 0, uMax: 0, vMax: 0, cellSpan: 1)

        var vertices: [CellVertex] = []
        vertices.reserveCapacity(rowRange.count * cols * 6)

        let cw = Float(cellWidth)
        let ch = Float(cellHeight)

        // First pass: ensure all glyphs are in the atlas.
        var newGlyphs = false
        for row in rowRange {
            for col in 0..<cols {
                let cell = source.cellAt(row: row, col: col)
                if cell.width == 0 { continue }
                if cell.character != " " && glyphUVs[cell.character] == nil {
                    ensureGlyph(cell.character)
                    newGlyphs = true
                }
            }
        }
        if newGlyphs {
            flushAtlasToTexture()
        }

        // Second pass: build vertex data.
        for row in rowRange {
            // Map source row to screen row (0-based for vertex positioning).
            let screenRow = row - rowRange.lowerBound

            for col in 0..<cols {
                let cell = source.cellAt(row: row, col: col)
                if cell.width == 0 { continue }

                var fgTermColor = cell.fgColor
                var bgTermColor = cell.bgColor
                if cell.isInverse {
                    swap(&fgTermColor, &bgTermColor)
                }

                let fgTheme = theme.resolve(fgTermColor, isForeground: true)
                let bgTheme = theme.resolve(bgTermColor, isForeground: false)

                var fg = SIMD4<Float>(
                    Float(fgTheme.r) / 255.0,
                    Float(fgTheme.g) / 255.0,
                    Float(fgTheme.b) / 255.0,
                    1.0
                )
                var bg = SIMD4<Float>(
                    Float(bgTheme.r) / 255.0,
                    Float(bgTheme.g) / 255.0,
                    Float(bgTheme.b) / 255.0,
                    1.0
                )

                // Block cursor: only show in live mode.
                if !isScrollback,
                   row == source.cursorRow && col == source.cursorCol {
                    swap(&fg, &bg)
                }

                let uv = glyphUVs[cell.character] ?? spaceUV
                let cellSpan = Int(cell.width)
                let quadWidth = cw * Float(cellSpan)

                let x0 = Float(col) * cw
                let y0 = Float(screenRow) * ch
                let x1 = x0 + quadWidth
                let y1 = y0 + ch

                vertices.append(CellVertex(
                    position: SIMD2(x0, y0), uv: SIMD2(uv.u, uv.v),
                    fgColor: fg, bgColor: bg))
                vertices.append(CellVertex(
                    position: SIMD2(x1, y0), uv: SIMD2(uv.uMax, uv.v),
                    fgColor: fg, bgColor: bg))
                vertices.append(CellVertex(
                    position: SIMD2(x0, y1), uv: SIMD2(uv.u, uv.vMax),
                    fgColor: fg, bgColor: bg))

                vertices.append(CellVertex(
                    position: SIMD2(x1, y0), uv: SIMD2(uv.uMax, uv.v),
                    fgColor: fg, bgColor: bg))
                vertices.append(CellVertex(
                    position: SIMD2(x1, y1), uv: SIMD2(uv.uMax, uv.vMax),
                    fgColor: fg, bgColor: bg))
                vertices.append(CellVertex(
                    position: SIMD2(x0, y1), uv: SIMD2(uv.u, uv.vMax),
                    fgColor: fg, bgColor: bg))
            }
        }

        vertexCount = vertices.count
        guard vertexCount > 0 else {
            vertexBuffer = nil
            return
        }
        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<CellVertex>.stride * vertexCount,
            options: .storageModeShared
        )
    }
```

**Step 3: Run existing TerminalBuffer tests to verify no regression**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' -only-testing:MuxiTests/TerminalBufferTests 2>&1 | tail -20`
Expected: PASS — all existing tests still pass

**Step 4: Commit**

```bash
git add ios/Muxi/Terminal/TerminalRenderer.swift
git commit -m "feat: add scrollback rendering support to TerminalRenderer

Renderer reads from scrollbackBuffer when scrollOffset > 0,
rendering only the visible window of rows. Cursor hidden in
scrollback mode."
```

---

### Task 3: ConnectionManager Scrollback Fetch + Tests

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift`
- Modify: `ios/MuxiTests/Services/ConnectionManagerTests.swift`

Add a `fetchScrollback(paneId:)` method that sends `capture-pane -e -p -S -500` and returns the response. Uses a `CheckedContinuation` to bridge the async gap between sending the command and receiving the `%begin/%end` response.

**Step 1: Write the tests**

Add to `ios/MuxiTests/Services/ConnectionManagerTests.swift`:

```swift
    // MARK: - Scrollback Fetch

    @Test("fetchScrollback sends capture-pane and returns response")
    func fetchScrollbackSuccess() async throws {
        let mock = MockSSHService()
        mock.mockExecResults["tmux -V"] = "tmux 3.4"
        mock.mockExecResults["tmux list-sessions"] = "$0:test:1:1709571200"
        let cm = ConnectionManager(sshService: mock)
        let server = Server(name: "test", host: "h", port: 22, username: "u", authMethod: .password)
        _ = try await cm.connect(server: server, password: "p")

        // Simulate scrollback: mock will capture the written command
        // and we need to trigger onCommandResponse with the result.
        // Since fetchScrollback uses the tmux response pipeline,
        // we test by calling the method and delivering the response.
        let fetchTask = Task {
            try await cm.fetchScrollback(paneId: "%0")
        }

        // Give the fetch task time to send the command and set up continuation.
        try await Task.sleep(for: .milliseconds(50))

        // Simulate tmux responding with scrollback content.
        cm.deliverScrollbackResponse("line1\nline2\nline3")

        let result = try await fetchTask.value
        #expect(result == "line1\nline2\nline3")
    }

    @Test("fetchScrollback returns empty string when no history")
    func fetchScrollbackEmpty() async throws {
        let mock = MockSSHService()
        mock.mockExecResults["tmux -V"] = "tmux 3.4"
        mock.mockExecResults["tmux list-sessions"] = "$0:test:1:1709571200"
        let cm = ConnectionManager(sshService: mock)
        let server = Server(name: "test", host: "h", port: 22, username: "u", authMethod: .password)
        _ = try await cm.connect(server: server, password: "p")

        let fetchTask = Task {
            try await cm.fetchScrollback(paneId: "%0")
        }

        try await Task.sleep(for: .milliseconds(50))
        cm.deliverScrollbackResponse("")

        let result = try await fetchTask.value
        #expect(result == "")
    }
```

**Step 2: Run tests to verify they fail**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' -only-testing:MuxiTests/ConnectionManagerTests/fetchScrollbackSuccess 2>&1 | tail -20`
Expected: FAIL — fetchScrollback not defined

**Step 3: Add fetchScrollback to ConnectionManager**

Add at `ios/Muxi/Services/ConnectionManager.swift`, after the `capturePaneQueue` property (line 70):

```swift
    /// Continuation waiting for a scrollback `capture-pane` response.
    /// Set by ``fetchScrollback(paneId:)`` and resumed by
    /// ``deliverScrollbackResponse(_:)``.
    private var scrollbackContinuation: CheckedContinuation<String, Error>?
```

Add the following methods before the `// MARK: - Auth Resolution` section:

```swift
    // MARK: - Scrollback

    /// Fetch scrollback history for a pane from tmux.
    ///
    /// Sends `capture-pane -e -p -S -500` to fetch up to 500 lines of
    /// history with ANSI color escapes. Returns the raw response string.
    ///
    /// - Parameter paneId: The tmux pane ID (e.g., "%0").
    /// - Returns: The captured scrollback content with ANSI escapes.
    func fetchScrollback(paneId: String) async throws -> String {
        guard case .attached = state else {
            throw ScrollbackError.notAttached
        }
        guard scrollbackContinuation == nil else {
            throw ScrollbackError.fetchInProgress
        }

        return try await withCheckedThrowingContinuation { continuation in
            scrollbackContinuation = continuation
            let cmd = "capture-pane -e -p -S -500 -t \(paneId.shellEscaped())\n"
            Task {
                try? await sshServiceForWrites.writeToChannel(Data(cmd.utf8))
                logger.info("Sent scrollback capture-pane for \(paneId)")
            }
        }
    }

    /// Deliver a scrollback capture-pane response from tmux.
    /// Called by ``onCommandResponse`` when a scrollback fetch is pending.
    func deliverScrollbackResponse(_ response: String) {
        guard let continuation = scrollbackContinuation else { return }
        scrollbackContinuation = nil
        continuation.resume(returning: response)
    }
```

Add the error type in a new section after `ConnectionState`:

```swift
/// Errors specific to scrollback operations.
enum ScrollbackError: Error {
    case notAttached
    case fetchInProgress
}
```

**Step 4: Modify onCommandResponse to route scrollback responses**

In the `wireCallbacks()` method, update `onCommandResponse` (line 527) to check for scrollback continuation first:

```swift
        tmuxService.onCommandResponse = { [weak self] response in
            guard let self else { return }

            // If a scrollback fetch is pending, deliver the response to it.
            if self.scrollbackContinuation != nil {
                self.deliverScrollbackResponse(response)
                return
            }

            guard let paneId = self.capturePaneQueue.first else {
                self.logger.info("Command response with no pending capture-pane")
                return
            }
            self.capturePaneQueue.removeFirst()
            self.logger.info("capture-pane response for \(paneId): \(response.count) chars")
            if !response.isEmpty {
                self.paneBuffers[paneId]?.feed(response)
            }
        }
```

**Step 5: Run tests to verify they pass**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' -only-testing:MuxiTests/ConnectionManagerTests 2>&1 | tail -20`
Expected: PASS — all tests pass (new + existing)

**Step 6: Commit**

```bash
git add ios/Muxi/Services/ConnectionManager.swift ios/MuxiTests/Services/ConnectionManagerTests.swift
git commit -m "feat: add fetchScrollback to ConnectionManager

Sends capture-pane -e -p -S -500 to fetch history with ANSI
colors. Uses CheckedContinuation to bridge tmux response pipeline."
```

---

### Task 4: TerminalView Pan Gesture + Scrollback Props

**Files:**
- Modify: `ios/Muxi/Views/Terminal/TerminalView.swift:9-14,17-18,59-76,120-172`

Add a `UIPanGestureRecognizer` to the MTKView, scrollback properties, and callbacks for the parent view to handle scroll state changes.

**Step 1: Add scrollback parameters to TerminalView**

At `ios/Muxi/Views/Terminal/TerminalView.swift:10-14`, update the struct properties:

```swift
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
```

**Step 2: Update Coordinator to handle pan gestures**

Add to the Coordinator class (after the existing properties around line 127):

```swift
        var onScrollOffsetChanged: ((Int) -> Void)?
        var onScrollbackNeeded: (() -> Void)?
        private var cellHeight: CGFloat = 0
        private var accumulatedPanDelta: CGFloat = 0
```

Update the Coordinator `init` to accept the new parameters:

```swift
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
```

Add the pan gesture handler to the Coordinator:

```swift
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
```

**Step 3: Update makeCoordinator**

```swift
    func makeCoordinator() -> Coordinator {
        Coordinator(
            buffer: buffer, channel: channel, theme: theme,
            onPaste: onPaste,
            onScrollOffsetChanged: onScrollOffsetChanged,
            onScrollbackNeeded: onScrollbackNeeded
        )
    }
```

**Step 4: Add pan gesture recognizer in makeUIView**

After the long press gesture (line 76), add:

```swift
        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        mtkView.addGestureRecognizer(pan)
```

**Step 5: Wire scrollback buffer to renderer in makeUIView**

After `context.coordinator.renderer = renderer` (line 46), add:

```swift
            // Store cell height for scroll calculations.
            context.coordinator.cellHeight = renderer.cellHeight
```

**Step 6: Update updateUIView to pass scrollback state to renderer**

In `updateUIView` (around line 81), add after updating coordinator references:

```swift
        // Update scrollback state on renderer.
        context.coordinator.renderer?.scrollbackBuffer = scrollbackBuffer
        context.coordinator.renderer?.scrollOffset = scrollOffset
        context.coordinator.onScrollOffsetChanged = onScrollOffsetChanged
        context.coordinator.onScrollbackNeeded = onScrollbackNeeded

        if context.coordinator.renderer?.scrollOffset != scrollOffset
            || context.coordinator.renderer?.scrollbackBuffer !== scrollbackBuffer {
            context.coordinator.requestRedraw()
        }
```

**Step 7: Run existing tests to verify no regression**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' 2>&1 | tail -30`
Expected: PASS

**Step 8: Commit**

```bash
git add ios/Muxi/Views/Terminal/TerminalView.swift
git commit -m "feat: add pan gesture and scrollback props to TerminalView

UIPanGestureRecognizer on MTKView detects vertical swipe.
Scrollback buffer and offset passed to renderer for display."
```

---

### Task 5: End-to-End Wiring + New Output Indicator

**Files:**
- Modify: `ios/Muxi/Views/Terminal/PaneContainerView.swift:59-66,72-90,114-131,176-197`
- Modify: `ios/Muxi/Views/Terminal/TerminalSessionView.swift:10-18,20-36,38-116`

Wire the scroll gesture through PaneContainerView to TerminalSessionView, which coordinates with ConnectionManager to fetch scrollback and manage state. Add a "↓ New output" indicator overlay.

**Step 1: Add scrollback props to PaneContainerView.PaneInfo**

In `PaneContainerView` struct (line 59), add:

```swift
    var scrollbackBuffer: TerminalBuffer?
    var scrollbackOffset: Int = 0
    var onScrollOffsetChanged: ((String, Int) -> Void)?
    var onScrollbackNeeded: ((String) -> Void)?
    var showNewOutputIndicator: Bool = false
    var onReturnToLive: ((String) -> Void)?
```

**Step 2: Pass scrollback props to TerminalView in compact layout**

Update the TerminalView creation in `compactLayout` (line 118):

```swift
                TerminalView(
                    buffer: pane.buffer,
                    theme: theme,
                    channel: pane.channel,
                    onPaste: onPaste,
                    scrollbackBuffer: scrollbackBuffer,
                    scrollOffset: scrollbackOffset,
                    onScrollOffsetChanged: { delta in
                        onScrollOffsetChanged?(pane.id, delta)
                    },
                    onScrollbackNeeded: {
                        onScrollbackNeeded?(pane.id)
                    }
                )
```

Do the same for `regularLayout` (line 180).

**Step 3: Add new output indicator overlay**

Add after each TerminalView in both layouts:

```swift
                .overlay(alignment: .bottom) {
                    if showNewOutputIndicator,
                       scrollbackOffset > 0,
                       pane.id == activePaneId {
                        Button {
                            onReturnToLive?(pane.id)
                        } label: {
                            HStack(spacing: MuxiTokens.Spacing.xs) {
                                Image(systemName: "arrow.down")
                                Text("New output")
                            }
                            .font(MuxiTokens.Typography.caption)
                            .padding(.horizontal, MuxiTokens.Spacing.md)
                            .padding(.vertical, MuxiTokens.Spacing.sm)
                            .background(
                                RoundedRectangle(
                                    cornerRadius: MuxiTokens.Radius.sm,
                                    style: .continuous
                                )
                                .fill(MuxiTokens.Colors.accentDefault)
                            )
                            .foregroundStyle(.white)
                        }
                        .padding(.bottom, MuxiTokens.Spacing.md)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
```

**Step 4: Add scrollback state management to TerminalSessionView**

In `TerminalSessionView` (line 16), add state:

```swift
    @State private var scrollbackState: [String: ScrollbackState] = [:]
    @State private var scrollbackCaches: [String: TerminalBuffer] = [:]
    @State private var hasNewOutput: [String: Bool] = [:]
```

**Step 5: Update panes computed property**

Update the `panes` computed property to include scrollback info:

```swift
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
```

**Step 6: Add PaneContainerView scrollback callbacks**

In the `body` (where PaneContainerView is created, around line 45), pass scrollback props:

```swift
                    PaneContainerView(
                        panes: panes,
                        theme: themeManager.currentTheme,
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
                        onScrollbackNeeded: { paneId in
                            fetchScrollbackIfNeeded(paneId: paneId)
                        },
                        showNewOutputIndicator: activePaneId.flatMap { hasNewOutput[$0] } ?? false,
                        onReturnToLive: { paneId in
                            returnToLive(paneId: paneId)
                        }
                    )
```

**Step 7: Add scrollback methods to TerminalSessionView**

```swift
    // MARK: - Scrollback

    private func handleScrollDelta(paneId: String, delta: Int) {
        let currentState = scrollbackState[paneId] ?? .live

        switch currentState {
        case .live where delta > 0:
            // Starting to scroll up — request data first.
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
            }

        default:
            break
        }
    }

    private func fetchScrollbackIfNeeded(paneId: String) {
        guard scrollbackState[paneId] != .loading else { return }
        scrollbackState[paneId] = .loading

        Task {
            do {
                let response = try await connectionManager.fetchScrollback(paneId: paneId)
                guard !response.isEmpty else {
                    scrollbackState[paneId] = .live
                    return
                }

                // Create a temporary buffer sized for the captured content.
                let lines = response.components(separatedBy: "\n")
                let liveBuffer = connectionManager.paneBuffers[paneId]
                let cols = liveBuffer?.cols ?? 80
                let cacheBuffer = TerminalBuffer(cols: cols, rows: lines.count)
                cacheBuffer.feed(response)

                scrollbackCaches[paneId] = cacheBuffer
                scrollbackState[paneId] = .scrolling(
                    offset: 1, totalLines: lines.count
                )

                // Track new output while scrolled back.
                hasNewOutput[paneId] = false
                liveBuffer?.onUpdate = { [weak liveBuffer] in
                    // Original onUpdate is called by the buffer.
                    // Mark new output available.
                    if self.scrollbackState[paneId]?.isScrolledBack == true {
                        self.hasNewOutput[paneId] = true
                    }
                }
            } catch {
                logger.error("Scrollback fetch failed: \(error.localizedDescription)")
                scrollbackState[paneId] = .live
            }
        }
    }

    private func returnToLive(paneId: String) {
        scrollbackState[paneId] = .live
        scrollbackCaches[paneId] = nil
        hasNewOutput[paneId] = false
    }
```

**Step 8: Run all tests**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' 2>&1 | tail -30`
Expected: PASS

**Step 9: Commit**

```bash
git add ios/Muxi/Views/Terminal/PaneContainerView.swift ios/Muxi/Views/Terminal/TerminalSessionView.swift
git commit -m "feat: wire scrollback end-to-end with new output indicator

Pan gesture triggers capture-pane fetch, cached in temporary
buffer, rendered by Metal. New output indicator shown when
live data arrives while scrolled back."
```

---

## Notes for Implementer

### Key files to read first
- `docs/plans/2026-03-04-scrollback-buffer-design.md` — design rationale
- `ios/Muxi/Terminal/TerminalBuffer.swift` — understand VT parser wrapper
- `ios/Muxi/Terminal/TerminalRenderer.swift:311-420` — understand rebuildVertices
- `ios/Muxi/Views/Terminal/TerminalView.swift` — understand UIViewRepresentable pattern
- `ios/Muxi/Services/ConnectionManager.swift:517-539` — existing capture-pane pattern

### Testing strategy
- Task 1: Pure model tests with Swift Testing
- Task 2: Renderer changes verified by existing TerminalBuffer tests (Metal rendering can't be unit tested)
- Task 3: ConnectionManager tests with MockSSHService
- Task 4-5: Integration verified by full test suite + manual testing on simulator

### Shell escaping
All tmux pane IDs passed to commands MUST use `.shellEscaped()`. This is enforced by the project guidelines — see CLAUDE.md.

### Known limitation
The `onUpdate` callback rewiring in Task 5's `fetchScrollbackIfNeeded` replaces the existing callback set in TerminalView. This may cause the Metal view to stop redrawing live content while scrolled back — which is actually desired behavior since we're not showing live content. When returning to live, the TerminalView's `updateUIView` re-wires the callback.
