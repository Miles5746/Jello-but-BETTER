#if os(macOS)
import Metal

/// "Liquid glass" lens centred on the cursor: content at the cursor is squeezed smaller and
/// the stretch grows outward toward the screen edges, which stay fixed so the full screen
/// remains visible.
final class LiquidGlass {
    /// Must stay below 0.5, where the edges would fold over; 0.45 squeezes content at the
    /// cursor 1.45× and stretches it 10× at the screen edges.
    static let strength: Float = 0.4

    /// Must match GlassParams in `shaderSource`.
    private struct GlassParams {
        var size: SIMD2<Float>
        var cursor: SIMD2<Float>
        var strength: Float
    }

    /// Compiled at launch, so the project doesn't depend on Xcode's Metal toolchain.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;And 

    // Must match GlassParams above.
    struct GlassParams {
        float2 size;
        float2 cursor;
        float strength;
    };

    // Maps an output coordinate on one axis to the source coordinate. On each side of the
    // cursor, t runs 0 (cursor) to 1 (screen edge); the cubic keeps both ends fixed, with slope
    // 1 + a at the cursor (squeezed) falling to 1 - 2a at the edge (stretched).
    float warp(float x, float cursor, float size, float a) {
        float side = x < cursor ? cursor : size - cursor;
        if (side <= 0.0) return x;
        float t = abs(x - cursor) / side;
        float s = (1.0 + a) * t - a * t * t * t;
        return cursor + sign(x - cursor) * s * side;
    }

    kernel void liquidGlass(texture2d<half, access::sample> source [[texture(0)]],
                            texture2d<half, access::write> output [[texture(1)]],
                            constant GlassParams &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        constexpr sampler linearClamp(address::clamp_to_edge, filter::linear);

        float2 position = float2(gid) + 0.5;
        float2 cursor = clamp(p.cursor, float2(0.0), p.size);
        float2 sourcePosition = float2(warp(position.x, cursor.x, p.size.x, p.strength),
                                       warp(position.y, cursor.y, p.size.y, p.strength));
        output.write(source.sample(linearClamp, sourcePosition / p.size), gid);
    }
    """

    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState?
    private var output: MTLTexture?

    init(device: MTLDevice) {
        self.device = device
        pipeline = (try? device.makeLibrary(source: Self.shaderSource, options: nil))
            .flatMap { $0.makeFunction(name: "liquidGlass") }
            .flatMap { try? device.makeComputePipelineState(function: $0) }
    }

    /// Returns `source` seen through the lens.
    /// - Parameter cursor: Cursor position in `source` pixels, from the top-left.
    func process(_ source: MTLTexture, cursor: CGPoint, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let pipeline else { return nil }
        if output?.width != source.width || output?.height != source.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: source.width, height: source.height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            output = device.makeTexture(descriptor: descriptor)
        }
        guard let output, let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        var params = GlassParams(
            size: SIMD2(Float(source.width), Float(source.height)),
            cursor: SIMD2(Float(cursor.x), Float(cursor.y)),
            strength: Self.strength)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<GlassParams>.stride, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: source.width, height: source.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth,
                                           height: pipeline.maxTotalThreadsPerThreadgroup / pipeline.threadExecutionWidth,
                                           depth: 1))
        encoder.endEncoding()
        return output
    }

    /// Frees the output texture.
    func reset() {
        output = nil
    }
}
#endif
