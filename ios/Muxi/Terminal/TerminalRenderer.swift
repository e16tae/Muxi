import MetalKit
import CoreText
import UIKit
import os

// MARK: - TerminalRenderer

/// Metal-based terminal renderer with a **dynamic glyph atlas**.
///
/// Renders a ``TerminalBuffer`` combined with a ``Theme`` as a grid of colored
/// glyphs.  The atlas starts with ASCII printable characters and grows
/// on-demand when new characters (CJK, box-drawing, emoji, etc.) are
/// encountered during ``rebuildVertices()``.
///
/// Wide (CJK) characters occupy two cell widths in the atlas and are
/// rendered across two columns in the grid.
final class TerminalRenderer: NSObject, MTKViewDelegate {

    private let logger = Logger(subsystem: "com.muxi.app", category: "TerminalRenderer")

    // MARK: - Configuration

    /// Width of a single monospace cell in points.
    private(set) var cellWidth: CGFloat = 0
    /// Height of a single monospace cell in points.
    private(set) var cellHeight: CGFloat = 0

    private var font: UIFont
    private var theme: Theme
    private var scale: CGFloat

    // MARK: - Metal State

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?

    // MARK: - Glyph Atlas

    private var atlasTexture: MTLTexture?
    /// UV coordinates in the glyph atlas for each cached character.
    private var glyphUVs: [Character: GlyphUV] = [:]

    /// Persistent bitmap context for rendering new glyphs into the atlas.
    private var atlasContext: CGContext?
    /// CoreText font reference cached for glyph rendering.
    private var ctFont: CTFont?
    private var fontAscent: CGFloat = 0

    /// Current atlas dimensions.
    private var atlasWidth: Int = 2048
    private var atlasHeight: Int = 2048

    /// Scaled cell dimensions for atlas bitmap rendering (points * scale).
    private var scaledCellWidth: CGFloat = 0
    private var scaledCellHeight: CGFloat = 0

    /// Next available position in the atlas for a new glyph (in scaled pixels).
    private var atlasNextX: CGFloat = 0
    private var atlasNextY: CGFloat = 0
    /// Set to true when new glyphs are added and the texture needs updating.
    private var atlasDirty = false
    /// Dirty region Y bounds (pixel rows) for partial texture upload.
    private var atlasDirtyMinY: Int = Int.max
    private var atlasDirtyMaxY: Int = 0

    /// UV rectangle within the glyph atlas texture.
    struct GlyphUV {
        let u: Float
        let v: Float
        let uMax: Float
        let vMax: Float
        /// Number of cell widths this glyph occupies (1 or 2).
        let cellSpan: Int
    }

    // MARK: - Vertex Data

