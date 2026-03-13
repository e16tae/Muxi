# ADR-0003: Metal GPU rendering with Retina glyph atlas

## Status

Accepted

## Date

2026-02-28

## Context

The terminal view must render monospaced text at 60fps during scrolling, resize, and rapid output. Mobile GPUs are efficient at textured quad rendering. The app targets iOS devices with Retina displays (2x/3x scale factor).

## Decision

Use Metal for terminal rendering with a pre-rasterized glyph atlas texture. Rasterize glyphs at the device's `contentScaleFactor` (2x or 3x) for sharp text on Retina displays.

Each character cell is a textured quad. The vertex buffer is rebuilt when terminal content changes. The fragment shader samples the glyph atlas and mixes foreground/background colors.

Use on-demand rendering (`isPaused=true`, `enableSetNeedsDisplay=true`) to avoid unnecessary GPU work when terminal content is static.

## Alternatives Considered

### CoreText + CALayer

Render text using CoreText attributed strings into CALayers or UILabels per line.

Rejected because:
- CoreText layout is CPU-bound — at terminal throughput rates (thousands of characters per frame), CPU becomes the bottleneck
- Layer compositing overhead scales linearly with visible lines
- Cannot achieve consistent 60fps during rapid output scrolling on older devices

### 1x glyph atlas with GPU scaling

Rasterize the glyph atlas at 1x resolution and let the GPU scale up.

Rejected because:
- Text appears blurry on Retina displays (2x/3x)
- Monospaced terminal text makes blurriness especially noticeable
- The memory cost difference between 1x and 2x atlas is acceptable (~4x pixels but still small for a monospace character set)

## Consequences

- (+) Consistent 60fps terminal scrolling on all supported iOS devices
- (+) Sharp text at native Retina resolution
- (+) On-demand rendering saves battery when terminal is idle
- (-) Metal shader and renderer code is more complex than CoreText
- (-) Must manage glyph atlas lifecycle (rebuild on font size change, scale factor change)
- (-) Viewport sizing requires care — use `drawableSizeWillChange` not `view.bounds` (bounds lag during animated resizes)
