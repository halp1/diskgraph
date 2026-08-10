import DiskGraphCore
import Foundation
import Testing
import simd
@testable import DiskGraphLayout

/// A class rather than a `~Copyable` struct so it can be returned alongside the tree.
private final class Fixture {
    let root: URL
    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskgraph-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func file(_ path: String, bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }
}

/// A tree wide and deep enough to exercise merging, several ring levels and nesting.
private func sampleTree() throws -> (FileTree, Fixture) {
    let fixture = try Fixture()
    for group in 0 ..< 6 {
        for item in 0 ..< 8 {
            try fixture.file("g\(group)/f\(item).bin", bytes: (group + 1) * (item + 1) * 512)
        }
        try fixture.file("g\(group)/nested/deep/leaf.bin", bytes: (group + 1) * 4096)
    }
    var options = ScanOptions()
    options.threadCount = 2
    let tree = try DirectoryScanner().scan(rootPath: fixture.root.path, options: options)
    return (tree, fixture)
}

private let viewSize = SIMD2<Float>(940, 800)

@Suite struct SunburstLayoutTests {
    @Test func childAnglesExactlyFillTheParentSweep() throws {
        let (tree, fixture) = try sampleTree()
        withExtendedLifetime(fixture) {}

        var options = GraphOptions()
        options.sizeMode = .logical
        options.mergeThreshold = 0   // no merging, so children must tile exactly
        let cells = SunburstLayout()
            .layout(tree: tree, root: 0, options: options, viewSize: viewSize).cells

        // Group cells by parent and check their sweeps abut with no gap or overlap.
        var byParent: [NodeID: [CellInstance]] = [:]
        for cell in cells where !cell.cellFlags.contains(.merged) {
            byParent[tree.parent[Int(cell.node)], default: []].append(cell)
        }
        for (parent, group) in byParent {
            let sorted = group.sorted { $0.startAngle < $1.startAngle }
            for i in 1 ..< sorted.count {
                #expect(abs(sorted[i].startAngle - sorted[i - 1].endAngle) < 1e-4,
                        "gap between siblings of \(tree.name(of: parent))")
            }
        }

        // The first ring must span the whole circle.
        let innermost = cells.map(\.innerRadius).min() ?? 0
        let firstRing = cells.filter { abs($0.innerRadius - innermost) < 1e-6 }
        let span = firstRing.reduce(Float(0)) { $0 + ($1.endAngle - $1.startAngle) }
        #expect(abs(span - 2 * .pi) < 1e-3)
    }

    @Test func neverExceedsTheConfiguredRingCount() throws {
        let (tree, fixture) = try sampleTree()
        withExtendedLifetime(fixture) {}

        for levels in 1 ... 6 {
            var options = GraphOptions()
            options.graphLevels = levels
            let result = SunburstLayout()
                .layout(tree: tree, root: 0, options: options, viewSize: viewSize)
            let maxOuter = result.cells.map(\.outerRadius).max() ?? 0
            #expect(maxOuter <= 1.0001)
            let ringCount = Set(result.cells.map { ($0.innerRadius * 10_000).rounded() }).count
            #expect(ringCount <= levels)
        }
    }

    @Test func mergesThinSiblingsIntoOneGrayCellPerParent() throws {
        let fixture = try Fixture()
        try fixture.file("big.bin", bytes: 10_000_000)
        for i in 0 ..< 200 { try fixture.file("tiny\(i).bin", bytes: 16) }
        let tree = try DirectoryScanner().scan(rootPath: fixture.root.path)

        var options = GraphOptions()
        options.sizeMode = .logical
        options.mergeThreshold = 4
        let cells = SunburstLayout()
            .layout(tree: tree, root: 0, options: options, viewSize: viewSize).cells

        let gray = cells.filter { $0.cellFlags.contains(.merged) }
        #expect(gray.count == 1)
        #expect(gray[0].color == CellPalette.mergedGray)
        // The 200 slivers collapsed into it rather than each getting a cell.
        #expect(cells.count < 10)
    }

    @Test func staysWithinTheUnitDiscAndTheHole() throws {
        let (tree, fixture) = try sampleTree()
        withExtendedLifetime(fixture) {}

        let options = GraphOptions()
        let cells = SunburstLayout()
            .layout(tree: tree, root: 0, options: options, viewSize: viewSize).cells

        #expect(!cells.isEmpty)
        for cell in cells {
            #expect(cell.innerRadius >= 0)
            #expect(cell.outerRadius <= 1 + 1e-5)
            #expect(cell.endAngle >= cell.startAngle)
            // Angles begin at the three o'clock start angle, so they run up to one full
            // turn beyond it rather than stopping at 2π.
            #expect(cell.startAngle >= options.startAngle - 1e-4)
            #expect(cell.endAngle <= options.startAngle + 2 * Float.pi + 1e-3)
            #expect(cell.endAngle - cell.startAngle <= 2 * Float.pi + 1e-3)
        }
    }
}

