import Foundation

/// How far out of the starting volume a scan is allowed to wander.
public enum VolumeScope: String, Sendable, Codable, CaseIterable {
    /// Stay on the volume the root is on.
    case sameVolume
    /// Follow into other volumes on the same physical disk. This is what a user means by
    /// "scan my disk": on an APFS system the boot volume group spreads the System and
    /// Data volumes across `disk3s1s1` and `disk3s5`, and only counting one of them would
    /// under-report enormously.
    case sameDisk
    /// Follow every local mount, including external drives.
    case allLocalVolumes

    public var localizedName: String {
        switch self {
        case .sameVolume: return "This Volume Only"
        case .sameDisk: return "This Disk"
        case .allLocalVolumes: return "All Local Volumes"
        }
    }
}

/// Decides which mounted filesystems a scan should refuse to descend into.
///
/// This matters more on macOS than it sounds. The boot volume group is stitched together
/// with *firmlinks*: `/Users`, `/Applications`, `/Library`, `/private` and a dozen more
/// appear under `/` but live on the Data volume, which is *also* mounted at
/// `/System/Volumes/Data`. Every one of those directories is therefore reachable by two
/// paths, and — critically — `stat` reports the **same device id** for both, so the usual
/// "don't cross device boundaries" check does nothing. A naive walk of `/` counts most of
/// the disk twice.
///
/// See `/usr/share/firmlinks` for the list the system itself uses.
public struct VolumeMap: Sendable {
    /// Absolute mount points that must not be descended into.
    public let excludedMountPoints: Set<String>

    /// Filesystems that either are not real storage or can block indefinitely.
    /// `autofs` covers `/net` and `/home`, which hang waiting on a network mount.
    private static let unscannableFileSystems: Set<String> = [
        "autofs", "devfs", "fdesc", "nfs", "smbfs", "afpfs", "webdav", "ftp", "cddafs",
        "procfs", "kernfs", "lifs",
    ]

    public init(rootPath: String, scope: VolumeScope) {
        let root = VolumeMap.canonical(rootPath)
        let mounts = VolumeMap.mountedFileSystems()

        // Which filesystem the root itself sits on, i.e. the deepest mount point that is a
        // prefix of the root.
        let rootMount = mounts
            .filter { VolumeMap.path(root, isAtOrUnder: $0.mountPoint) }
            .max { $0.mountPoint.count < $1.mountPoint.count }

        var excluded: Set<String> = []
        for mount in mounts {
            // Never exclude the root's own filesystem, nor one containing it.
            if VolumeMap.path(root, isAtOrUnder: mount.mountPoint) { continue }

            if VolumeMap.unscannableFileSystems.contains(mount.fileSystemType) {
                excluded.insert(mount.mountPoint)
                continue
            }

            switch scope {
            case .sameVolume:
                excluded.insert(mount.mountPoint)
            case .sameDisk:
                if mount.physicalDisk == nil || mount.physicalDisk != rootMount?.physicalDisk {
                    excluded.insert(mount.mountPoint)
                }
            case .allLocalVolumes:
                break
            }
        }

        // The Data volume's own mount point is a second view of content already reachable
        // through the firmlinks in `/`. Counting it as well is the double-counting bug.
        // Excluded unless the scan actually starts inside it.
        let dataVolume = "/System/Volumes/Data"
        if !VolumeMap.path(root, isAtOrUnder: dataVolume) {
            excluded.insert(dataVolume)
        }

        excludedMountPoints = excluded
    }

    /// For tests and for callers that want to scan exactly what they asked for.
    public init(excludedMountPoints: Set<String>) {
        self.excludedMountPoints = excludedMountPoints
    }

    public func excludes(_ path: String) -> Bool {
        excludedMountPoints.contains(path)
    }

    // MARK: - Mount table

    struct Mount {
        var mountPoint: String
        var fileSystemType: String
        var device: String
        /// `/dev/disk3s5` → `disk3`. Volumes of one APFS container share this.
        var physicalDisk: String?
    }

    static func mountedFileSystems() -> [Mount] {
        // `statfs` names both a C struct and a C function, and Swift resolves `statfs()`
        // to the function — so the buffer has to be allocated rather than built from an
        // array literal. Ask for a few extra slots in case a volume is mounted between
        // the size query and the read.
        let probe = getfsstat(nil, 0, MNT_NOWAIT)
        guard probe > 0 else { return [] }
        let capacity = Int(probe) + 8
        let buffer = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        let written = getfsstat(
            buffer, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        guard written > 0 else { return [] }

        var mounts: [Mount] = []
        mounts.reserveCapacity(Int(written))
        for index in 0 ..< Int(min(written, Int32(capacity))) {
            let entry = buffer.advanced(by: index)
            let mountPoint = withUnsafePointer(to: &entry.pointee.f_mntonname) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            let device = withUnsafePointer(to: &entry.pointee.f_mntfromname) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            let type = withUnsafePointer(to: &entry.pointee.f_fstypename) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            mounts.append(Mount(
                mountPoint: canonical(mountPoint),
                fileSystemType: type,
                device: device,
                physicalDisk: physicalDisk(of: device)))
        }
        return mounts
    }

    /// Strips the slice suffix: `/dev/disk3s1s1` → `disk3`.
    static func physicalDisk(of device: String) -> String? {
        guard device.hasPrefix("/dev/disk") else { return nil }
        let name = device.dropFirst("/dev/".count)
        var digits = "disk"
        for character in name.dropFirst("disk".count) {
            guard character.isNumber else { break }
            digits.append(character)
        }
        return digits == "disk" ? nil : digits
    }

    static func canonical(_ path: String) -> String {
        var result = (path as NSString).standardizingPath
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// True when `path` is `ancestor` or sits inside it.
    static func path(_ path: String, isAtOrUnder ancestor: String) -> Bool {
        if ancestor == "/" { return true }
        if path == ancestor { return true }
        return path.hasPrefix(ancestor + "/")
    }
}
