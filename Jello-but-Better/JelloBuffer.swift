#if os(macOS)
import Metal

/// Rolling-shutter "jello" centred on a row (the cursor): rows further from that row show
/// older frames, so motion ripples outward — up and down — from the cursor.
///
/// Keeps a ring of recent whole frames in a texture array. Because the centre row moves,
/// any row may need any delay, so every slot stores the full frame. The `jelloCompose`
/// kernel (`shaderSource`) then gives every row its own delay, blending neighbouring frames,
/// and shifts it by the drag wobble (`JelloSpring`) from that same moment, so each row
/// overshoots as it catches up.
final class JelloBuffer {
    /// Must match JelloParams in `shaderSource`.
    private struct JelloParams {
        var centerRow: Float
        var reach: Float
        var maxAge: Float
        var ageOffset: Float
        var newest: UInt32
        var slotCount: UInt32
        var maxAgeTicks: Float
        var wobbleCount: UInt32
    }

    /// Compiled at launch, so the project doesn't depend on Xcode's Metal toolchain.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    // Must match JelloParams above.
    struct JelloParams {
        float centerRow;  // Row that is always live
        float reach;      // Distance in rows at which the full delay is reached
        float maxAge;     // Oldest usable slot age
        float ageOffset;  // How far (in slots) the newest slot already lags behind now
        uint newest;      // Slice holding the newest frame
        uint slotCount;
        float maxAgeTicks; // Oldest usable age in display ticks
        uint wobbleCount;  // Entries in the wobble history
    };

    // Wobble offset from ageTicks ago, interpolated between ticks.
    float2 wobbleAt(constant float2 *wobble, uint count, float ageTicks) {
        float i = clamp(ageTicks, 0.0, float(count - 1));
        uint i0 = uint(i);
        uint i1 = min(i0 + 1, count - 1);
        return mix(wobble[i0], wobble[i1], i - float(i0));
    }

    // Each row shows a frame whose age grows with distance from the centre row. Fractional
    // ages blend the two neighbouring frames, so the delay changes smoothly row by row. The row
    // is also shifted by the wobble from the same moment; rows near the cursor are held still.
    kernel void jelloCompose(texture2d_array<half, access::sample> history [[texture(0)]],
                             texture2d<half, access::write> output [[texture(1)]],
                             constant JelloParams &p [[buffer(0)]],
                             constant float2 *wobble [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        constexpr sampler linearClamp(address::clamp_to_edge, filter::linear);

        float2 size = float2(output.get_width(), output.get_height());
        float2 position = float2(gid) + 0.5;
        float reachFraction = min(abs(position.y - p.centerRow) / p.reach, 1.0);

        float age = clamp(reachFraction * p.maxAge - p.ageOffset, 0.0, p.maxAge);
        uint older = min(uint(age) + 1, p.slotCount - 1);
        uint newer = uint(age);
        half t = half(age - float(newer));

        float hold = smoothstep(0.0, 0.25, reachFraction);
        float2 shift = wobbleAt(wobble, p.wobbleCount, reachFraction * p.maxAgeTicks) * hold;
        float2 uv = (position - shift) / size;

        half4 a = history.sample(linearClamp, uv, (p.newest + p.slotCount - newer) % p.slotCount);
        half4 b = history.sample(linearClamp, uv, (p.newest + p.slotCount - older) % p.slotCount);
        output.write(mix(a, b, t), gid);
    }
    """

    /// Caps memory: longer delays store every Nth frame instead of more frames.
    static let maxSlots = 30

    private let device: MTLDevice
    private let compose: MTLComputePipelineState?
    private var history: MTLTexture?  // 2D array, one slice per stored frame
    private var output: MTLTexture?
    private var width = 0
    private var height = 0
    private var slotCount = 0
    private var newest = 0
    private var ticksSinceWrite = 0
    private var needsPrime = false

    init(device: MTLDevice) {
        self.device = device
        compose = (try? device.makeLibrary(source: Self.shaderSource, options: nil))
            .flatMap { $0.makeFunction(name: "jelloCompose") }
            .flatMap { try? device.makeComputePipelineState(function: $0) }
    }

    /// Stores `source` and returns the composed frame.
    /// - Parameters:
    ///   - delayTicks: Lag, in display ticks, of a row a full screen height from `centerRow`.
    ///   - centerRow: Row (from the top) that is always live.
    ///   - wobble: Drag wobble offsets in pixels, newest first, one per tick (`JelloSpring.history`).
    func process(_ source: MTLTexture, delayTicks: Int, centerRow: Int, wobble: [SIMD2<Float>],
                 commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let ticks = max(1, delayTicks)
        let slots = min(ticks, Self.maxSlots)
        let ticksPerSlot = (ticks + slots - 1) / slots
        if source.width != width || source.height != height || slots != slotCount {
            rebuild(width: source.width, height: source.height, slots: slots)
        }
        guard let history, let output, let compose else { return nil }

        // Store the frame (every tick, or every few ticks for long delays).
        if needsPrime || ticksSinceWrite >= ticksPerSlot - 1 {
            newest = needsPrime ? 0 : (newest + 1) % slots
            let targets = needsPrime ? Array(0..<slots) : [newest]  // Prime so nothing shows garbage.
            guard let write = commandBuffer.makeBlitCommandEncoder() else { return nil }
            for slice in targets {
                write.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                           sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                           sourceSize: MTLSize(width: width, height: height, depth: 1),
                           to: history, destinationSlice: slice, destinationLevel: 0,
                           destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            }
            write.endEncoding()
            needsPrime = false
            ticksSinceWrite = 0
        } else {
            ticksSinceWrite += 1
        }

        // Delay grows steadily all the way to the screen edge, so no part moves as a block.
        // When frames are stored only every few ticks, ageOffset accounts for how stale the
        // newest one is, so the picture glides between stored frames instead of jumping.
        var params = JelloParams(
            centerRow: Float(min(max(centerRow, 0), height)),
            reach: Float(max(1, height)),
            maxAge: Float(slots - 1),
            ageOffset: Float(ticksSinceWrite) / Float(ticksPerSlot),
            newest: UInt32(newest),
            slotCount: UInt32(slots),
            maxAgeTicks: Float((slots - 1) * ticksPerSlot),
            wobbleCount: UInt32(max(wobble.count, 1)))
        let wobbleOffsets = wobble.isEmpty ? [SIMD2<Float>.zero] : wobble
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(compose)
        encoder.setTexture(history, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<JelloParams>.stride, index: 0)
        wobbleOffsets.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: compose.threadExecutionWidth,
                                           height: compose.maxTotalThreadsPerThreadgroup / compose.threadExecutionWidth,
                                           depth: 1))
        encoder.endEncoding()
        return output
    }

    /// Frees the history textures.
    func reset() {
        history = nil
        output = nil
        width = 0
        height = 0
        slotCount = 0
    }

    private func rebuild(width: Int, height: Int, slots: Int) {
        self.width = width
        self.height = height
        slotCount = slots
        history = makeTexture(width: width, height: height, slices: slots)
        output = makeTexture(width: width, height: height, slices: 1, usage: [.shaderRead, .shaderWrite])
        newest = 0
        ticksSinceWrite = 0
        needsPrime = true
    }

    private func makeTexture(width: Int, height: Int, slices: Int,
                             usage: MTLTextureUsage = .shaderRead) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        if slices > 1 {
            descriptor.textureType = .type2DArray
            descriptor.arrayLength = slices
        }
        descriptor.storageMode = .private
        descriptor.usage = usage
        return device.makeTexture(descriptor: descriptor)
    }
}
#endif