@Suite struct TreemapLayoutTests {
    /// Rectangles must tile their parent without gaps or overlap. Checked by sampling a
    /// grid rather than comparing floats pairwise.
    @Test(arguments: TreemapStrategy.allCases)
    func leafRectanglesTileTheViewWithoutOverlap(strategy: TreemapStrategy) throws {
        let (tree, fixture) = try sampleTree()
        withExtendedLifetime(fixture) {}

        var options = GraphOptions()
        options.treemapLayout = strategy
        options.sizeMode = .logical
        options.mergeThreshold = 0.5
        let cells = TreemapLayout()
            .layout(tree: tree, root: 0, options: options, viewSize: viewSize).cells

        let filled = cells.filter { $0.rectAlpha > 0 }
        #expect(!filled.isEmpty)

        let steps = 120
        var covered = 0
        var overlaps = 0
        for iy in 0 ..< steps {
            for ix in 0 ..< steps {
                let p = SIMD2<Float>(
                    (Float(ix) + 0.5) / Float(steps), (Float(iy) + 0.5) / Float(steps))
                var hits = 0
                for cell in filled {
                    let r = cell.rect
                    if p.x >= r.x, p.x < r.x + r.z, p.y >= r.y, p.y < r.y + r.w { hits += 1 }
                }
                if hits > 0 { covered += 1 }
                if hits > 1 { overlaps += 1 }
            }
        }
        let total = steps * steps
        #expect(overlaps == 0, "\(strategy.rawValue) overlaps at \(overlaps) sample points")
        // A few samples can land in the seams of degenerate slivers.
        #expect(Double(covered) / Double(total) > 0.995,
                "\(strategy.rawValue) covered only \(covered)/\(total)")
    }

    @Test(arguments: TreemapStrategy.allCases)
    func rectanglesStayInsideTheUnitSquare(strategy: TreemapStrategy) throws {
        let (tree, fixture) = try sampleTree()
        withExtendedLifetime(fixture) {}

        var options = GraphOptions()
        options.treemapLayout = strategy
        let cells = TreemapLayout()
            .layout(tree: tree, root: 0, options: options, viewSize: viewSize).cells

        for cell in cells {
            let r = cell.rect
            #expect(r.x >= -1e-4 && r.y >= -1e-4)
            #expect(r.x + r.z <= 1 + 1e-4)
            #expect(r.y + r.w <= 1 + 1e-4)
            #expect(r.z >= 0 && r.w >= 0)
        }
    }

    @Test func cellAreaIsProportionalToSize() throws {
        let fixture = try Fixture()
        try fixture.file("a.bin", bytes: 400_000)
        try fixture.file("b.bin", bytes: 200_000)
        try fixture.file("c.bin", bytes: 100_000)
        try fixture.file("d.bin", bytes: 100_000)
        let tree = try DirectoryScanner().scan(rootPath: fixture.root.path)

        var options = GraphOptions()
        options.sizeMode = .logical
        let cells = TreemapLayout()
            .layout(tree: tree, root: 0, options: options, viewSize: viewSize).cells

        let total = Float(tree.logicalSize[0])
        for cell in cells where cell.rectAlpha > 0 {
            let expected = Float(tree.logicalSize[Int(cell.node)]) / total
            let actual = cell.rect.z * cell.rect.w
            #expect(abs(actual - expected) < 0.005,
                    "\(tree.name(of: cell.node)) area \(actual) expected \(expected)")
        }
    }

    @Test func descendsBelowThePieRingLimit() throws {
        let (tree, fixture) = try sampleTree()
        withExtendedLifetime(fixture) {}

        var options = GraphOptions()
        options.graphLevels = 1
        options.mergeThreshold = 0.2
        let cells = TreemapLayout()
            .layout(tree: tree, root: 0, options: options, viewSize: viewSize).cells

        // The tree map ignores graphLevels: g0/nested/deep/leaf.bin is four levels down.
        let deepest = cells.map { Int(tree.depth[Int($0.node)]) }.max() ?? 0
        #expect(deepest >= 4)
    }

    @Test func bottomEdgeOptionMirrorsVertically() throws {
        let (tree, fixture) = try sampleTree()
        withExtendedLifetime(fixture) {}

        var normal = GraphOptions()
        normal.mergeThreshold = 1
        var flipped = normal
        flipped.beginLayoutOnBottomEdge = true

        let a = TreemapLayout().layout(tree: tree, root: 0, options: normal, viewSize: viewSize).cells
        let b = TreemapLayout().layout(tree: tree, root: 0, options: flipped, viewSize: viewSize).cells

        #expect(a.count == b.count)
        for (lhs, rhs) in zip(a, b) {
            #expect(lhs.rect.x == rhs.rect.x)
            #expect(lhs.rect.z == rhs.rect.z)
            #expect(abs((1 - lhs.rect.y - lhs.rect.w) - rhs.rect.y) < 1e-5)
        }
    }
}

