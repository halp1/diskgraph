import Foundation

/// Directory extensions the Finder shows as a single opaque item.
private let packageExtensions: Set<String> = [
    "app", "bundle", "framework", "kext", "plugin", "docset", "xpc", "qlgenerator",
    "component", "mdimporter", "prefpane", "saver", "service", "wdgt", "pkg", "mpkg",
    "dsym", "photoslibrary", "musiclibrary", "tvlibrary", "photoslibrary", "rtfd",
    "scptd", "download", "sparsebundle", "logarchive", "aplibrary", "fcpbundle",
    "imovielibrary", "theater", "playground", "xcodeproj", "xcworkspace", "xcassets",
]

public struct ScanOptions: Sendable {
    /// How far out of the starting volume the walk may go. See `VolumeScope`.
    public var volumeScope: VolumeScope = .sameDisk
    /// Count a multiply-linked inode's bytes only the first time it is seen, like `du`.
    ///
    /// On by default, which is a deliberate *departure* from the reference app. Scanning
    /// `/Applications` there reports 22.52 GB — exactly this scanner's total with dedup
    /// off — whereas `du` reports 22.23 GB, which is what you would actually reclaim.
    /// Charging every path for bytes it shares makes whole-disk totals visibly too big,
    /// so this favours the truthful number and leaves the other available.
    ///
    /// Note that neither setting can see APFS clones: two files that share blocks
    /// copy-on-write both report their full size, so a whole-volume total still reads
    /// higher than the container's real usage. `du` has the same blind spot.
    public var countHardLinksOnce = true
    /// Walk into `.app` and friends. On by default — their contents count towards the
    /// total. Whether the *graph* subdivides a package is a separate, display-time
    /// decision (see `GraphOptions`), which is what File ▸ Show Package Contents flips.
    public var descendIntoPackages = true
    public var threadCount: Int = max(1, ProcessInfo.processInfo.activeProcessorCount)

    /// Denominator for the progress estimate, in allocated bytes.
    ///
    /// Nothing can know a tree's size without walking it, so progress needs an outside
    /// guess. Best is the total this same folder came to last time; failing that, the used
    /// bytes of its volume. With neither, progress falls back to the share of discovered
    /// directories finished — which barely moves on a depth-first walk, because the queue
    /// stays short, so it is a last resort rather than the default.
    public var expectedTotalBytes: Int64?

    public init() {}
}

public struct ScanProgress: Sendable {
    public var nodesScanned: Int
    public var bytesScanned: Int64
    /// Directories finished, and still waiting in the queue.
    public var directoriesScanned: Int
    public var directoriesPending: Int
    /// The top-level folder under the scan root currently being worked on. Changes a
    /// handful of times over a whole scan, unlike the full path, which changes hundreds of
    /// times a second and just flickers.
    public var currentTopLevel: String
    /// 0…1. Estimated, and guaranteed never to go backwards.
    ///
    /// Bytes seen against `ScanOptions.expectedTotalBytes` when that is available. See
    /// there for why the alternative is poor.
    public var fractionComplete: Double
    /// False while the estimate has no real denominator, so the UI can stay indeterminate
    /// instead of showing a number it cannot stand behind.
    public var isEstimateMeaningful: Bool

    public init(
        nodesScanned: Int = 0, bytesScanned: Int64 = 0,
        directoriesScanned: Int = 0, directoriesPending: Int = 0,
        currentTopLevel: String = "", fractionComplete: Double = 0,
        isEstimateMeaningful: Bool = false
    ) {
        self.nodesScanned = nodesScanned
        self.bytesScanned = bytesScanned
        self.directoriesScanned = directoriesScanned
        self.directoriesPending = directoriesPending
        self.currentTopLevel = currentTopLevel
        self.fractionComplete = fractionComplete
        self.isEstimateMeaningful = isEstimateMeaningful
    }
}

public enum ScanFailure: Error, LocalizedError {
    case cancelled
    case unreadableRoot(path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The scan was cancelled."
        case let .unreadableRoot(path, code):
            return "Could not read \(path): \(String(cString: strerror(code)))"
        }
    }
}

