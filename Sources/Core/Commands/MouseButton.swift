import Foundation

/// An extra mouse button that can be bound to a command. `number` is AppKit's `NSEvent.buttonNumber` (3 = the
/// "back" side button, 4 = "forward"). Buttons 0–2 (left, right, middle) are never bindable.
public struct MouseButton: Hashable, Sendable, Comparable, CustomStringConvertible {
    public static let bindable = 3...8
    public let number: Int

    public init?(number: Int) {
        guard Self.bindable.contains(number) else { return nil }
        self.number = number
    }

    /// "mouse4" (case-insensitive) = buttonNumber 3. Mice label their buttons from 1, so text is number + 1.
    public init?(parsing text: String) {
        let lower = text.lowercased()
        guard lower.hasPrefix("mouse"), let label = Int(lower.dropFirst(5)) else { return nil }
        self.init(number: label - 1)
    }

    public var description: String { "mouse\(number + 1)" }
    public static func < (a: MouseButton, b: MouseButton) -> Bool { a.number < b.number }
}

extension MouseButton: Codable {
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let button = MouseButton(parsing: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad mouse button '\(text)'"))
        }
        self = button
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
