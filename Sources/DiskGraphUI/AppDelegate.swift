import AppKit
import DiskGraphCore
import DiskGraphLayout
import UniformTypeIdentifiers

/// Opens folders rather than files. `public.directory` is registered as the document
/// type, so the panel has to be told to choose directories.
public final class GraphDocumentController: NSDocumentController {
    public override func runModalOpenPanel(
        _ openPanel: NSOpenPanel, forTypes types: [String]?
    ) -> Int {
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = true
        openPanel.prompt = Strings.buttonOpen
        openPanel.message = "Choose a folder or volume to scan."
        openPanel.treatsFilePackagesAsDirectories = true
        return super.runModalOpenPanel(openPanel, forTypes: types)
    }

    /// Volumes and folders both come through as `public.directory`.
    public override func typeForContents(of url: URL) throws -> String {
        UTType.folder.identifier
    }
}

public final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Retained so the document controller stays the shared one.
    private let documentController = GraphDocumentController()

    public override init() { super.init() }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if FullDiskAccess.shouldPrompt() {
            FullDiskAccess.presentPrompt { [weak self] in self?.openIfNoDocuments() }
        } else {
            openIfNoDocuments()
        }
    }

    /// A document opened from the Finder or the command line arrives *after*
    /// `applicationDidFinishLaunching`, so give it a turn of the run loop before
    /// deciding the user needs the Open panel.
    private func openIfNoDocuments() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.documentController.documents.isEmpty else { return }
            self.documentController.openDocument(nil)
        }
    }

    /// No blank window on launch — a scan needs a folder first.
    public func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Menu plumbing

    private var activeController: GraphWindowController? {
        NSApp.mainWindow?.windowController as? GraphWindowController
            ?? documentController.currentDocument?.windowControllers.first as? GraphWindowController
    }

    private func mutateOptions(_ body: (inout GraphOptions) -> Void) {
        guard let document = activeController?.document as? GraphDocument else { return }
        var options = document.options
        body(&options)
        document.options = options
    }

    @objc public func setGraphType(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? GraphType else { return }
        mutateOptions { $0.graphType = value }
        rebuildGraphOptionsMenu(for: value)
    }

    /// Graph Options is context-dependent in the reference app, so it is rebuilt whenever
    /// the graph type changes.
    private func rebuildGraphOptionsMenu(for graphType: GraphType) {
        guard let view = NSApp.mainMenu?.items
            .first(where: { $0.title == Strings.menuView })?.submenu,
              let options = view.item(withTag: MainMenu.graphOptionsTag)?.submenu
        else { return }
        MainMenu.buildGraphOptions(options, graphType: graphType)
    }

    // MARK: Graph Options steppers

    /// Steps that feel like the reference app's Decrease/Increase: a ring at a time, and
    /// geometric steps for the continuous values.
    @objc public func increaseGraphLevels(_ sender: Any?) {
        mutateOptions { $0.graphLevels = min(24, $0.graphLevels + 1) }
    }
    @objc public func decreaseGraphLevels(_ sender: Any?) {
        mutateOptions { $0.graphLevels = max(1, $0.graphLevels - 1) }
    }
    @objc public func resetGraphLevels(_ sender: Any?) {
        mutateOptions { $0.graphLevels = GraphOptions().graphLevels }
    }

    @objc public func increaseMergeThreshold(_ sender: Any?) {
        mutateOptions { $0.mergeThreshold = min(32, max(0.25, $0.mergeThreshold * 1.5)) }
    }
    @objc public func decreaseMergeThreshold(_ sender: Any?) {
        mutateOptions {
            let next = $0.mergeThreshold / 1.5
            $0.mergeThreshold = next < 0.25 ? 0 : next
        }
    }
    @objc public func resetMergeThreshold(_ sender: Any?) {
        mutateOptions { $0.mergeThreshold = GraphOptions().mergeThreshold }
    }

    @objc public func increaseAnimationSpeed(_ sender: Any?) {
        mutateOptions { $0.animationSpeed = min(4, max(0.25, $0.animationSpeed * 1.5)) }
    }
    @objc public func decreaseAnimationSpeed(_ sender: Any?) {
        mutateOptions {
            let next = $0.animationSpeed / 1.5
            $0.animationSpeed = next < 0.25 ? 0 : next
        }
    }
    @objc public func resetAnimationSpeed(_ sender: Any?) {
        mutateOptions { $0.animationSpeed = GraphOptions().animationSpeed }
    }

    @objc public func increaseDirectoryBorder(_ sender: Any?) {
        mutateOptions { $0.directoryBorderWidth = min(8, $0.directoryBorderWidth + 0.5) }
    }
    @objc public func decreaseDirectoryBorder(_ sender: Any?) {
        mutateOptions { $0.directoryBorderWidth = max(0, $0.directoryBorderWidth - 0.5) }
    }
    @objc public func resetDirectoryBorder(_ sender: Any?) {
        mutateOptions { $0.directoryBorderWidth = GraphOptions().directoryBorderWidth }
    }

    @objc public func toggleShowAvailableSpace(_ sender: Any?) {
        mutateOptions { $0.showAvailableSpace.toggle() }
    }

    @objc public func setTreemapLayout(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? TreemapStrategy else { return }
        mutateOptions { $0.treemapLayout = value }
    }

    @objc public func setSizeMode(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? SizeMode else { return }
        mutateOptions { $0.sizeMode = value }
    }

    @objc public func setColorMode(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? ColorMode else { return }
        mutateOptions { $0.colorMode = value }
    }

    @objc public func toggleBeginLayoutOnBottomEdge(_ sender: NSMenuItem) {
        mutateOptions { $0.beginLayoutOnBottomEdge.toggle() }
    }

    @objc public func toggleKeepAspectRatio(_ sender: NSMenuItem) {
        mutateOptions { $0.keepAspectRatioDuringZoom.toggle() }
    }

    @objc public func focusSearch(_ sender: Any?) {
        activeController?.window?.toolbar?.items
            .compactMap { $0 as? NSSearchToolbarItem }
            .first?
            .beginSearchInteraction()
    }

    @objc public func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(nil)
    }

    // MARK: - Menu state

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let document = activeController?.document as? GraphDocument else {
            return item.action == #selector(NSDocumentController.openDocument(_:))
                || item.action == #selector(NSApplication.terminate(_:))
        }
        let options = document.options

        switch item.action {
        case #selector(setGraphType(_:)):
            item.state = (item.representedObject as? GraphType) == options.graphType ? .on : .off
        case #selector(setTreemapLayout(_:)):
            item.state = (item.representedObject as? TreemapStrategy) == options.treemapLayout ? .on : .off
        case #selector(setSizeMode(_:)):
            item.state = (item.representedObject as? SizeMode) == options.sizeMode ? .on : .off
        case #selector(setColorMode(_:)):
            item.state = (item.representedObject as? ColorMode) == options.colorMode ? .on : .off
        case #selector(toggleShowAvailableSpace(_:)):
            item.state = options.showAvailableSpace ? .on : .off
        case #selector(FileActionResponder.showPackageContents(_:)):
            // Only meaningful on a package that is not already opened up.
            return activeController?.actionTargetIsPackage == true
        case #selector(toggleBeginLayoutOnBottomEdge(_:)):
            item.state = options.beginLayoutOnBottomEdge ? .on : .off
        case #selector(toggleKeepAspectRatio(_:)):
            item.state = options.keepAspectRatioDuringZoom ? .on : .off
        case #selector(GraphWindowController.toggleOutline(_:)):
            item.state = activeController?.isOutlineVisible == true ? .on : .off
        default:
            break
        }
        return true
    }
}
