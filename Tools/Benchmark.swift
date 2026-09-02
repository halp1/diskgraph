// Serial scan benchmark. Build against the release objects:
//
//   swift build -c release
//   B=.build/release
//   swiftc -O -I $B/Modules $B/DiskGraphCore.build/*.o Tools/Benchmark.swift -o bench
//   ./bench ~/Library            # sweep thread counts
//   ./bench ~/Library 8          # one configuration
//
// Two things this is careful about, because scan benchmarks are easy to fake:
//
//  * It warms the metadata cache first. A cold first scan and a warm second scan differ by
//    several times, so an unwarmed "before and after" measures the cache, not the code.
//  * It reports the tree's totals alongside the timing. A faster scan that changes the
//    numbers is not a faster scan, and the totals are the cheapest way to catch that.
//
// Numbers are only comparable when nothing else is running. Anything measured while other
// work is on the machine is contention, not a result.

import DiskGraphCore
import Foundation

let arguments = CommandLine.arguments
let target = arguments.count > 1
    ? (arguments[1] as NSString).expandingTildeInPath
    : NSHomeDirectory() + "/Library"
let fixedThreadCount = arguments.count > 2 ? Int(arguments[2]) : nil
let repetitions = 3

func scan(threads: Int) throws -> (seconds: Double, tree: FileTree) {
    var options = ScanOptions()
    options.threadCount = threads
    var best = Double.infinity
    var result: FileTree?
    for _ in 0 ..< repetitions {
        let start = DispatchTime.now().uptimeNanoseconds
        let tree = try DirectoryScanner().scan(rootPath: target, options: options)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        best = min(best, elapsed)
        result = tree
    }
    return (best, result!)
}

// Warm the directory-metadata cache so the first measured run is not the outlier.
var warmUp = ScanOptions()
warmUp.threadCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
let warmed = try DirectoryScanner().scan(rootPath: target, options: warmUp)

var directories = 0
for index in warmed.indices where warmed.isDirectory(NodeID(index)) { directories += 1 }

print("target      \(target)")
print("nodes       \(warmed.count)  (\(directories) directories)")
print("logical     \(warmed.logicalSize[0])")
print("on disk     \(warmed.allocatedSize[0])")
print("files       \(warmed.fileCount[0])")
print("errors      \(warmed.errors.count)")
print("")
print("threads   best(s)      nodes/s       dirs/s")

let configurations = fixedThreadCount.map { [$0] } ?? [1, 2, 4, 6, 8, 10, 12, 16]
var fastest = (threads: 0, rate: 0.0)
for threads in configurations {
    let (seconds, tree) = try scan(threads: threads)
    let rate = Double(tree.count) / seconds
    if rate > fastest.rate { fastest = (threads, rate) }
    print(String(format: "%7d %8.3f %12.0f %12.0f",
                 threads, seconds, rate, Double(directories) / seconds))

    // A change that speeds the walk up but moves the totals is a regression, not a win.
    guard tree.count == warmed.count,
          tree.logicalSize[0] == warmed.logicalSize[0],
          tree.allocatedSize[0] == warmed.allocatedSize[0]
    else {
        print("  MISMATCH against the warm-up scan — results are not stable across runs")
        print("  nodes \(tree.count) vs \(warmed.count)")
        print("  logical \(tree.logicalSize[0]) vs \(warmed.logicalSize[0])")
        print("  on disk \(tree.allocatedSize[0]) vs \(warmed.allocatedSize[0])")
        exit(1)
    }
}

print("")
print(String(format: "fastest: %d threads, %.0f nodes/s", fastest.threads, fastest.rate))
