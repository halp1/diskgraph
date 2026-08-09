import DiskGraphCore
import simd

/// Which graph the window is showing. Mirrors View ▸ Graph Type.
public enum GraphType: String, CaseIterable, Sendable, Codable {
    case pieChart
    case treeMap

    public var localizedName: String {
        switch self {
        case .pieChart: return "Pie Chart"
        case .treeMap: return "Tree Map"
        }
    }
}

public struct CellFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let directory = CellFlags(rawValue: 1 << 0)
    /// A synthetic cell standing in for siblings too small to draw. Rendered gray and
    /// never navigable.
    public static let merged = CellFlags(rawValue: 1 << 1)
    /// Dimmed because a search is active and this cell does not match.
    public static let searchMiss = CellFlags(rawValue: 1 << 2)
    public static let package = CellFlags(rawValue: 1 << 3)
    /// The tree map laid this cell out. Directories carry it with `rectAlpha == 0` — they
    /// are not filled, but the border pass still needs to outline them, including the
    /// ones deeper than the pie's ring limit.
    public static let inTreeMap = CellFlags(rawValue: 1 << 4)
}

/// One drawable cell, carrying *both* the polar and the rectangular geometry.
///
/// Holding both on the same instance is what makes the pie ↔ tree map transition a
/// single `mix()` in the vertex shader against a scalar uniform — no per-frame CPU work
/// and no second vertex buffer. `pieAlpha`/`rectAlpha` let a cell exist in one graph but
/// not the other: interior directories are invisible in the tree map (which draws only
/// leaves) and files below the visible ring count are invisible in the pie.
///
/// Field order and padding must stay in sync with `CellInstance` in `Graph.metal`.
public struct CellInstance: Equatable {
    /// `(innerRadius, outerRadius, startAngle, endAngle)`. Radii are fractions of the
    /// graph radius; angles are radians measured clockwise from twelve o'clock.
    public var pie: SIMD4<Float>
    /// `(x, y, width, height)` in a normalised, y-down unit square.
    public var rect: SIMD4<Float>
    public var color: UInt32
    public var pieAlpha: Float
    public var rectAlpha: Float
    public var nodeID: UInt32
    public var flags: UInt32
    // No explicit tail padding: SIMD4<Float> forces 16-byte alignment, so the 52 bytes
    // above round up to a 64-byte stride on both sides. `CellInstanceLayoutTests` pins it.

    public init(
        pie: SIMD4<Float> = .zero,
        rect: SIMD4<Float> = .zero,
        color: UInt32 = 0,
        pieAlpha: Float = 0,
        rectAlpha: Float = 0,
        nodeID: NodeID = 0,
        flags: CellFlags = []
    ) {
        self.pie = pie
        self.rect = rect
        self.color = color
        self.pieAlpha = pieAlpha
        self.rectAlpha = rectAlpha
        self.nodeID = UInt32(bitPattern: nodeID)
        self.flags = flags.rawValue
    }

    public var innerRadius: Float { pie.x }
    public var outerRadius: Float { pie.y }
    public var startAngle: Float { pie.z }
    public var endAngle: Float { pie.w }
    public var node: NodeID { NodeID(bitPattern: nodeID) }
    public var cellFlags: CellFlags { CellFlags(rawValue: flags) }

    /// Angular subdivisions needed to keep the outer arc looking smooth. Slivers get 1,
    /// so the renderer can bucket instances by cost instead of tessellating everything
    /// for the worst case.
    public func arcSubdivisions(radiusInPoints: Float) -> Int {
        let sweep = abs(endAngle - startAngle)
        let arcLength = sweep * outerRadius * radiusInPoints
        if arcLength <= 3 { return 1 }
        return min(64, max(2, Int((arcLength / 4).rounded(.up))))
    }
}

/// Everything the two layout passes need, plus the knobs from View ▸ Graph Options.
public struct GraphOptions: Sendable, Equatable, Codable {
    public var graphType: GraphType = .pieChart
    public var sizeMode: SizeMode = .allocated
    public var colorMode: ColorMode = .hueWheel
    public var treemapLayout: TreemapStrategy = .stack

