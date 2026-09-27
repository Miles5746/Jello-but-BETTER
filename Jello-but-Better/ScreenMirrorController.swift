#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Observation
import ScreenCaptureKit

/// Captures the main display live and mirrors it, with an effect, into a click-through
/// overlay window that is itself excluded from the capture.
@Observable
final class ScreenMirrorController {
    private(set) var isRunning = false
    private(set) var errorMessage: String?
    var effect: Effect = .none {
        didSet { view?.effect = effect }
    }
    var jello: Jello = .medium {
        didSet {
            view?.jelloDelay = jello.delay
            if jello == .off { endWindowCapture() }
        }
    }
    /// Wobble only the window being dragged, instead of rippling the whole screen.
    var jelloWindowOnly = true {
        didSet {
            view?.jelloWindowOnly = jelloWindowOnly
            if !jelloWindowOnly { endWindowCapture() }
        }
    }
    var liquidGlass = false {
        didSet { view?.liquidGlass = liquidGlass }
    }

    private var window: NSWindow?
    private var view: MetalScreenView?
    private var stream: SCStream?
    private var receiver: FrameReceiver?
    @ObservationIgnored private var hotKey: GlobalHotKey?

    // Kept from start() so the main capture filter can be rebuilt around a dragged window.
    @ObservationIgnored private var display: SCDisplay?
    @ObservationIgnored private var overlayWindows: [SCWindow] = []
    @ObservationIgnored private var pixelScale: CGFloat = 1
    // Single-window capture of the window being dragged in "Dragged Window Only" mode.
    @ObservationIgnored private var windowStream: SCStream?
    @ObservationIgnored private var windowReceiver: FrameReceiver?
    @ObservationIgnored private var windowCaptureTask: Task<Void, Never>?
    @ObservationIgnored private var capturedWindow: SCWindow?
    @ObservationIgnored private var windowHidden = false
    // Window list kept fresh in the background, so starting a window capture is quick.
    @ObservationIgnored private var cachedContent: SCShareableContent?
    @ObservationIgnored private var contentRefreshTask: Task<Void, Never>?

