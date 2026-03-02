import MetalKit
import CoreText
import UIKit
import os

// MARK: - TerminalRenderer

/// Metal-based terminal renderer.
///
/// Renders a ``TerminalBuffer`` combined with a ``Theme`` as a grid of colored
/// glyphs.  The renderer builds a **glyph atlas** texture once (for ASCII
/// printable characters 32-126) and then, on every frame that requires a
/// redraw, rebuilds a per-cell vertex buffer that pairs screen positions with
/// UV coordinates, foreground colors, and background colors.
///
/// Usage:
/// ```swift
/// let renderer = TerminalRenderer(device: mtlDevice, font: font, theme: theme)
/// renderer.buffer = terminalBuffer
/// mtkView.delegate = renderer
/// ```
final class TerminalRenderer: NSObject, MTKViewDelegate {

    private let logger = Logger(subsystem: "com.muxi.app", category: "TerminalRenderer")

    // MARK: - Configuration

    /// Width of a single monospace cell in points.
    private(set) var cellWidth: CGFloat = 0
    /// Height of a single monospace cell in points.
    private(set) var cellHeight: CGFloat = 0

    private var font: UIFont
    private var theme: Theme

    // MARK: - Metal State

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?

    // MARK: - Glyph Atlas

    private var atlasTexture: MTLTexture?
    /// UV coordinates in the glyph atlas for each cached character.
    private var glyphUVs: [Character: GlyphUV] = [:]

    /// UV rectangle within the glyph atlas texture.
    struct GlyphUV {
        /// Top-left U coordinate.
        let u: Float
        /// Top-left V coordinate.
        let v: Float
        /// Bottom-right U coordinate.
        let uMax: Float
        /// Bottom-right V coordinate.
        let vMax: Float
    }

    // MARK: - Vertex Data

    /// Per-vertex data sent to the GPU.  Each cell is drawn as two triangles
    /// (6 vertices) sharing position, UV, and color attributes.
    ///
    /// The layout **must** match the `CellVertex` struct in `Shaders.metal`.
    struct CellVertex {
        var position: SIMD2<Float>   // screen position in pixels
        var uv: SIMD2<Float>         // glyph atlas texture coordinate
        var fgColor: SIMD4<Float>    // foreground RGBA
        var bgColor: SIMD4<Float>    // background RGBA
    }

    private var vertexBuffer: MTLBuffer?
    private var vertexCount: Int = 0

    // MARK: - Buffer Reference

    /// The terminal buffer to render.  Set this and flip ``needsRedraw`` when
    /// the buffer contents change.
    var buffer: TerminalBuffer?
    /// Set to `true` to force a vertex-buffer rebuild on the next frame.
    var needsRedraw: Bool = true

    // MARK: - Init

    /// Create a new Metal terminal renderer.
    ///
    /// - Parameters:
    ///   - device: The `MTLDevice` to use for rendering.
    ///   - font: A monospace `UIFont` used for glyph measurements and atlas
    ///     generation.
    ///   - theme: The terminal color theme.
    /// - Returns: `nil` if the Metal command queue could not be created.
    init?(device: MTLDevice, font: UIFont, theme: Theme) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.font = font
        self.theme = theme
        super.init()

