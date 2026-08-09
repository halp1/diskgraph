import AppKit
import DiskGraphCore
import DiskGraphLayout

/// Builds the menu bar in code, mirroring the reference app's menu structure and
/// wording. Everything in View ▸ Graph Options maps onto a `GraphOptions` field.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(applicationMenu())
        main.addItem(fileMenu())
        main.addItem(editMenu())
        main.addItem(viewMenu())
        main.addItem(windowMenu())
        main.addItem(helpMenu())
        return main
    }

    private static func submenu(_ title: String, into parent: NSMenu? = nil) -> (NSMenuItem, NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        parent?.addItem(item)
        return (item, menu)
    }

    @discardableResult
    private static func add(
        _ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
        modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil,
        tag: Int = 0, representedObject: Any? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        item.tag = tag
        item.representedObject = representedObject
        menu.addItem(item)
        return item
    }

    // MARK: - Menus

    private static func applicationMenu() -> NSMenuItem {
        let (item, menu) = submenu("DiskGraph")
        add(menu, Strings.appAbout, #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        menu.addItem(.separator())
        add(menu, Strings.appSettings, #selector(AppDelegate.showSettings(_:)), ",")
        menu.addItem(.separator())

        let services = NSMenuItem(title: Strings.appServices, action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())

        add(menu, Strings.appHideSelf, #selector(NSApplication.hide(_:)), "h")
        add(menu, Strings.appHideOthers, #selector(NSApplication.hideOtherApplications(_:)), "h",
            modifiers: [.command, .option])
        add(menu, Strings.appShowAll, #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        add(menu, Strings.appQuit, #selector(NSApplication.terminate(_:)), "q")
        return item
    }

    private static func fileMenu() -> NSMenuItem {
        let (item, menu) = submenu(Strings.menuFile)
        add(menu, Strings.fileOpen, #selector(NSDocumentController.openDocument(_:)), "o")

        let recent = NSMenuItem(title: Strings.fileOpenRecent, action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Recent")
        // AppKit populates any menu carrying this identifier.
        recentMenu.identifier = NSUserInterfaceItemIdentifier("NSRecentDocumentsMenu")
        recent.submenu = recentMenu
        menu.addItem(recent)

        menu.addItem(.separator())
        add(menu, Strings.fileRescan, #selector(GraphWindowController.rescan(_:)), "r",
            modifiers: [.command, .shift])
        add(menu, Strings.fileClose, #selector(NSWindow.performClose(_:)), "w")
        menu.addItem(.separator())
        add(menu, Strings.fileQuickLook, #selector(FileActionResponder.quickLook(_:)), " ",
            modifiers: [])
        add(menu, Strings.fileOpenInFinder, #selector(FileActionResponder.showInFinder(_:)), "r")
        add(menu, Strings.fileShowPackageContents,
            #selector(FileActionResponder.showPackageContents(_:)))
        add(menu, Strings.fileSelectEnclosingFolder,
            #selector(GraphWindowController.goToEnclosingFolder(_:)), "\u{1b}", modifiers: [.command])
        menu.addItem(.separator())
        add(menu, Strings.fileMoveToTrash, #selector(FileActionResponder.moveToTrash(_:)),
            "\u{8}", modifiers: .command)
        return item
    }

    private static func editMenu() -> NSMenuItem {
        let (item, menu) = submenu(Strings.menuEdit)
        add(menu, Strings.editUndo, Selector(("undo:")), "z")
        add(menu, Strings.editRedo, Selector(("redo:")), "z", modifiers: [.command, .shift])
        menu.addItem(.separator())
        add(menu, Strings.editCut, #selector(NSText.cut(_:)), "x")
        add(menu, Strings.editCopy, #selector(FileActionResponder.copyPath(_:)), "c")
        add(menu, Strings.editPaste, #selector(NSText.paste(_:)), "v")
        add(menu, Strings.editSelectAll, #selector(NSText.selectAll(_:)), "a")
        menu.addItem(.separator())
        add(menu, Strings.editFind, #selector(AppDelegate.focusSearch(_:)), "f")
        return item
    }

    /// Mirrors the reference app's View menu, which was read out of the running app:
    /// Graph Type, Size Mode and Color Mode are inline **section headers** with flat items
    /// beneath them, and only Graph Options is a real submenu.
    private static func viewMenu() -> NSMenuItem {
        let (item, menu) = submenu(Strings.menuView)

        add(menu, Strings.viewShowOutline, #selector(GraphWindowController.toggleOutline(_:)), "l")
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: Strings.viewGraphType))
        for (index, type) in GraphType.allCases.enumerated() {
            add(menu, type.localizedName, #selector(AppDelegate.setGraphType(_:)),
                "\(index + 1)", representedObject: type)
        }

        let (graphOptionsItem, graphOptions) = submenu(Strings.viewGraphOptions, into: menu)
        graphOptionsItem.tag = graphOptionsTag
        buildGraphOptions(graphOptions, graphType: .pieChart)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: Strings.viewSizeMode))
        for mode in SizeMode.allCases {
            add(menu, mode.localizedName, #selector(AppDelegate.setSizeMode(_:)),
                representedObject: mode)
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: Strings.viewColorMode))
        for mode in ColorMode.allCases {
            add(menu, mode.localizedName, #selector(AppDelegate.setColorMode(_:)),
                representedObject: mode)
        }

        menu.addItem(.separator())
        add(menu, Strings.navigationPrevious, #selector(GraphWindowController.goBack(_:)), "[")
        add(menu, Strings.navigationNext, #selector(GraphWindowController.goForward(_:)), "]")
        menu.addItem(.separator())
        add(menu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f",
            modifiers: [.command, .control])
        return item
    }

    static let graphOptionsTag = 9001

    /// Graph Options differs by graph type in the reference app: Graph Levels only appears
    /// for the pie, and Layout / Directory Border / the two tree-map toggles only for the
    /// tree map. Rebuilt whenever the graph type changes.
    static func buildGraphOptions(_ menu: NSMenu, graphType: GraphType) {
        menu.removeAllItems()

        // Decrease/Increase/Reset triplets, exactly as the reference app exposes them.
        func stepper(
            _ title: String, decrease: Selector, increase: Selector, reset: Selector,
            key: String
        ) {
            let (_, submenu) = submenu(title, into: menu)
            add(submenu, Strings.buttonDecrease, decrease, key,
                modifiers: [.command, .option])
            add(submenu, Strings.buttonIncrease, increase, key.uppercased(),
                modifiers: [.command, .option, .shift])
            submenu.addItem(.separator())
            add(submenu, Strings.buttonReset, reset)
        }

        stepper(Strings.viewAnimationSpeed,
                decrease: #selector(AppDelegate.decreaseAnimationSpeed(_:)),
                increase: #selector(AppDelegate.increaseAnimationSpeed(_:)),
                reset: #selector(AppDelegate.resetAnimationSpeed(_:)), key: "a")
        menu.addItem(.separator())
        stepper(Strings.viewMergeThreshold,
                decrease: #selector(AppDelegate.decreaseMergeThreshold(_:)),
                increase: #selector(AppDelegate.increaseMergeThreshold(_:)),
                reset: #selector(AppDelegate.resetMergeThreshold(_:)), key: "m")
        add(menu, Strings.viewShowAvailableSpace,
            #selector(AppDelegate.toggleShowAvailableSpace(_:)))
        menu.addItem(.separator())

        switch graphType {
        case .pieChart:
            stepper(Strings.viewGraphLevels,
                    decrease: #selector(AppDelegate.decreaseGraphLevels(_:)),
                    increase: #selector(AppDelegate.increaseGraphLevels(_:)),
                    reset: #selector(AppDelegate.resetGraphLevels(_:)), key: "g")

        case .treeMap:
            stepper(Strings.viewDirectoryBorder,
                    decrease: #selector(AppDelegate.decreaseDirectoryBorder(_:)),
                    increase: #selector(AppDelegate.increaseDirectoryBorder(_:)),
                    reset: #selector(AppDelegate.resetDirectoryBorder(_:)), key: "b")
            let (_, layouts) = submenu(Strings.viewTreeMapLayout, into: menu)
            for strategy in TreemapStrategy.allCases {
                add(layouts, strategy.localizedName, #selector(AppDelegate.setTreemapLayout(_:)),
                    representedObject: strategy)
            }
            add(menu, Strings.viewKeepAspectRatioDuringZoom,
                #selector(AppDelegate.toggleKeepAspectRatio(_:)))
            add(menu, Strings.viewBeginLayoutOnBottomEdge,
                #selector(AppDelegate.toggleBeginLayoutOnBottomEdge(_:)))
        }
    }

    private static func windowMenu() -> NSMenuItem {
        let (item, menu) = submenu(Strings.menuWindow)
        add(menu, Strings.windowMinimize, #selector(NSWindow.performMiniaturize(_:)), "m")
        add(menu, Strings.windowZoom, #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        add(menu, Strings.windowBringAllToFront, #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = menu
        return item
    }

    private static func helpMenu() -> NSMenuItem {
        let (item, menu) = submenu(Strings.menuHelp)
        add(menu, "DiskGraph Help", #selector(NSApplication.showHelp(_:)), "?")
        NSApp.helpMenu = menu
        return item
    }
}