    /// Per-vertex data sent to the GPU.
    struct CellVertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
        var fgColor: SIMD4<Float>
        var bgColor: SIMD4<Float>
    }

    // Triple-buffered ring to avoid per-frame MTLBuffer allocation.
    private static let maxFramesInFlight = 3
    private let frameSemaphore = DispatchSemaphore(value: maxFramesInFlight)
    private var ringBuffers: [MTLBuffer] = []
    private var currentBufferIndex: Int = 0
    private var ringVertexCounts: [Int] = [0, 0, 0]
    private var ringBufferCapacity: Int = 0

    // MARK: - Buffer Reference

    var buffer: TerminalBuffer?
    var needsRedraw: Bool = true

    /// Cached viewport size in points, derived from the drawable size.
    /// Updated in `drawableSizeWillChange` to guarantee it matches the
    /// actual rendering target — unlike `view.bounds`, which can lag
    /// behind the drawable during animated resizes (e.g. keyboard).
    private var cachedViewportSize: SIMD2<Float> = .zero

    // MARK: - Scrollback

    /// When set, the renderer reads from this buffer instead of the live buffer.
    var scrollbackBuffer: TerminalBuffer?
    /// Number of lines scrolled back from the bottom. 0 = live mode.
    var scrollOffset: Int = 0

    /// Whether this pane is the active (focused) pane. Affects cursor shape:
    /// focused panes show the program-requested style; unfocused show hollow block.
    var isFocused: Bool = true

    // MARK: - Selection

    /// The currently selected range, if any. When set, `rebuildVertices()`
    /// renders selected cells with the theme's selection background color.
    /// Coordinates are in screen-space (0-based row/col of the visible area).
    var selectionRange: (start: (row: Int, col: Int), end: (row: Int, col: Int))?

    // MARK: - Init

    init?(device: MTLDevice, font: UIFont, theme: Theme, scale: CGFloat = 1.0) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.font = font
        self.theme = theme
        self.scale = max(scale, 1.0)
        super.init()

        measureCellSize()
        buildPipeline()
        setupAtlas()
        prerenderASCII()
    }

    deinit {
        // Drain the semaphore to ensure no in-flight GPU work references our buffers.
        for _ in 0..<Self.maxFramesInFlight { frameSemaphore.wait() }
        for _ in 0..<Self.maxFramesInFlight { frameSemaphore.signal() }
    }

    // MARK: - Ring Buffer Management

    /// Ensure ring buffers are large enough for the given grid size.
    /// Called from `rebuildVertices()` which runs inside `draw()`'s semaphore hold,
    /// so we only drain the remaining `maxFramesInFlight - 1` slots.
    private func allocateRingBuffers(rows: Int, cols: Int) {
        let needed = rows * cols * 6 + 36  // +36 for cursor overlay (6 cell + 24 hollow + 6 margin)
        guard needed > ringBufferCapacity else { return }

        // Caller (draw) already holds 1 semaphore slot.
        // Wait for the remaining in-flight frames to complete.
        let otherSlots = Self.maxFramesInFlight - 1
        for _ in 0..<otherSlots { frameSemaphore.wait() }

        let byteSize = MemoryLayout<CellVertex>.stride * needed
        ringBuffers = (0..<Self.maxFramesInFlight).compactMap { _ in
            device.makeBuffer(length: byteSize, options: .storageModeShared)
        }
        ringBufferCapacity = needed
        ringVertexCounts = [0, 0, 0]

        for _ in 0..<otherSlots { frameSemaphore.signal() }
    }

    // MARK: - Public Helpers

    func updateFont(_ newFont: UIFont) {
        font = newFont
        measureCellSize()
        glyphUVs.removeAll()
        setupAtlas()
        prerenderASCII()
        ringBufferCapacity = 0  // Force ring buffer reallocation on next rebuild.
        needsRedraw = true
    }

    var currentScale: CGFloat { scale }

    func updateTheme(_ newTheme: Theme) {
        theme = newTheme
        needsRedraw = true
    }

    func updateScale(_ newScale: CGFloat) {
        let clamped = max(newScale, 1.0)
        guard clamped != scale else { return }
        scale = clamped
        glyphUVs.removeAll()
        setupAtlas()
        prerenderASCII()
        needsRedraw = true
    }

    // MARK: - Cell Measurement

    private func measureCellSize() {
        let ct = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        var glyph = CTFontGetGlyphWithName(ct, "M" as CFString)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ct, .horizontal, &glyph, &advance, 1)
        cellWidth = ceil(advance.width)
        cellHeight = ceil(CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct))
    }

    // MARK: - Atlas Setup

    /// Create the persistent bitmap context and Metal texture for the glyph atlas.
    private func setupAtlas() {
        guard cellWidth > 0, cellHeight > 0 else { return }

        scaledCellWidth = ceil(cellWidth * scale)
        scaledCellHeight = ceil(cellHeight * scale)

        let scaledFontSize = font.pointSize * scale
        let ct = CTFontCreateWithName(font.fontName as CFString, scaledFontSize, nil)
        ctFont = ct
        fontAscent = CTFontGetAscent(ct)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        atlasContext = CGContext(
            data: nil,
            width: atlasWidth,
            height: atlasHeight,
            bitsPerComponent: 8,
            bytesPerRow: atlasWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        atlasContext?.clear(CGRect(x: 0, y: 0, width: atlasWidth, height: atlasHeight))

        atlasNextX = 0
        atlasNextY = 0
        glyphUVs.removeAll()

        // Create the Metal texture.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: atlasWidth,
            height: atlasHeight,
            mipmapped: false
        )
        desc.usage = .shaderRead
        atlasTexture = device.makeTexture(descriptor: desc)
        atlasDirty = true
        atlasDirtyMinY = 0
        atlasDirtyMaxY = atlasHeight
    }

    /// Pre-render ASCII printable characters (32-126) into the atlas.
    private func prerenderASCII() {
        for code in 32...126 {
            let ch = Character(UnicodeScalar(code)!)
            _ = ensureGlyph(ch)
        }
        flushAtlasToTexture()
    }

    // MARK: - Dynamic Glyph Rendering

    /// Ensure a character has been rendered into the atlas. Returns its UV info.
    @discardableResult
    private func ensureGlyph(_ char: Character) -> GlyphUV {
        if let existing = glyphUVs[char] { return existing }

        guard let ctx = atlasContext, let ct = ctFont else {
            let fallback = GlyphUV(u: 0, v: 0, uMax: 0, vMax: 0, cellSpan: 1)
            return fallback
        }

        // Determine if this is a wide character (CJK, fullwidth, etc.)
        let isWide = isWideCharacter(char)
        let glyphWidth = isWide ? scaledCellWidth * 2 : scaledCellWidth
        let cellSpan = isWide ? 2 : 1

        // Wrap to the next row if the glyph doesn't fit.
        if atlasNextX + glyphWidth > CGFloat(atlasWidth) {
            atlasNextX = 0
            atlasNextY += scaledCellHeight
        }
        // Atlas full — cannot add more glyphs.
        if atlasNextY + scaledCellHeight > CGFloat(atlasHeight) {
            logger.warning("Glyph atlas full, cannot add '\(String(char))'")
            let fallback = glyphUVs[" "] ?? GlyphUV(u: 0, v: 0, uMax: 0, vMax: 0, cellSpan: 1)
            return fallback
        }

        let str = String(char)
        let attrString = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
        CFAttributedStringReplaceString(attrString, CFRange(location: 0, length: 0), str as CFString)
        let fullRange = CFRange(location: 0, length: CFAttributedStringGetLength(attrString))
        CFAttributedStringSetAttribute(attrString, fullRange, kCTFontAttributeName, ct)

        let line = CTLineCreateWithAttributedString(attrString)

        // CG uses bottom-left origin. Position baseline correctly.
        let drawY = CGFloat(atlasHeight) - atlasNextY - scaledCellHeight + (scaledCellHeight - fontAscent)

        ctx.saveGState()
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.textPosition = CGPoint(x: atlasNextX, y: drawY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()

        let uv = GlyphUV(
            u: Float(atlasNextX) / Float(atlasWidth),
            v: Float(atlasNextY) / Float(atlasHeight),
            uMax: Float(atlasNextX + glyphWidth) / Float(atlasWidth),
            vMax: Float(atlasNextY + scaledCellHeight) / Float(atlasHeight),
            cellSpan: cellSpan
        )
        glyphUVs[char] = uv
        atlasNextX += glyphWidth
        atlasDirty = true

        let glyphRowY = Int(atlasNextY)
        let glyphRowBottom = Int(atlasNextY + scaledCellHeight)
        atlasDirtyMinY = min(atlasDirtyMinY, glyphRowY)
        atlasDirtyMaxY = max(atlasDirtyMaxY, glyphRowBottom)

        return uv
    }

    /// Upload changed rows of the bitmap context to the Metal texture.
    private func flushAtlasToTexture() {
        guard atlasDirty, let ctx = atlasContext, let basePtr = ctx.data else { return }

        let bytesPerRow = atlasWidth * 4

        // Determine upload region — dirty bounds or full fallback.
        let regionY: Int
        let regionHeight: Int
        if atlasDirtyMinY < atlasDirtyMaxY {
            regionY = atlasDirtyMinY
            regionHeight = min(atlasDirtyMaxY, atlasHeight) - regionY
        } else {
            regionY = 0
            regionHeight = atlasHeight
        }

        let offset = regionY * bytesPerRow
        let srcPtr = basePtr.advanced(by: offset)

        atlasTexture?.replace(
            region: MTLRegion(
                origin: MTLOrigin(x: 0, y: regionY, z: 0),
                size: MTLSize(width: atlasWidth, height: regionHeight, depth: 1)
            ),
            mipmapLevel: 0,
            withBytes: srcPtr,
            bytesPerRow: bytesPerRow
        )

        atlasDirty = false
        atlasDirtyMinY = Int.max
        atlasDirtyMaxY = 0
    }

    /// Heuristic to detect wide (2-cell) characters.
    private func isWideCharacter(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first else { return false }
        let v = scalar.value
        // CJK Unified Ideographs and extensions
        if (0x2E80...0x9FFF).contains(v) { return true }
        if (0xF900...0xFAFF).contains(v) { return true }
        // CJK Compatibility Ideographs
        if (0xFE30...0xFE4F).contains(v) { return true }
        // Hangul Syllables
        if (0xAC00...0xD7AF).contains(v) { return true }
        // Fullwidth Forms
        if (0xFF01...0xFF60).contains(v) { return true }
        if (0xFFE0...0xFFE6).contains(v) { return true }
        // CJK Unified Ideographs Extension B+
        if v >= 0x20000 && v <= 0x2FA1F { return true }
        return false
    }

    // MARK: - Metal Pipeline

    private func buildPipeline() {
        guard let library = device.makeDefaultLibrary() else {
            logger.error("Failed to load default Metal library")
            return
        }
        guard let vertexFunc = library.makeFunction(name: "terminalVertex"),
              let fragmentFunc = library.makeFunction(name: "terminalFragment") else {
            logger.error("Failed to load shader functions")
            return
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFunc
        desc.fragmentFunction = fragmentFunc
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            logger.error("Pipeline creation failed: \(error)")
        }
    }

    // MARK: - Vertex Buffer

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

        allocateRingBuffers(rows: rowRange.count, cols: cols)
        guard !ringBuffers.isEmpty else { return }

        let buf = ringBuffers[currentBufferIndex]
        let vertexPtr = buf.contents().bindMemory(to: CellVertex.self, capacity: ringBufferCapacity)
        var writeIndex = 0

        let cw = Float(cellWidth)
        let ch = Float(cellHeight)

        var newGlyphs = false

        // Pre-compute normalized selection bounds and color outside the loop.
        let selectionInfo: (start: (row: Int, col: Int), end: (row: Int, col: Int), bgColor: SIMD4<Float>)?
        if let sel = selectionRange {
            let normalized: (start: (row: Int, col: Int), end: (row: Int, col: Int))
            if sel.start.row < sel.end.row
                || (sel.start.row == sel.end.row && sel.start.col <= sel.end.col) {
                normalized = (start: sel.start, end: sel.end)
            } else {
                normalized = (start: sel.end, end: sel.start)
            }
            let sc = theme.selection
            selectionInfo = (
                start: normalized.start,
                end: normalized.end,
                bgColor: SIMD4<Float>(
                    Float(sc.r) / 255.0,
                    Float(sc.g) / 255.0,
                    Float(sc.b) / 255.0,
                    1.0
                )
            )
        } else {
            selectionInfo = nil
        }

        // Pre-compute cursor rendering info.
        let cursorInfo: (row: Int, col: Int, style: CursorStyle, color: SIMD4<Float>)?
        if !isScrollback, let buf = buffer {
            let cc = theme.cursor
            cursorInfo = (
                row: buf.cursorRow,
                col: buf.cursorCol,
                style: isFocused ? buf.cursorStyle : .block,
                color: SIMD4<Float>(
                    Float(cc.r) / 255.0,
                    Float(cc.g) / 255.0,
                    Float(cc.b) / 255.0,
                    1.0
                )
            )
        } else {
            cursorInfo = nil
        }

        // Single pass: discover new glyphs and build vertex data together.
        rowLoop: for row in rowRange {
            let screenRow = row - rowRange.lowerBound

            for col in 0..<cols {
                let cell = source.cellAt(row: row, col: col)
                let isCursorCell = cursorInfo.map { $0.row == row && $0.col == col } ?? false
                if cell.width == 0 && !isCursorCell { continue }

                // Inline glyph discovery (ensureGlyph is idempotent).
                if cell.character != " " && glyphUVs[cell.character] == nil {
                    ensureGlyph(cell.character)
                    newGlyphs = true
                }

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

                // Cursor rendering.
                var cursorUnderline = false
                var cursorBar = false
                if let ci = cursorInfo, row == ci.row && col == ci.col {
                    if isFocused {
                        switch ci.style {
                        case .block:
                            // Filled block: cursor color as bg, theme bg as fg (for contrast).
                            bg = ci.color
                            fg = SIMD4<Float>(
                                Float(theme.background.r) / 255.0,
                                Float(theme.background.g) / 255.0,
                                Float(theme.background.b) / 255.0,
                                1.0
                            )
                        case .underline:
                            cursorUnderline = true
                        case .bar:
                            cursorBar = true
                        }
                    }
                    // Unfocused: hollow block outline is added below after the cell quad.
                }

                // Selection highlight: override background with theme selection color.
                if let sel = selectionInfo {
                    let inSelection: Bool
                    if screenRow > sel.start.row && screenRow < sel.end.row {
                        inSelection = true
                    } else if screenRow == sel.start.row && screenRow == sel.end.row {
                        inSelection = col >= sel.start.col && col <= sel.end.col
                    } else if screenRow == sel.start.row {
                        inSelection = col >= sel.start.col
                    } else if screenRow == sel.end.row {
                        inSelection = col <= sel.end.col
                    } else {
                        inSelection = false
                    }

                    if inSelection {
                        bg = sel.bgColor
                    }
                }

                let uv = glyphUVs[cell.character] ?? spaceUV
                let cellSpan = max(Int(cell.width), 1)
                let quadWidth = cw * Float(cellSpan)

                let x0 = Float(col) * cw
                let y0 = Float(screenRow) * ch
                let x1 = x0 + quadWidth
                let y1 = y0 + ch

                guard writeIndex + 6 <= ringBufferCapacity else { break rowLoop }
                vertexPtr[writeIndex]     = CellVertex(position: SIMD2(x0, y0), uv: SIMD2(uv.u, uv.v), fgColor: fg, bgColor: bg)
                vertexPtr[writeIndex + 1] = CellVertex(position: SIMD2(x1, y0), uv: SIMD2(uv.uMax, uv.v), fgColor: fg, bgColor: bg)
                vertexPtr[writeIndex + 2] = CellVertex(position: SIMD2(x0, y1), uv: SIMD2(uv.u, uv.vMax), fgColor: fg, bgColor: bg)
                vertexPtr[writeIndex + 3] = CellVertex(position: SIMD2(x1, y0), uv: SIMD2(uv.uMax, uv.v), fgColor: fg, bgColor: bg)
                vertexPtr[writeIndex + 4] = CellVertex(position: SIMD2(x1, y1), uv: SIMD2(uv.uMax, uv.vMax), fgColor: fg, bgColor: bg)
                vertexPtr[writeIndex + 5] = CellVertex(position: SIMD2(x0, y1), uv: SIMD2(uv.u, uv.vMax), fgColor: fg, bgColor: bg)
                writeIndex += 6

                // Draw cursor overlays (underline, bar, or hollow block).
                if let ci = cursorInfo, row == ci.row && col == ci.col {
                    let spUV = spaceUV
                    if isFocused && cursorUnderline {
                        let uy0 = y1 - 2
                        let c = ci.color
                        guard writeIndex + 6 <= ringBufferCapacity else { break rowLoop }
                        vertexPtr[writeIndex]     = CellVertex(position: SIMD2(x0, uy0), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 1] = CellVertex(position: SIMD2(x0 + cw, uy0), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 2] = CellVertex(position: SIMD2(x0, y1), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 3] = CellVertex(position: SIMD2(x0 + cw, uy0), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 4] = CellVertex(position: SIMD2(x0 + cw, y1), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 5] = CellVertex(position: SIMD2(x0, y1), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        writeIndex += 6
                    } else if isFocused && cursorBar {
                        let bx1 = x0 + 2
                        let c = ci.color
                        guard writeIndex + 6 <= ringBufferCapacity else { break rowLoop }
                        vertexPtr[writeIndex]     = CellVertex(position: SIMD2(x0, y0), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 1] = CellVertex(position: SIMD2(bx1, y0), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 2] = CellVertex(position: SIMD2(x0, y1), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 3] = CellVertex(position: SIMD2(bx1, y0), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 4] = CellVertex(position: SIMD2(bx1, y1), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 5] = CellVertex(position: SIMD2(x0, y1), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        writeIndex += 6
                    } else if !isFocused {
                        let t: Float = 1.5
                        let c = ci.color
                        guard writeIndex + 24 <= ringBufferCapacity else { break rowLoop }
                        // Top edge
                        vertexPtr[writeIndex]     = CellVertex(position: SIMD2(x0, y0), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 1] = CellVertex(position: SIMD2(x0 + cw, y0), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 2] = CellVertex(position: SIMD2(x0, y0 + t), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 3] = CellVertex(position: SIMD2(x0 + cw, y0), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 4] = CellVertex(position: SIMD2(x0 + cw, y0 + t), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 5] = CellVertex(position: SIMD2(x0, y0 + t), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        // Bottom edge
                        vertexPtr[writeIndex + 6]  = CellVertex(position: SIMD2(x0, y1 - t), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 7]  = CellVertex(position: SIMD2(x0 + cw, y1 - t), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 8]  = CellVertex(position: SIMD2(x0, y1), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 9]  = CellVertex(position: SIMD2(x0 + cw, y1 - t), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 10] = CellVertex(position: SIMD2(x0 + cw, y1), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 11] = CellVertex(position: SIMD2(x0, y1), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        // Left edge
                        vertexPtr[writeIndex + 12] = CellVertex(position: SIMD2(x0, y0 + t), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 13] = CellVertex(position: SIMD2(x0 + t, y0 + t), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 14] = CellVertex(position: SIMD2(x0, y1 - t), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 15] = CellVertex(position: SIMD2(x0 + t, y0 + t), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 16] = CellVertex(position: SIMD2(x0 + t, y1 - t), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 17] = CellVertex(position: SIMD2(x0, y1 - t), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        // Right edge
                        vertexPtr[writeIndex + 18] = CellVertex(position: SIMD2(x0 + cw - t, y0 + t), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 19] = CellVertex(position: SIMD2(x0 + cw, y0 + t), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 20] = CellVertex(position: SIMD2(x0 + cw - t, y1 - t), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 21] = CellVertex(position: SIMD2(x0 + cw, y0 + t), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 22] = CellVertex(position: SIMD2(x0 + cw, y1 - t), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        vertexPtr[writeIndex + 23] = CellVertex(position: SIMD2(x0 + cw - t, y1 - t), uv: SIMD2(spUV.u, spUV.v), fgColor: c, bgColor: c)
                        writeIndex += 24
                    }
                }
            }
        }

        // Flush any newly discovered glyphs before building the vertex buffer.
        if newGlyphs { flushAtlasToTexture() }

        ringVertexCounts[currentBufferIndex] = writeIndex
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let scale = view.contentScaleFactor
        cachedViewportSize = SIMD2<Float>(
            Float(size.width / scale),
            Float(size.height / scale)
        )
        needsRedraw = true
        view.setNeedsDisplay()
    }

    func draw(in view: MTKView) {
        guard let pipelineState,
              cachedViewportSize.x > 0, cachedViewportSize.y > 0
        else { return }

        frameSemaphore.wait()

        guard let drawable = view.currentDrawable,
              let renderPassDesc = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc)
        else {
            frameSemaphore.signal()
            return
        }

        if needsRedraw {
            if Thread.isMainThread {
                rebuildVertices()
            } else {
                DispatchQueue.main.sync { [self] in
                    rebuildVertices()
                }
            }
            needsRedraw = false
        }

        let bufferIndex = currentBufferIndex
        let vertexCount = ringVertexCounts[bufferIndex]
        currentBufferIndex = (currentBufferIndex + 1) % Self.maxFramesInFlight

        var viewportSize = cachedViewportSize

        encoder.setRenderPipelineState(pipelineState)

        if bufferIndex < ringBuffers.count {
            encoder.setVertexBuffer(ringBuffers[bufferIndex], offset: 0, index: 0)
        }
        encoder.setVertexBytes(&viewportSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)

        if let atlas = atlasTexture {
            encoder.setFragmentTexture(atlas, index: 0)
        }

        if vertexCount > 0 {
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)

        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.frameSemaphore.signal()
        }
        commandBuffer.commit()
    }
}
