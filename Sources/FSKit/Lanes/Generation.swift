/// Monotonic read generation (§4.2). A result is applied only if its generation is still current.
public struct Generation: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let raw: UInt64
    public static let initial = Generation(raw: 0)
    private init(raw: UInt64) { self.raw = raw }
    public func next() -> Generation { Generation(raw: raw &+ 1) }
    public static func < (lhs: Generation, rhs: Generation) -> Bool { lhs.raw < rhs.raw }
    public var description: String { "gen\(raw)" }
}
