import DiskGraphCore
import simd

/// Resolves a point in the graph view to the cell under it.
///
/// Both graphs are exact partitions, so neither needs a pick buffer. The pie inverts the
/// polar mapping and binary-searches the ring; the tree map uses a uniform grid built
/// once per layout. Hovering therefore costs no GPU readback and never stalls the
/// render loop.
public struct GraphHitTester {
    /// One angular span of one ring. Spans are stored normalised into `[0, 2π)`; a cell
    /// whose sweep crosses twelve o'clock — possible because the layout starts at three
    /// o'clock — contributes two spans pointing at the same cell.
    private struct Span {
        var start: Float
        var end: Float
        var cell: Int
    }

    private var rings: [[Span]] = []
    private var ringRadii: [(inner: Float, outer: Float)] = []

    /// Uniform grid over the unit square for the tree map.
    private static let gridSize = 96
    private var grid: [[Int]] = []

    private let cells: [CellInstance]
    private let graphType: GraphType
    /// Must match what the renderer drew with, or radii will not line up.
    private let discRadiusFraction: Float

    public init(cells: [CellInstance], graphType: GraphType, discRadiusFraction: Float = 1) {
        self.cells = cells
        self.graphType = graphType
        self.discRadiusFraction = max(discRadiusFraction, 0.0001)
        switch graphType {
        case .pieChart: buildRings()
        case .treeMap: buildGrid()
        }
    }

    private mutating func buildRings() {
        let twoPi = 2 * Float.pi
        var byRadius: [Float: Int] = [:]
        for (index, cell) in cells.enumerated() where cell.pieAlpha > 0 {
            let ring: Int
            if let existing = byRadius[cell.innerRadius] {
                ring = existing
            } else {
                ring = rings.count
                byRadius[cell.innerRadius] = ring
                rings.append([])
                ringRadii.append((cell.innerRadius, cell.outerRadius))
            }

            var start = cell.startAngle.truncatingRemainder(dividingBy: twoPi)
            if start < 0 { start += twoPi }
            let end = start + (cell.endAngle - cell.startAngle)
            if end <= twoPi {
                rings[ring].append(Span(start: start, end: end, cell: index))
            } else {
                // Wraps past twelve o'clock: split so every span stays inside [0, 2π).
                rings[ring].append(Span(start: start, end: twoPi, cell: index))
                rings[ring].append(Span(start: 0, end: end - twoPi, cell: index))
            }
        }
        for ring in rings.indices {
            rings[ring].sort { $0.start < $1.start }
        }
    }

    private mutating func buildGrid() {
        let size = Self.gridSize
        grid = Array(repeating: [], count: size * size)
        for (index, cell) in cells.enumerated() where cell.rectAlpha > 0 {
            let r = cell.rect
            let x0 = clamp(Int(r.x * Float(size)), 0, size - 1)
            let x1 = clamp(Int((r.x + r.z) * Float(size)), 0, size - 1)
            let y0 = clamp(Int(r.y * Float(size)), 0, size - 1)
            let y1 = clamp(Int((r.y + r.w) * Float(size)), 0, size - 1)
            for y in y0 ... y1 {
                for x in x0 ... x1 {
                    grid[y * size + x].append(index)
                }
            }
        }
    }

    /// `point` is in normalised view coordinates: `(0,0)` top-left, `(1,1)` bottom-right.
    /// `aspect` is the view's width / height, needed to un-squash the pie.
    public func cellIndex(at point: SIMD2<Float>, aspect: Float) -> Int? {
        switch graphType {
        case .pieChart: return pieHit(point, aspect: aspect)
        case .treeMap: return treeMapHit(point)
        }
    }

    public func cell(at point: SIMD2<Float>, aspect: Float) -> CellInstance? {
        cellIndex(at: point, aspect: aspect).map { cells[$0] }
    }

    private func pieHit(_ point: SIMD2<Float>, aspect: Float) -> Int? {
        // Undo the aspect-preserving fit the renderer applies so the graph stays circular.
        var offset = SIMD2(point.x - 0.5, point.y - 0.5)
        if aspect >= 1 { offset.x *= aspect } else { offset.y /= aspect }
        // Cell radii are fractions of the disc, and the disc is only part of the view.
        let radius = length(offset) * 2 / discRadiusFraction
        guard radius > 0 else { return nil }

        // Angles run clockwise from twelve o'clock, matching the layout.
        var angle = atan2(offset.x, -offset.y)
        if angle < 0 { angle += 2 * .pi }

        for (ring, radii) in ringRadii.enumerated() {
            guard radius >= radii.inner, radius <= radii.outer else { continue }
            let spans = rings[ring]
            // Spans tile the ring in sorted order, so binary search finds the only one.
            var low = 0
            var high = spans.count - 1
            while low <= high {
                let mid = (low + high) / 2
                if angle < spans[mid].start {
                    high = mid - 1
                } else if angle >= spans[mid].end {
                    low = mid + 1
                } else {
                    return spans[mid].cell
                }
            }
        }
        return nil
    }

    private func treeMapHit(_ point: SIMD2<Float>) -> Int? {
        let size = Self.gridSize
        guard point.x >= 0, point.x < 1, point.y >= 0, point.y < 1 else { return nil }
        let x = clamp(Int(point.x * Float(size)), 0, size - 1)
        let y = clamp(Int(point.y * Float(size)), 0, size - 1)
        // Later cells are deeper in the tree; prefer the deepest match so a leaf wins
        // over the directory containing it.
        var best: Int?
        for index in grid[y * size + x] {
            let r = cells[index].rect
            if point.x >= r.x, point.x < r.x + r.z, point.y >= r.y, point.y < r.y + r.w {
                if best == nil || index > best! { best = index }
            }
        }
        return best
    }
}
