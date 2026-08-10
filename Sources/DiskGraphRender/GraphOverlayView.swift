import AppKit

/// Text drawn on top of the Metal view: the total in the middle of the graph, and the
/// hover tooltip.
///
/// Native text rendering rather than a glyph atlas — it is a handful of strings per
/// frame, and this way they match the system's font smoothing exactly.
final class GraphOverlayView: NSView {
    struct Tooltip {
        /// Enclosing folders, already relative to the graph root. Drawn dimmed above the
        /// name; middle-truncated, because these chains get very long.
        var path: String
        var name: String
        var detail: String
        var anchor: CGPoint
    }

    var centerText: String = "" { didSet { if centerText != oldValue { needsDisplay = true } } }
    var centerPoint: CGPoint = .zero { didSet { needsDisplay = true } }
    var tooltip: Tooltip? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    /// Purely decorative: every event belongs to the graph view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    private static let centerFont = NSFont.systemFont(ofSize: 22, weight: .bold)
    private static let tooltipNameFont = NSFont.systemFont(ofSize: 11, weight: .bold)
    private static let tooltipDetailFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    private static let tooltipPathFont = NSFont.systemFont(ofSize: 10, weight: .regular)
    /// Wide enough for a useful chain, narrow enough not to cover the graph.
    private static let tooltipMaxWidth: CGFloat = 460

    override func draw(_ dirtyRect: NSRect) {
        drawCenterText()
        if let tooltip { draw(tooltip) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func drawCenterText() {
        guard !centerText.isEmpty else { return }
        // The label lands on top of whatever cells are underneath it in the tree map, so a
        // soft shadow in the opposite direction keeps it readable over any of them.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = .zero
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.centerFont,
            .foregroundColor: NSColor.labelColor,
            .shadow: shadow,
        ]
        let string = NSAttributedString(string: centerText, attributes: attributes)
        let size = string.size()
        string.draw(at: CGPoint(
            x: (centerPoint.x - size.width / 2).rounded(),
            y: (centerPoint.y - size.height / 2).rounded()))
    }

    private func draw(_ tooltip: Tooltip) {
        let text = NSMutableAttributedString(
            string: tooltip.name,
            attributes: [.font: Self.tooltipNameFont, .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(
            string: " - " + tooltip.detail,
            attributes: [.font: Self.tooltipDetailFont, .foregroundColor: NSColor.labelColor]))

        // The path can be arbitrarily deep, so it truncates in the middle — the outermost
        // and innermost folders are the ones that place a file.
        var pathText: NSAttributedString?
        if !tooltip.path.isEmpty {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingMiddle
            pathText = NSAttributedString(string: tooltip.path, attributes: [
                .font: Self.tooltipPathFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style,
            ])
        }

        let padding = CGSize(width: 7, height: 4)
        let spacing: CGFloat = 1
        let textSize = text.size()
        let pathWidth = min(pathText?.size().width ?? 0, Self.tooltipMaxWidth)
        let pathHeight = pathText == nil ? 0 : (pathText!.size().height + spacing)
        let boxSize = CGSize(
            width: (min(max(textSize.width, pathWidth), Self.tooltipMaxWidth)
                + padding.width * 2).rounded(.up),
            height: (textSize.height + pathHeight + padding.height * 2).rounded(.up))

        // Sit just below and right of the cursor, then pull back inside the view.
        var origin = CGPoint(x: tooltip.anchor.x + 12, y: tooltip.anchor.y + 16)
        origin.x = min(max(4, origin.x), bounds.maxX - boxSize.width - 4)
        origin.y = min(max(4, origin.y), bounds.maxY - boxSize.height - 4)
        let box = CGRect(origin: origin, size: boxSize)

        // Dynamic colours, so the chip inverts with the appearance. Fixed greys here meant
        // white label text on a light chip in dark mode.
        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        NSColor.controlBackgroundColor.withAlphaComponent(0.97).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        var cursor = box.minY + padding.height
        if let pathText {
            pathText.draw(with: CGRect(
                x: box.minX + padding.width, y: cursor,
                width: box.width - padding.width * 2, height: pathText.size().height),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            cursor += pathText.size().height + spacing
        }
        text.draw(at: CGPoint(x: box.minX + padding.width, y: cursor))
    }
}
