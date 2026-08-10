import AppKit
import DiskGraphCore

/// A small settings window. The reference app's predicate-based exclude filter is out of
/// scope, so this covers the defaults that apply to new scans plus the Full Disk Access
/// state, which is the thing most likely to make a scan look wrong.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let accessLabel = NSTextField(labelWithString: "")
    private let packagesCheckbox = NSButton(
        checkboxWithTitle: "Look inside packages such as .app bundles", target: nil, action: nil)
    private let hardLinkCheckbox = NSButton(
        checkboxWithTitle: "Count hard-linked files only once", target: nil, action: nil)
    private let scopePopUp = NSPopUpButton(frame: .zero, pullsDown: false)

    static let descendIntoPackagesKey = "DescendIntoPackages"
    static let countHardLinksOnceKey = "CountHardLinksOnce"
    static let volumeScopeKey = "VolumeScope"

    /// Scan options as the user has configured them. Applied to every new scan.
    static func scanOptions() -> ScanOptions {
        registerDefaults()
        let defaults = UserDefaults.standard
        var options = ScanOptions()
        options.descendIntoPackages = defaults.bool(forKey: descendIntoPackagesKey)
        options.countHardLinksOnce = defaults.bool(forKey: countHardLinksOnceKey)
        options.volumeScope = defaults.string(forKey: volumeScopeKey)
            .flatMap(VolumeScope.init(rawValue:)) ?? .sameDisk
        return options
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            descendIntoPackagesKey: true,
            countHardLinksOnceKey: true,
            volumeScopeKey: VolumeScope.sameDisk.rawValue,
        ])
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 210),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.center()
        window.setFrameAutosaveName("settingsWindow")
        super.init(window: window)
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent() {
        Self.registerDefaults()
        let defaults = UserDefaults.standard

        for box in [packagesCheckbox, hardLinkCheckbox] {
            box.target = self
            box.action = #selector(checkboxChanged)
        }
        packagesCheckbox.state = defaults.bool(forKey: Self.descendIntoPackagesKey) ? .on : .off
        hardLinkCheckbox.state = defaults.bool(forKey: Self.countHardLinksOnceKey) ? .on : .off

        for (index, scope) in VolumeScope.allCases.enumerated() {
            scopePopUp.addItem(withTitle: scope.localizedName)
            scopePopUp.item(at: index)?.representedObject = scope
        }
        let current = defaults.string(forKey: Self.volumeScopeKey)
            .flatMap(VolumeScope.init(rawValue:)) ?? .sameDisk
        scopePopUp.selectItem(at: VolumeScope.allCases.firstIndex(of: current) ?? 1)
        scopePopUp.target = self
        scopePopUp.action = #selector(checkboxChanged)
        scopePopUp.controlSize = .small

        accessLabel.font = .systemFont(ofSize: 11)
        let openAccess = NSButton(
            title: "Open Privacy Settings", target: self, action: #selector(openAccessSettings))
        openAccess.bezelStyle = .rounded
        openAccess.controlSize = .small

        let accessRow = NSStackView(views: [accessLabel, openAccess])
        accessRow.orientation = .horizontal
        accessRow.spacing = 8

        let scopeRow = NSStackView(views: [
            NSTextField(labelWithString: "Include:"), scopePopUp,
        ])
        scopeRow.orientation = .horizontal
        scopeRow.spacing = 8

        let stack = NSStackView(views: [
            sectionTitle("Scanning"),
            packagesCheckbox, hardLinkCheckbox, scopeRow,
            NSBox.separator(),
            sectionTitle("Permissions"),
            accessRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),
        ])
        window?.contentView = content
        refreshAccessLabel()
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    override func showWindow(_ sender: Any?) {
        refreshAccessLabel()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    private func refreshAccessLabel() {
        let granted = FullDiskAccess.isGranted
        accessLabel.stringValue = granted
            ? "Full Disk Access is granted."
            : "Full Disk Access is off — some folders will be missing from scans."
        accessLabel.textColor = granted ? .secondaryLabelColor : .systemOrange
    }

    @objc private func checkboxChanged() {
        let defaults = UserDefaults.standard
        defaults.set(packagesCheckbox.state == .on, forKey: Self.descendIntoPackagesKey)
        defaults.set(hardLinkCheckbox.state == .on, forKey: Self.countHardLinksOnceKey)
        if let scope = scopePopUp.selectedItem?.representedObject as? VolumeScope {
            defaults.set(scope.rawValue, forKey: Self.volumeScopeKey)
        }
    }

    @objc private func openAccessSettings() {
        FullDiskAccess.openSettings()
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
