import simd

/// Damped spring that makes the jello overshoot: when a drag speeds up, slows down or is let go,
/// the content keeps going, then swings back and settles like a decaying sine wave.
///
/// Driven by the cursor while the mouse button is held, since the dragged content moves with it.
/// Keeps a short history of offsets so each jello row can replay the wobble at its own delay.
struct JelloSpring {
    /// Wobbles per second.
    static let frequency = 3.0
    /// 0 wobbles forever; 1 settles without overshooting.
    static let damping = 0.25
    /// How much of a change in drag speed turns into wobble.
    static let gain = 1.0

    /// Offsets in pixels, newest first; index i is the offset from i ticks ago.
    private(set) var history: [SIMD2<Float>] = []

    private var offset = SIMD2<Double>.zero
    private var velocity = SIMD2<Double>.zero
    private var lastCursor: SIMD2<Double>?
    private var dragVelocity = SIMD2<Double>.zero

    /// Advances one display tick.
    /// - Parameters:
    ///   - cursor: Cursor position in frame pixels.
    ///   - dragging: Whether the mouse button is held.
    ///   - historyLength: Ticks of history to keep (the longest jello delay, plus one).
    ///   - limit: Largest offset allowed, in pixels.
    mutating func step(cursor: SIMD2<Double>, dragging: Bool, dt: Double, historyLength: Int, limit: Double) {
        // Smoothed drag velocity; mouse updates are jittery tick to tick.
        let rawVelocity = dragging ? (cursor - (lastCursor ?? cursor)) / dt : .zero
        let newDragVelocity = dragVelocity + (rawVelocity - dragVelocity) * 0.3
        lastCursor = cursor

        // Slowing down pushes the content forward (overshoot); speeding up pushes it back.
        velocity -= (newDragVelocity - dragVelocity) * Self.gain
        dragVelocity = newDragVelocity

        let omega = 2 * Double.pi * Self.frequency
        velocity += (-omega * omega * offset - 2 * Self.damping * omega * velocity) * dt
        offset += velocity * dt
        offset = simd_clamp(offset, SIMD2(repeating: -limit), SIMD2(repeating: limit))

        history.insert(SIMD2<Float>(offset), at: 0)
        if history.count > historyLength {
            history.removeLast(history.count - historyLength)
        }
    }

    mutating func reset() {
        self = JelloSpring()
    }
}
