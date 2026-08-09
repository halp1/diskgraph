#include <metal_stdlib>
using namespace metal;

// Must match `CellInstance` in DiskGraphLayout and `GraphUniforms`/`GraphDrawParams`
// in ShaderTypes.swift. CellInstanceLayoutTests pins the Swift-side strides.

struct CellInstance {
    float4 pie;        // innerRadius, outerRadius, startAngle, endAngle
    float4 rect;       // x, y, width, height  (normalised, y down)
    uint   color;      // RGBA8, little endian
    float  pieAlpha;
    float  rectAlpha;
    uint   nodeID;
    uint   flags;
};

struct GraphUniforms {
    // float4s first: they set the 16-byte alignment, so every scalar below lands at the
    // same offset as its Swift counterpart with no padding to reason about.
    float4 borderColor;
    float4 dimTarget;
    float2 viewportSize;
    float2 pieCenter;
    float  pieRadius;
    // Which geometry this pass draws: 0 = pie, 1 = tree map. Switching graph type
    // cross-dissolves by encoding both passes with complementary opacities rather than
    // interpolating one shape into the other.
    float  shape;
    float  opacity;
    float  blend;
    uint   highlightedCell;
    float  borderWidth;
    float  directoryBorderWidth;
    float  searchDim;
    uint   renderPass;
    float  highlightStrength;
};

struct GraphDrawParams {
    uint instanceOffset;
    uint subdivisions;
};

constant uint kFlagDirectory  = 1u << 0;
constant uint kFlagMerged     = 1u << 1;
constant uint kFlagSearchMiss = 1u << 2;
constant uint kFlagPackage    = 1u << 3;
constant uint kFlagInTreeMap  = 1u << 4;

constant uint kPassFill            = 0u;
constant uint kPassDirectoryBorder = 1u;

struct Varyings {
    float4 position [[position]];
    // Cell-local coordinates: u runs along the cell, v across it. Both graphs share this
    // parameterisation, which is what lets one border calculation serve arcs, rectangles
    // and every intermediate shape during the morph.
    float2 uv;
    float4 fill;
    float  alpha;
    float  borderWidth;
};

// Straight alpha in, premultiplied out.
static inline float4 unpackColor(uint packed) {
    return unpack_unorm4x8_to_float(packed);
}

