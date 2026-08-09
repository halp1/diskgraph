import AppKit
import DiskGraphCore

/// View ▸ Show List. A sortable outline of the current subtree beside the graph.
///
/// Backed by the same `FileTree` as the graph, so it costs no extra memory — rows are
/// node ids and children are read straight out of the tree's contiguous child ranges.
final class OutlinePanelController: NSViewController {
    var onSelect: ((NodeID) -> Void)?
    var onActivate: ((NodeID) -> Void)?

    var sizeMode: SizeMode = .allocated {
        didSet { if sizeMode != oldValue { outlineView.reloadData() } }
    }

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private var tree: FileTree?
    private var root: NodeID = 0
    /// Cached so the outline does not re-sort a directory on every row it draws.
    private var sortedChildrenCache: [NodeID: [NodeID]] = [:]

    override func loadView() {
        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.title = Strings.fileName
        nameColumn.width = 170
        nameColumn.minWidth = 100

        let sizeColumn = NSTableColumn(identifier: .init("size"))
        sizeColumn.title = Strings.fileSize
        sizeColumn.width = 90
        sizeColumn.minWidth = 60

        outlineView.addTableColumn(nameColumn)
        outlineView.addTableColumn(sizeColumn)
        outlineView.outlineTableColumn = nameColumn
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.rowSizeStyle = .small
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.headerView = NSTableHeaderView()
        outlineView.target = self
        outlineView.doubleAction = #selector(rowDoubleClicked)
        outlineView.style = .inset

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        view = scrollView
        view.setFrameSize(NSSize(width: 280, height: 400))
    }

    func show(tree: FileTree, root: NodeID) {
        self.tree = tree
        self.root = root
        sortedChildrenCache.removeAll()
        outlineView.reloadData()
    }

    func setRoot(_ node: NodeID) {
        root = node
        outlineView.reloadData()
    }

    func select(node: NodeID) {
        guard let tree else { return }
        // Expand the chain down to the node before trying to select its row.
        for ancestor in tree.ancestry(of: node) where ancestor != node {
            outlineView.expandItem(NSNumber(value: ancestor))
        }
        let row = outlineView.row(forItem: NSNumber(value: node))
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    private func children(of node: NodeID) -> [NodeID] {
        if let cached = sortedChildrenCache[node] { return cached }
        guard let tree else { return [] }
        let sorted = tree.sortedChildren(of: node, mode: sizeMode)
        sortedChildrenCache[node] = sorted
        return sorted
    }

    private func node(from item: Any?) -> NodeID {
        (item as? NSNumber).map { NodeID($0.int32Value) } ?? root
    }

    @objc private func rowDoubleClicked() {
        guard let tree else { return }
        let node = self.node(from: outlineView.item(atRow: outlineView.clickedRow))
        if tree.isDirectory(node) { onActivate?(node) }
    }
}

extension OutlinePanelController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: node(from: item)).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        NSNumber(value: children(of: node(from: item))[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let tree else { return false }
        return tree.isDirectory(node(from: item)) && tree.childCount[Int(node(from: item))] > 0
    }
}

extension OutlinePanelController: NSOutlineViewDelegate {
    func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        guard let tree, let tableColumn else { return nil }
        let node = self.node(from: item)
        let identifier = tableColumn.identifier

        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier)

        if identifier.rawValue == "name" {
            cell.textField?.stringValue = tree.name(of: node)
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: tree.path(of: node))
            cell.imageView?.isHidden = false
        } else {
            cell.textField?.stringValue = SizeFormatter.byteString(tree.size(of: node, mode: sizeMode))
            cell.textField?.alignment = .right
            cell.imageView?.isHidden = true
        }
        return cell
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let textField = NSTextField(labelWithString: "")
        textField.font = .systemFont(ofSize: 11)
        textField.lineBreakMode = .byTruncatingMiddle
        textField.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 14),
            imageView.heightAnchor.constraint(equalToConstant: 14),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) else { return }
        onSelect?(node(from: item))
    }
}
