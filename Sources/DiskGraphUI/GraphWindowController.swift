import AppKit
import DiskGraphCore
import DiskGraphLayout
import DiskGraphRender

/// The scan window: a unified toolbar over an edge-to-edge graph, with an optional list
/// panel beside it.
///
/// The toolbar reproduces the reference screenshot — a back/forward chevron pair, a
/// rounded pill naming the current directory whose menu lists its ancestors, and a wide
/// trailing search field.
public final class GraphWindowController: NSWindowController {
    private unowned let graphDocument: GraphDocument

    private var graphView: GraphView?
    private let containerView = NSView()
    private let scanOverlay = ScanOverlayView()
    private var outlinePanel: OutlinePanelController?
    private var splitView: NSSplitView?

    private var navigationControl: NSSegmentedControl?
    private var pathButton: NSPopUpButton?
    private var searchField: NSSearchField?

    /// Visited roots. `historyIndex` points at the current one, so Previous/Next behave
    /// like a browser rather than a stack.
    private var history: [NodeID] = [0]
    private var historyIndex = 0

    private var tree: FileTree? { graphDocument.state.tree }

    public init(document: GraphDocument) {
        graphDocument = document

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 680),
            // No .fullSizeContentView: the reference app centres its disc in the area
            // *below* the toolbar, which measuring its window confirms.
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 420, height: 360)
        // Same autosave name the reference app uses, so the two open at the same size
        // when comparing them side by side.
        window.setFrameAutosaveName("graphWindow")
        // A scan is a live measurement of the disk, not a document to restore. Bringing
        // one back on launch would only show stale numbers, so opt out.
        window.isRestorable = false
        super.init(window: window)

        window.delegate = self
        buildContent()
        buildToolbar()

        document.stateDidChange = { [weak self] state in self?.stateChanged(state) }
        document.optionsDidChange = { [weak self] options in self?.optionsChanged(options) }
        stateChanged(document.state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Content

    private func buildContent() {
        guard let window else { return }
        let content = NSView()

        let graph = GraphView(frame: .zero, options: graphDocument.options)
        graph?.delegate = self
        graphView = graph

        // The graph fills the whole content area. The reference app has no bottom bar —
        // Graph Type, Size Mode and Color Mode live only in the View menu — so neither
        // does this, which also keeps the disc centred in the window the way it is there.
        content.fill(with: containerView)

        if let graph {
            containerView.fill(with: graph)
        } else {
            containerView.fill(with: MetalUnavailableView())
        }
        containerView.fill(with: scanOverlay)
        window.contentView = content
    }

    // MARK: - State

    private func stateChanged(_ state: GraphDocument.State) {
        switch state {
        case .idle:
            scanOverlay.show(.idle)
        case let .scanning(progress):
            scanOverlay.show(.scanning(progress))
        case let .loaded(tree):
            scanOverlay.show(.hidden)
            history = [0]
            historyIndex = 0
            graphView?.show(tree: tree, root: 0)
            outlinePanel?.show(tree: tree, root: 0)
            updateChrome()
        case let .failed(error):
            scanOverlay.show(.failed(error))
        }
        updateChrome()
    }

    private func optionsChanged(_ options: GraphOptions) {
        graphView?.options = options
        outlinePanel?.sizeMode = options.sizeMode
        updateChrome()
    }

    private func updateChrome() {
        guard let tree else {
            window?.title = graphDocument.displayName ?? "DiskGraph"
            navigationControl?.setEnabled(false, forSegment: 0)
            navigationControl?.setEnabled(false, forSegment: 1)
            return
        }
        let root = graphView?.root ?? 0
        window?.title = tree.name(of: root)
        rebuildPathMenu(for: root, tree: tree)

        navigationControl?.setEnabled(historyIndex > 0, forSegment: 0)
        navigationControl?.setEnabled(historyIndex + 1 < history.count, forSegment: 1)
    }

    private func rebuildPathMenu(for root: NodeID, tree: FileTree) {
        guard let pathButton else { return }
        let menu = NSMenu()
        // Deepest first, the way the Finder's proxy-icon menu reads.
        for node in tree.ancestry(of: root).reversed() {
            let item = NSMenuItem(
                title: tree.name(of: node), action: #selector(pathComponentSelected(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = node
            item.image = NSWorkspace.shared.icon(forFile: tree.path(of: node))
            item.image?.size = NSSize(width: 14, height: 14)
            menu.addItem(item)
        }
        pathButton.menu = menu
        pathButton.selectItem(at: 0)
    }

    @objc private func pathComponentSelected(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? NodeID else { return }
        navigate(to: node)
    }

    // MARK: - Navigation

    public func navigate(to node: NodeID) {
        guard node != graphView?.root else { return }
        history.removeSubrange((historyIndex + 1)...)
        history.append(node)
        historyIndex = history.count - 1
        graphView?.navigate(to: node)
        outlinePanel?.setRoot(node)
        updateChrome()
    }

    @objc public func goBack(_ sender: Any?) {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        graphView?.navigate(to: history[historyIndex])
        outlinePanel?.setRoot(history[historyIndex])
        updateChrome()
    }

    @objc public func goForward(_ sender: Any?) {
        guard historyIndex + 1 < history.count else { return }
        historyIndex += 1
        graphView?.navigate(to: history[historyIndex])
        outlinePanel?.setRoot(history[historyIndex])
        updateChrome()
    }

    @objc public func goToEnclosingFolder(_ sender: Any?) {
        guard let tree, let root = graphView?.root, root != 0 else { return }
        navigate(to: tree.parent[Int(root)])
    }

    @objc private func navigationChanged(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? goBack(sender) : goForward(sender)
    }

    // MARK: - Actions

    @objc public func rescan(_ sender: Any?) {
        graphDocument.startScan()
    }

    @objc public func toggleOutline(_ sender: Any?) {
        if outlinePanel != nil {
            removeOutlinePanel()
        } else {
            addOutlinePanel()
        }
    }

    public var isOutlineVisible: Bool { outlinePanel != nil }

    private func addOutlinePanel() {
        guard let tree, let graphView else { return }
        let panel = OutlinePanelController()
        panel.sizeMode = graphDocument.options.sizeMode
        panel.onSelect = { [weak self] node in self?.graphView?.highlight(node: node) }
        panel.onActivate = { [weak self] node in self?.navigate(to: node) }
        panel.show(tree: tree, root: graphView.root)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin

        graphView.removeFromSuperview()
        scanOverlay.removeFromSuperview()
        // The split view manages its arranged subviews' frames itself.
        graphView.translatesAutoresizingMaskIntoConstraints = true
        split.addArrangedSubview(graphView)
        split.addArrangedSubview(panel.view)

        containerView.fill(with: split)
        // Keep the overlay above the split so a rescan still covers the whole area.
        containerView.fill(with: scanOverlay)
        containerView.layoutSubtreeIfNeeded()
        split.setPosition(containerView.bounds.width - 280, ofDividerAt: 0)

        splitView = split
        outlinePanel = panel
    }

    private func removeOutlinePanel() {
        guard let splitView, let graphView else { return }
        graphView.removeFromSuperview()
        splitView.removeFromSuperview()
        scanOverlay.removeFromSuperview()

        containerView.fill(with: graphView)
        containerView.fill(with: scanOverlay)

        self.splitView = nil
        outlinePanel = nil
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        graphView?.searchQuery = sender.stringValue
    }

    /// The node menu commands act on, preferring an explicit selection.
    public var actionTarget: NodeID? {
        graphView?.selectedNode ?? graphView?.hoveredNode
    }

    public var actionTargetIsPackage: Bool {
        guard let tree, let node = actionTarget else { return false }
        return tree.nodeFlags(node).contains(.package)
    }

    public var currentTree: FileTree? { tree }
    public var currentGraphView: GraphView? { graphView }
}

// MARK: - Toolbar

private extension NSToolbarItem.Identifier {
    static let navigation = NSToolbarItem.Identifier("navigation")
    static let path = NSToolbarItem.Identifier("path")
    static let search = NSToolbarItem.Identifier("search")
}

extension GraphWindowController: NSToolbarDelegate {
    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "graphToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.navigation, .path, .flexibleSpace, .search]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.navigation, .path, .flexibleSpace, .space, .search]
    }

    public func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .navigation:
            let control = NSSegmentedControl(
                images: [
                    NSImage(systemSymbolName: "chevron.left", accessibilityDescription: Strings.navigationPrevious)!,
                    NSImage(systemSymbolName: "chevron.right", accessibilityDescription: Strings.navigationNext)!,
                ],
                trackingMode: .momentary,
                target: self,
                action: #selector(navigationChanged(_:)))
            control.segmentStyle = .separated
            control.setEnabled(false, forSegment: 0)
            control.setEnabled(false, forSegment: 1)
            navigationControl = control

            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = control
            item.label = Strings.navigationPrevious
            item.isNavigational = true
            return item

        case .path:
            let button = NSPopUpButton(frame: .zero, pullsDown: false)
            button.bezelStyle = .toolbar
            button.imagePosition = .imageLeading
            pathButton = button

            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = button
            item.label = ""
            return item

        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField.sendsWholeSearchString = false
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.preferredWidthForSearchField = 380
            searchField = item.searchField
            return item

        default:
            return nil
        }
    }
}