@Suite struct PaletteTests {
    /// Pins the mapping measured off the reference app: hue = 115° − θ, with θ clockwise
    /// from twelve o'clock. The expected values are the eight plateaus sampled from a
    /// folder of eight equal files.
    @Test func hueMatchesTheMeasuredReferenceMapping() {
        func hue(atDegrees degrees: Float) -> Float {
            CellPalette.hue(of: CellPalette.hueWheelColor(
                midAngle: degrees * .pi / 180, depth: 1))
        }
        // (θ, expected hue) straight off the reference app.
        let samples: [(Float, Float)] = [
            (112.5, 4.5), (157.5, 312.9), (202.5, 266.4), (247.5, 223.9),
            (292.5, 182.1), (337.5, 123.7), (22.5, 85.4), (67.5, 45.6),
        ]
        for (theta, expected) in samples {
            let actual = hue(atDegrees: theta)
            // Within the colour-space wobble of the original measurement.
            let delta = min(abs(actual - expected), 360 - abs(actual - expected))
            #expect(delta < 17, "theta \(theta): got \(actual), reference \(expected)")
        }
        // The relationship itself is exact.
        #expect(abs(hue(atDegrees: 0) - 115) < 1)
        #expect(abs(hue(atDegrees: 115) - 0) < 1)
    }

    /// The reference app starts the largest child at three o'clock: a 50/30/20 folder puts
    /// the 50 % wedge exactly from 3 to 9 o'clock through the bottom.
    @Test func largestChildStartsAtThreeOClock() throws {
        let fixture = try Fixture()
        try fixture.file("half.bin", bytes: 5_000_000)
        try fixture.file("thirty.bin", bytes: 3_000_000)
        try fixture.file("twenty.bin", bytes: 2_000_000)
        let tree = try DirectoryScanner().scan(rootPath: fixture.root.path)

        var options = GraphOptions()
        options.sizeMode = .logical
        let cells = SunburstLayout()
            .layout(tree: tree, root: 0, options: options, viewSize: SIMD2(700, 680)).cells

        let largest = try #require(cells.first { tree.name(of: $0.node) == "half.bin" })
        #expect(abs(largest.startAngle - .pi / 2) < 1e-4)
        #expect(abs(largest.endAngle - 3 * .pi / 2) < 1e-3)
    }

    @Test func packingRoundTrips() {
        let packed = CellPalette.packed(r: 0.2, g: 0.4, b: 0.6)
        let (r, g, b, a) = CellPalette.unpack(packed)
        #expect(abs(r - 0.2) < 0.01)
        #expect(abs(g - 0.4) < 0.01)
        #expect(abs(b - 0.6) < 0.01)
        #expect(a == 1)
    }