vertex Varyings graph_vertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    device const CellInstance *cellsFrom [[buffer(0)]],
    device const uint *renderOrder [[buffer(1)]],
    constant GraphUniforms &uniforms [[buffer(2)]],
    constant GraphDrawParams &params [[buffer(3)]],
    device const CellInstance *cellsTo [[buffer(4)]])
{
    const uint cellIndex = renderOrder[params.instanceOffset + instanceID];

    // Two orthogonal interpolations. `blend` moves between two layouts of *different*
    // subtrees — the navigation animation — and is resolved first, per cell. `morph`
    // then moves between the polar and rectangular shape of that blended cell. Both
    // buffers share an index order, so a node's two states line up.
    const CellInstance a = cellsFrom[cellIndex];
    const CellInstance b = cellsTo[cellIndex];
    const float blend = uniforms.blend;

    const float4 piePart = mix(a.pie, b.pie, blend);
    const float4 rectPart = mix(a.rect, b.rect, blend);
    const float pieAlpha = mix(a.pieAlpha, b.pieAlpha, blend);
    const float rectAlpha = mix(a.rectAlpha, b.rectAlpha, blend);
    const uint flags = blend < 0.5 ? a.flags : b.flags;

    // A triangle strip of 2*(K+1) vertices: k walks along the cell, side crosses it.
    const uint k = vertexID >> 1;
    const uint side = vertexID & 1u;
    const float u = float(k) / float(params.subdivisions);
    const float v = float(side);

    // Pie: interpolate radius across the ring and angle along the sweep. Angles run
    // clockwise from twelve o'clock and the viewport is y-down, so "up" is -y.
    const float radius = mix(piePart.x, piePart.y, v) * uniforms.pieRadius;
    const float angle = mix(piePart.z, piePart.w, u);
    const float2 piePosition = uniforms.pieCenter + float2(sin(angle), -cos(angle)) * radius;

    // Tree map: the same (u, v) bilinearly across the rectangle.
    const float2 rectPosition = float2(
        (rectPart.x + u * rectPart.z) * uniforms.viewportSize.x,
        (rectPart.y + v * rectPart.w) * uniforms.viewportSize.y);

    const bool drawingTreeMap = uniforms.shape > 0.5;
    const float2 position = drawingTreeMap ? rectPosition : piePosition;

    Varyings out;
    out.position = float4(
        position.x / uniforms.viewportSize.x * 2.0 - 1.0,
        1.0 - position.y / uniforms.viewportSize.y * 2.0,
        0.0, 1.0);
    out.uv = float2(u, v);

    const bool isDirectory = (flags & kFlagDirectory) != 0;
    float alpha = drawingTreeMap ? rectAlpha : pieAlpha;

    if (uniforms.renderPass == kPassDirectoryBorder) {
        // Outline-only pass: draw the directory's boundary over the leaves inside it.
        // Keyed off the flag rather than alpha, because tree-map directories are
        // deliberately unfilled.
        const bool outlined = isDirectory && (flags & kFlagInTreeMap) != 0;
        alpha = (outlined && drawingTreeMap) ? 1.0 : 0.0;
        out.borderWidth = uniforms.directoryBorderWidth;
    } else {
        out.borderWidth = uniforms.borderWidth;
    }
    alpha *= uniforms.opacity;

    float4 colour = mix(unpackColor(a.color), unpackColor(b.color), blend);
    if (cellIndex == uniforms.highlightedCell) {
        // Hover darkens the cell in place, as in the reference app.
        colour.rgb *= uniforms.highlightStrength;
    }
    if ((flags & kFlagSearchMiss) != 0) {
        colour.rgb = mix(colour.rgb, uniforms.dimTarget.rgb, uniforms.searchDim);
    }

    out.fill = colour;
    out.alpha = alpha;
    return out;
}

fragment float4 graph_fragment(
    Varyings in [[stage_in]],
    constant GraphUniforms &uniforms [[buffer(2)]])
{
    // Distance to the nearest cell edge, converted from cell-local units to pixels via
    // the screen-space derivative. This yields a constant-width antialiased outline for
    // arcs, rectangles and every shape in between, with no geometry of its own.
    const float2 duv = max(fwidth(in.uv), float2(1e-6));
    const float2 edge = min(in.uv, 1.0 - in.uv) / duv;
    const float distanceToEdge = min(edge.x, edge.y);

    const float halfWidth = in.borderWidth * 0.5;
    float border = 1.0 - smoothstep(halfWidth - 0.5, halfWidth + 0.5, distanceToEdge);

    // A cell only a pixel or two across would be entirely border, turning dense regions
    // into a black mush. Fade the outline out as the cell approaches that size.
    const float2 cellPixels = 1.0 / duv;
    border *= smoothstep(0.9, 2.4, min(cellPixels.x, cellPixels.y));

    const float3 borderColour = uniforms.borderColor.rgb;

    if (uniforms.renderPass == kPassDirectoryBorder) {
        // Nothing but the outline itself contributes in this pass.
        const float alpha = border * in.alpha;
        if (alpha <= 0.001) { discard_fragment(); }
        return float4(borderColour * alpha, alpha);
    }

    if (in.alpha <= 0.001) { discard_fragment(); }

    // Composite the outline over the fill, premultiplied.
    const float3 premultipliedFill = in.fill.rgb * in.alpha;
    const float3 rgb = premultipliedFill * (1.0 - border) + borderColour * border;
    const float alpha = in.alpha * (1.0 - border) + border;
    return float4(rgb, alpha);
}