// MARK: - Window delegate

extension GraphWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        graphDocument.cancelScan()
    }
}

// MARK: - Graph delegate

extension GraphWindowController: GraphViewDelegate {
    public func graphView(_ view: GraphView, didActivate node: NodeID) {
        navigate(to: node)
    }

    public func graphView(_ view: GraphView, didHover node: NodeID?) {
        // The centre label already tracks the hover; keep the status bar on the root.
    }

    public func graphView(_ view: GraphView, didSelect node: NodeID?) {
        guard let node else { return }
        outlinePanel?.select(node: node)
    }

    public func graphView(_ view: GraphView, menuFor node: NodeID) -> NSMenu? {
        guard let tree else { return nil }
        return FileActions.contextMenu(for: node, tree: tree, target: self)
    }
}

extension NSView {
    /// Adds `child` on top and pins it to every edge.
    func fill(with child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: topAnchor),
            child.leadingAnchor.constraint(equalTo: leadingAnchor),
            child.trailingAnchor.constraint(equalTo: trailingAnchor),
            child.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

/// Shown instead of the graph if the machine has no Metal device at all.
private final class MetalUnavailableView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        let text = NSAttributedString(
            string: "This Mac does not support Metal, which DiskGraph needs to draw the graph.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        let size = text.size()
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
