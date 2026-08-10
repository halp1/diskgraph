import DiskGraphCore

/// The words shown for a cell: the hover tooltip, and the label in the middle of the graph.
///
/// Pure, and deliberately outside the view layer. The merged-group case is easy to get
/// wrong — a merged cell has no node of its own, so anything that reaches for
/// `tree.size(of: cell.node)` reports the *parent's* size, and anything that gives up and
/// substitutes zero reports "Zero KB" for a group that may be gigabytes. Keeping this here
/// means both mistakes are caught by a test rather than by looking at the screen.
public enum CellDescription {
    public struct Tooltip: Equatable {
        /// Enclosing folders, relative to the graph's current root, joined with "›".
        /// Empty when the item sits directly in the root.
        ///
        /// Without this a tree map is unreadable: every cell is a bare filename with no
        /// indication of where in the tree it came from.
        public var path: String
        /// Shown in bold.
        public var name: String
        public var detail: String

        public init(path: String = "", name: String, detail: String) {
            self.path = path
            self.name = name
            self.detail = detail
        }
    }

    public static let pathSeparator = " › "

    public static func tooltip(
        for cell: CellInstance, tree: FileTree, root: NodeID, sizeMode: SizeMode
    ) -> Tooltip {
        guard cell.cellFlags.contains(.merged) else {
            return Tooltip(
                path: enclosingPath(of: cell.node, tree: tree, root: root),
                name: tree.name(of: cell.node),
                detail: SizeFormatter.string(tree.size(of: cell.node, mode: sizeMode),
                                             mode: sizeMode))
        }

        // A merged cell's node id *is* its enclosing folder, so that folder belongs in the
        // path rather than being dropped as the item's own name.
        let count = Int(cell.mergedCount)
        return Tooltip(
            path: enclosingPath(of: cell.node, tree: tree, root: root, includingNode: true),
            name: count == 1 ? "1 smaller item" : "\(count) smaller items",
            // The group's own total, carried on the cell — never the parent's, never zero.
            detail: SizeFormatter.string(cell.mergedSize, mode: sizeMode))
    }

    /// Folders between `root` and `node`, outermost first. `root` itself is never included:
    /// it is already named in the toolbar, so repeating it wastes the width.
    public static func enclosingPath(
        of node: NodeID, tree: FileTree, root: NodeID, includingNode: Bool = false
    ) -> String {
        var components: [String] = []
        var current = includingNode ? node : (node == root ? -1 : tree.parent[Int(node)])
        while current >= 0, current != root {
            components.append(tree.name(of: current))
            current = tree.parent[Int(current)]
        }
        return components.reversed().joined(separator: pathSeparator)
    }

    /// The total in the middle of the graph.
    public static func centerLabel(
        for node: NodeID, tree: FileTree, sizeMode: SizeMode
    ) -> String {
        SizeFormatter.string(tree.size(of: node, mode: sizeMode), mode: sizeMode)
    }
}
