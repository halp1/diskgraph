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
        /// Shown in bold.
        public var name: String
        public var detail: String
    }

    public static func tooltip(
        for cell: CellInstance, tree: FileTree, sizeMode: SizeMode
    ) -> Tooltip {
        guard cell.cellFlags.contains(.merged) else {
            return Tooltip(
                name: tree.name(of: cell.node),
                detail: SizeFormatter.string(tree.size(of: cell.node, mode: sizeMode),
                                             mode: sizeMode))
        }

        let count = Int(cell.mergedCount)
        return Tooltip(
            name: count == 1 ? "1 smaller item" : "\(count) smaller items",
            // The group's own total, carried on the cell — never the parent's, never zero.
            detail: SizeFormatter.string(cell.mergedSize, mode: sizeMode))
    }

    /// The total in the middle of the graph.
    public static func centerLabel(
        for node: NodeID, tree: FileTree, sizeMode: SizeMode
    ) -> String {
        SizeFormatter.string(tree.size(of: node, mode: sizeMode), mode: sizeMode)
    }
}
