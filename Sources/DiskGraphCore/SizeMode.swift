import Foundation

/// How much space a graph cell is given. Mirrors Disk Graph's View ▸ Size Mode.
public enum SizeMode: String, CaseIterable, Sendable, Codable {
    case logical
    case allocated
    case childCount

    /// Matches the app's `file.size` / `file.sizeAllocated` / `file.childCount` strings.
    public var localizedName: String {
        switch self {
        case .logical: return "Size"
        case .allocated: return "Size on Disk"
        case .childCount: return "Child Count"
        }
    }
}

/// Colour assignment for cells. Mirrors View ▸ Color Mode.
public enum ColorMode: String, CaseIterable, Sendable, Codable {
    case hueWheel
    case creationDate
    case modificationDate

    public var localizedName: String {
        switch self {
        case .hueWheel: return "Hue Wheel"
        case .creationDate: return "Date Created"
        case .modificationDate: return "Date Modified"
        }
    }
}

public enum SizeFormatter {
    /// `ByteCountFormatter` with `.file` reproduces Disk Graph's own output exactly —
    /// "2.42 GB" and "882.3 MB" in the reference screenshots both fall out of it.
    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = .useAll
        return f
    }()

    private static let counts: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    public static func string(_ value: Int64, mode: SizeMode) -> String {
        switch mode {
        case .logical:
            return bytes.string(fromByteCount: value)
        case .allocated:
            // "file.display.allocatedSize" = "%@ on disk"
            return String(format: "%@ on disk", bytes.string(fromByteCount: value))
        case .childCount:
            // "file.display.childCount" = "%lu files"
            let n = counts.string(from: NSNumber(value: value)) ?? "\(value)"
            return "\(n) files"
        }
    }

    /// Plain byte string with no mode suffix, for detail panels and list columns.
    public static func byteString(_ value: Int64) -> String {
        bytes.string(fromByteCount: value)
    }
}
