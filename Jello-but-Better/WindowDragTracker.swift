#if os(macOS)
import AppKit

/// Finds the window under the cursor when the mouse button goes down, and reports it as dragged
/// once it moves without changing size (so clicks and resizes are ignored). Keeps following the
/// window after the button is released, until `finish()`, so its wobble can settle in place.
/// A press on another window meanwhile is remembered, and becomes the next drag once this one ends.
final class WindowDragTracker {
    struct Drag {
        let windowID: CGWindowID
        /// Process that owns the window, to tell when its app loses focus.
        let ownerPID: pid_t
        /// Window frame in capture pixels, from the top-left of the captured display.
        var frame: CGRect
        /// Where the cursor grabbed the window, relative to its top-left, in pixels.
        let grabPoint: CGPoint
    }

    private(set) var drag: Drag?
    private(set) var buttonDown = false
    /// The window being pressed on or dragged, from the moment the button goes down.
    var pressedWindowID: CGWindowID? { drag?.windowID ?? candidate?.id }
    /// The dragged window lost focus: another window was pressed, or another app became active.
    /// This app becoming active doesn't count, since the overlay itself belongs to it.
    private(set) var focusLost = false
    /// Window pressed on but not yet moved: its ID, bounds in global points, and grab offset in points.
    private var candidate: (id: CGWindowID, pid: pid_t, bounds: CGRect, grab: CGPoint)?

    /// Advances one display tick.
    /// - Parameters:
    ///   - displayBounds: The captured display's bounds in global points (`CGDisplayBounds`).
    ///   - scale: Capture pixels per point.
    func step(displayBounds: CGRect, scale: CGFloat) {
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        defer { buttonDown = pressed }
        let cursor = globalCursor()

        if pressed, !buttonDown, let hit = Self.window(at: cursor), hit.id != drag?.windowID {
            candidate = (hit.id, hit.pid, hit.bounds, CGPoint(x: cursor.x - hit.bounds.minX, y: cursor.y - hit.bounds.minY))
        }
        if !pressed {
            candidate = nil
        }
        if let drag {
            focusLost = focusLost || candidate != nil || Self.otherAppIsActive(than: drag.ownerPID)
        }

        if drag == nil, let pending = candidate, let bounds = Self.bounds(of: pending.id),
           bounds.origin != pending.bounds.origin, bounds.size == pending.bounds.size {
            drag = Drag(windowID: pending.id,
                        ownerPID: pending.pid,
                        frame: pixels(bounds, displayBounds: displayBounds, scale: scale),
                        grabPoint: CGPoint(x: pending.grab.x * scale, y: pending.grab.y * scale))
            candidate = nil
        } else if let current = drag, let bounds = Self.bounds(of: current.windowID) {
            drag?.frame = pixels(bounds, displayBounds: displayBounds, scale: scale)
        }
    }

    /// Stops following the dragged window. A press on another window is kept, so it can start next.
    func finish() {
        drag = nil
        focusLost = false
    }

    /// Cursor in global CoreGraphics points (top-left origin of the primary display).
    private func globalCursor() -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
    }

    private func pixels(_ bounds: CGRect, displayBounds: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: (bounds.minX - displayBounds.minX) * scale,
               y: (bounds.minY - displayBounds.minY) * scale,
               width: bounds.width * scale,
               height: bounds.height * scale)
    }

    /// Topmost normal window of another app containing `point`.
    private static func window(at point: CGPoint) -> (id: CGWindowID, pid: pid_t, bounds: CGRect)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in list {  // Front to back.
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = bounds(from: info),
                  bounds.contains(point) else { continue }
            return (id, pid, bounds)
        }
        return nil
    }

    /// Whether an app other than `pid` (and other than this one) is the active app.
    private static func otherAppIsActive(than pid: pid_t) -> Bool {
        guard let active = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        return active != pid && active != ProcessInfo.processInfo.processIdentifier
    }

    private static func bounds(of windowID: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]])?.first
        else { return nil }
        return bounds(from: info)
    }

    private static func bounds(from info: [String: Any]) -> CGRect? {
        guard let dictionary = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }
}
#endif
