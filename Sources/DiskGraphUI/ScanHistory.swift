import DiskGraphCore
import Foundation

/// Remembers what each folder came to last time, so the next scan of it can show a
/// trustworthy percentage.
///
/// Progress needs a denominator and a tree has none until it has been walked. The volume's
/// used bytes is a serviceable fallback but overshoots badly for anything smaller than the
/// whole volume; a remembered total is right to within whatever changed since.
enum ScanHistory {
    private static let key = "ScanTotalsByPath"
    /// Enough for plenty of folders without letting the defaults file grow unbounded.
    private static let limit = 64

    static func expectedBytes(for path: String) -> Int64? {
        if let remembered = totals()[path], remembered > 0 { return remembered }
        return VolumeMap.usedBytes(ofVolumeContaining: path)
    }

    static func record(path: String, allocatedBytes: Int64) {
        guard allocatedBytes > 0 else { return }
        var stored = totals()
        stored[path] = allocatedBytes
        if stored.count > limit {
            // Drop the smallest entries first: big folders are the slow ones, and the only
            // ones whose progress bar anybody actually watches.
            let smallestFirst = stored.sorted(by: { $0.value < $1.value })
            for entry in smallestFirst.prefix(stored.count - limit) {
                stored.removeValue(forKey: entry.key)
            }
        }
        UserDefaults.standard.set(stored, forKey: key)
    }

    private static func totals() -> [String: Int64] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: NSNumber])?
            .mapValues { $0.int64Value } ?? [:]
    }
}
