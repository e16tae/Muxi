#include <metal_stdlib>
using namespace metal;

// MARK: - Types

/// Per-vertex data produced by the CPU.
/// Layout **must** match `TerminalRenderer.CellVertex` in Swift.
struct CellVertex {
    float2 position;   // screen position in pixels
    float2 uv;         // glyph atlas texture coordinate
    float4 fgColor;    // foreground RGBA
    float4 bgColor;    // background RGBA
};

/// Interpolated data passed from the vertex shader to the fragment shader.
struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float4 fgColor;
    float4 bgColor;
};

// MARK: - Vertex Shader

/// Converts pixel-space cell positions into Metal clip space [-1, 1] and
/// passes through the UV coordinates and colors.
vertex VertexOut terminalVertex(
    const device CellVertex *vertices [[buffer(0)]],
    const device float2     &viewportSize [[buffer(1)]],
    uint                     vid [[vertex_id]]
) {
    VertexOut out;

    float2 pixelPos = vertices[vid].position;

    // Pixel coordinates -> clip space.
    //   x: [0, width]  -> [-1, 1]
    //   y: [0, height] -> [ 1,-1]  (Metal's Y points up; we want top-down)
    out.position = float4(
        (pixelPos.x / viewportSize.x) * 2.0 - 1.0,
        1.0 - (pixelPos.y / viewportSize.y) * 2.0,
        0.0,
        1.0
    );

    out.uv      = vertices[vid].uv;
    out.fgColor = vertices[vid].fgColor;
    out.bgColor = vertices[vid].bgColor;

    return out;
}

// MARK: - Fragment Shader

/// Samples the glyph atlas and blends foreground/background colors based on
/// the glyph alpha.  Where the atlas has a white glyph (alpha > 0) the
/// foreground color is shown; everywhere else the background color fills in.
fragment float4 terminalFragment(
    VertexOut             in         [[stage_in]],
    texture2d<float>      glyphAtlas [[texture(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float4 texColor = glyphAtlas.sample(textureSampler, in.uv);

    // The atlas stores white glyphs on a transparent background.  Use the
    // sampled alpha to lerp between the cell's background and foreground.
    float alpha = texColor.a;
    float4 color = mix(in.bgColor, in.fgColor, alpha);
    return color;
}
