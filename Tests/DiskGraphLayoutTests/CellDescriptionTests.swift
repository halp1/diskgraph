import DiskGraphCore
import Foundation
import Testing
@testable import DiskGraphLayout

@Suite struct CellDescriptionTests {
    private func fixtureTree() throws -> (FileTree, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskgraph-describe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 20_000_000)
            .write(to: root.appendingPathComponent("big.bin"))
        for i in 0 ..< 150 {
            try Data(repeating: 0x41, count: 200_000)
                .write(to: root.appendingPathComponent("tiny\(i).bin"))
        }
        return (try DirectoryScanner().scan(rootPath: root.path), root)
    }

    /// The bug this pins: a merged cell borrows its parent's node id, so reading its size
    /// from the tree gives the parent's total and giving up gives "Zero KB". It reported
    /// zero on screen for a group worth megabytes.
    @Test func mergedCellReportsItsGroupNotZeroAndNotTheParent() throws {
        let (tree, root) = try fixtureTree()
        defer { try? FileManager.default.removeItem(at: root) }

        var options = GraphOptions()
        options.sizeMode = .logical
        options.mergeThreshold = 20
        let cells = SunburstLayout()
            .layout(tree: tree, root: 0, options: options, viewSize: SIMD2(940, 800)).cells
        let merged = try #require(cells.first { $0.cellFlags.contains(.merged) })

        let text = CellDescription.tooltip(for: merged, tree: tree, root: 0, sizeMode: .logical)
        #expect(text.name == "\(merged.mergedCount) smaller items")
        #expect(text.detail == SizeFormatter.string(merged.mergedSize, mode: .logical))
        #expect(!text.detail.contains("Zero"))
        // Emphatically not the parent's size, which is what a naive lookup would give.
        #expect(text.detail != SizeFormatter.string(tree.logicalSize[0], mode: .logical))
    }

    @Test func singleMergedSiblingIsNotPluralised() throws {
        let (tree, root) = try fixtureTree()
        defer { try? FileManager.default.removeItem(at: root) }
        var cell = CellInstance(nodeID: 0, flags: [.merged], mergedCount: 1, mergedSize: 4096)
        cell.pieAlpha = 1
        let text = CellDescription.tooltip(for: cell, tree: tree, root: 0, sizeMode: .allocated)
        #expect(text.name == "1 smaller item")
        #expect(text.detail == "4 KB on disk")
    }

    @Test func ordinaryCellNamesItsNodeAndUsesTheActiveSizeMode() throws {
        let (tree, root) = try fixtureTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let big = try #require(tree.children(of: 0).first { tree.name(of: $0) == "big.bin" })
        let cell = CellInstance(nodeID: big)

        #expect(CellDescription.tooltip(for: cell, tree: tree, root: 0, sizeMode: .logical)
            == CellDescription.Tooltip(path: "", name: "big.bin", detail: "20 MB"))
        #expect(CellDescription.tooltip(for: cell, tree: tree, root: 0, sizeMode: .allocated)
            .detail.hasSuffix("on disk"))
        #expect(CellDescription.tooltip(for: cell, tree: tree, root: 0, sizeMode: .childCount)
            .detail == "1 files")
    }

    @Test func centreLabelFollowsTheSizeMode() throws {
        let (tree, root) = try fixtureTree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CellDescription.centerLabel(for: 0, tree: tree, sizeMode: .allocated)
            .hasSuffix("on disk"))
        #expect(CellDescription.centerLabel(for: 0, tree: tree, sizeMode: .childCount)
            == "151 files")
    }
}

@Suite struct EnclosingPathTests {
    private func nestedTree() throws -> (FileTree, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskgraph-path-\(UUID().uuidString)")
        let deep = root.appendingPathComponent("Library/Application Support/CrossOver/Bottles")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096).write(to: deep.appendingPathComponent("game.pak"))
        try Data(repeating: 0x41, count: 4096).write(to: root.appendingPathComponent("top.bin"))
        return (try DirectoryScanner().scan(rootPath: root.path), root)
    }

    private func node(_ tree: FileTree, _ relativePath: String) -> NodeID? {
        var current: NodeID = 0
        for component in relativePath.split(separator: "/") {
            guard let match = tree.children(of: current)
                .first(where: { tree.name(of: $0) == String(component) }) else { return nil }
            current = match
        }
        return current
    }

    /// A tree-map cell is otherwise just a bare filename with no clue where it came from.
    @Test func namesEveryFolderBetweenTheRootAndTheItem() throws {
        let (tree, url) = try nestedTree()
        defer { try? FileManager.default.removeItem(at: url) }
        let leaf = try #require(
            node(tree, "Library/Application Support/CrossOver/Bottles/game.pak"))

        #expect(CellDescription.enclosingPath(of: leaf, tree: tree, root: 0)
            == "Library › Application Support › CrossOver › Bottles")
    }

    @Test func isEmptyForAnItemSittingDirectlyInTheRoot() throws {
        let (tree, url) = try nestedTree()
        defer { try? FileManager.default.removeItem(at: url) }
        let top = try #require(node(tree, "top.bin"))
        #expect(CellDescription.enclosingPath(of: top, tree: tree, root: 0).isEmpty)
        #expect(CellDescription.enclosingPath(of: 0, tree: tree, root: 0).isEmpty)
    }

    /// After drilling in, the path is relative to where you are — the root is already named
    /// in the toolbar.
    @Test func isRelativeToTheCurrentGraphRoot() throws {
        let (tree, url) = try nestedTree()
        defer { try? FileManager.default.removeItem(at: url) }
        let support = try #require(node(tree, "Library/Application Support"))
        let leaf = try #require(
            node(tree, "Library/Application Support/CrossOver/Bottles/game.pak"))

        #expect(CellDescription.enclosingPath(of: leaf, tree: tree, root: support)
            == "CrossOver › Bottles")
        let cell = CellInstance(nodeID: leaf)
        #expect(CellDescription.tooltip(for: cell, tree: tree, root: support, sizeMode: .logical)
            .path == "CrossOver › Bottles")
    }

    /// A merged group lives *inside* its folder, so that folder belongs in the path.
    @Test func mergedGroupPathIncludesTheFolderItSitsIn() throws {
        let (tree, url) = try nestedTree()
        defer { try? FileManager.default.removeItem(at: url) }
        let bottles = try #require(node(tree, "Library/Application Support/CrossOver/Bottles"))

        let cell = CellInstance(nodeID: bottles, flags: [.merged], mergedCount: 3, mergedSize: 99)
        let text = CellDescription.tooltip(for: cell, tree: tree, root: 0, sizeMode: .logical)
        #expect(text.path == "Library › Application Support › CrossOver › Bottles")
        #expect(text.name == "3 smaller items")
    }
}
