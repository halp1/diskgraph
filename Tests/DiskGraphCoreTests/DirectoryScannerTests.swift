import Foundation
import Testing
@testable import DiskGraphCore

/// Builds a throwaway directory tree and tears it down afterwards.
private struct Fixture: ~Copyable {
    let root: URL

    init(_ name: String = "diskgraph-tests") throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ path: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    func hardLink(_ path: String, to target: URL) throws {
        try FileManager.default.linkItem(at: target, to: root.appendingPathComponent(path))
    }

    func symlink(_ path: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent(path).path, withDestinationPath: destination)
    }
}

private func scan(_ root: URL, _ options: ScanOptions = ScanOptions()) throws -> FileTree {
    try DirectoryScanner().scan(rootPath: root.path, options: options)
}

private func node(_ tree: FileTree, _ relativePath: String) -> NodeID? {
    var current: NodeID = 0
    for component in relativePath.split(separator: "/") {
        guard let match = tree.children(of: current).first(where: {
            tree.name(of: $0) == String(component)
        }) else { return nil }
        current = match
    }
    return current
}

@Suite struct DirectoryScannerTests {
    @Test func sumsSizesUpTheTree() throws {
        let fixture = try Fixture()
        try fixture.file("a.bin", bytes: 3000)
        try fixture.file("sub/b.bin", bytes: 5000)
        try fixture.file("sub/deep/c.bin", bytes: 7000)

        let tree = try scan(fixture.root)

        #expect(tree.logicalSize[0] == 15000)
        #expect(tree.fileCount[0] == 3)
        let sub = try #require(node(tree, "sub"))
        #expect(tree.logicalSize[Int(sub)] == 12000)
        #expect(tree.fileCount[Int(sub)] == 2)
        let deep = try #require(node(tree, "sub/deep"))
        #expect(tree.logicalSize[Int(deep)] == 7000)
    }