    @Test func recentFilesAreWarmAndOldFilesAreCool() {
        let newest = CellPalette.dateColor(timestamp: 200, oldest: 100, newest: 200)
        let oldest = CellPalette.dateColor(timestamp: 100, oldest: 100, newest: 200)
        #expect(CellPalette.hue(of: newest) < 30)      // red
        #expect(CellPalette.hue(of: oldest) > 200)     // blue
    }

    @Test func aNodeKeepsTheSameColourInBothGraphs() throws {
        let (tree, fixture) = try sampleTree()
        withExtendedLifetime(fixture) {}

        var options = GraphOptions()
        options.mergeThreshold = 0
        let pie = SunburstLayout().layout(tree: tree, root: 0, options: options, viewSize: viewSize)
        let map = TreemapLayout().layout(tree: tree, root: 0, options: options, viewSize: viewSize)

        var pieColors: [NodeID: UInt32] = [:]
        for cell in pie.cells where !cell.cellFlags.contains(.merged) {
            pieColors[cell.node] = cell.color
        }
        var compared = 0
        for cell in map.cells where !cell.cellFlags.contains(.merged) {
            guard let expected = pieColors[cell.node] else { continue }
            #expect(cell.color == expected, "\(tree.name(of: cell.node)) differs between graphs")
            compared += 1
        }
        #expect(compared > 10)
    }
}

@Suite struct HitTestingTests {
    @Test func pieHitTestFindsTheCellUnderThePoint() throws {
        let (tree, fixture) = try sampleTree()
        withExtendedLifetime(fixture) {}

        var options = GraphOptions()
        options.mergeThreshold = 0
        let result = SunburstLayout().layout(
            tree: tree, root: 0, options: options, viewSize: SIMD2(800, 800))
        let tester = GraphHitTester(
            cells: result.cells, graphType: .pieChart,
            discRadiusFraction: result.discRadiusFraction)

        // Probe the centre of every cell and expect to get that same cell back.
        var checked = 0
        for cell in result.cells where cell.endAngle - cell.startAngle > 0.02 {
            // Half-way through the ring, scaled by the disc size, then halved again
            // because the view's half-extent is 0.5 in normalised coordinates.
            let radius = (cell.innerRadius + cell.outerRadius) / 2
                * result.discRadiusFraction / 2
            let angle = (cell.startAngle + cell.endAngle) / 2
            let point = SIMD2<Float>(0.5 + radius * sin(angle), 0.5 - radius * cos(angle))
            let hit = tester.cell(at: point, aspect: 1)
            #expect(hit?.node == cell.node, "missed \(tree.name(of: cell.node))")
            checked += 1
        }
        #expect(checked > 5)
    }

    @Test func pieHitTestReturnsNothingInTheHoleOrOutsideTheDisc() throws {
        let (tree, fixture) = try sampleTree()
        withExtendedLifetime(fixture) {}

        let result = SunburstLayout().layout(
            tree: tree, root: 0, options: GraphOptions(), viewSize: SIMD2(800, 800))
        let tester = GraphHitTester(
            cells: result.cells, graphType: .pieChart,
            discRadiusFraction: result.discRadiusFraction)

        #expect(tester.cell(at: SIMD2(0.5, 0.5), aspect: 1) == nil)
        #expect(tester.cell(at: SIMD2(0.01, 0.01), aspect: 1) == nil)
    }

    @Test func treeMapHitTestPrefersTheLeafOverItsDirectory() throws {
        let (tree, fixture) = try sampleTree()
        withExtendedLifetime(fixture) {}

        var options = GraphOptions()
        options.mergeThreshold = 0.5
        let result = TreemapLayout().layout(tree: tree, root: 0, options: options, viewSize: viewSize)
        let tester = GraphHitTester(cells: result.cells, graphType: .treeMap)

        var checked = 0
        for cell in result.cells where cell.rectAlpha > 0 && cell.rect.z > 0.01 && cell.rect.w > 0.01 {
            let point = SIMD2(cell.rect.x + cell.rect.z / 2, cell.rect.y + cell.rect.w / 2)
            let hit = tester.cell(at: point, aspect: viewSize.x / viewSize.y)
            #expect(hit != nil)
            // Whatever is returned must be a filled cell containing the point.
            if let hit {
                #expect(hit.rectAlpha > 0)
                #expect(!tree.isDirectory(hit.node) || hit.cellFlags.contains(.merged))
            }
            checked += 1
        }
        #expect(checked > 5)
    }
}

