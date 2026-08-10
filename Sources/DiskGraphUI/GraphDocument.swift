import AppKit
import DiskGraphCore
import DiskGraphLayout

/// A scanned folder. Matching the reference app, a directory *is* the document type, so
/// every scan gets its own window, Open Recent works, and two folders can sit side by
/// side for comparison.
public final class GraphDocument: NSDocument {
    public enum State {
        case idle
        case scanning(ScanProgress)
        case loaded(FileTree)
        case failed(Error)

        public var tree: FileTree? {
            if case let .loaded(tree) = self { return tree }
            return nil
        }
    }

    public private(set) var state: State = .idle {
        didSet { stateDidChange?(state) }
    }

    /// Called on the main queue whenever `state` changes.
    public var stateDidChange: ((State) -> Void)?

    /// Persisted per document so a rescan or a new window keeps the user's choices.
    public var options = GraphOptions() {
        didSet { optionsDidChange?(options) }
    }
    public var optionsDidChange: ((GraphOptions) -> Void)?

    private var cancellation: ScanCancellation?

    // Nothing about a scan is editable, so keep the whole save machinery out of the way.
    public override class var autosavesInPlace: Bool { false }
    public override var isDocumentEdited: Bool { false }
    public override func canAsynchronouslyWrite(
        to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType
    ) -> Bool { false }

    public override func read(from url: URL, ofType typeName: String) throws {
        // The scan itself is far too slow to run inside the open path; record the folder
        // and let the window controller start it once there is something to show progress
        // in.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if !isDirectory.boolValue {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
    }

    public override func makeWindowControllers() {
        let controller = GraphWindowController(document: self)
        addWindowController(controller)
        startScan()
    }

    public override var displayName: String! {
        get { fileURL?.lastPathComponent ?? super.displayName }
        set { super.displayName = newValue }
    }

    // MARK: - Scanning

    public func startScan() {
        guard let url = fileURL else { return }
        cancellation?.cancel()
        let cancellation = ScanCancellation()
        self.cancellation = cancellation

        state = .scanning(ScanProgress())

        // Honour whatever the user set in Settings; these were previously ignored.
        var scanOptions = SettingsWindowController.scanOptions()
        scanOptions.expectedTotalBytes = ScanHistory.expectedBytes(for: url.path)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let tree = try DirectoryScanner().scan(
                    rootPath: url.path,
                    options: scanOptions,
                    cancellation: cancellation
                ) { progress in
                    DispatchQueue.main.async {
                        guard let self, case .scanning = self.state else { return }
                        self.state = .scanning(progress)
                    }
                }
                DispatchQueue.main.async {
                    guard let self, self.cancellation === cancellation else { return }
                    // Sharpen the next scan's progress estimate for this folder.
                    ScanHistory.record(path: url.path, allocatedBytes: tree.allocatedSize[0])
                    self.state = .loaded(tree)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.cancellation === cancellation else { return }
                    if case ScanFailure.cancelled = error { return }
                    self.state = .failed(error)
                }
            }
        }
    }

    public func cancelScan() {
        cancellation?.cancel()
        cancellation = nil
    }

    public override func close() {
        cancelScan()
        super.close()
    }
}
