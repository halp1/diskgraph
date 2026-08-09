import DiskGraphCore
import simd

/// Builds the instance buffer the renderer draws.
///
/// A steady-state graph only needs one layout. A transition needs both, paired by node
/// id so a cell's pie geometry and rect geometry travel together and the shader can
/// interpolate between them with a single uniform.
public struct GraphLayoutEngine {
    public init() {}

    public func layout(
        tree: FileTree, root: NodeID, options: GraphOptions, viewSize: SIMD2<Float>
    ) -> GraphLayoutResult {
        switch options.graphType {
        case .pieChart:
            return SunburstLayout().layout(
                tree: tree, root: root, options: options, viewSize: viewSize)
        case .treeMap:
            return TreemapLayout().layout(
                tree: tree, root: root, options: options, viewSize: viewSize)
        }
    }

    /// Builds both layouts and fuses them into one buffer suitable for morphing.
    ///
    /// A node present in only one graph keeps a zero alpha in the other and inherits a
    /// collapsed geometry from its nearest ancestor that *is* present there, so it grows
    /// out of, and shrinks back into, the right place instead of flying in from the
    /// origin.
    public func morphable(
        tree: FileTree, root: NodeID, options: GraphOptions, viewSize: SIMD2<Float>
    ) -> GraphLayoutResult {
        var pieOptions = options
        pieOptions.graphType = .pieChart
        var treeOptions = options
        treeOptions.graphType = .treeMap

        let pie = SunburstLayout().layout(
            tree: tree, root: root, options: pieOptions, viewSize: viewSize)
        let map = TreemapLayout().layout(
            tree: tree, root: root, options: treeOptions, viewSize: viewSize)

        return GraphLayoutResult(
            cells: fuse(pie: pie.cells, treeMap: map.cells, tree: tree, root: root),
            root: root, options: options, viewSize: viewSize,
            // The disc size is a property of the pie pass; the tree map has no say in it.
            discRadiusFraction: pie.discRadiusFraction)
    }

    /// Pairs two layouts of the same subtree into a single instance list.
    func fuse(
        pie: [CellInstance], treeMap: [CellInstance], tree: FileTree, root: NodeID
    ) -> [CellInstance] {
        // Merged gray cells carry their parent's node id rather than a unique one, so key
        // them separately to avoid two unrelated gray groups colliding.
        var index: [CellKey: Int] = [:]
        index.reserveCapacity(pie.count + treeMap.count)
        var fused: [CellInstance] = []
        fused.reserveCapacity(pie.count + treeMap.count)

        for cell in pie {
            index[CellKey(cell)] = fused.count
            fused.append(cell)
        }

        for cell in treeMap {
            let key = CellKey(cell)
            if let existing = index[key] {
                fused[existing].rect = cell.rect
                fused[existing].rectAlpha = cell.rectAlpha
                fused[existing].flags |= cell.flags
            } else {
                var merged = cell
                merged.pie = collapsedArc(for: cell, tree: tree, root: root, pie: pie, index: index,
                                          fused: fused)
                merged.pieAlpha = 0
                index[key] = fused.count
                fused.append(merged)
            }
        }

        // Anything the tree map never mentioned — interior directories deeper than its
        // recursion, and pie cells for nodes with no rectangle — collapses to a point at
        // the centre of its parent's rectangle.
        for i in fused.indices where fused[i].rect == .zero {
            fused[i].rect = collapsedRect(
                for: fused[i], tree: tree, root: root, index: index, fused: fused)
            fused[i].rectAlpha = 0
        }

        return fused
    }

    /// Zero-thickness arc at the outer edge of the nearest ancestor that the pie drew,
    /// so the cell appears to unfold out of that ring.
    private func collapsedArc(
        for cell: CellInstance, tree: FileTree, root: NodeID,
        pie: [CellInstance], index: [CellKey: Int], fused: [CellInstance]
    ) -> SIMD4<Float> {
        var node = cell.node
        while node != root && node >= 0 {
            node = tree.parent[Int(node)]
            if let position = index[CellKey(node: node, merged: false)] {
                let arc = fused[position].pie
                let mid = (arc.z + arc.w) / 2
                return SIMD4(arc.y, arc.y, mid, mid)
            }
        }
        return SIMD4(1, 1, 0, 0)
    }

    /// Zero-area rectangle at the centre of the nearest ancestor's rectangle.
    private func collapsedRect(
        for cell: CellInstance, tree: FileTree, root: NodeID,
        index: [CellKey: Int], fused: [CellInstance]
    ) -> SIMD4<Float> {
        var node = cell.node
        while node != root && node >= 0 {
            node = tree.parent[Int(node)]
            if let position = index[CellKey(node: node, merged: false)] {
                let rect = fused[position].rect
                guard rect != .zero else { continue }
                return SIMD4(rect.x + rect.z / 2, rect.y + rect.w / 2, 0, 0)
            }
        }
        return SIMD4(0.5, 0.5, 0, 0)
    }

    public struct CellKey: Hashable {
        public var node: NodeID
        public var merged: Bool
        public init(node: NodeID, merged: Bool) {
            self.node = node
            self.merged = merged
        }
        public init(_ cell: CellInstance) {
            node = cell.node
            merged = cell.cellFlags.contains(.merged)
        }
    }
}