    /// Maximum rings drawn outside the hole. The pie uses fewer when the subtree is
    /// shallower, and the disc shrinks accordingly.
    public var graphLevels: Int = 8
    /// Cells thinner than this many points are merged into their gray sibling.
    public var mergeThreshold: Double = 1.5
    /// Width of the outline drawn around directories in the tree map, in points. The
    /// reference app exposes this as a Decrease/Increase/Reset value, not a toggle.
    public var directoryBorderWidth: Double = 1.75
    public var beginLayoutOnBottomEdge: Bool = false
    public var keepAspectRatioDuringZoom: Bool = true
    /// Include the volume's free space as a cell when the root is a volume.
    public var showAvailableSpace: Bool = true
    /// Multiplier on transition durations; 0 disables animation.
    public var animationSpeed: Double = 1.0

    /// Subdivide `.app` and other packages instead of drawing them as one cell.
    ///
    /// Off by default, which is what makes `/Applications` render as a single ring in the
    /// reference app even though every bundle's contents are counted. Navigating into a
    /// package always shows its contents regardless.
    public var showPackageContents: Bool = false

    /// Angle the first (largest) child starts at, radians clockwise from twelve o'clock.
    ///
    /// The reference app starts at three o'clock: a 50/30/20 fixture puts the 50 % wedge
    /// exactly from 3 to 9 o'clock through the bottom. Both graphs use this, so hues line
    /// up between them.
    public var startAngle: Float = .pi / 2

    /// Hole radius, as a fraction of half the view's smaller dimension.
    ///
    /// Measured off the reference app: at a 700 × 680 window showing one ring, the hole
    /// was 100 pt and the ring 40 pt, against a 340 pt half-minimum — so the hole and the
    /// ring width are both fixed fractions and the *outer* radius grows with the number
    /// of rings, rather than the rings dividing a fixed disc.
    public var holeRadiusFraction: Float = 0.294
    public var ringWidthFraction: Float = 0.118
    /// The disc never grows past this, however deep the tree; rings compress instead.
    public var maximumRadiusFraction: Float = 0.96

    public init() {}

    /// Hole radius and ring width for a subtree that is `depth` levels deep, both as
    /// fractions of `maximumRadiusFraction`-scaled space, normalised so the renderer can
    /// keep treating radii as fractions of one pie radius.
    ///
    /// Returns `nil` when there is nothing to draw.
    public func ringMetrics(visibleLevels: Int) -> (hole: Float, ringWidth: Float)? {
        guard visibleLevels > 0 else { return nil }
        let levels = Float(min(visibleLevels, graphLevels))
        var outer = holeRadiusFraction + ringWidthFraction * levels
        var width = ringWidthFraction
        if outer > maximumRadiusFraction {
            // Too deep to keep the natural ring width — squeeze the rings to fit.
            width = (maximumRadiusFraction - holeRadiusFraction) / levels
            outer = maximumRadiusFraction
        }
        // Renderer works in units of the pie radius, so divide through by the outer edge.
        return (holeRadiusFraction / outer, width / outer)
    }

    /// How much of the view the disc actually covers, so the renderer can size it.
    public func discRadiusFraction(visibleLevels: Int) -> Float {
        guard visibleLevels > 0 else { return holeRadiusFraction }
        let levels = Float(min(visibleLevels, graphLevels))
        return min(maximumRadiusFraction, holeRadiusFraction + ringWidthFraction * levels)
    }
}

/// The result of laying out one graph.
public struct GraphLayoutResult {
    public var cells: [CellInstance]
    /// Root the layout was taken from; the graph shows this node's subtree.
    public var root: NodeID
    public var options: GraphOptions
    /// Point size the thresholds were computed against.
    public var viewSize: SIMD2<Float>
    /// How much of half the view's smaller dimension the pie disc fills. Shrinks for
    /// shallow subtrees, matching the reference app's thin donut over `/Applications`.
    public var discRadiusFraction: Float

    public init(
        cells: [CellInstance], root: NodeID, options: GraphOptions, viewSize: SIMD2<Float>,
        discRadiusFraction: Float = 1
    ) {
        self.cells = cells
        self.root = root
        self.options = options
        self.viewSize = viewSize
        self.discRadiusFraction = discRadiusFraction
    }
}
