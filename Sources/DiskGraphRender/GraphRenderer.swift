import DiskGraphCore
import DiskGraphLayout
import Metal
import MetalKit
import simd

/// Draws the graph with one instanced pass per level of detail.
///
/// Every cell is a triangle strip of `2·(K+1)` vertices where `K` comes from the cell's
/// LOD bucket, so a hair-thin sliver costs four vertices while a large wedge still gets
/// a smooth arc. Four buckets means four draw calls no matter how many cells there are.
///
/// Nothing about the geometry is rebuilt per frame: an animating graph only changes the
/// `morph` uniform, so a transition costs the same as a static frame.
public final class GraphRenderer: NSObject {
    public struct Configuration {
        public var backgroundColor: SIMD4<Double> = SIMD4(0.933, 0.933, 0.933, 1)
        public var sampleCount: Int = 4
        public init() {}
    }

    public var configuration = Configuration()

    /// Fraction of half the view's smaller dimension the disc fills. Comes from the
    /// layout, because the reference app grows and shrinks the disc with the depth of the
    /// subtree rather than always filling the view.
    public var discRadiusFraction: Float = 1

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    /// Layout being animated away from. Equal to `toBuffer` when nothing is animating.
    private var fromBuffer: MTLBuffer?
    private var toBuffer: MTLBuffer?
    private var orderBuffer: MTLBuffer?
    /// One entry per LOD bucket: where it starts in the order buffer and how many cells.
    private var buckets: [(offset: Int, count: Int, subdivisions: Int)] = []

    /// The cells the hit tester and overlay read. During a navigation transition these
    /// are the destination cells, so hovering already reflects where you are going.
    public private(set) var cells: [CellInstance] = []
    public var uniforms = GraphUniforms()

    public init(device: MTLDevice, library: MTLLibrary, configuration: Configuration = Configuration()) throws {
        self.device = device
        self.configuration = configuration
        guard let queue = device.makeCommandQueue() else { throw RendererError.noCommandQueue }
        commandQueue = queue

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "graph_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "graph_fragment")
        descriptor.rasterSampleCount = configuration.sampleCount
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        // Premultiplied: the fragment shader composites each cell's outline over its own
        // fill before blending.
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        super.init()
    }

    public enum RendererError: Error {
        case noCommandQueue
        case missingLibrary
    }

