#if os(macOS)
import CoreImage
import MetalKit

/// Holds the newest captured frame. Written on the capture queue, read on the main thread.
nonisolated final class LatestFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?

    func set(_ newBuffer: CVPixelBuffer) { lock.withLock { buffer = newBuffer } }
    func get() -> CVPixelBuffer? { lock.withLock { buffer } }
    func clear() { lock.withLock { buffer = nil } }
}

/// Keeps a value alive until a command buffer completes.
nonisolated private final class GPURetainer: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

/// Draws the latest captured frame, run through the current effect, at display refresh rate.
final class MetalScreenView: MTKView {
    var effect: Effect = .none
    /// Delay a full screen height from the cursor, in seconds. 0 disables the jello effect.
    var jelloDelay: TimeInterval = 0
    /// Wobble only the dragged window (see `WobblyWindow`) instead of rippling the screen.
    var jelloWindowOnly = false
    let frames = LatestFrame()
    /// Frames of the dragged window, from its own capture, in "Dragged Window Only" mode.
    let windowFrames = LatestFrame()
    /// Asks the controller to start capturing a window the moment it's pressed on.
    var onWindowPressed: ((CGWindowID) -> Void)?
    /// Tells the controller the pressed window is being dragged, so it can hide the real one.
    var onDragStarted: (() -> Void)?
    /// Set by the controller once the real window is hidden and the jello copy should be drawn.
    var windowHiddenFromCapture = false
    /// Tells the controller the wobble has settled and the window capture can end.
    var onWobbleFinished: (() -> Void)?

    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    private let jello: JelloBuffer
    private var spring = JelloSpring()
    private var lastTick = CACurrentMediaTime()
    private let dragTracker = WindowDragTracker()
    private let wobbly: WobblyWindow
    private var pressedWindowID: CGWindowID?
    private var dragReported = false
    private var finishReported = false
    /// The dragged window lost focus: its jello was cut off and it's drawn flat until handed back.
    private var cutOff = false
    private var textureCache: CVMetalTextureCache?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let startTime = CACurrentMediaTime()

