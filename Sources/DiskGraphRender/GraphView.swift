import AppKit
import DiskGraphCore
import DiskGraphLayout
import MetalKit
import simd

public protocol GraphViewDelegate: AnyObject {
    /// The cell under the pointer changed. `nil` when the pointer leaves the graph.
    func graphView(_ view: GraphView, didHover node: NodeID?)
    /// A directory was clicked and should become the new root.
    func graphView(_ view: GraphView, didActivate node: NodeID)
    /// A cell was selected without navigating.
    func graphView(_ view: GraphView, didSelect node: NodeID?)
    func graphView(_ view: GraphView, menuFor node: NodeID) -> NSMenu?
}

public extension GraphViewDelegate {
    func graphView(_ view: GraphView, didHover node: NodeID?) {}
    func graphView(_ view: GraphView, didSelect node: NodeID?) {}
    func graphView(_ view: GraphView, menuFor node: NodeID) -> NSMenu? { nil }
}

/// The graph itself: a Metal view with a text overlay, plus the interaction and
/// animation that drive them.
///
/// Switching between the pie chart and the tree map does **not** relayout. Both
/// geometries already live on every cell, so the change is an animation of one uniform.
/// A relayout only happens when the data, the root or a layout option changes.
public final class GraphView: NSView {
    public weak var delegate: GraphViewDelegate?

    private let metalView: MTKView
    private let overlay = GraphOverlayView()
    private let renderer: GraphRenderer
    private let layoutEngine = GraphLayoutEngine()

    private var tree: FileTree?
    private var hitTester: GraphHitTester?
    private var currentCells: [CellInstance] = []

    public private(set) var root: NodeID = 0
    public private(set) var hoveredNode: NodeID?
    public private(set) var selectedNode: NodeID?

    public var options: GraphOptions {
        didSet { optionsChanged(from: oldValue) }
    }

    /// Cells whose name does not contain this are dimmed. Empty disables dimming.
    public var searchQuery: String = "" {
        didSet { if searchQuery != oldValue { applySearch() } }
    }

    // MARK: - Animation

    private struct Animation {
        var from: Float
        var to: Float
        var start: CFTimeInterval
        var duration: CFTimeInterval
    }

    private var morphAnimation: Animation?
    private var blendAnimation: Animation?
    private var relayoutWork: DispatchWorkItem?
    private let layoutQueue = DispatchQueue(label: "org.diskgraph.layout", qos: .userInitiated)
    private var layoutGeneration = 0

    // MARK: - Init

    public init?(frame: NSRect, options: GraphOptions = GraphOptions()) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = try? GraphRenderer.makeLibrary(device: device),
              let renderer = try? GraphRenderer(device: device, library: library)
        else { return nil }

        self.options = options
        self.renderer = renderer
        metalView = MTKView(frame: frame, device: device)
        super.init(frame: frame)

