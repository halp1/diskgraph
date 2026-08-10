import AppKit
import DiskGraphCore

/// Covers the graph while a scan runs, and reports failures.
///
/// Two things it deliberately does *not* do: spin indefinitely with a raw item count, and
/// print the directory currently being read. The count means nothing without a total, and
/// the path changes hundreds of times a second, so it reads as flicker rather than
/// information. Instead: a determinate bar with a percentage, and the top-level folder,
/// which changes a handful of times over a whole scan.
final class ScanOverlayView: NSView {
    enum Mode {
        case hidden
        case idle
        case scanning(ScanProgress)
        case failed(Error)
    }

    private let progressBar = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    private static let counts: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        progressBar.style = .bar
        progressBar.isIndeterminate = true
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .regular
        progressBar.translatesAutoresizingMaskIntoConstraints = false

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
        stack.addArrangedSubview(progressBar)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(detailLabel)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
            progressBar.widthAnchor.constraint(equalToConstant: 260),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A CGColor is a fixed value, so a layer background does not follow the appearance the
    /// way an NSColor does. Painting it here keeps it in step — a hardcoded light grey left
    /// white system text on a near-white field in dark mode.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func show(_ mode: Mode) {
        switch mode {
        case .hidden:
            isHidden = true
            progressBar.stopAnimation(nil)

        case .idle:
            isHidden = false
            progressBar.isHidden = false
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
            titleLabel.stringValue = "Preparing…"
            detailLabel.stringValue = ""

        case let .scanning(progress):
            isHidden = false
            progressBar.isHidden = false
            // Only show a number when there is a real denominator behind it.
            let determinate = progress.isEstimateMeaningful
            if progressBar.isIndeterminate != !determinate {
                progressBar.isIndeterminate = !determinate
                if determinate { progressBar.stopAnimation(nil) } else { progressBar.startAnimation(nil) }
            }
            progressBar.doubleValue = progress.fractionComplete

            let percent = Int((progress.fractionComplete * 100).rounded())
            titleLabel.stringValue = determinate ? "Scanning… \(percent)%" : "Scanning…"
            detailLabel.stringValue = Self.detail(for: progress)

        case let .failed(error):
            isHidden = false
            progressBar.isHidden = true
            progressBar.stopAnimation(nil)
            titleLabel.stringValue = "Could not scan this folder"
            detailLabel.stringValue = error.localizedDescription
        }
    }

    /// "Library — 1,204,338 items · 210.4 GB": the folder changes rarely and the numbers
    /// climb steadily, so nothing here flickers.
    private static func detail(for progress: ScanProgress) -> String {
        let items = counts.string(from: NSNumber(value: progress.nodesScanned))
            ?? "\(progress.nodesScanned)"
        var parts = "\(items) items"
        if progress.bytesScanned > 0 {
            parts += " · " + SizeFormatter.byteString(progress.bytesScanned)
        }
        return progress.currentTopLevel.isEmpty ? parts : "\(progress.currentTopLevel) — \(parts)"
    }
}
