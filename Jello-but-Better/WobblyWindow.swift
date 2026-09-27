#if os(macOS)
import CoreGraphics
import Metal
import simd

/// Draws the dragged window with the same jello as the whole-screen mode, but only for that
/// window: it is cut into horizontal strips, and each strip shows where the window was a moment
/// ago — longer ago the further it is from the grabbed row — plus the `JelloSpring` overshoot
/// from that same moment, so strips swing past and settle as they catch up.
final class WobblyWindow {
    /// Horizontal strips the window is cut into; each moves as one piece.
    static let rowCount = 64

    /// Compiled at launch, so the project doesn't depend on Xcode's Metal toolchain.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // Each vertex is (x, y) in target pixels from the top-left, then (u, v) in the window.
    vertex VertexOut wobblyVertex(constant float4 *vertices [[buffer(0)]],
                                  constant float2 &targetSize [[buffer(1)]],
                                  uint vid [[vertex_id]]) {
        float4 v = vertices[vid];
        VertexOut out;
        out.position = float4(v.x / targetSize.x * 2.0 - 1.0, 1.0 - v.y / targetSize.y * 2.0, 0.0, 1.0);
        out.uv = v.zw;
        return out;
    }

    fragment half4 wobblyFragment(VertexOut in [[stage_in]], texture2d<half> window [[texture(0)]]) {
        constexpr sampler linearClamp(address::clamp_to_edge, filter::linear);
        return window.sample(linearClamp, in.uv);
    }
    """

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState?
    private let indexBuffer: MTLBuffer?
    private let indexCount: Int
    private var composite: MTLTexture?

    private var spring = JelloSpring()
    /// Window top-left in pixels, newest first; index i is from i ticks ago.
    private var origins: [SIMD2<Double>] = []
    private var frame = CGRect.zero
    private var grabY = 0.0
    /// Top-left of each strip boundary (rowCount + 1 lines), from the last `step`.
    private var lines: [SIMD2<Double>] = []

    /// Whether a wobble is in progress (between `begin` and `reset`).
    var isActive: Bool { !origins.isEmpty }

    init(device: MTLDevice) {
        self.device = device

        let library = try? device.makeLibrary(source: Self.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library?.makeFunction(name: "wobblyVertex")
        descriptor.fragmentFunction = library?.makeFunction(name: "wobblyFragment")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true  // Premultiplied alpha, so rounded corners stay see-through.
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = descriptor.vertexFunction == nil ? nil : try? device.makeRenderPipelineState(descriptor: descriptor)

        // Two vertices (left, right) per strip boundary; two triangles per strip.
        var indices: [UInt16] = []
        for line in 0..<Self.rowCount {
            let i = UInt16(line * 2)
            indices += [i, i + 1, i + 2, i + 1, i + 3, i + 2]
        }
        indexCount = indices.count
        indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt16>.stride)
    }

    /// Starts a wobble with every strip at rest on the window.
    /// - Parameter grab: Grab point relative to the window's top-left, in pixels.
    func begin(frame: CGRect, grab: CGPoint) {
        self.frame = frame
        grabY = min(max(Double(grab.y), 0), Double(frame.height))
        origins = [Self.origin(of: frame)]
        spring.reset()
        lines = (0...Self.rowCount).map { Self.origin(of: frame) + SIMD2(0, lineY($0)) }
    }

    /// Advances one display tick.
    /// - Parameters:
    ///   - delayTicks: Lag, in ticks, a full screen height from the grabbed row (as in the screen jello).
    ///   - screenHeight: Captured display height in pixels.
    func step(frame: CGRect, dt: Double, delayTicks: Int, screenHeight: Double) {
        guard isActive else { return }
        self.frame = frame
        let origin = Self.origin(of: frame)
        let historyLength = delayTicks + 1

        spring.step(cursor: origin, dragging: true, dt: dt, historyLength: historyLength, limit: screenHeight * 0.1)
        origins.insert(origin, at: 0)
        if origins.count > historyLength {
            origins.removeLast(origins.count - historyLength)
        }

        let wobble = spring.history.map { SIMD2<Double>($0) }
        let height = Double(frame.height)
        lines = (0...Self.rowCount).map { line in
            let y = lineY(line)
            let distance = abs(y - grabY)
            let age = distance / max(screenHeight, 1) * Double(delayTicks)
            // Strips near the grabbed row are held still, like the spot you're pinching.
            let t = min(distance / max(height * 0.25, 1), 1)
            let hold = t * t * (3 - 2 * t)
            return Self.sample(origins, age: age) + SIMD2(0, y) + Self.sample(wobble, age: age) * hold
        }
    }

    /// Drops all lag and overshoot at once, so the window is drawn flat on its real frame.
    func snap(to frame: CGRect) {
        guard isActive else { return }
        self.frame = frame
        origins = [Self.origin(of: frame)]
        spring.reset()
        lines = (0...Self.rowCount).map { Self.origin(of: frame) + SIMD2(0, lineY($0)) }
    }

    /// True once the window has been still for the whole delay and the overshoot has died away.
    var isSettled: Bool {
        guard let newest = origins.first else { return true }
        return origins.allSatisfy { simd_length($0 - newest) < 0.5 }
            && spring.history.allSatisfy { simd_length($0) < 0.5 }
    }

    /// Composites the mesh-deformed window over `background` and returns the result.
    func draw(window windowTexture: MTLTexture, over background: MTLTexture,
              commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard isActive, let pipeline, let indexBuffer else { return nil }
        if composite?.width != background.width || composite?.height != background.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: background.width, height: background.height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            composite = device.makeTexture(descriptor: descriptor)
        }
        guard let composite, let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: background, to: composite)
        blit.endEncoding()

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = composite
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }

        let width = Float(frame.width)
        let vertices = lines.indices.flatMap { line -> [SIMD4<Float>] in
            let x = Float(lines[line].x), y = Float(lines[line].y)
            let v = Float(line) / Float(Self.rowCount)
            return [SIMD4(x, y, 0, v), SIMD4(x + width, y, 1, v)]
        }
        var targetSize = SIMD2<Float>(Float(composite.width), Float(composite.height))
        encoder.setRenderPipelineState(pipeline)
        vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.setVertexBytes(&targetSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.setFragmentTexture(windowTexture, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint16,
                                      indexBuffer: indexBuffer, indexBufferOffset: 0)
        encoder.endEncoding()
        return composite
    }

    /// Ends the wobble and frees the composite texture.
    func reset() {
        origins = []
        lines = []
        spring.reset()
        composite = nil
    }

    private func lineY(_ line: Int) -> Double {
        Double(line) / Double(Self.rowCount) * Double(frame.height)
    }

    private static func origin(of frame: CGRect) -> SIMD2<Double> {
        SIMD2(Double(frame.minX), Double(frame.minY))
    }

    /// Value from `age` ticks ago in a newest-first history, interpolated between ticks.
    private static func sample(_ history: [SIMD2<Double>], age: Double) -> SIMD2<Double> {
        guard !history.isEmpty else { return .zero }
        let clamped = min(max(age, 0), Double(history.count - 1))
        let i0 = Int(clamped)
        let i1 = min(i0 + 1, history.count - 1)
        let t = clamped - Double(i0)
        return history[i0] * (1 - t) + history[i1] * t
    }
}
#endif
