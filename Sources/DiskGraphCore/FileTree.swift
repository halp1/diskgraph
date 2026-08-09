import Foundation

public typealias NodeID = Int32

public struct NodeFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let directory = NodeFlags(rawValue: 1 << 0)
    /// A directory the Finder presents as a single item (`.app`, `.framework`, …).
    public static let package = NodeFlags(rawValue: 1 << 1)
    public static let symbolicLink = NodeFlags(rawValue: 1 << 2)
    /// Directory we could not open — its contents are missing from the totals.
    public static let unreadable = NodeFlags(rawValue: 1 << 3)
    /// Additional link to an inode already counted; contributes zero bytes.
    public static let hardLinkDuplicate = NodeFlags(rawValue: 1 << 4)
}

/// An immutable scanned directory tree stored as parallel arrays.
///
/// A class-per-node graph costs roughly an order of magnitude more memory and pointer
/// chasing than this layout, and multi-million-node trees are the normal case. Children
/// of a node occupy a contiguous index range, so iterating them is a simple loop and a
/// node's whole subtree is *not* contiguous but always has higher indices than the node
/// itself — which is what makes the bottom-up size roll-up a single reverse pass.
public final class FileTree: @unchecked Sendable {
    /// Absolute path of node 0.
    public let rootPath: String

    /// UTF-8 bytes of every node name, concatenated.
    public let nameBytes: [UInt8]
    public let nameOffset: [UInt32]
    public let nameLength: [UInt16]

    public let parent: [NodeID]
    /// Index of the first child, or `-1`. Children are `firstChild ..< firstChild + childCount`.
    public let firstChild: [NodeID]
    public let childCount: [UInt32]

    /// Logical bytes across all forks, summed over the subtree.
    public let logicalSize: [Int64]
    /// Allocated ("on disk") bytes, summed over the subtree.
    public let allocatedSize: [Int64]
    /// Number of non-directory nodes in the subtree.
    public let fileCount: [Int64]

    public let creationTime: [Int64]
    public let modificationTime: [Int64]
    public let flags: [UInt8]
    public let depth: [UInt16]

    /// Directories that could not be opened, with the failing `errno`.
    public let errors: [ScanError]

    public struct ScanError: Sendable, Hashable {
        public let path: String
        public let code: Int32
        public var message: String { String(cString: strerror(code)) }
    }

    public var count: Int { parent.count }
    public var indices: Range<Int> { 0 ..< parent.count }

    init(rootPath: String, storage: FileTreeStorage, errors: [ScanError]) {
        self.rootPath = rootPath
        self.nameBytes = storage.nameBytes
        self.nameOffset = storage.nameOffset
        self.nameLength = storage.nameLength
        self.parent = storage.parent
        self.firstChild = storage.firstChild
        self.childCount = storage.childCount
        self.logicalSize = storage.logicalSize
        self.allocatedSize = storage.allocatedSize
        self.fileCount = storage.fileCount
        self.creationTime = storage.creationTime
        self.modificationTime = storage.modificationTime
        self.flags = storage.flags
        self.depth = storage.depth
        self.errors = errors
    }

    // MARK: - Accessors

    public func name(of node: NodeID) -> String {
        let i = Int(node)
        let start = Int(nameOffset[i])
        let end = start + Int(nameLength[i])
        guard start < end else { return "" }
        return nameBytes.withUnsafeBufferPointer {
            String(decoding: UnsafeBufferPointer(rebasing: $0[start ..< end]), as: UTF8.self)
        }
    }

    public func nodeFlags(_ node: NodeID) -> NodeFlags { NodeFlags(rawValue: flags[Int(node)]) }

    public func isDirectory(_ node: NodeID) -> Bool {
        flags[Int(node)] & NodeFlags.directory.rawValue != 0
    }

    public func children(of node: NodeID) -> Range<NodeID> {
        let i = Int(node)
        let first = firstChild[i]
        guard first >= 0 else { return 0 ..< 0 }
        return first ..< (first + NodeID(childCount[i]))
    }

    public func path(of node: NodeID) -> String {
        guard node != 0 else { return rootPath }
        var components: [String] = []
        var current = node
        while current > 0 {
            components.append(name(of: current))
            current = parent[Int(current)]
        }
        var base = rootPath
        if base.hasSuffix("/") { base.removeLast() }
        return base + "/" + components.reversed().joined(separator: "/")
    }

    public func url(of node: NodeID) -> URL { URL(fileURLWithPath: path(of: node)) }

    /// Ancestors of `node` from the root down to and including `node`.
    public func ancestry(of node: NodeID) -> [NodeID] {
        var chain: [NodeID] = []
        var current = node
        while true {
            chain.append(current)
            if current == 0 { break }
            current = parent[Int(current)]
        }
        return chain.reversed()
    }

    public func size(of node: NodeID, mode: SizeMode) -> Int64 {
        switch mode {
        case .logical: return logicalSize[Int(node)]
        case .allocated: return allocatedSize[Int(node)]
        case .childCount: return fileCount[Int(node)]
        }
    }

    /// Byte-wise name ordering. The layouts sort every directory they visit, so this
    /// avoids materialising two `String`s per comparison on a hot path.
    @inline(__always)
    public func nameIsOrderedBefore(_ a: NodeID, _ b: NodeID) -> Bool {
        let ai = Int(a), bi = Int(b)
        let aStart = Int(nameOffset[ai]), aCount = Int(nameLength[ai])
        let bStart = Int(nameOffset[bi]), bCount = Int(nameLength[bi])
        return nameBytes.withUnsafeBufferPointer { bytes -> Bool in
            let shared = min(aCount, bCount)
            var i = 0
            while i < shared {
                let x = bytes[aStart + i], y = bytes[bStart + i]
                if x != y { return x < y }
                i += 1
            }
            return aCount < bCount
        }
    }

    /// Child indices sorted largest first, which is the order both graphs lay out in.
    public func sortedChildren(of node: NodeID, mode: SizeMode) -> [NodeID] {
        let range = children(of: node)
        guard !range.isEmpty else { return [] }
        var result = Array(range)
        // Ties broken by name so a rescan of unchanged content produces an identical graph.
        result.sort { a, b in
            let sa = size(of: a, mode: mode), sb = size(of: b, mode: mode)
            if sa != sb { return sa > sb }
            return nameIsOrderedBefore(a, b)
        }
        return result
    }
}

/// Mutable arrays handed to `FileTree` once the scan finishes.
struct FileTreeStorage {
    var nameBytes: [UInt8] = []
    var nameOffset: [UInt32] = []
    var nameLength: [UInt16] = []
    var parent: [NodeID] = []
    var firstChild: [NodeID] = []
    var childCount: [UInt32] = []
    var logicalSize: [Int64] = []
    var allocatedSize: [Int64] = []
    var fileCount: [Int64] = []
    var creationTime: [Int64] = []
    var modificationTime: [Int64] = []
    var flags: [UInt8] = []
    var depth: [UInt16] = []
}
