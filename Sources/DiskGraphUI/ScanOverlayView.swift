import AppKit
import DiskGraphCore

/// Covers the graph while a scan runs, and reports failures.
final class ScanOverlayView: NSView {
    enum Mode {
        case hidden
        case idle
        case scanning(ScanProgress)
        case failed(Error)
    }

    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.933, alpha: 1).cgColor

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true

        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.alignment = .center
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.cell?.usesSingleLineMode = true

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(detailLabel)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ mode: Mode) {
        switch mode {
        case .hidden:
            isHidden = true
            spinner.stopAnimation(nil)

        case .idle:
            isHidden = false
            spinner.isHidden = false
            spinner.startAnimation(nil)
            titleLabel.stringValue = "Preparing…"
            detailLabel.stringValue = ""

        case let .scanning(progress):
            isHidden = false
            spinner.isHidden = false
            spinner.startAnimation(nil)
            titleLabel.stringValue = "Scanning… \(progress.nodesScanned) items"
            detailLabel.stringValue = progress.currentPath

        case let .failed(error):
            isHidden = false
            spinner.isHidden = true
            spinner.stopAnimation(nil)
            titleLabel.stringValue = "Could not scan this folder"
            detailLabel.stringValue = error.localizedDescription
        }
    }
}
