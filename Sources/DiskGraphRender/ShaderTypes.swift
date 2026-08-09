import simd

/// Per-frame constants shared with `GraphUniforms` in `Graph.metal`.
///
/// The two `SIMD4<Float>` fields come first deliberately. They force 16-byte alignment,
/// and putting them at the front means every following scalar sits at the same offset on
/// both sides without any padding guesswork. `GraphUniformsLayoutTests` pins the result.
public struct GraphUniforms: Equatable {
    /// Cell outline colour — dark on a light background, light on a dark one. `w` unused.
    public var borderColor: SIMD4<Float> = SIMD4(0.10, 0.10, 0.10, 1)
    /// Colour search misses fade towards, so they recede into the background. `w` unused.
    public var dimTarget: SIMD4<Float> = SIMD4(0.93, 0.93, 0.93, 1)

    /// Drawable size in points.
    public var viewportSize: SIMD2<Float> = .zero
    /// Centre of the pie in points.
    public var pieCenter: SIMD2<Float> = .zero

    /// Pie radius in points.
    public var pieRadius: Float = 0
    /// Which geometry to draw: 0 the pie chart, 1 the tree map.
    ///
    /// Not an interpolation. Folding an annular sector into a rectangle only makes sense
    /// for cells that exist in both graphs, and most do not — interior directories are
    /// unfilled in the tree map, and files below the ring limit are absent from the pie.
    /// Interpolating them anyway makes every one of them half-transparent for the whole
    /// transition, which looks like overlapping ghosts. Switching graph type therefore
    /// encodes both shapes as two passes with complementary `opacity`, a clean dissolve.
    public var shape: Float = 0
    /// Multiplier on every cell's alpha, used for the cross-dissolve.
    public var opacity: Float = 1
    /// Blends the "from" instance buffer into the "to" buffer. Drives navigation
    /// transitions, and is orthogonal to `morph` so the two compose.
    public var blend: Float = 0
    /// Index into the instance buffer of the hovered cell, or `noHighlight`.
    public var highlightedCell: UInt32 = GraphUniforms.noHighlight

    /// Cell outline width in points.
    public var borderWidth: Float = 1
    /// Heavier outline drawn around directories in the tree map.
    public var directoryBorderWidth: Float = 1.75
    /// How far non-matching cells fade towards `dimTarget` while searching.
    public var searchDim: Float = 0.82
    /// 0 draws cell fills, 1 draws the directory outline pass on top.
    public var renderPass: UInt32 = 0
    /// Multiplier applied to the hovered cell so it darkens in place.
    public var highlightStrength: Float = 0.72

    public static let noHighlight: UInt32 = .max

    public init() {}
}

/// Constants for one LOD-bucketed draw call.
public struct GraphDrawParams {
    /// Offset into the render-order buffer where this bucket starts.
    public var instanceOffset: UInt32
    /// Angular subdivisions each instance in this bucket is tessellated with.
    public var subdivisions: UInt32

    public init(instanceOffset: UInt32, subdivisions: UInt32) {
        self.instanceOffset = instanceOffset
        self.subdivisions = subdivisions
    }
}

/// Tessellation buckets. Almost every cell in a dense graph is a sliver that needs a
/// single quad; only the few large wedges pay for a smooth arc.
public enum LODBucket {
    public static let subdivisions: [Int] = [1, 4, 16, 64]

    public static func index(forSubdivisions needed: Int) -> Int {
        for (index, value) in subdivisions.enumerated() where needed <= value { return index }
        return subdivisions.count - 1
    }
}