    @Test func childrenOccupyAContiguousRangeAboveTheirParent() throws {
        let fixture = try Fixture()
        for i in 0 ..< 5 { try fixture.file("dir\(i)/file.bin", bytes: 100) }

        let tree = try scan(fixture.root)

        // The reverse-pass roll-up depends on this invariant holding for every node.
        for i in tree.indices {
            let range = tree.children(of: NodeID(i))
            for child in range {
                #expect(Int(child) > i)
                #expect(tree.parent[Int(child)] == NodeID(i))
            }
            if range.isEmpty { #expect(tree.childCount[i] == 0) }
        }
    }

    @Test func deduplicatesHardLinksByDefaultAndCountsPerPathOnRequest() throws {
        let fixture = try Fixture()
        let original = try fixture.file("original.bin", bytes: 8192)
        try fixture.hardLink("copy.bin", to: original)

        // Default counts the inode once, like `du`, so the total is what you would
        // actually reclaim. The reference app instead reports 16384 here.
        let deduplicated = try scan(fixture.root)
        #expect(deduplicated.logicalSize[0] == 8192)
        let duplicates = deduplicated.indices.filter {
            deduplicated.nodeFlags(NodeID($0)).contains(.hardLinkDuplicate)
        }
        #expect(duplicates.count == 1)

        var perPath = ScanOptions()
        perPath.countHardLinksOnce = false
        #expect(try scan(fixture.root, perPath).logicalSize[0] == 16384)
    }

    @Test func doesNotFollowSymbolicLinks() throws {
        let fixture = try Fixture()
        try fixture.file("real/payload.bin", bytes: 4096)
        let realPath = fixture.root.appendingPathComponent("real").path
        try fixture.symlink("loop", to: fixture.root.path)
        try fixture.symlink("into-real", to: realPath)

        let tree = try scan(fixture.root)

        // Following either link would recurse forever or double-count the payload.
        let real = try #require(node(tree, "real"))
        #expect(tree.logicalSize[Int(real)] == 4096)
        #expect(tree.fileCount[0] == 3)

        let loop = try #require(node(tree, "loop"))
        #expect(tree.nodeFlags(loop).contains(.symbolicLink))
        #expect(tree.childCount[Int(loop)] == 0)

        // A link contributes only its own target-path bytes, the same as stat(2) reports.
        #expect(tree.logicalSize[Int(loop)] == Int64(fixture.root.path.utf8.count))
        let expectedTotal = 4096
            + Int64(fixture.root.path.utf8.count)
            + Int64(realPath.utf8.count)
        #expect(tree.logicalSize[0] == expectedTotal)
    }

    @Test func reportsAllocatedSizeSeparatelyFromLogicalSize() throws {
        let fixture = try Fixture()
        try fixture.file("small.bin", bytes: 10)

        let tree = try scan(fixture.root)

        #expect(tree.logicalSize[0] == 10)
        // APFS may store a 10-byte file inline, so allocation is 0 or a whole block —
        // never a partial block, and never the logical size.
        let allocated = tree.allocatedSize[0]
        #expect(allocated % 4096 == 0)
    }

    @Test func flagsPackagesAndStillDescendsByDefault() throws {
        let fixture = try Fixture()
        try fixture.file("Thing.app/Contents/MacOS/thing", bytes: 2048)

        let tree = try scan(fixture.root)
        let app = try #require(node(tree, "Thing.app"))

        #expect(tree.nodeFlags(app).contains(.package))
        #expect(tree.nodeFlags(app).contains(.directory))
        #expect(tree.logicalSize[Int(app)] == 2048)

        var opaque = ScanOptions()
        opaque.descendIntoPackages = false
        let shallow = try scan(fixture.root, opaque)
        let shallowApp = try #require(node(shallow, "Thing.app"))
        #expect(shallow.childCount[Int(shallowApp)] == 0)
    }

    @Test func recordsUnreadableDirectoriesWithoutFailingTheScan() throws {
        let fixture = try Fixture()
        try fixture.file("readable/file.bin", bytes: 512)
        let locked = try fixture.directory("locked")
        try fixture.file("locked/hidden.bin", bytes: 999_999)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let tree = try scan(fixture.root)

        #expect(tree.logicalSize[0] == 512)
        #expect(tree.errors.count == 1)
        let lockedNode = try #require(node(tree, "locked"))
        #expect(tree.nodeFlags(lockedNode).contains(.unreadable))
    }

    @Test func producesIdenticalTreesAcrossRepeatedScans() throws {
        let fixture = try Fixture()
        for i in 0 ..< 40 { try fixture.file("d\(i % 7)/f\(i).bin", bytes: (i + 1) * 137) }

        let first = try scan(fixture.root)
        let second = try scan(fixture.root)

        // Node ordering depends on kernel enumeration order, so compare the sorted view
        // the graph actually lays out from.
        func fingerprint(_ tree: FileTree) -> [String] {
            var out: [String] = []
            func walk(_ node: NodeID, prefix: String) {
                for child in tree.sortedChildren(of: node, mode: .logical) {
                    let line = "\(prefix)/\(tree.name(of: child)):\(tree.logicalSize[Int(child)])"
                    out.append(line)
                    walk(child, prefix: line)
                }
            }
            walk(0, prefix: "")
            return out
        }
        #expect(fingerprint(first) == fingerprint(second))
    }

    @Test func scansAFileRootAsASingleNode() throws {
        let fixture = try Fixture()
        let file = try fixture.file("solo.bin", bytes: 1234)

        let tree = try DirectoryScanner().scan(rootPath: file.path)

        #expect(tree.count == 1)
        #expect(tree.logicalSize[0] == 1234)
        #expect(!tree.isDirectory(0))
    }

    @Test func cancellationStopsTheScan() throws {
        let fixture = try Fixture()
        for i in 0 ..< 200 { try fixture.file("d\(i)/f.bin", bytes: 64) }

        let cancellation = ScanCancellation()
        cancellation.cancel()

        #expect(throws: ScanFailure.self) {
            try DirectoryScanner().scan(rootPath: fixture.root.path, cancellation: cancellation)
        }
    }

    @Test func reportsProgressAndFinalTotals() throws {
        let fixture = try Fixture()
        for i in 0 ..< 50 { try fixture.file("d\(i % 5)/f\(i).bin", bytes: 4096) }

        let box = Locked(ScanProgress())
        let tree = try DirectoryScanner().scan(rootPath: fixture.root.path) { box.value = $0 }

        // The final callback fires after the walk, so it must agree with the tree.
        #expect(box.value.nodesScanned == tree.count - 1)
        #expect(tree.fileCount[0] == 50)
        // Nothing left queued means the estimate has to read as complete.
        #expect(box.value.directoriesPending == 0)
        #expect(box.value.fractionComplete == 1)
        #expect(box.value.directoriesScanned == 6)   // the root plus d0…d4
    }
}

/// Minimal box so the progress callback can publish across threads.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

@Suite struct PathAndFormattingTests {
    @Test func buildsAbsolutePathsFromTheNodeChain() throws {
        let fixture = try Fixture()
        try fixture.file("one/two/three.bin", bytes: 1)

        let tree = try scan(fixture.root)
        let leaf = try #require(node(tree, "one/two/three.bin"))

        #expect(tree.path(of: 0) == tree.rootPath)
        #expect(tree.path(of: leaf) == tree.rootPath + "/one/two/three.bin")
        #expect(tree.ancestry(of: leaf).map { tree.name(of: $0) }
            == [(tree.rootPath as NSString).lastPathComponent, "one", "two", "three.bin"])
    }

    /// The reference screenshots read "2.42 GB on disk" and "882.3 MB on disk".
    @Test func matchesTheScreenshotSizeStrings() {
        #expect(SizeFormatter.byteString(2_420_000_000) == "2.42 GB")
        #expect(SizeFormatter.byteString(882_300_000) == "882.3 MB")
        #expect(SizeFormatter.string(2_420_000_000, mode: .allocated) == "2.42 GB on disk")
        #expect(SizeFormatter.string(2_420_000_000, mode: .logical) == "2.42 GB")
        #expect(SizeFormatter.string(1234, mode: .childCount) == "1,234 files")
    }

    @Test func sortsChildrenLargestFirst() throws {
        let fixture = try Fixture()
        try fixture.file("small.bin", bytes: 10)
        try fixture.file("large.bin", bytes: 9000)
        try fixture.file("medium.bin", bytes: 500)

        let tree = try scan(fixture.root)
        let order = tree.sortedChildren(of: 0, mode: .logical).map { tree.name(of: $0) }

        #expect(order == ["large.bin", "medium.bin", "small.bin"])
    }
}

