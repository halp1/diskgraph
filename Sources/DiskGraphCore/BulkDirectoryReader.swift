import Foundation

/// One directory entry as returned by `getattrlistbulk`.
///
/// `name` points into the reader's reusable kernel buffer and is only valid for the
/// duration of the enumeration callback.
public struct BulkEntry {
    public var name: UnsafeRawBufferPointer
    public var objectType: UInt32
    public var deviceID: Int32
    public var fileID: UInt64
    public var linkCount: UInt32
    public var logicalSize: Int64
    public var allocatedSize: Int64
    public var creationTime: Int64
    public var modificationTime: Int64
    public var error: UInt32

    public var isDirectory: Bool { objectType == VDIR.rawValue }
    public var isRegularFile: Bool { objectType == VREG.rawValue }
    public var isSymbolicLink: Bool { objectType == VLNK.rawValue }
}

/// Batched directory enumeration via `getattrlistbulk(2)`.
///
/// One syscall returns name, type, sizes, dates and link count for a whole batch of
/// entries, which is roughly an order of magnitude faster than `readdir` plus a `lstat`
/// per entry — the difference between a full-volume scan taking seconds and taking
/// minutes.
///
/// The buffer layout below was verified empirically against `lstat` for every entry of
/// `/etc`, `/usr/bin` and `~/Documents` with zero mismatches. Two things about it are
/// easy to get wrong:
///
/// 1. `ATTR_CMN_ERROR` is written immediately after the returned-attributes header,
///    *before* `ATTR_CMN_NAME`, not in attribute-bit order like everything else.
/// 2. Fields are packed without regard to natural alignment — `ATTR_FILE_TOTALSIZE`
///    lands on a 4-byte boundary — so every read must be unaligned.
///
/// `FSOPT_PACK_INVAL_ATTRS` makes the kernel emit a fixed layout even when the file
/// system cannot supply an attribute, so offsets never shift between entries.
public final class BulkDirectoryReader {
    private let buffer: UnsafeMutableRawBufferPointer
    private var attributes: attrlist

    public init(bufferSize: Int = 512 * 1024) {
        buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: bufferSize, alignment: MemoryLayout<UInt64>.alignment)

        // Split out per term: a single `|` chain of these macros defeats the type checker.
        let returned = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        let error = attrgroup_t(ATTR_CMN_ERROR)
        let name = attrgroup_t(ATTR_CMN_NAME)
        let devID = attrgroup_t(ATTR_CMN_DEVID)
        let objType = attrgroup_t(ATTR_CMN_OBJTYPE)
        let created = attrgroup_t(ATTR_CMN_CRTIME)
        let modified = attrgroup_t(ATTR_CMN_MODTIME)
        let fileID = attrgroup_t(ATTR_CMN_FILEID)
        let links = attrgroup_t(ATTR_FILE_LINKCOUNT)
        let total = attrgroup_t(ATTR_FILE_TOTALSIZE)
        let alloc = attrgroup_t(ATTR_FILE_ALLOCSIZE)

        attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = returned | error | name | devID | objType | created | modified | fileID
        attributes.fileattr = links | total | alloc
    }

    deinit { buffer.deallocate() }

    /// Reads one batch. Returns `false` once the directory is exhausted.
    /// Throws only on a failure of the directory itself, never on a bad entry.
    public func readBatch(fd: Int32, _ body: (BulkEntry) -> Void) throws -> Bool {
        let count = getattrlistbulk(
            fd, &attributes, buffer.baseAddress, buffer.count, UInt64(FSOPT_PACK_INVAL_ATTRS))
        if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if count == 0 { return false }

        let raw = UnsafeRawBufferPointer(buffer)
        var offset = 0
        for _ in 0 ..< Int(count) {
            let entryLength = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            var cursor = offset + MemoryLayout<UInt32>.size

            // ATTR_CMN_RETURNED_ATTRS
            cursor += MemoryLayout<attribute_set_t>.size
            // ATTR_CMN_ERROR — out of bit order, see the note above.
            let error = raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
            cursor += 4
            // ATTR_CMN_NAME, an attrreference_t whose offset is relative to itself.
            let nameOffset = Int(raw.loadUnaligned(fromByteOffset: cursor, as: Int32.self))
            let nameLength = Int(raw.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self))
            let nameStart = cursor + nameOffset
            cursor += MemoryLayout<attrreference_t>.size

            let deviceID = raw.loadUnaligned(fromByteOffset: cursor, as: Int32.self)
            cursor += 4
            let objectType = raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
            cursor += 4
            let created = raw.loadUnaligned(fromByteOffset: cursor, as: Int64.self)
            cursor += MemoryLayout<timespec>.size
            let modified = raw.loadUnaligned(fromByteOffset: cursor, as: Int64.self)
            cursor += MemoryLayout<timespec>.size
            let fileID = raw.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)
            cursor += 8
            let linkCount = raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
            cursor += 4
            let logicalSize = raw.loadUnaligned(fromByteOffset: cursor, as: Int64.self)
            cursor += 8
            let allocatedSize = raw.loadUnaligned(fromByteOffset: cursor, as: Int64.self)

            offset += entryLength

            // The trailing NUL is included in attr_length but is not part of the name.
            let bytes = nameLength > 0
                ? UnsafeRawBufferPointer(start: raw.baseAddress! + nameStart, count: nameLength - 1)
                : UnsafeRawBufferPointer(start: nil, count: 0)

            body(BulkEntry(
                name: bytes,
                objectType: objectType,
                deviceID: deviceID,
                fileID: fileID,
                linkCount: linkCount,
                logicalSize: logicalSize,
                allocatedSize: allocatedSize,
                creationTime: created,
                modificationTime: modified,
                error: error))
        }
        return true
    }
}
