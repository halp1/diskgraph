import AppKit
import DiskGraphCore

/// Finder operations sent from the context menu and the File menu.
///
/// Moving to the Bin is registered with the window's undo manager so ⌘Z puts the item
/// back, matching the reference app's "Move of %@" undo title.
extension GraphWindowController: FileActionResponder {
    /// The node a command applies to: an explicit menu item's node, else the selection.
    private func targetNode(_ sender: Any?) -> NodeID? {
        if let item = sender as? NSMenuItem, let node = item.representedObject as? NodeID {
            return node
        }
        return actionTarget
    }

    private func targetURL(_ sender: Any?) -> (node: NodeID, url: URL, tree: FileTree)? {
        guard let tree = currentTree, let node = targetNode(sender) else { return nil }
        return (node, tree.url(of: node), tree)
    }

    public func showInGraph(_ sender: Any?) {
        guard let (node, _, tree) = targetURL(sender), tree.isDirectory(node) else { return }
        navigate(to: node)
    }

    /// Re-roots the graph on the package, which is how its contents become visible while
    /// packages stay atomic everywhere else.
    public func showPackageContents(_ sender: Any?) {
        guard let (node, _, tree) = targetURL(sender), tree.isDirectory(node) else { return }
        navigate(to: node)
    }

    public func quickLook(_ sender: Any?) {
        guard let (_, url, _) = targetURL(sender) else { return }
        QuickLookPresenter.shared.present(url)
    }

    public func showInFinder(_ sender: Any?) {
        guard let (_, url, _) = targetURL(sender) else { return }
        FileActions.showInFinder(url)
    }

    public func selectEnclosingFolder(_ sender: Any?) {
        guard let (node, _, tree) = targetURL(sender), node != 0 else { return }
        navigate(to: tree.parent[Int(node)])
    }

    public func copyPath(_ sender: Any?) {
        guard let (_, url, _) = targetURL(sender) else { return }
        FileActions.copyPath(url.path)
    }

    public func moveToTrash(_ sender: Any?) {
        guard let (node, url, tree) = targetURL(sender) else { return }
        let name = tree.name(of: node)

        do {
            let recovered = try FileActions.moveToTrash(url)
            registerUndoForMove(of: name, from: recovered, to: url)
            // The tree no longer matches the disk; a rescan is the honest way to show it.
            rescan(nil)
        } catch {
            presentTrashFailure(error, name: name)
        }
    }

    private func registerUndoForMove(of name: String, from trashURL: URL?, to original: URL) {
        guard let trashURL, let undoManager = window?.undoManager else { return }
        undoManager.setActionName(Strings.undoMove(name))
        undoManager.registerUndo(withTarget: self) { controller in
            do {
                try FileActions.restore(from: trashURL, to: original)
                controller.rescan(nil)
            } catch {
                controller.presentTrashFailure(error, name: name)
            }
        }
    }

    private func presentTrashFailure(_ error: Error, name: String) {
        let alert = NSAlert(error: error)
        alert.messageText = "Could not move “\(name)”"
        alert.informativeText = error.localizedDescription
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
