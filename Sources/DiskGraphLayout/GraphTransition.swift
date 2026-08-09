import DiskGraphCore
import simd

/// Pairs two layouts of *different* subtrees into index-aligned buffers so the renderer
/// can blend between them — the drill-in and go-back animation.
///
/// This is the time axis; `GraphLayoutEngine.fuse` is the shape axis. They compose: a
/// cell carries a pie and a rect shape at each end of the navigation, and the shader
/// resolves the navigation blend first, then the pie ↔ tree map morph.
public enum GraphTransition {
    /// Returns two arrays of equal length whose entries describe the same cell before
    /// and after the change.
    ///
    /// A cell that exists on only one side keeps its own geometry on the other with zero
    /// alpha, so it fades in or out where it belongs instead of sliding in from nowhere.
    /// Cells present in both — the subtree being navigated into — genuinely move, which
    /// is the part of the animation the eye follows.
    public static func pair(
        from: [CellInstance], to: [CellInstance]
    ) -> (from: [CellInstance], to: [CellInstance]) {
        var indexByKey: [GraphLayoutEngine.CellKey: Int] = [:]
        indexByKey.reserveCapacity(from.count + to.count)

        var start: [CellInstance] = []
        var end: [CellInstance] = []
        start.reserveCapacity(from.count + to.count)
        end.reserveCapacity(from.count + to.count)

        for cell in from {
            indexByKey[GraphLayoutEngine.CellKey(cell)] = start.count
            start.append(cell)
            end.append(faded(cell))
        }

        for cell in to {
            let key = GraphLayoutEngine.CellKey(cell)
            if let existing = indexByKey[key] {
                end[existing] = cell
            } else {
                indexByKey[key] = start.count
                start.append(faded(cell))
                end.append(cell)
            }
        }

        return (start, end)
    }

    private static func faded(_ cell: CellInstance) -> CellInstance {
        var copy = cell
        copy.pieAlpha = 0
        copy.rectAlpha = 0
        return copy
    }
}
