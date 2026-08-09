import DiskGraphCore
import simd

/// Tree map arrangement, mirroring View ▸ Layout in the reference app — including its
/// order and its default, both read out of the app's own menu.
public enum TreemapStrategy: String, CaseIterable, Sendable, Codable {
    /// Strips across the rectangle's longer axis, each filled in the same direction.
    /// The reference app's default, and what the second reference screenshot shows.
    case stack
    /// The same strips, but with the fill direction alternating row to row.
    case snake
    /// Strips wound around the rectangle's edge, working inwards.
    case spiral
    /// Spiral at the top level, snake inside it.
    case snakeSpiral

    /// Menu order in the reference app.
    public static let allCases: [TreemapStrategy] = [.stack, .snake, .spiral, .snakeSpiral]

    public var localizedName: String {
        switch self {
        case .stack: return "Stack"
        case .snake: return "Snake"
        case .spiral: return "Spiral"
        case .snakeSpiral: return "Snake / Spiral"
        }
    }
}

struct LayoutRect {
    var x: Float
    var y: Float
    var width: Float
    var height: Float

    var area: Float { max(0, width) * max(0, height) }
    var shorterSide: Float { min(width, height) }
}

/// Lays out the tree map.
///
/// Unlike the pie chart this descends all the way to the leaves — the app's own
/// description is that the tree map "shows all files at a glance … regardless how deep
/// they are inside the directory". Interior directories still get a cell so the border
/// pass and the pie ↔ tree map morph have something to pair against, but they are not
/// filled (`rectAlpha == 0`); only leaves and merged gray groups are.
///
/// Colours come from the node's angular position in the *pie* ordering rather than from
/// anything spatial, which is why the same node is the same colour in both graphs.
public struct TreemapLayout {
    public init() {}

    public func layout(
        tree: FileTree,
        root: NodeID,
        options: GraphOptions,
        viewSize: SIMD2<Float>
    ) -> GraphLayoutResult {
        var cells: [CellInstance] = []
        let total = tree.size(of: root, mode: options.sizeMode)
        guard total > 0, viewSize.x > 0, viewSize.y > 0 else {
            return GraphLayoutResult(cells: cells, root: root, options: options, viewSize: viewSize)
        }

        let dateRange = CellPalette.dateRange(of: tree, root: root, mode: options.colorMode)
        let rootDepth = Int(tree.depth[Int(root)])
        // Thresholds are expressed in points, so convert once into normalised units.
        let minSide = SIMD2<Float>(
            Float(options.mergeThreshold) / viewSize.x,
            Float(options.mergeThreshold) / viewSize.y)

        cells.reserveCapacity(min(tree.count, 1 << 16))

        var stack: [Frame] = [
            Frame(node: root, rect: LayoutRect(x: 0, y: 0, width: 1, height: 1),
                  angleStart: options.startAngle, angleSweep: 2 * .pi, level: 0)
        ]
        var childRects: [LayoutRect] = []
        var areas: [Float] = []

        while let frame = stack.popLast() {
            let parentSize = tree.size(of: frame.node, mode: options.sizeMode)
            guard parentSize > 0 else { continue }

            let children = tree.sortedChildren(of: frame.node, mode: options.sizeMode)
            guard !children.isEmpty else { continue }

            // Split the children into those big enough to draw and a merged tail. They
            // arrive largest-first, so the visible set is always a prefix and the merged
            // group a suffix. Zero-sized children sort to the very end and are dropped.
            let rectArea = frame.rect.area
            let minCellArea = minSide.x * minSide.y
            var visibleCount = 0
            var mergedSize: Int64 = 0
            for child in children {
                let size = tree.size(of: child, mode: options.sizeMode)
                guard size > 0 else { continue }
                let share = Float(size) / Float(parentSize)
                if mergedSize == 0, share * rectArea >= minCellArea {
                    visibleCount += 1
                } else {
                    mergedSize += size
                }
            }

            areas.removeAll(keepingCapacity: true)
            let scale = rectArea / Float(parentSize)
            for index in 0 ..< visibleCount {
                areas.append(Float(tree.size(of: children[index], mode: options.sizeMode)) * scale)
            }
            if mergedSize > 0 { areas.append(Float(mergedSize) * scale) }
            guard !areas.isEmpty else { continue }

            childRects.removeAll(keepingCapacity: true)
            arrange(
                areas: areas, in: frame.rect, strategy: options.treemapLayout,
                level: frame.level, into: &childRects)

            // Angles are allocated over *all* children, merged or not, so a node's hue is
            // identical to the one the pie chart would give it.
            var angle = frame.angleStart
            for index in 0 ..< visibleCount {
                let child = children[index]
                let size = tree.size(of: child, mode: options.sizeMode)
                let sweep = frame.angleSweep * Float(size) / Float(parentSize)
                let rect = childRects[index]
                let isDirectory = tree.isDirectory(child)
                let isPackage = tree.nodeFlags(child).contains(.package)
                let depth = Int(tree.depth[Int(child)]) - rootDepth
                // A package is one cell unless the user asked to see inside it, which is
                // what makes a folder of .app bundles a single flat level.
                let subdivides = isDirectory
                    && (options.showPackageContents || !isPackage)
                    && tree.childCount[Int(child)] > 0

                var flags: CellFlags = [.inTreeMap]
                if isDirectory { flags.insert(.directory) }
                if isPackage { flags.insert(.package) }

                cells.append(CellInstance(
                    pie: .zero,
                    rect: SIMD4(rect.x, rect.y, rect.width, rect.height),
                    color: color(
                        tree: tree, node: child, midAngle: angle + sweep / 2, depth: depth,
                        options: options, dateRange: dateRange),
                    pieAlpha: 0,
                    // A cell that gets subdivided is not filled — its children cover it and
                    // it contributes only the directory outline. Everything else, including
                    // an unopened package, is a filled leaf.
                    rectAlpha: subdivides ? 0 : 1,
                    nodeID: child,
                    flags: flags))

                if subdivides, rect.shorterSide > 0 {
                    stack.append(Frame(
                        node: child, rect: rect, angleStart: angle, angleSweep: sweep,
                        level: frame.level + 1))
                }
                angle += sweep
            }

            if mergedSize > 0 {
                let rect = childRects[visibleCount]
                cells.append(CellInstance(
                    pie: .zero,
                    rect: SIMD4(rect.x, rect.y, rect.width, rect.height),
                    color: CellPalette.mergedGray,
                    pieAlpha: 0,
                    rectAlpha: 1,
                    nodeID: frame.node,
                    flags: [.merged, .inTreeMap]))
            }
        }

        // "Begin Layout On Bottom Edge" is a vertical mirror of the finished layout.
        // rect is (x, y, width, height), so only the origin moves.
        if options.beginLayoutOnBottomEdge {
            for index in cells.indices {
                cells[index].rect.y = 1 - cells[index].rect.y - cells[index].rect.w
            }
        }

        return GraphLayoutResult(cells: cells, root: root, options: options, viewSize: viewSize)
    }

