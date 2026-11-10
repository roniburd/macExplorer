import Foundation

/// Finder's tag colours; raw values are the digits stored after the newline in `_kMDItemUserTags`.
public enum TagColor: Int, Sendable, Codable, CaseIterable { case none = 0, gray, green, purple, blue, yellow, red, orange }

/// One Finder tag. Names compare case-insensitively wherever the app matches tags (`TagIO.normalize`, `TagEdit`).
public struct FileTag: Sendable, Codable, Hashable {
    public var name: String
    public var color: TagColor
    public init(name: String, color: TagColor = .none) { self.name = name; self.color = color }

    /// Finder's seven default tags, in Finder's order.
    public static let standard: [FileTag] = [
        FileTag(name: "Red", color: .red), FileTag(name: "Orange", color: .orange), FileTag(name: "Yellow", color: .yellow),
        FileTag(name: "Green", color: .green), FileTag(name: "Blue", color: .blue), FileTag(name: "Purple", color: .purple),
        FileTag(name: "Gray", color: .gray),
    ]
}
