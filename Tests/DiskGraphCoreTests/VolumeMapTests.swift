import Foundation
import Testing
@testable import DiskGraphCore

/// On an APFS boot volume group, `/Users`, `/Applications`, `/Library`, `/private` and a
/// dozen more are *firmlinks*: they appear under `/` but live on the Data volume, which is
/// also mounted at `/System/Volumes/Data`. Every one is reachable by two paths and — the
/// part that makes this a real trap — `stat` reports the **same device id** for both, so
/// the usual cross-device check cannot see the difference. A naive walk of `/` counts most
/// of the disk twice.
@Suite struct VolumeMapTests {
    @Test func excludesTheDataVolumeDuplicateWhenScanningTheSystemRoot() {
        let map = VolumeMap(rootPath: "/", scope: .sameDisk)
        #expect(map.excludes("/System/Volumes/Data"))
    }

    @Test func doesNotExcludeTheDataVolumeWhenItIsTheRoot() {
        let map = VolumeMap(rootPath: "/System/Volumes/Data", scope: .sameDisk)
        #expect(!map.excludes("/System/Volumes/Data"))
    }

    /// `/net` and `/home` are autofs triggers that block waiting on a network mount.
    @Test func excludesFileSystemsThatCannotBeScanned() {
        let mounts = VolumeMap.mountedFileSystems()
        let map = VolumeMap(rootPath: "/", scope: .allLocalVolumes)
        for mount in mounts where mount.fileSystemType == "autofs" || mount.fileSystemType == "devfs" {
            #expect(map.excludes(mount.mountPoint), "\(mount.mountPoint) (\(mount.fileSystemType))")
        }
    }

    @Test func sameVolumeScopeStopsAtEveryOtherMountPoint() {
        let map = VolumeMap(rootPath: "/", scope: .sameVolume)
        let mounts = VolumeMap.mountedFileSystems()
        for mount in mounts where mount.mountPoint != "/" {
            #expect(map.excludes(mount.mountPoint), "should stop at \(mount.mountPoint)")
        }
    }

    /// Widening the scope may only ever remove exclusions, never add them.
    @Test func scopesAreNested() {
        let strict = VolumeMap(rootPath: "/", scope: .sameVolume).excludedMountPoints
        let disk = VolumeMap(rootPath: "/", scope: .sameDisk).excludedMountPoints
        let all = VolumeMap(rootPath: "/", scope: .allLocalVolumes).excludedMountPoints
        #expect(disk.isSubset(of: strict))
        #expect(all.isSubset(of: disk))
    }

    @Test func extractsThePhysicalDiskFromADeviceNode() {
        #expect(VolumeMap.physicalDisk(of: "/dev/disk3s1s1") == "disk3")
        #expect(VolumeMap.physicalDisk(of: "/dev/disk3s5") == "disk3")
        #expect(VolumeMap.physicalDisk(of: "/dev/disk12s1") == "disk12")
        #expect(VolumeMap.physicalDisk(of: "map auto_home") == nil)
        #expect(VolumeMap.physicalDisk(of: "devfs") == nil)
    }

    /// The boot volume group spreads the System and Data volumes across slices of one
    /// container, so `.sameDisk` has to treat them as the same storage.
    @Test func systemAndDataVolumesShareAPhysicalDisk() throws {
        let mounts = VolumeMap.mountedFileSystems()
        let system = try #require(mounts.first { $0.mountPoint == "/" })
        guard let data = mounts.first(where: { $0.mountPoint == "/System/Volumes/Data" }) else {
            return  // not an APFS volume-group layout
        }
        #expect(system.physicalDisk != nil)
        #expect(system.physicalDisk == data.physicalDisk)
    }

    @Test func recognisesContainmentIncludingTheRootItself() {
        #expect(VolumeMap.path("/Users/x", isAtOrUnder: "/Users"))
        #expect(VolumeMap.path("/Users", isAtOrUnder: "/Users"))
        #expect(VolumeMap.path("/anything", isAtOrUnder: "/"))
        #expect(!VolumeMap.path("/Users2", isAtOrUnder: "/Users"))
        #expect(!VolumeMap.path("/", isAtOrUnder: "/Users"))
    }
}

@Suite struct DirectoryIdentityTests {
    /// Two directory entries reaching the same inode must be walked once. This is the
    /// mechanism that fixes the firmlink double-count, so it is worth pinning directly.
    @Test func aDirectoryIsOnlyClaimedOnce() {
        let state = ScanState(
            options: ScanOptions(), rootDevice: 1,
            volumeMap: VolumeMap(excludedMountPoints: []))

        #expect(state.claimDirectory(device: 1, fileID: 42))
        #expect(!state.claimDirectory(device: 1, fileID: 42))
        // A different volume with a colliding inode number is a different directory.
        #expect(state.claimDirectory(device: 2, fileID: 42))
    }

    /// A symlinked second path to a real directory must not double the total.
    @Test func aSecondPathToTheSameDirectoryAddsNothing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskgraph-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 100_000)
            .write(to: payload.appendingPathComponent("big.bin"))
        // A hard-linked directory is not creatable from user space, so use the closest
        // reachable analogue: a symlink, which must not be followed at all.
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("alias").path,
            withDestinationPath: payload.path)

        let tree = try DirectoryScanner().scan(rootPath: root.path)
        let alias = try #require(tree.children(of: 0).first { tree.name(of: $0) == "alias" })
        #expect(tree.childCount[Int(alias)] == 0)
        // 100 KB once, plus the symlink's own target-path bytes.
        #expect(tree.logicalSize[0] < 110_000)
    }
}