    private struct Frame {
        var node: NodeID
        var rect: LayoutRect
        var angleStart: Float
        var angleSweep: Float
        var level: Int
    }

    private func color(
        tree: FileTree, node: NodeID, midAngle: Float, depth: Int,
        options: GraphOptions, dateRange: (oldest: Int64, newest: Int64)
    ) -> UInt32 {
        switch options.colorMode {
        case .hueWheel:
            return CellPalette.hueWheelColor(midAngle: midAngle, depth: depth)
        case .creationDate:
            return CellPalette.dateColor(
                timestamp: tree.creationTime[Int(node)],
                oldest: dateRange.oldest, newest: dateRange.newest)
        case .modificationDate:
            return CellPalette.dateColor(
                timestamp: tree.modificationTime[Int(node)],
                oldest: dateRange.oldest, newest: dateRange.newest)
        }
    }

    // MARK: - Arrangements

    func arrange(
        areas: [Float], in rect: LayoutRect, strategy: TreemapStrategy, level: Int,
        into out: inout [LayoutRect]
    ) {
        switch strategy {
        case .stack:
            strips(areas: areas, in: rect, snake: false, into: &out)
        case .snake:
            strips(areas: areas, in: rect, snake: true, into: &out)
        case .spiral:
            spiral(areas: areas, in: rect, into: &out)
        case .snakeSpiral:
            if level == 0 {
                spiral(areas: areas, in: rect, into: &out)
            } else {
                strips(areas: areas, in: rect, snake: true, into: &out)
            }
        }
    }

    /// Strip treemap. Rows run across the rectangle's longer axis and each row's
    /// thickness is chosen so its cells come out as square as possible; with `snake` the
    /// fill direction alternates row to row.
    func strips(areas: [Float], in rect: LayoutRect, snake: Bool, into out: inout [LayoutRect]) {
        var remaining = rect
        var index = 0
        var row = 0

        while index < areas.count {
            let horizontal = remaining.width >= remaining.height
            let stripLength = horizontal ? remaining.width : remaining.height
            guard stripLength > 0, remaining.shorterSide > 0 else {
                appendDegenerate(areas[index...].count, at: remaining, into: &out)
                return
            }

            // Grow the run while the worst aspect ratio in it keeps improving.
            var runArea: Float = 0
            var runMin = Float.greatestFiniteMagnitude
            var runMax: Float = 0
            var best = Float.greatestFiniteMagnitude
            var end = index

            while end < areas.count {
                let area = max(areas[end], 0)
                let newArea = runArea + area
                guard newArea > 0 else { end += 1; continue }
                let newMin = min(runMin, area)
                let newMax = max(runMax, area)
                let thickness = newArea / stripLength
                let worst = worstAspect(thickness: thickness, smallest: newMin, largest: newMax)
                if worst > best { break }
                best = worst
                runArea = newArea
                runMin = newMin
                runMax = newMax
                end += 1
            }
            if end == index { end = index + 1; runArea = max(areas[index], 0) }

            let available = horizontal ? remaining.height : remaining.width
            let thickness = runArea > 0 ? min(runArea / stripLength, available) : available
            var offset: Float = 0
            let reversed = snake && row % 2 == 1

            for i in index ..< end {
                let extent = runArea > 0 ? stripLength * (max(areas[i], 0) / runArea) : 0
                let position = reversed ? stripLength - offset - extent : offset
                out.append(horizontal
                    ? LayoutRect(x: remaining.x + position, y: remaining.y,
                                 width: extent, height: thickness)
                    : LayoutRect(x: remaining.x, y: remaining.y + position,
                                 width: thickness, height: extent))
                offset += extent
            }

            if horizontal {
                remaining.y += thickness
                remaining.height -= thickness
            } else {
                remaining.x += thickness
                remaining.width -= thickness
            }
            index = end
            row += 1
        }
    }