@Suite struct MorphFusionTests {
    @Test func fusedBufferCoversBothGraphsAndKeepsEachCellDrawableInOne() throws {
        let (tree, fixture) = try sampleTree()
        withExtendedLifetime(fixture) {}

        var options = GraphOptions()
        options.mergeThreshold = 0.5
        let engine = GraphLayoutEngine()
        let pie = SunburstLayout().layout(tree: tree, root: 0, options: options, viewSize: viewSize)
        let map = TreemapLayout().layout(tree: tree, root: 0, options: options, viewSize: viewSize)
        let fused = engine.morphable(tree: tree, root: 0, options: options, viewSize: viewSize).cells

        // Every cell of each source layout survives into the fused buffer.
        let fusedKeys = Set(fused.map { GraphLayoutEngine.CellKey($0) })
        for cell in pie.cells { #expect(fusedKeys.contains(GraphLayoutEngine.CellKey(cell))) }
        for cell in map.cells { #expect(fusedKeys.contains(GraphLayoutEngine.CellKey(cell))) }

        // No cell is invisible in both end states, and none is left without geometry.
        for cell in fused {
            #expect(cell.pieAlpha > 0 || cell.rectAlpha > 0)
            if cell.pieAlpha > 0 { #expect(cell.outerRadius > 0) }
        }
    }

    @Test func fusedEndStatesMatchTheStandaloneLayouts() throws {
        let (tree, fixture) = try sampleTree()
        withExtendedLifetime(fixture) {}

        var options = GraphOptions()
        options.mergeThreshold = 0.5
        let pie = SunburstLayout().layout(tree: tree, root: 0, options: options, viewSize: viewSize)
        let fused = GraphLayoutEngine()
            .morphable(tree: tree, root: 0, options: options, viewSize: viewSize).cells

        var fusedByKey: [GraphLayoutEngine.CellKey: CellInstance] = [:]
        for cell in fused { fusedByKey[GraphLayoutEngine.CellKey(cell)] = cell }

        for cell in pie.cells {
            let match = try #require(fusedByKey[GraphLayoutEngine.CellKey(cell)])
            #expect(match.pie == cell.pie)
            #expect(match.pieAlpha == cell.pieAlpha)
            #expect(match.color == cell.color)
        }
    }
}

@Suite struct MergedCellTests {
    /// The gray cell stands in for siblings too small to draw, so it has to report their
    /// combined size — it previously read as zero because a merged cell borrows its
    /// parent's node id and has nothing of its own to look up in the tree.
    @Test(arguments: [GraphType.pieChart, GraphType.treeMap])
    func mergedCellsReportTheGroupTheyStandFor(graphType: GraphType) throws {
        let fixture = try Fixture()
        try fixture.file("big.bin", bytes: 20_000_000)
        for i in 0 ..< 150 { try fixture.file("tiny\(i).bin", bytes: 1024) }
        let tree = try DirectoryScanner().scan(rootPath: fixture.root.path)

        var options = GraphOptions()
        options.sizeMode = .logical
        options.graphType = graphType
        // The pie merges on arc length and the tree map on area, so pick a threshold
        // comfortably past both.
        options.mergeThreshold = 20
        let cells = GraphLayoutEngine()
            .layout(tree: tree, root: 0, options: options, viewSize: viewSize).cells

        let merged = cells.filter { $0.cellFlags.contains(.merged) }
        #expect(merged.count == 1)
        let group = try #require(merged.first)
        #expect(group.mergedCount > 1)
        #expect(group.mergedSize > 0)
        // The group accounts for exactly what the drawn cells leave out.
        let drawn = cells
            .filter { !$0.cellFlags.contains(.merged) && $0.node != 0 }
            .reduce(Int64(0)) { $0 + tree.logicalSize[Int($1.node)] }
        #expect(group.mergedSize == tree.logicalSize[0] - drawn)
    }
}
