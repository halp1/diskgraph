import AppKit

/// Text drawn on top of the Metal view: the total in the middle of the graph, and the
/// hover tooltip.
///
/// Native text rendering rather than a glyph atlas — it is a handful of strings per
/// frame, and this way they match the system's font smoothing exactly.
final class GraphOverlayView: NSView {
    struct Tooltip {
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

    override func draw(_ dirtyRect: NSRect) {
        drawCenterText()
        if let tooltip { draw(tooltip) }
    }

    private func drawCenterText() {
        guard !centerText.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.centerFont,
            .foregroundColor: NSColor.labelColor,
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

        let padding = CGSize(width: 7, height: 3)
        let textSize = text.size()
        let boxSize = CGSize(
            width: (textSize.width + padding.width * 2).rounded(.up),
            height: (textSize.height + padding.height * 2).rounded(.up))

        // Sit just below and right of the cursor, then pull back inside the view.
        var origin = CGPoint(x: tooltip.anchor.x + 12, y: tooltip.anchor.y + 16)
        origin.x = min(max(4, origin.x), bounds.maxX - boxSize.width - 4)
        origin.y = min(max(4, origin.y), bounds.maxY - boxSize.height - 4)
        let box = CGRect(origin: origin, size: boxSize)

        let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        NSColor(calibratedWhite: 0.91, alpha: 0.97).setFill()
        path.fill()
        NSColor(calibratedWhite: 0.72, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()

        text.draw(at: CGPoint(x: box.minX + padding.width, y: box.minY + padding.height))
    }
}