    /// Winds strips around the edge of the rectangle, working inwards.
    func spiral(areas: [Float], in rect: LayoutRect, into out: inout [LayoutRect]) {
        var remaining = rect
        var index = 0
        var edge = 0

        while index < areas.count {
            guard remaining.width > 0, remaining.height > 0 else {
                appendDegenerate(areas[index...].count, at: remaining, into: &out)
                return
            }
            let horizontal = edge % 2 == 0
            let stripLength = horizontal ? remaining.width : remaining.height
            guard stripLength > 0 else { break }

            var runArea: Float = 0
            var runMin = Float.greatestFiniteMagnitude
            var runMax: Float = 0
            var best = Float.greatestFiniteMagnitude
            var end = index
            while end < areas.count {
                let area = max(areas[end], 0)
                let newArea = runArea + area
                guard newArea > 0 else { end += 1; continue }
                let thickness = newArea / stripLength
                let worst = worstAspect(
                    thickness: thickness, smallest: min(runMin, area), largest: max(runMax, area))
                if worst > best { break }
                best = worst
                runArea = newArea
                runMin = min(runMin, area)
                runMax = max(runMax, area)
                end += 1
            }
            if end == index { end = index + 1; runArea = max(areas[index], 0) }

            let available = horizontal ? remaining.height : remaining.width
            let thickness = runArea > 0 ? min(runArea / stripLength, available) : available
            // Edges run top → right → bottom → left, so every other one is reversed.
            let reversed = edge == 2 || edge == 3
            var offset: Float = 0
            for i in index ..< end {
                let extent = runArea > 0 ? stripLength * (max(areas[i], 0) / runArea) : 0
                let position = reversed ? stripLength - offset - extent : offset
                switch edge % 4 {
                case 0: // top, left → right
                    out.append(LayoutRect(x: remaining.x + position, y: remaining.y,
                                          width: extent, height: thickness))
                case 1: // right, top → bottom
                    out.append(LayoutRect(x: remaining.x + remaining.width - thickness,
                                          y: remaining.y + position,
                                          width: thickness, height: extent))
                case 2: // bottom, right → left
                    out.append(LayoutRect(x: remaining.x + position,
                                          y: remaining.y + remaining.height - thickness,
                                          width: extent, height: thickness))
                default: // left, bottom → top
                    out.append(LayoutRect(x: remaining.x, y: remaining.y + position,
                                          width: thickness, height: extent))
                }
                offset += extent
            }

            switch edge % 4 {
            case 0: remaining.y += thickness; remaining.height -= thickness
            case 1: remaining.width -= thickness
            case 2: remaining.height -= thickness
            default: remaining.x += thickness; remaining.width -= thickness
            }
            index = end
            edge += 1
        }
    }

    /// Slice-and-dice along a single axis.
    func slice(areas: [Float], in rect: LayoutRect, horizontal: Bool, into out: inout [LayoutRect]) {
        let total = areas.reduce(0) { $0 + max($1, 0) }
        guard total > 0 else {
            appendDegenerate(areas.count, at: rect, into: &out)
            return
        }
        var offset: Float = 0
        for area in areas {
            let share = max(area, 0) / total
            if horizontal {
                let width = rect.width * share
                out.append(LayoutRect(x: rect.x + offset, y: rect.y, width: width, height: rect.height))
                offset += width
            } else {
                let height = rect.height * share
                out.append(LayoutRect(x: rect.x, y: rect.y + offset, width: rect.width, height: height))
                offset += height
            }
        }
    }

    private func appendDegenerate(_ count: Int, at rect: LayoutRect, into out: inout [LayoutRect]) {
        for _ in 0 ..< count {
            out.append(LayoutRect(x: rect.x, y: rect.y, width: 0, height: 0))
        }
    }

    /// Worst aspect ratio in a strip of the given thickness. Cell length is
    /// `area / thickness`, so the ratio is monotonic in area and only the smallest and
    /// largest members can be the worst.
    @inline(__always)
    func worstAspect(thickness: Float, smallest: Float, largest: Float) -> Float {
        guard thickness > 0, smallest > 0 else { return .greatestFiniteMagnitude }
        let squared = thickness * thickness
        return max(squared / smallest, largest / squared)
    }
}