    init() {
        // ⌃⌥⌘E toggles the overlay from anywhere, so it's never a trap when the screen is warped.
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_E),
                              modifiers: UInt32(controlKey | optionKey | cmdKey)) { [weak self] in
            self?.toggle()
        }
    }

    func toggle() {
        Task { isRunning ? await stop() : await start() }
    }

    func start() async {
        guard !isRunning, let screen = NSScreen.main else { return }
        errorMessage = nil

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            errorMessage = "Screen Recording permission is required."
            return
        }

        let (window, view) = overlay(for: screen)
        // Order front first so the window exists in the window list and can be excluded.
        window.orderFrontRegardless()

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard let display = content.displays.first(where: { $0.displayID == displayID })
                    ?? content.displays.first else {
                throw CocoaError(.featureUnsupported)
            }

            // sharingType = .none already hides the overlay; excluding it here too is belt-and-suspenders.
            let ownWindows = content.windows.filter { $0.windowID == CGWindowID(window.windowNumber) }
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.queueDepth = 5
            config.showsCursor = false  // The real cursor already draws above the overlay.

            let receiver = FrameReceiver(frames: view.frames) { [weak self] error in
                let controller = self
                Task { @MainActor in controller?.streamDidStop(error) }
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: receiver)
            try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
            try await stream.startCapture()

            self.receiver = receiver
            self.stream = stream
            self.display = display
            self.overlayWindows = ownWindows
            self.pixelScale = scale
            self.cachedContent = content
            isRunning = true
            startRefreshingContent()
        } catch {
            window.orderOut(nil)
            errorMessage = "Couldn't start capture: \(error.localizedDescription)"
        }
    }

    func stop() async {
        guard isRunning else { return }
        try? await stream?.stopCapture()
        tearDown()
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func streamDidStop(_ error: Error) {
        errorMessage = "Capture stopped: \(error.localizedDescription)"
        tearDown()
    }

    private func tearDown() {
        if let windowStream {
            Task { try? await windowStream.stopCapture() }
        }
        windowStream = nil
        windowReceiver = nil
        capturedWindow = nil
        windowHidden = false
        contentRefreshTask?.cancel()
        contentRefreshTask = nil
        view?.windowCaptureEnded()
        stream = nil
        receiver = nil
        window?.orderOut(nil)
        view?.frames.clear()
        isRunning = false
    }

    private func overlay(for screen: NSScreen) -> (NSWindow, MetalScreenView) {
        if let window, let view {
            window.setFrame(screen.frame, display: false)
            return (window, view)
        }

        let view = MetalScreenView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.effect = effect
        view.jelloDelay = jello.delay
        view.liquidGlass = liquidGlass
        view.jelloWindowOnly = jelloWindowOnly
        view.onWindowPressed = { [weak self] windowID in self?.prepareWindowCapture(windowID) }
        view.onDragStarted = { [weak self] in self?.commitWindowCapture() }
        view.onWobbleFinished = { [weak self] in self?.endWindowCapture() }

        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.sharingType = .none  // Hidden from screen capture, so it never mirrors itself.
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrame(screen.frame, display: false)

        self.window = window
        self.view = view
        return (window, view)
    }

    // MARK: Dragged-window capture
    //
    // Pressing on a window starts its own capture straight away (prepare), before it moves. Once
    // it's actually dragged, the real window is hidden from the main capture (commit) and the
    // overlay draws it as jello instead. Letting go without dragging just stops the capture.

    /// Runs window-capture changes one after another, so a drag's start and end never overlap.
    private func enqueueWindowCapture(_ work: @escaping @MainActor () async -> Void) {
        let previous = windowCaptureTask
        windowCaptureTask = Task {
            await previous?.value
            await work()
        }
    }

    /// Looks up a window, from the cached list when possible since a fresh lookup is slow.
    private func shareableWindow(_ windowID: CGWindowID) async throws -> SCWindow? {
        if let cached = cachedContent?.windows.first(where: { $0.windowID == windowID }) {
            return cached
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cachedContent = content
        return content.windows.first(where: { $0.windowID == windowID })
    }

    /// Keeps the window list fresh in the background while "Dragged Window Only" is on.
    private func startRefreshingContent() {
        contentRefreshTask?.cancel()
        contentRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                guard self.isRunning, self.jelloWindowOnly, self.jello != .off else { continue }
                if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
                    self.cachedContent = content
                }
            }
        }
    }

    /// Starts capturing a pressed window on its own, so it's ready if it gets dragged.
    private func prepareWindowCapture(_ windowID: CGWindowID) {
        enqueueWindowCapture { [weak self] in
            guard let self, let view = self.view else { return }
            guard self.isRunning, self.windowStream == nil else {
                view.windowCaptureEnded()
                return
            }
            do {
                guard let scWindow = try await self.shareableWindow(windowID) else {
                    throw CocoaError(.featureUnsupported)
                }

                let config = SCStreamConfiguration()
                config.width = Int(scWindow.frame.width * self.pixelScale)
                config.height = Int(scWindow.frame.height * self.pixelScale)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.sRGB
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                config.queueDepth = 3
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true

                let receiver = FrameReceiver(frames: view.windowFrames) { [weak self] _ in
                    let controller = self
                    Task { @MainActor in controller?.endWindowCapture() }
                }
                let windowStream = SCStream(filter: SCContentFilter(desktopIndependentWindow: scWindow),
                                            configuration: config, delegate: receiver)
                try windowStream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
                try await windowStream.startCapture()
                guard self.isRunning else {
                    try? await windowStream.stopCapture()
                    return
                }
                self.windowStream = windowStream
                self.windowReceiver = receiver
                self.capturedWindow = scWindow
            } catch {
                await self.stopWindowStream()
            }
        }
    }

    /// The pressed window is being dragged: hide the real one from the main capture so the
    /// overlay's jello copy takes its place.
    private func commitWindowCapture() {
        enqueueWindowCapture { [weak self] in
            guard let self, let view = self.view,
                  let stream = self.stream, let display = self.display, let window = self.capturedWindow else { return }
            // Hide the real window only once its own capture is showing, so it never vanishes.
            for _ in 0..<50 where view.windowFrames.get() == nil {
                try? await Task.sleep(for: .milliseconds(10))
            }
            do {
                try await stream.updateContentFilter(
                    SCContentFilter(display: display, excludingWindows: self.overlayWindows + [window]))
                self.windowHidden = true
                view.windowHiddenFromCapture = true
            } catch {
                await self.stopWindowStream()
            }
        }
    }

    /// Puts the real window back in the main capture (if it was hidden), then stops its capture.
    private func endWindowCapture() {
        enqueueWindowCapture { [weak self] in
            guard let self else { return }
            if self.windowHidden, let stream = self.stream, let display = self.display {
                try? await stream.updateContentFilter(SCContentFilter(display: display, excludingWindows: self.overlayWindows))
                // Give the main capture time to show the real window before the jello copy disappears.
                try? await Task.sleep(for: .milliseconds(250))
            }
            await self.stopWindowStream()
        }
    }

    private func stopWindowStream() async {
        try? await windowStream?.stopCapture()
        windowStream = nil
        windowReceiver = nil
        capturedWindow = nil
        windowHidden = false
        view?.windowCaptureEnded()
    }
}

/// Receives frames from ScreenCaptureKit on a background queue.
nonisolated final class FrameReceiver: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "ScreenMirror.frames", qos: .userInteractive)
    private let frames: LatestFrame
    private let onStop: @Sendable (Error) -> Void

    init(frames: LatestFrame, onStop: @escaping @Sendable (Error) -> Void) {
        self.frames = frames
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        frames.set(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }
}
#endif
