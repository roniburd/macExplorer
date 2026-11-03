/// Paces loading presentation to at most one reset per display frame (§4.3 loading-state presentation).
public protocol FramePacer: Sendable {
    /// Returns at the next frame boundary (or when the calling task is cancelled).
    func nextFrame() async
}

/// A fixed-interval pacer (8 ms ≈ one 120 Hz frame).
public struct TimerFramePacer: FramePacer {
    public let interval: Duration
    public init(interval: Duration = .milliseconds(8)) { self.interval = interval }
    public func nextFrame() async { try? await Task.sleep(for: interval) }
}