        metalView.colorPixelFormat = .bgra8Unorm
        // Pin the drawable's colour space. Without this the layer inherits the display's
        // (Display P3 here), and the numbers written by the shader no longer mean what the
        // palette says they do — measured greys came out several points light.
        metalView.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalView.layer?.isOpaque = true
        metalView.sampleCount = renderer.configuration.sampleCount
        metalView.autoResizeDrawable = true
        metalView.enableSetNeedsDisplay = true
        metalView.isPaused = true
        metalView.delegate = self
        metalView.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metalView)
        addSubview(overlay)
        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        renderer.graphTypeProgress = options.graphType == .treeMap ? 1 : 0
        renderer.uniforms.directoryBorderWidth = Float(options.directoryBorderWidth)
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    // MARK: - Content

    public func show(tree: FileTree, root: NodeID = 0) {
        self.tree = tree
        self.root = root
        hoveredNode = nil
        selectedNode = nil
        relayout(animated: false)
    }

    /// Changes the subtree the graph draws, animating the geometry between the two.
    public func navigate(to node: NodeID, animated: Bool = true) {
        guard let tree, node >= 0, node < NodeID(tree.count), node != root else { return }
        root = node
        hoveredNode = nil
        relayout(animated: animated)
    }

    private func optionsChanged(from old: GraphOptions) {
        // Graph type is free: both shapes are already in the buffer.
        if old.graphType != options.graphType {
            animateMorph(to: options.graphType == .treeMap ? 1 : 0)
        }
        // Everything else changes the geometry itself.
        let needsRelayout = old.sizeMode != options.sizeMode
            || old.colorMode != options.colorMode
            || old.treemapLayout != options.treemapLayout
            || old.graphLevels != options.graphLevels
            || old.mergeThreshold != options.mergeThreshold
            || old.holeRadiusFraction != options.holeRadiusFraction
            || old.ringWidthFraction != options.ringWidthFraction
            || old.showAvailableSpace != options.showAvailableSpace
            || old.beginLayoutOnBottomEdge != options.beginLayoutOnBottomEdge
        if old.showPackageContents != options.showPackageContents { relayout(animated: true) }
        else if needsRelayout { relayout(animated: options.animationSpeed > 0) }

        if old.directoryBorderWidth != options.directoryBorderWidth {
            renderer.uniforms.directoryBorderWidth = Float(options.directoryBorderWidth)
            metalView.needsDisplay = true
        }
    }

    // MARK: - Appearance

    /// The graph's colours follow the system appearance, as the reference app's do: the
    /// same wedge is vivid on a light background and deeper on a dark one, and the cell
    /// outlines invert so they stay visible either way.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
        // Colours are baked into the instance buffer, so this needs a fresh layout.
        relayout(animated: false)
    }

    private func applyAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let tuning = isDark ? CellPalette.dark : CellPalette.light
        CellPalette.current = tuning

        renderer.configuration.backgroundColor = SIMD4(
            tuning.background.x, tuning.background.y, tuning.background.z, 1)
        renderer.uniforms.borderColor = SIMD4(tuning.border, 1)
        renderer.uniforms.dimTarget = SIMD4(
            Float(tuning.background.x), Float(tuning.background.y), Float(tuning.background.z), 1)
        overlay.needsDisplay = true
    }

    // MARK: - Layout

    private var viewSizeInPoints: SIMD2<Float> {
        SIMD2(Float(max(bounds.width, 1)), Float(max(bounds.height, 1)))
    }

    private func relayout(animated: Bool) {
        guard let tree else { return }
        relayoutWork?.cancel()

        layoutGeneration += 1
        let generation = layoutGeneration
        let root = self.root
        let options = self.options
        let size = viewSizeInPoints
        let previous = animated && !currentCells.isEmpty ? currentCells : nil
        let engine = layoutEngine

        layoutQueue.async { [weak self] in
            let result = engine.morphable(tree: tree, root: root, options: options, viewSize: size)
            DispatchQueue.main.async {
                guard let self, generation == self.layoutGeneration else { return }
                self.apply(
                    result.cells, previous: previous, animated: animated,
                    discRadiusFraction: result.discRadiusFraction)
            }
        }
    }

    private func apply(
        _ cells: [CellInstance], previous: [CellInstance]?, animated: Bool,
        discRadiusFraction: Float
    ) {
        renderer.discRadiusFraction = discRadiusFraction
        let radius = renderer.pieGeometry(for: viewSizeInPoints).radius

        if let previous, animated {
            let paired = GraphTransition.pair(from: previous, to: cells)
            currentCells = paired.to
            renderer.setCells(paired.to, previous: paired.from, radiusInPoints: radius)
            renderer.uniforms.blend = 0
            animateBlend()
        } else {
            currentCells = cells
            renderer.setCells(cells, radiusInPoints: radius)
            renderer.uniforms.blend = 0
        }

        rebuildHitTester()
        applySearch()
        updateOverlay()
        metalView.needsDisplay = true
    }

    private func rebuildHitTester() {
        hitTester = GraphHitTester(
            cells: renderer.cells, graphType: options.graphType,
            discRadiusFraction: renderer.discRadiusFraction)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Cell geometry is normalised, so a resize is already correct on the next frame.
        // Only the point-based merge threshold and the arc LOD need refreshing, and those
        // can wait until the drag settles.
        scheduleThresholdRefresh()
        updateOverlay()
        metalView.needsDisplay = true
    }

    private func scheduleThresholdRefresh() {
        relayoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.relayout(animated: false) }
        relayoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: - Animation

    private func animateMorph(to target: Float) {
        let duration = baseDuration
        guard duration > 0 else {
            renderer.graphTypeProgress = target
            rebuildHitTester()
            metalView.needsDisplay = true
            return
        }
        morphAnimation = Animation(
            from: renderer.graphTypeProgress, to: target,
            start: CACurrentMediaTime(), duration: duration)
        startDisplayLoop()
    }

    private func animateBlend() {
        let duration = baseDuration
        guard duration > 0 else {
            renderer.uniforms.blend = 1
            renderer.finishTransition()
            metalView.needsDisplay = true
            return
        }
        blendAnimation = Animation(
            from: 0, to: 1, start: CACurrentMediaTime(), duration: duration)
        startDisplayLoop()
    }

    private var baseDuration: CFTimeInterval {
        options.animationSpeed <= 0 ? 0 : 0.45 / options.animationSpeed
    }

    private func startDisplayLoop() {
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
    }

    private func stopDisplayLoopIfIdle() {
        guard morphAnimation == nil, blendAnimation == nil else { return }
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true
    }

    /// Ease-in-out, so transitions start and end at rest.
    private static func ease(_ t: Float) -> Float {
        let clamped = min(max(t, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    private func advanceAnimations() {
        let now = CACurrentMediaTime()

        if let animation = morphAnimation {
            let progress = Float((now - animation.start) / animation.duration)
            renderer.graphTypeProgress = animation.from
                + (animation.to - animation.from) * Self.ease(progress)
            if progress >= 1 {
                renderer.graphTypeProgress = animation.to
                morphAnimation = nil
                // The hit tester is per graph type, so swap it once the dissolve lands.
                rebuildHitTester()
            }
        }

        if let animation = blendAnimation {
            let progress = Float((now - animation.start) / animation.duration)
            renderer.uniforms.blend = animation.from
                + (animation.to - animation.from) * Self.ease(progress)
            if progress >= 1 {
                renderer.uniforms.blend = 1
                blendAnimation = nil
                renderer.finishTransition()
            }
        }

        stopDisplayLoopIfIdle()
    }

    // MARK: - Search

    private func applySearch() {
        guard let tree else { return }
        let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else {
            renderer.setSearchMisses { _ in false }
            metalView.needsDisplay = true
            return
        }
        renderer.setSearchMisses { cell in
            guard !cell.cellFlags.contains(.merged) else { return true }
            return !tree.name(of: cell.node).lowercased().contains(query)
        }
        metalView.needsDisplay = true
    }

    /// Number of cells currently matching the search.
    public var searchMatchCount: Int {
        renderer.cells.reduce(into: 0) { count, cell in
            if !cell.cellFlags.contains(.searchMiss) && !cell.cellFlags.contains(.merged) {
                count += 1
            }
        }
    }

    // MARK: - Overlay

    private func updateOverlay() {
        guard let tree else {
            overlay.centerText = ""
            return
        }
        overlay.centerPoint = CGPoint(x: bounds.midX, y: bounds.midY)
        let node = hoveredNode ?? root
        overlay.centerText = CellDescription.centerLabel(
            for: node, tree: tree, sizeMode: options.sizeMode)
    }

    // MARK: - Mouse

    private var trackingArea: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    /// The hit tester indexes the same array the renderer uploaded, so it hands back the
    /// instance index directly — no search over the cell list on the hover path.
    private func cellIndex(at point: NSPoint) -> Int? {
        guard let hitTester, bounds.width > 0, bounds.height > 0 else { return nil }
        let normalized = SIMD2(
            Float(point.x / bounds.width), Float(point.y / bounds.height))
        return hitTester.cellIndex(at: normalized, aspect: Float(bounds.width / bounds.height))
    }

    private func cell(at point: NSPoint) -> CellInstance? {
        cellIndex(at: point).map { renderer.cells[$0] }
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHover(at: point)
    }

    public override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    public override func mouseExited(with event: NSEvent) {
        hoveredNode = nil
        renderer.uniforms.highlightedCell = GraphUniforms.noHighlight
        overlay.tooltip = nil
        updateOverlay()
        metalView.needsDisplay = true
        delegate?.graphView(self, didHover: nil)
    }

    private func updateHover(at point: NSPoint) {
        guard let tree else { return }
        let index = cellIndex(at: point)
        let hit = index.map { renderer.cells[$0] }
        let node = hit.flatMap { $0.cellFlags.contains(.merged) ? nil : $0.node }

        renderer.uniforms.highlightedCell = index.map(UInt32.init) ?? GraphUniforms.noHighlight

        if let hit {
            let text = CellDescription.tooltip(for: hit, tree: tree, sizeMode: options.sizeMode)
            overlay.tooltip = GraphOverlayView.Tooltip(
                name: text.name, detail: text.detail, anchor: point)
        } else {
            overlay.tooltip = nil
        }

        if node != hoveredNode {
            hoveredNode = node
            delegate?.graphView(self, didHover: node)
        }
        updateOverlay()
        metalView.needsDisplay = true
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = cell(at: point), !hit.cellFlags.contains(.merged) else {
            selectedNode = nil
            delegate?.graphView(self, didSelect: nil)
            return
        }

        selectedNode = hit.node
        delegate?.graphView(self, didSelect: hit.node)

        // Clicking a directory re-roots the graph on it, as in the reference app.
        // Files can only be selected.
        if tree?.isDirectory(hit.node) == true {
            delegate?.graphView(self, didActivate: hit.node)
        }
    }

    public override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = cell(at: point), !hit.cellFlags.contains(.merged),
              let menu = delegate?.graphView(self, menuFor: hit.node)
        else { return }
        selectedNode = hit.node
        delegate?.graphView(self, didSelect: hit.node)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Screen point of a node's cell, for revealing it from the outline list.
    public func highlight(node: NodeID) {
        guard let index = renderer.cells.firstIndex(where: { $0.node == node }) else { return }
        renderer.uniforms.highlightedCell = UInt32(index)
        selectedNode = node
        metalView.needsDisplay = true
    }
}

// MARK: - MTKViewDelegate

extension GraphView: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        advanceAnimations()

        let size = viewSizeInPoints
        let geometry = renderer.pieGeometry(for: size)
        renderer.uniforms.viewportSize = size
        renderer.uniforms.pieCenter = geometry.center
        renderer.uniforms.pieRadius = geometry.radius
        renderer.draw(in: view)
    }
}
