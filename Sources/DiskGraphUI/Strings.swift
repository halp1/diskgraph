import Foundation

/// UI wording, keyed the same way the reference app keys its `Localizable.strings`.
///
/// Keeping the keys means a future localisation drops straight in; keeping the exact
/// English wording is what makes the menus read like the original.
public enum Strings {
    // Menus
    public static let menuFile = "File"
    public static let menuEdit = "Edit"
    public static let menuView = "View"
    public static let menuWindow = "Window"
    public static let menuHelp = "Help"

    public static let appAbout = "About DiskGraph"
    public static let appHideSelf = "Hide DiskGraph"
    public static let appHideOthers = "Hide Others"
    public static let appShowAll = "Show All"
    public static let appServices = "Services"
    public static let appQuit = "Quit DiskGraph"
    public static let appSettings = "Settings…"

    public static let fileOpen = "Open…"
    public static let fileOpenRecent = "Open Recent"
    public static let fileClose = "Close"
    public static let fileRescan = "Rescan"
    public static let fileShowDetails = "Show Details"
    public static let filePreview = "Preview"
    public static let fileQuickLook = "Quick Look"
    public static let fileOpenInFinder = "Show in Finder"
    public static let fileShowPackageContents = "Show Package Contents"
    public static let fileShowInGraph = "Show in Graph"
    public static let fileSelectEnclosingFolder = "Enclosing Folder"
    public static let fileMoveToTrash = "Move to Bin"
    public static let fileDelete = "Delete"

    public static let editUndo = "Undo"
    public static let editRedo = "Redo"
    public static let editCut = "Cut"
    public static let editCopy = "Copy"
    public static let editPaste = "Paste"
    public static let editSelectAll = "Select All"
    public static let editFind = "Find"
    /// "menu.edit.undo.move" = "Move of %@"
    public static func undoMove(_ name: String) -> String { "Move of \(name)" }

    public static let viewGraphType = "Graph Type"
    public static let viewTreeMapLayout = "Layout"
    public static let viewSizeMode = "Size Mode"
    public static let viewColorMode = "Color Mode"
    public static let viewGraphOptions = "Graph Options"
    public static let viewShowOutline = "Show List"
    public static let viewGraphLevels = "Graph Levels"
    public static let viewMergeThreshold = "Merge Threshold"
    public static let viewDirectoryBorder = "Directory Border"
    public static let viewAnimationSpeed = "Animation Speed"
    public static let viewKeepAspectRatioDuringZoom = "Keep Aspect Ratio During Zoom"
    public static let viewBeginLayoutOnBottomEdge = "Begin Layout On Bottom Edge"
    public static let viewShowAvailableSpace = "Show Available Space"

    public static let windowMinimize = "Minimize"
    public static let windowZoom = "Zoom"
    public static let windowBringAllToFront = "Bring All to Front"

    public static let navigationPrevious = "Previous"
    public static let navigationNext = "Next"

    public static let buttonOpen = "Open"
    public static let buttonCancel = "Cancel"
    public static let buttonContinue = "Continue"
    public static let buttonDone = "Done"
    public static let buttonReset = "Reset"
    public static let buttonIncrease = "Increase"
    public static let buttonDecrease = "Decrease"

    /// "search.results" = "Search results in %@:"
    public static func searchResults(in name: String) -> String { "Search results in \(name):" }
    public static let searchResultsEmpty = "No Results"

    public static let fileName = "Name"
    public static let fileSize = "Size"
    public static let fileSizeAllocated = "Size on Disk"
    public static let fileChildCount = "Child Count"
    public static let fileCreationDate = "Date Created"
    public static let fileModificationDate = "Date Modified"

    /// Sections merged because they are too small to draw individually.
    public static let mergedSections = "Smaller items"

    public static func scanError(_ path: String) -> String { "Error scanning \(path)" }
}