    init(frame: CGRect) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Metal is not available on this Mac")
        }
        commandQueue = queue
        ciContext = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false])
        jello = JelloBuffer(device: device)
        wobbly = WobblyWindow(device: device)
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false  // Core Image writes into the drawable texture
        preferredFramesPerSecond = 60
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pixelBuffer = frames.get(),
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let size = drawableSize
        var image = gpuPassesImage(from: pixelBuffer, commandBuffer: commandBuffer)
            ?? CIImage(cvPixelBuffer: pixelBuffer)
        image = image.transformed(by: CGAffineTransform(
            scaleX: size.width / image.extent.width,
            y: size.height / image.extent.height))
        image = effect.apply(to: image, time: CACurrentMediaTime() - startTime)

        let texture = drawable.texture
        let destination = CIRenderDestination(
            width: Int(size.width),
            height: Int(size.height),
            pixelFormat: colorPixelFormat,
            commandBuffer: commandBuffer,
            mtlTextureProvider: { texture })
        _ = try? ciContext.startTask(
            toRender: image,
            from: CGRect(origin: .zero, size: size),
            to: destination,
            at: .zero)

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Runs the frame through the jello Metal pass, or returns nil if it's off. Called every
    /// display tick, even when the screen hasn't changed, so the jello's delayed rows keep
    /// catching up to the live frame.
    private func gpuPassesImage(from pixelBuffer: CVPixelBuffer, commandBuffer: MTLCommandBuffer) -> CIImage? {
        let windowMode = jelloWindowOnly && jelloDelay > 0
        if jelloDelay <= 0 || windowMode {
            jello.reset()
            spring.reset()
        }
        guard jelloDelay > 0, let textureCache else { return nil }

        guard let source = metalTexture(for: pixelBuffer, cache: textureCache, commandBuffer: commandBuffer) else {
            return nil
        }

        let cursor = cursorPosition(width: source.width, height: source.height)
        let row = Int(cursor.y.rounded())
        var composed = source
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 1.0 / 240), 1.0 / 20)
        lastTick = now
        if windowMode {
            composed = wobbleDraggedWindow(over: composed, dt: dt, cache: textureCache,
                                           commandBuffer: commandBuffer) ?? composed
        } else if jelloDelay > 0 {
            let delayTicks = Int((jelloDelay * Double(preferredFramesPerSecond)).rounded())
            spring.step(cursor: SIMD2(Double(cursor.x), Double(cursor.y)),
                        dragging: NSEvent.pressedMouseButtons & 1 != 0,
                        dt: dt,
                        historyLength: delayTicks + 1,
                        limit: Double(source.height) * 0.1)
            composed = jello.process(composed, delayTicks: delayTicks, centerRow: row, wobble: spring.history,
                                     commandBuffer: commandBuffer) ?? composed
        }

        // Metal textures are top-down; Core Image is bottom-up.
        return CIImage(mtlTexture: composed, options: [.colorSpace: colorSpace])?
            .oriented(.downMirrored)
    }

    /// Follows the dragged window and draws it as a jelly mesh over `background`. Returns nil
    /// while there's nothing to draw (no drag, or its capture hasn't delivered a frame yet).
    private func wobbleDraggedWindow(over background: MTLTexture, dt: Double, cache: CVMetalTextureCache,
                                     commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let screen = window?.screen,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }
        let displayBounds = CGDisplayBounds(displayID)
        dragTracker.step(displayBounds: displayBounds, scale: CGFloat(background.width) / displayBounds.width)
        // Start capturing the window as soon as it's pressed on, so it's ready by the time it moves.
        if pressedWindowID == nil, !finishReported, let id = dragTracker.pressedWindowID {
            pressedWindowID = id
            onWindowPressed?(id)
        }
        guard pressedWindowID != nil else { return nil }

        guard let drag = dragTracker.drag else {
            // Clicked without dragging: just stop the capture.
            if !dragTracker.buttonDown { reportWobbleFinished() }
            return nil
        }

        // Track the window's movement from its very first tick, even before its own capture is
        // ready, so a quick flick still has the history it needs to lag and overshoot.
        if !dragReported {
            dragReported = true
            wobbly.begin(frame: drag.frame, grab: drag.grabPoint)
            onDragStarted?()
        }
        // Once another window takes focus, cut the jello off immediately so that window can have
        // its turn. The copy stays, flat on the real window, until the real one is back in the capture.
        if dragTracker.focusLost {
            cutOff = true
        }
        if cutOff {
            wobbly.snap(to: drag.frame)
            reportWobbleFinished()
        } else {
            let delayTicks = Int((jelloDelay * Double(preferredFramesPerSecond)).rounded())
            wobbly.step(frame: drag.frame, dt: dt, delayTicks: delayTicks, screenHeight: Double(background.height))
            if !dragTracker.buttonDown && wobbly.isSettled {
                reportWobbleFinished()
            }
        }

        guard windowHiddenFromCapture,
              let windowBuffer = windowFrames.get(),
              let windowTexture = metalTexture(for: windowBuffer, cache: cache, commandBuffer: commandBuffer) else {
            return nil
        }
        return wobbly.draw(window: windowTexture, over: background, commandBuffer: commandBuffer)
    }

    private func reportWobbleFinished() {
        guard !finishReported else { return }
        finishReported = true
        onWobbleFinished?()
    }

    /// Called by the controller once the dragged window's capture has stopped (or failed).
    func windowCaptureEnded() {
        windowFrames.clear()
        windowHiddenFromCapture = false
        dragTracker.finish()
        wobbly.reset()
        pressedWindowID = nil
        dragReported = false
        finishReported = false
        cutOff = false
    }

    /// Wraps a captured frame as a Metal texture, kept alive until the GPU is done with it.
    private func metalTexture(for pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache,
                              commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture)
        guard let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        let retainer = GPURetainer(cvTexture)
        commandBuffer.addCompletedHandler { _ in _ = retainer }
        return texture
    }

    /// The cursor's position in a frame of the given pixel size, from the top-left.
    private func cursorPosition(width: Int, height: Int) -> CGPoint {
        guard let screen = window?.screen else { return CGPoint(x: width / 2, y: height / 2) }
        let mouse = NSEvent.mouseLocation
        let fromLeft = (mouse.x - screen.frame.minX) / screen.frame.width
        let fromTop = (screen.frame.maxY - mouse.y) / screen.frame.height
        return CGPoint(x: fromLeft * CGFloat(width), y: fromTop * CGFloat(height))
    }
}
#endif