    /// Loads the compiled shader from the app bundle, falling back to compiling the
    /// `.metal` source shipped as a package resource (the path `swift test` takes, where
    /// no `default.metallib` exists).
    public static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        if let bundled = try? device.makeDefaultLibrary(bundle: .main) { return bundled }
        if let source = Bundle.module.url(forResource: "Graph", withExtension: "metal"),
           let text = try? String(contentsOf: source, encoding: .utf8) {
            return try device.makeLibrary(source: text, options: nil)
        }
        if let fallback = device.makeDefaultLibrary() { return fallback }
        throw RendererError.missingLibrary
    }

    // MARK: - Geometry upload

    /// Replaces the cell set. Called when the layout changes, never per frame.
    ///
    /// `previous`, when supplied, must be index-aligned with `cells` (see
    /// `GraphTransition.pair`) and becomes the start state of a navigation animation.
    public func setCells(
        _ cells: [CellInstance], previous: [CellInstance]? = nil, radiusInPoints: Float
    ) {
        self.cells = cells
        guard !cells.isEmpty else {
            fromBuffer = nil
            toBuffer = nil
            orderBuffer = nil
            buckets = []
            return
        }

        toBuffer = makeBuffer(cells)
        if let previous, previous.count == cells.count {
            fromBuffer = makeBuffer(previous)
        } else {
            fromBuffer = toBuffer
        }

        // Group cell indices by tessellation cost so each bucket is one contiguous draw.
        // The bucket must cover both end states, or a wedge would coarsen mid-animation.
        var byBucket: [[UInt32]] = Array(repeating: [], count: LODBucket.subdivisions.count)
        for (index, cell) in cells.enumerated() {
            var needed = cell.pieAlpha > 0 ? cell.arcSubdivisions(radiusInPoints: radiusInPoints) : 1
            if let previous, index < previous.count, previous[index].pieAlpha > 0 {
                needed = max(needed, previous[index].arcSubdivisions(radiusInPoints: radiusInPoints))
            }
            byBucket[LODBucket.index(forSubdivisions: needed)].append(UInt32(index))
        }

        var order: [UInt32] = []
        order.reserveCapacity(cells.count)
        buckets = []
        for (bucket, indices) in byBucket.enumerated() where !indices.isEmpty {
            buckets.append((offset: order.count, count: indices.count,
                            subdivisions: LODBucket.subdivisions[bucket]))
            order.append(contentsOf: indices)
        }

        orderBuffer = order.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!,
                              length: MemoryLayout<UInt32>.stride * order.count,
                              options: .storageModeShared)
        }
    }

    private func makeBuffer(_ cells: [CellInstance]) -> MTLBuffer? {
        cells.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!,
                              length: MemoryLayout<CellInstance>.stride * cells.count,
                              options: .storageModeShared)
        }
    }

    /// Collapses the animation start state into the current one, ending any blend.
    public func finishTransition() {
        fromBuffer = toBuffer
        uniforms.blend = 0
    }

    /// Rewrites cell flags in place. Search highlighting must not trigger a relayout, so
    /// it patches the live buffer rather than rebuilding it.
    public func setSearchMisses(_ isMiss: (CellInstance) -> Bool) {
        guard let buffer = toBuffer else { return }
        let pointer = buffer.contents().bindMemory(to: CellInstance.self, capacity: cells.count)
        let alsoPatchFrom = fromBuffer !== toBuffer ? fromBuffer : nil
        let fromPointer = alsoPatchFrom?.contents().bindMemory(
            to: CellInstance.self, capacity: cells.count)
        for index in cells.indices {
            var flags = cells[index].cellFlags
            if isMiss(cells[index]) { flags.insert(.searchMiss) } else { flags.remove(.searchMiss) }
            cells[index].flags = flags.rawValue
            pointer[index].flags = flags.rawValue
            fromPointer?[index].flags = flags.rawValue
        }
    }

    /// Pie geometry in points for the current drawable size.
    public func pieGeometry(for size: SIMD2<Float>) -> (center: SIMD2<Float>, radius: Float) {
        (SIMD2(size.x / 2, size.y / 2), min(size.x, size.y) / 2 * discRadiusFraction)
    }

    // MARK: - Drawing

    public func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let background = configuration.backgroundColor
        descriptor.colorAttachments[0].clearColor =
            MTLClearColor(red: background.x, green: background.y, blue: background.z, alpha: background.w)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        if let fromBuffer, let toBuffer, let orderBuffer, !buckets.isEmpty {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(fromBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(orderBuffer, offset: 0, index: 1)
            encoder.setVertexBuffer(toBuffer, offset: 0, index: 4)

            // A graph-type change draws both shapes with complementary opacity; the rest of
            // the time only one shape is on screen and costs a single set of passes.
            let outgoing = 1 - graphTypeProgress
            if outgoing > 0.002 {
                encodeShape(pieShapeValue, opacity: outgoing, encoder: encoder)
            }
            if graphTypeProgress > 0.002 {
                encodeShape(treeMapShapeValue, opacity: graphTypeProgress, encoder: encoder)
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// 0 → pie chart, 1 → tree map. Anything in between cross-dissolves.
    public var graphTypeProgress: Float = 0

    private let pieShapeValue: Float = 0
    private let treeMapShapeValue: Float = 1

    private func encodeShape(_ shape: Float, opacity: Float, encoder: MTLRenderCommandEncoder) {
        encodePass(.fill, shape: shape, opacity: opacity, encoder: encoder)
        // Directory outlines exist only in the tree map.
        if shape > 0.5, uniforms.directoryBorderWidth > 0 {
            encodePass(.directoryBorder, shape: shape, opacity: opacity, encoder: encoder)
        }
    }

    private enum Pass: UInt32 {
        case fill = 0
        case directoryBorder = 1
    }

    private func encodePass(
        _ pass: Pass, shape: Float, opacity: Float, encoder: MTLRenderCommandEncoder
    ) {
        var passUniforms = uniforms
        passUniforms.renderPass = pass.rawValue
        passUniforms.shape = shape
        passUniforms.opacity = opacity
        encoder.setVertexBytes(&passUniforms, length: MemoryLayout<GraphUniforms>.stride, index: 2)
        encoder.setFragmentBytes(&passUniforms, length: MemoryLayout<GraphUniforms>.stride, index: 2)

        for bucket in buckets {
            var params = GraphDrawParams(
                instanceOffset: UInt32(bucket.offset), subdivisions: UInt32(bucket.subdivisions))
            encoder.setVertexBytes(&params, length: MemoryLayout<GraphDrawParams>.stride, index: 3)
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 2 * (bucket.subdivisions + 1),
                instanceCount: bucket.count)
        }
    }
}