        measureCellSize()
        buildPipeline()
        buildGlyphAtlas()
    }

    // MARK: - Public Helpers

    /// Reconfigure the renderer with a new font.  This remeasures cell
    /// dimensions and rebuilds the glyph atlas.
    func updateFont(_ newFont: UIFont) {
        font = newFont
        measureCellSize()
        buildGlyphAtlas()
        needsRedraw = true
    }

    /// Reconfigure the renderer with a new theme.  Only triggers a vertex
    /// rebuild (colors change, atlas does not).
    func updateTheme(_ newTheme: Theme) {
        theme = newTheme
        needsRedraw = true
    }

    // MARK: - Cell Measurement

    /// Derive `cellWidth` and `cellHeight` from the current font metrics.
    private func measureCellSize() {
        let ctFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        // Use a reference glyph ("M") to determine the advance width.
        var glyph = CTFontGetGlyphWithName(ctFont, "M" as CFString)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
        cellWidth = ceil(advance.width)
        cellHeight = ceil(CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont))
    }

    // MARK: - Glyph Atlas Generation

    /// Build a texture containing white-on-transparent renderings of ASCII
    /// printable characters (32-126).  The resulting atlas is stored in
    /// ``atlasTexture`` and per-glyph UV coordinates in ``glyphUVs``.
    private func buildGlyphAtlas() {
        guard cellWidth > 0, cellHeight > 0 else { return }

        let chars: [Character] = (32...126).map { Character(UnicodeScalar($0)) }
        let atlasWidth = 1024
        let atlasHeight = 1024

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: atlasWidth,
            height: atlasHeight,
            bitsPerComponent: 8,
            bytesPerRow: atlasWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        // Clear to transparent black.
        ctx.clear(CGRect(x: 0, y: 0, width: atlasWidth, height: atlasHeight))

        let ctFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        let ascent = CTFontGetAscent(ctFont)

        var x: CGFloat = 0
        var y: CGFloat = 0 // row origin (top of glyph row in flipped coords)
        glyphUVs.removeAll()

        for char in chars {
            // Wrap to the next row if the current glyph would overflow.
            if x + cellWidth > CGFloat(atlasWidth) {
                x = 0
                y += cellHeight
            }
            if y + cellHeight > CGFloat(atlasHeight) {
                break // atlas full — should not happen for 95 ASCII glyphs
            }

            let str = String(char)
            let attrString = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
            CFAttributedStringReplaceString(attrString, CFRange(location: 0, length: 0), str as CFString)
            let fullRange = CFRange(location: 0, length: CFAttributedStringGetLength(attrString))
            CFAttributedStringSetAttribute(attrString, fullRange, kCTFontAttributeName, ctFont)

            let line = CTLineCreateWithAttributedString(attrString)

            // Core Graphics uses a bottom-left origin.  We lay out rows from
            // the top of the bitmap, so `drawY` positions the baseline.
            let drawY = CGFloat(atlasHeight) - y - cellHeight + (cellHeight - ascent)

            ctx.saveGState()
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.textPosition = CGPoint(x: x, y: drawY)
            CTLineDraw(line, ctx)
            ctx.restoreGState()

            // UV coordinates (origin top-left in texture space for Metal).
            let u    = Float(x) / Float(atlasWidth)
            let v    = Float(y) / Float(atlasHeight)
            let uMax = Float(x + cellWidth) / Float(atlasWidth)
            let vMax = Float(y + cellHeight) / Float(atlasHeight)

            glyphUVs[char] = GlyphUV(u: u, v: v, uMax: uMax, vMax: vMax)
            x += cellWidth
        }

        // Transfer the rendered image to a Metal texture.
        guard let image = ctx.makeImage(),
              let dataProvider = image.dataProvider,
              let cfData = dataProvider.data,
              let bytes = CFDataGetBytePtr(cfData) else { return }

        let textureDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: atlasWidth,
            height: atlasHeight,
            mipmapped: false
        )
        textureDesc.usage = .shaderRead
        atlasTexture = device.makeTexture(descriptor: textureDesc)

        atlasTexture?.replace(
            region: MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: atlasWidth, height: atlasHeight, depth: 1)
            ),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: atlasWidth * 4
        )
    }

    // MARK: - Metal Pipeline

    /// Build the render pipeline state from the vertex and fragment functions
    /// defined in `Shaders.metal`.
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

        // Enable alpha blending so glyph edges blend smoothly.
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

    /// Rebuild the vertex buffer from the current ``buffer`` and ``theme``.
    ///
    /// Each terminal cell maps to **6 vertices** (2 triangles forming a quad).
    /// Every vertex carries screen-space position, atlas UV, foreground color,
    /// and background color.
    func rebuildVertices() {
        guard let buffer = buffer else { return }

        let rows = buffer.rows
        let cols = buffer.cols
        let spaceUV = glyphUVs[" "] ?? GlyphUV(u: 0, v: 0, uMax: 0, vMax: 0)

        var vertices: [CellVertex] = []
        vertices.reserveCapacity(rows * cols * 6)

        let cw = Float(cellWidth)
        let ch = Float(cellHeight)

        for row in 0..<rows {
            for col in 0..<cols {
                let cell = buffer.cellAt(row: row, col: col)

                // Resolve colors via theme, respecting the inverse attribute.
                var fgTermColor = cell.fgColor
                var bgTermColor = cell.bgColor
                if cell.isInverse {
                    swap(&fgTermColor, &bgTermColor)
                }

                let fgTheme = theme.resolve(fgTermColor, isForeground: true)
                let bgTheme = theme.resolve(bgTermColor, isForeground: false)

                let fg = SIMD4<Float>(
                    Float(fgTheme.r) / 255.0,
                    Float(fgTheme.g) / 255.0,
                    Float(fgTheme.b) / 255.0,
                    1.0
                )
                let bg = SIMD4<Float>(
                    Float(bgTheme.r) / 255.0,
                    Float(bgTheme.g) / 255.0,
                    Float(bgTheme.b) / 255.0,
                    1.0
                )

                // Quad corners in pixel coordinates.
                let x0 = Float(col) * cw
                let y0 = Float(row) * ch
                let x1 = x0 + cw
                let y1 = y0 + ch

                // Atlas UVs (fall back to space for unknown characters).
                let uv = glyphUVs[cell.character] ?? spaceUV

                // Triangle 1 (top-left, top-right, bottom-left).
                vertices.append(CellVertex(
                    position: SIMD2(x0, y0), uv: SIMD2(uv.u, uv.v),
                    fgColor: fg, bgColor: bg))
                vertices.append(CellVertex(
                    position: SIMD2(x1, y0), uv: SIMD2(uv.uMax, uv.v),
                    fgColor: fg, bgColor: bg))
                vertices.append(CellVertex(
                    position: SIMD2(x0, y1), uv: SIMD2(uv.u, uv.vMax),
                    fgColor: fg, bgColor: bg))

                // Triangle 2 (top-right, bottom-right, bottom-left).
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

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // The viewport changed — force a redraw so the projection matches.
        needsRedraw = true
    }

    func draw(in view: MTKView) {
        guard let pipelineState,
              let drawable = view.currentDrawable,
              let renderPassDesc = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc)
        else { return }

        // Vertex rebuild reads TerminalBuffer which is mutated on @MainActor.
        // Dispatch to main to avoid concurrent access from the render thread.
        // Guard against deadlock when draw(in:) is called from the main thread
        // (e.g. enableSetNeedsDisplay mode or manual draw() calls).
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

        // Uniform: viewport size so the vertex shader can convert pixel
        // coordinates to Metal clip space.
        var viewportSize = SIMD2<Float>(
            Float(view.drawableSize.width),
            Float(view.drawableSize.height)
        )

        encoder.setRenderPipelineState(pipelineState)

        if let vb = vertexBuffer {
            encoder.setVertexBuffer(vb, offset: 0, index: 0)
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
        commandBuffer.commit()
    }
}
