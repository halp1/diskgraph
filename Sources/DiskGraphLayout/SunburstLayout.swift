import DiskGraphCore
import simd

/// Lays out the pie chart: one concentric ring per directory level, each cell's sweep
/// proportional to its size within its parent.
///
/// Two behaviours here are taken from the reference app rather than invented:
///
/// * The hole radius and the ring width are fixed, so the **disc grows with the depth**
///   actually present instead of a fixed disc being divided into rings. A folder of
///   packages draws one thin donut; a deeply nested folder fills the view.
/// * A package (`.app` and friends) is one cell. Its contents count towards its size but
///   are not subdivided until you look inside — which is why `/Applications` is a single
///   ring even though every bundle is really several levels deep.
///
/// Siblings whose arc would be thinner than the merge threshold collapse into a single
/// gray cell at the end of the parent's range.
public struct SunburstLayout {
    public init() {}

    public func layout(
        tree: FileTree,
        root: NodeID,
        options: GraphOptions,
        viewSize: SIMD2<Float>
    ) -> GraphLayoutResult {
        let total = tree.size(of: root, mode: options.sizeMode)
        guard total > 0, options.graphLevels > 0, viewSize.x > 0, viewSize.y > 0 else {
            return GraphLayoutResult(
                cells: [], root: root, options: options, viewSize: viewSize,
                discRadiusFraction: options.holeRadiusFraction)
        }

        let radiusInPoints = min(viewSize.x, viewSize.y) / 2
        let dateRange = CellPalette.dateRange(of: tree, root: root, mode: options.colorMode)

        // Pass one: angles, colours and the ring index for every drawable cell. Radii come
        // afterwards, because they depend on how deep the graph turned out to be.
        var cells: [CellInstance] = []
        var levels: [Int] = []
        cells.reserveCapacity(4096)
        levels.reserveCapacity(4096)
        var deepestLevel = 0

        // Provisional metrics for the threshold test. Using the deepest possible disc here
        // means a cell is never dropped for being thin in a disc that then grows.
        let provisional = options.ringMetrics(visibleLevels: options.graphLevels)
            ?? (hole: 0, ringWidth: 1)

        var stack: [(node: NodeID, start: Float, sweep: Float, level: Int)] = [
            (root, options.startAngle, 2 * .pi, 0)
        ]

        while let frame = stack.popLast() {
            let level = frame.level + 1
            guard level <= options.graphLevels else { continue }

            let parentSize = tree.size(of: frame.node, mode: options.sizeMode)
            guard parentSize > 0 else { continue }

            let outerAtLevel = provisional.hole + provisional.ringWidth * Float(level)
            let minSweep = outerAtLevel * radiusInPoints > 0
                ? Float(options.mergeThreshold) / (outerAtLevel * radiusInPoints)
                : .greatestFiniteMagnitude

            let children = tree.sortedChildren(of: frame.node, mode: options.sizeMode)
            var angle = frame.start
            var mergedSize: Int64 = 0

            for child in children {
                let size = tree.size(of: child, mode: options.sizeMode)
                guard size > 0 else { continue }
                let sweep = frame.sweep * Float(size) / Float(parentSize)

                // Children are largest-first, so once one is too thin every later one is
                // too. Sum the tail into the gray cell and keep going.
                if sweep < minSweep {
                    mergedSize += size
                    continue
                }

                var flags: CellFlags = []
                let isDirectory = tree.isDirectory(child)
                let isPackage = tree.nodeFlags(child).contains(.package)
                if isDirectory { flags.insert(.directory) }
                if isPackage { flags.insert(.package) }

                cells.append(CellInstance(
                    pie: SIMD4(0, 0, angle, angle + sweep),
                    rect: .zero,
                    color: color(
                        tree: tree, node: child, midAngle: angle + sweep / 2, level: level,
                        options: options, dateRange: dateRange),
                    pieAlpha: 1,
                    rectAlpha: 0,
                    nodeID: child,
                    flags: flags))
                levels.append(level)
                deepestLevel = max(deepestLevel, level)

                let subdivides = isDirectory && (options.showPackageContents || !isPackage)
                if subdivides, level < options.graphLevels {
                    stack.append((child, angle, sweep, level))
                }
                angle += sweep
            }

            if mergedSize > 0 {
                let sweep = frame.sweep * Float(mergedSize) / Float(parentSize)
                cells.append(CellInstance(
                    pie: SIMD4(0, 0, angle, angle + sweep),
                    rect: .zero,
                    color: CellPalette.mergedGray,
                    pieAlpha: 1,
                    rectAlpha: 0,
                    nodeID: frame.node,
                    flags: [.merged]))
                levels.append(level)
                deepestLevel = max(deepestLevel, level)
            }
        }

        // Pass two: turn ring indices into radii now that the depth is known.
        guard let metrics = options.ringMetrics(visibleLevels: deepestLevel) else {
            return GraphLayoutResult(
                cells: [], root: root, options: options, viewSize: viewSize,
                discRadiusFraction: options.holeRadiusFraction)
        }
        for index in cells.indices {
            let level = Float(levels[index] - 1)
            let inner = metrics.hole + metrics.ringWidth * level
            cells[index].pie.x = inner
            cells[index].pie.y = inner + metrics.ringWidth
        }

        return GraphLayoutResult(
            cells: cells, root: root, options: options, viewSize: viewSize,
            discRadiusFraction: options.discRadiusFraction(visibleLevels: deepestLevel))
    }

    private func color(
        tree: FileTree, node: NodeID, midAngle: Float, level: Int,
        options: GraphOptions, dateRange: (oldest: Int64, newest: Int64)
    ) -> UInt32 {
        switch options.colorMode {
        case .hueWheel:
            return CellPalette.hueWheelColor(midAngle: midAngle, depth: level)
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
}
