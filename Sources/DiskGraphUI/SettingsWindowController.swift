import AppKit

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
    private let crossDeviceCheckbox = NSButton(
        checkboxWithTitle: "Follow mount points onto other volumes", target: nil, action: nil)

    static let descendIntoPackagesKey = "DescendIntoPackages"
    static let countHardLinksOnceKey = "CountHardLinksOnce"
    static let crossDeviceBoundariesKey = "CrossDeviceBoundaries"

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
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Self.descendIntoPackagesKey: true,
            Self.countHardLinksOnceKey: true,
            Self.crossDeviceBoundariesKey: false,
        ])

        for box in [packagesCheckbox, hardLinkCheckbox, crossDeviceCheckbox] {
            box.target = self
            box.action = #selector(checkboxChanged)
        }
        packagesCheckbox.state = defaults.bool(forKey: Self.descendIntoPackagesKey) ? .on : .off
        hardLinkCheckbox.state = defaults.bool(forKey: Self.countHardLinksOnceKey) ? .on : .off
        crossDeviceCheckbox.state = defaults.bool(forKey: Self.crossDeviceBoundariesKey) ? .on : .off

        accessLabel.font = .systemFont(ofSize: 11)
        let openAccess = NSButton(
            title: "Open Privacy Settings", target: self, action: #selector(openAccessSettings))
        openAccess.bezelStyle = .rounded
        openAccess.controlSize = .small

        let accessRow = NSStackView(views: [accessLabel, openAccess])
        accessRow.orientation = .horizontal
        accessRow.spacing = 8

        let stack = NSStackView(views: [
            sectionTitle("Scanning"),
            packagesCheckbox, hardLinkCheckbox, crossDeviceCheckbox,
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
        defaults.set(crossDeviceCheckbox.state == .on, forKey: Self.crossDeviceBoundariesKey)
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
