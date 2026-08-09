import AppKit
import DiskGraphCore
import Quartz

/// Finder-style operations on a node, plus the context menu that offers them.
public enum FileActions {
    public static func contextMenu(for node: NodeID, tree: FileTree, target: AnyObject) -> NSMenu {
        let menu = NSMenu()
        let isDirectory = tree.isDirectory(node)
        let isPackage = tree.nodeFlags(node).contains(.package)

        func add(_ title: String, _ selector: Selector, key: String = "",
                 modifiers: NSEvent.ModifierFlags = []) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            item.representedObject = node
            menu.addItem(item)
        }

        if isDirectory {
            add(Strings.fileShowInGraph, #selector(FileActionResponder.showInGraph(_:)))
        }
        add(Strings.fileQuickLook, #selector(FileActionResponder.quickLook(_:)))
        add(Strings.fileOpenInFinder, #selector(FileActionResponder.showInFinder(_:)))
        if isPackage {
            add(Strings.fileShowPackageContents,
                #selector(FileActionResponder.showPackageContents(_:)))
        }
        add(Strings.fileSelectEnclosingFolder, #selector(FileActionResponder.selectEnclosingFolder(_:)))
        menu.addItem(.separator())
        add(Strings.editCopy, #selector(FileActionResponder.copyPath(_:)))
        menu.addItem(.separator())
        add(Strings.fileMoveToTrash, #selector(FileActionResponder.moveToTrash(_:)))
        return menu
    }

    public static func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    /// Moves to the Bin and returns the recovery URL, which the undo registration needs
    /// to put the item back.
    @discardableResult
    public static func moveToTrash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    public static func restore(from trashURL: URL, to original: URL) throws {
        try FileManager.default.moveItem(at: trashURL, to: original)
    }
}

/// Selectors the context menu and main menu send. Implemented by the window controller.
@objc public protocol FileActionResponder {
    func showInGraph(_ sender: Any?)
    func showPackageContents(_ sender: Any?)
    func quickLook(_ sender: Any?)
    func showInFinder(_ sender: Any?)
    func selectEnclosingFolder(_ sender: Any?)
    func copyPath(_ sender: Any?)
    func moveToTrash(_ sender: Any?)
}

/// Minimal Quick Look host: one preview panel showing the selected file.
public final class QuickLookPresenter: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    public static let shared = QuickLookPresenter()
    private var url: URL?

    public func present(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as NSURL?
    }
}