@Suite struct ScanProgressTests {
    /// The estimate has no total to divide by, so it is the share of *discovered*
    /// directories finished. It must still be monotonic and land exactly on 1.
    @Test func progressRisesMonotonicallyAndEndsComplete() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskgraph-progress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for group in 0 ..< 12 {
            for leaf in 0 ..< 6 {
                let dir = root.appendingPathComponent("g\(group)/sub\(leaf)/deep")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data(repeating: 0x41, count: 2048)
                    .write(to: dir.appendingPathComponent("f.bin"))
            }
        }

        let samples = Locked([Double]())
        var options = ScanOptions()
        options.threadCount = 2
        let tree = try DirectoryScanner().scan(rootPath: root.path, options: options) { progress in
            samples.value = samples.value + [progress.fractionComplete]
        }

        let observed = samples.value
        #expect(!observed.isEmpty)
        for (earlier, later) in zip(observed, observed.dropFirst()) {
            #expect(later >= earlier, "progress went backwards: \(earlier) → \(later)")
        }
        #expect(observed.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(observed.last == 1)
        #expect(tree.fileCount[0] == 72)
    }

    /// The top-level folder is what the overlay shows instead of the flickering full path.
    @Test func reportsTheTopLevelFolderRatherThanTheFullPath() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskgraph-toplevel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appendingPathComponent("Library/very/deeply/nested")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 1024).write(to: deep.appendingPathComponent("f.bin"))

        let seen = Locked(Set<String>())
        _ = try DirectoryScanner().scan(rootPath: root.path) { progress in
            if !progress.currentTopLevel.isEmpty {
                seen.value = seen.value.union([progress.currentTopLevel])
            }
        }

        // Only ever a single component, never a path.
        for value in seen.value {
            #expect(!value.contains("/"), "expected a folder name, got \(value)")
        }
    }
}

@Suite struct ProgressDenominatorTests {
    private func makeTree(_ root: URL, files: Int, bytes: Int) throws {
        for i in 0 ..< files {
            let dir = root.appendingPathComponent("d\(i % 8)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: bytes)
                .write(to: dir.appendingPathComponent("f\(i).bin"))
        }
    }

    /// With a denominator the estimate tracks bytes seen. Without one it falls back to the
    /// directory ratio, which on a depth-first walk barely moves — the queue stays short —
    /// so the UI is told not to show a number.
    @Test func reportsWhetherTheEstimateHasARealDenominator() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskgraph-denominator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeTree(root, files: 200, bytes: 8192)

        let withoutTotal = Locked(ScanProgress())
        _ = try DirectoryScanner().scan(rootPath: root.path) { withoutTotal.value = $0 }
        #expect(!withoutTotal.value.isEstimateMeaningful)

        var options = ScanOptions()
        options.expectedTotalBytes = 200 * 8192
        let withTotal = Locked(ScanProgress())
        _ = try DirectoryScanner().scan(rootPath: root.path, options: options) {
            withTotal.value = $0
        }
        #expect(withTotal.value.isEstimateMeaningful)
        #expect(withTotal.value.fractionComplete == 1)
    }

    /// A denominator that turns out to be far too large must not push the bar past 99 %
    /// early, nor stop it landing on 1 at the end.
    @Test func handlesAnOverEstimatedDenominator() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskgraph-over-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeTree(root, files: 40, bytes: 4096)

        var options = ScanOptions()
        options.expectedTotalBytes = 500_000_000_000   // as if the whole volume
        let samples = Locked([Double]())
        _ = try DirectoryScanner().scan(rootPath: root.path, options: options) {
            samples.value = samples.value + [$0.fractionComplete]
        }
        let observed = samples.value
        #expect(observed.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(observed.last == 1)
    }

    @Test func volumeUsedBytesIsAUsableFallback() throws {
        let used = try #require(VolumeMap.usedBytes(ofVolumeContaining: "/"))
        #expect(used > 0)
        // Sanity: a boot volume in use is at least a gigabyte.
        #expect(used > 1_000_000_000)
    }
}