/// Thread-safe flag polled once per directory.
public final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public func cancel() { lock.lock(); flag = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Walks a directory tree in parallel and returns a `FileTree`.
///
/// The walk is a shared LIFO stack of pending directories drained by a fixed pool of
/// threads. Depth-first ordering keeps the stack shallow, so the transient memory held
/// for pending paths stays small even on wide trees.
///
/// Each worker scans one directory completely into thread-local scratch, then takes the
/// tree lock exactly once to append that directory's children as a contiguous block.
/// One lock acquisition per directory rather than per entry is what keeps the pool from
/// serialising on a hot lock.
public final class DirectoryScanner {
    public init() {}

    public func scan(
        rootPath: String,
        options: ScanOptions = ScanOptions(),
        cancellation: ScanCancellation = ScanCancellation(),
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) throws -> FileTree {
        let root = (rootPath as NSString).standardizingPath

        var rootStat = stat()
        guard lstat(root, &rootStat) == 0 else {
            throw ScanFailure.unreadableRoot(path: root, code: errno)
        }
        let rootIsDirectory = (rootStat.st_mode & S_IFMT) == S_IFDIR

        let state = ScanState(
            options: options,
            rootDevice: rootStat.st_dev,
            volumeMap: VolumeMap(rootPath: root, scope: options.volumeScope))
        state.rootPath = root
        state.appendRoot(
            name: (root as NSString).lastPathComponent,
            isDirectory: rootIsDirectory,
            logicalSize: rootIsDirectory ? 0 : rootStat.st_size,
            allocatedSize: rootIsDirectory ? 0 : Int64(rootStat.st_blocks) * 512,
            creationTime: Int64(rootStat.st_birthtimespec.tv_sec),
            modificationTime: Int64(rootStat.st_mtimespec.tv_sec))

        if rootIsDirectory {
            _ = state.claimDirectory(device: Int32(rootStat.st_dev), fileID: rootStat.st_ino)
            state.push(node: 0, path: root)
            runWorkers(state: state, options: options, cancellation: cancellation, progress: progress)
        }

        if cancellation.isCancelled { throw ScanFailure.cancelled }

        state.rollUpSizes()
        return FileTree(rootPath: root, storage: state.storage, errors: state.errors)
    }

    private func runWorkers(
        state: ScanState,
        options: ScanOptions,
        cancellation: ScanCancellation,
        progress: (@Sendable (ScanProgress) -> Void)?
    ) {
        let reporter = progress.map { ProgressReporter(state: state, callback: $0) }
        reporter?.start()
        defer { reporter?.stop() }

        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        for _ in 0 ..< options.threadCount {
            queue.async(group: group) {
                let worker = ScanWorker(state: state, options: options, cancellation: cancellation)
                worker.run()
            }
        }
        group.wait()
    }
}

// MARK: - Shared state

final class ScanState: @unchecked Sendable {
    let options: ScanOptions
    let rootDevice: dev_t
    let volumeMap: VolumeMap

    private let treeLock = NSLock()
    var storage = FileTreeStorage()
    var errors: [FileTree.ScanError] = []

    private let queueLock = NSCondition()
    private var pending: [(node: NodeID, path: String)] = []
    private var activeWorkers = 0
    private var shutdown = false

    private let identityLock = NSLock()
    private var seenHardLinks = Set<FileIdentity>()
    /// Every directory already claimed by some worker. This, not the device id, is what
    /// stops firmlinked directories being counted twice — on an APFS system volume group
    /// `/Users` and `/System/Volumes/Data/Users` report the *same* device, so a device
    /// check cannot tell them apart, but they share an inode.
    private var claimedDirectories = Set<FileIdentity>()

    /// Updated once per directory, so the extra lock costs nothing measurable. It has to
    /// be a real lock rather than a relaxed read: `currentPath` is a `String`, and racing
    /// a read against a write tears its reference and crashes.
    private let progressLock = NSLock()
    private var nodesScanned = 0
    private var bytesScanned: Int64 = 0
    private var directoriesScanned = 0
    private var directoriesQueued = 0
    private var currentTopLevel = ""
    /// Kept so the reported fraction never goes backwards when a directory turns out to
    /// contain many more subdirectories than expected.
    private var highestFraction: Double = 0
    /// Prefix stripped to find the top-level folder being worked on.
    var rootPath = ""

    init(options: ScanOptions, rootDevice: dev_t, volumeMap: VolumeMap) {
        self.options = options
        self.rootDevice = rootDevice
        self.volumeMap = volumeMap
    }

    // MARK: Tree building

    func appendRoot(
        name: String, isDirectory: Bool, logicalSize: Int64, allocatedSize: Int64,
        creationTime: Int64, modificationTime: Int64
    ) {
        var flags = NodeFlags()
        if isDirectory { flags.insert(.directory) }
        let bytes = Array(name.utf8)
        storage.nameOffset.append(0)
        storage.nameLength.append(UInt16(clamping: bytes.count))
        storage.nameBytes.append(contentsOf: bytes)
        storage.parent.append(-1)
        storage.firstChild.append(-1)
        storage.childCount.append(0)
        storage.logicalSize.append(logicalSize)
        storage.allocatedSize.append(allocatedSize)
        storage.fileCount.append(isDirectory ? 0 : 1)
        storage.creationTime.append(creationTime)
        storage.modificationTime.append(modificationTime)
        storage.flags.append(flags.rawValue)
        storage.depth.append(0)
    }

    /// Appends `entries` as the contiguous child block of `parent`.
    /// Returns the node id assigned to each entry, in order.
    func appendChildren(
        of parent: NodeID, entries: [ScannedEntry], nameScratch: [UInt8], depth: UInt16
    ) -> NodeID {
        treeLock.lock()
        defer { treeLock.unlock() }

        let first = NodeID(storage.parent.count)
        let newCount = storage.parent.count + entries.count
        storage.parent.reserveCapacity(newCount)
        storage.nameBytes.reserveCapacity(storage.nameBytes.count + nameScratch.count)

        var bytes: Int64 = 0
        for entry in entries {
            storage.nameOffset.append(UInt32(storage.nameBytes.count))
            storage.nameLength.append(UInt16(clamping: entry.nameLength))
            let start = entry.nameStart
            storage.nameBytes.append(contentsOf: nameScratch[start ..< start + entry.nameLength])
            storage.parent.append(parent)
            storage.firstChild.append(-1)
            storage.childCount.append(0)
            storage.logicalSize.append(entry.logicalSize)
            storage.allocatedSize.append(entry.allocatedSize)
            storage.fileCount.append(entry.flags.contains(.directory) ? 0 : 1)
            storage.creationTime.append(entry.creationTime)
            storage.modificationTime.append(entry.modificationTime)
            storage.flags.append(entry.flags.rawValue)
            storage.depth.append(depth)
            bytes += entry.allocatedSize
        }

        storage.firstChild[Int(parent)] = entries.isEmpty ? -1 : first
        storage.childCount[Int(parent)] = UInt32(entries.count)

        progressLock.lock()
        nodesScanned += entries.count
        bytesScanned += bytes
        progressLock.unlock()
        return first
    }

    func markUnreadable(node: NodeID, path: String, code: Int32) {
        treeLock.lock()
        storage.flags[Int(node)] |= NodeFlags.unreadable.rawValue
        errors.append(FileTree.ScanError(path: path, code: code))
        treeLock.unlock()
    }

    func depth(of node: NodeID) -> UInt16 {
        treeLock.lock(); defer { treeLock.unlock() }
        return storage.depth[Int(node)]
    }

    /// Children always have a higher index than their parent, so one reverse pass
    /// propagates every subtree total.
    func rollUpSizes() {
        let count = storage.parent.count
        guard count > 1 else { return }

        // Move the buffers out of `storage` first. Nesting `withUnsafeMutableBufferPointer`
        // on `storage.a` inside one on `storage.b` is two overlapping exclusive accesses to
        // `storage` itself, which traps at runtime. Swapping hands each array over as a
        // uniquely-referenced local, so no copy happens either.
        var logical: [Int64] = []; swap(&logical, &storage.logicalSize)
        var allocated: [Int64] = []; swap(&allocated, &storage.allocatedSize)
        var files: [Int64] = []; swap(&files, &storage.fileCount)
        var parents: [NodeID] = []; swap(&parents, &storage.parent)

        logical.withUnsafeMutableBufferPointer { logical in
            allocated.withUnsafeMutableBufferPointer { allocated in
                files.withUnsafeMutableBufferPointer { files in
                    parents.withUnsafeBufferPointer { parents in
                        var i = count - 1
                        while i > 0 {
                            let p = Int(parents[i])
                            logical[p] += logical[i]
                            allocated[p] += allocated[i]
                            files[p] += files[i]
                            i -= 1
                        }
                    }
                }
            }
        }

        swap(&logical, &storage.logicalSize)
        swap(&allocated, &storage.allocatedSize)
        swap(&files, &storage.fileCount)
        swap(&parents, &storage.parent)
    }

    // MARK: Work queue

    func push(node: NodeID, path: String) {
        progressLock.lock()
        directoriesQueued += 1
        progressLock.unlock()

        queueLock.lock()
        pending.append((node, path))
        queueLock.signal()
        queueLock.unlock()
    }

    func pushAll(_ items: [(node: NodeID, path: String)]) {
        guard !items.isEmpty else { return }
        progressLock.lock()
        directoriesQueued += items.count
        progressLock.unlock()

        queueLock.lock()
        pending.append(contentsOf: items)
        queueLock.broadcast()
        queueLock.unlock()
    }

    /// Blocks until work is available, or returns nil once every worker is idle and the
    /// stack is empty.
    /// Notes which top-level folder a worker has moved on to. Called once per directory.
    func noteProcessing(path: String) {
        let relative = path.hasPrefix(rootPath)
            ? String(path.dropFirst(rootPath.count)).drop(while: { $0 == "/" })
            : Substring(path)
        let top = String(relative.prefix(while: { $0 != "/" }))
        guard !top.isEmpty else { return }
        progressLock.lock()
        if currentTopLevel != top { currentTopLevel = top }
        progressLock.unlock()
    }

    func nextTask() -> (node: NodeID, path: String)? {
        queueLock.lock()
        defer { queueLock.unlock() }
        while true {
            if shutdown { return nil }
            if let task = pending.popLast() {
                activeWorkers += 1
                progressLock.lock()
                directoriesQueued = max(0, directoriesQueued - 1)
                progressLock.unlock()
                return task
            }
            if activeWorkers == 0 {
                shutdown = true
                queueLock.broadcast()
                return nil
            }
            queueLock.wait()
        }
    }

    func finishTask() {
        progressLock.lock()
        directoriesScanned += 1
        progressLock.unlock()

        queueLock.lock()
        activeWorkers -= 1
        if activeWorkers == 0 && pending.isEmpty {
            shutdown = true
            queueLock.broadcast()
        }
        queueLock.unlock()
    }

    func abort() {
        queueLock.lock()
        shutdown = true
        queueLock.broadcast()
        queueLock.unlock()
    }

    // MARK: Hard links

    /// True if this inode's bytes have already been counted.
    func isDuplicateHardLink(device: Int32, fileID: UInt64) -> Bool {
        let key = FileIdentity(device: device, fileID: fileID)
        identityLock.lock()
        defer { identityLock.unlock() }
        return !seenHardLinks.insert(key).inserted
    }

    /// Claims a directory for scanning. Returns false if some other path already reached
    /// the same inode, in which case this path must not be walked again.
    func claimDirectory(device: Int32, fileID: UInt64) -> Bool {
        let key = FileIdentity(device: device, fileID: fileID)
        identityLock.lock()
        defer { identityLock.unlock() }
        return claimedDirectories.insert(key).inserted
    }

    var progressSnapshot: ScanProgress {
        progressLock.lock()
        defer { progressLock.unlock() }
        let expected = options.expectedTotalBytes ?? 0
        let estimate: Double
        if expected > 0 {
            estimate = min(Double(bytesScanned) / Double(expected), 0.99)
        } else {
            let known = directoriesScanned + directoriesQueued
            estimate = known > 0 ? min(Double(directoriesScanned) / Double(known), 0.99) : 0
        }
        // Hold just short of complete while work remains, so the bar never sits at 100 %
        // with the scan still running.
        highestFraction = max(highestFraction, estimate)
        let done = directoriesQueued == 0 && directoriesScanned > 0
        return ScanProgress(
            nodesScanned: nodesScanned,
            bytesScanned: bytesScanned,
            directoriesScanned: directoriesScanned,
            directoriesPending: directoriesQueued,
            currentTopLevel: currentTopLevel,
            fractionComplete: done ? 1 : highestFraction,
            isEstimateMeaningful: expected > 0)
    }
}

/// Exact (device, inode) pair. Hashing the two into one integer risked a collision
/// silently dropping a whole subtree, so keep them separate.
struct FileIdentity: Hashable {
    var device: Int32
    var fileID: UInt64
}

/// A directory entry accumulated in thread-local scratch before being published.
struct ScannedEntry {
    var nameStart: Int
    var nameLength: Int
    var device: Int32
    var fileID: UInt64
    var flags: NodeFlags
    var logicalSize: Int64
    var allocatedSize: Int64
    var creationTime: Int64
    var modificationTime: Int64
}

// MARK: - Worker

private final class ScanWorker {
    private let state: ScanState
    private let options: ScanOptions
    private let cancellation: ScanCancellation
    private let reader = BulkDirectoryReader()

    private var entries: [ScannedEntry] = []
    private var nameScratch: [UInt8] = []
    private var subdirectories: [(index: Int, name: String)] = []

    init(state: ScanState, options: ScanOptions, cancellation: ScanCancellation) {
        self.state = state
        self.options = options
        self.cancellation = cancellation
        entries.reserveCapacity(512)
        nameScratch.reserveCapacity(16 * 1024)
        subdirectories.reserveCapacity(64)
    }

    func run() {
        while let task = state.nextTask() {
            if cancellation.isCancelled {
                state.finishTask()
                state.abort()
                return
            }
            state.noteProcessing(path: task.path)
            process(node: task.node, path: task.path)
            state.finishTask()
        }
    }

    private func process(node: NodeID, path: String) {
        entries.removeAll(keepingCapacity: true)
        nameScratch.removeAll(keepingCapacity: true)
        subdirectories.removeAll(keepingCapacity: true)

        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            state.markUnreadable(node: node, path: path, code: errno)
            return
        }
        defer { close(fd) }

        while true {
            var hasMore = false
            do {
                hasMore = try reader.readBatch(fd: fd) { entry in self.collect(entry) }
            } catch {
                let code = (error as? POSIXError)?.code.rawValue ?? EIO
                state.markUnreadable(node: node, path: path, code: code)
                break
            }
            if !hasMore { break }
        }

        guard !entries.isEmpty else { return }

        let childDepth = state.depth(of: node) &+ 1
        let first = state.appendChildren(
            of: node, entries: entries, nameScratch: nameScratch, depth: childDepth)

        guard !subdirectories.isEmpty else { return }
        var base = path
        if base.hasSuffix("/") { base.removeLast() }

        var tasks: [(node: NodeID, path: String)] = []
        tasks.reserveCapacity(subdirectories.count)
        for sub in subdirectories {
            let childPath = base + "/" + sub.name
            // Mount points the volume map ruled out: other disks, network shares, autofs
            // triggers that would block, and the Data volume's duplicate view of `/`.
            if state.volumeMap.excludes(childPath) { continue }
            let entry = entries[sub.index]
            // Two paths can reach one directory — firmlinks do it all over the boot volume.
            // Whichever gets here first scans it; the other is left as an empty node.
            guard state.claimDirectory(device: entry.device, fileID: entry.fileID) else { continue }
            tasks.append((node: first + NodeID(sub.index), path: childPath))
        }
        state.pushAll(tasks)
    }

    private func collect(_ entry: BulkEntry) {
        guard entry.error == 0, entry.name.count > 0 else { return }

        var flags = NodeFlags()
        var logical = entry.logicalSize
        var allocated = entry.allocatedSize

        let nameStart = nameScratch.count
        nameScratch.append(contentsOf: entry.name)
        let nameLength = entry.name.count

        if entry.isDirectory {
            flags.insert(.directory)
            // Directory inodes have no meaningful ATTR_FILE_* values.
            logical = 0
            allocated = 0
            if isPackage(nameStart: nameStart, length: nameLength) {
                flags.insert(.package)
            }
        } else if entry.isSymbolicLink {
            flags.insert(.symbolicLink)
        } else if !entry.isRegularFile {
            // Sockets, fifos and devices occupy no space in the tree.
            logical = 0
            allocated = 0
        }

        if entry.isRegularFile, options.countHardLinksOnce, entry.linkCount > 1 {
            if state.isDuplicateHardLink(device: entry.deviceID, fileID: entry.fileID) {
                flags.insert(.hardLinkDuplicate)
                logical = 0
                allocated = 0
            }
        }

        let descend = flags.contains(.directory)
            && (options.descendIntoPackages || !flags.contains(.package))
        if descend {
            subdirectories.append((
                index: entries.count,
                name: String(decoding: entry.name, as: UTF8.self)))
        }

        entries.append(ScannedEntry(
            nameStart: nameStart,
            nameLength: nameLength,
            device: entry.deviceID,
            fileID: entry.fileID,
            flags: flags,
            logicalSize: logical,
            allocatedSize: allocated,
            creationTime: entry.creationTime,
            modificationTime: entry.modificationTime))
    }

    /// Extension match on the raw name bytes, avoiding a `String` per entry.
    private func isPackage(nameStart: Int, length: Int) -> Bool {
        var dot = -1
        var i = nameStart + length - 1
        let limit = nameStart
        while i > limit {
            if nameScratch[i] == UInt8(ascii: ".") { dot = i; break }
            i -= 1
        }
        guard dot > limit else { return false }
        let ext = String(decoding: nameScratch[(dot + 1) ..< (nameStart + length)], as: UTF8.self)
        return packageExtensions.contains(ext.lowercased())
    }
}

// MARK: - Progress

private final class ProgressReporter {
    private let state: ScanState
    private let callback: @Sendable (ScanProgress) -> Void
    private var timer: DispatchSourceTimer?

    init(state: ScanState, callback: @escaping @Sendable (ScanProgress) -> Void) {
        self.state = state
        self.callback = callback
    }

    func start() {
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        let state = self.state
        let callback = self.callback
        source.setEventHandler { callback(state.progressSnapshot) }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
        callback(state.progressSnapshot)
    }
}
