import Foundation

/// Per-window back/forward stacks (§5.2). URLs are compared by standardized path, ignoring a trailing slash.
public struct NavigationHistory: Sendable, Equatable {
    /// Maximum entries kept in `backList`; the oldest are dropped first.
    public static let limit = 100

    public init(current: URL) {
        self.current = current
        backList = []
        forwardList = []
    }

    public private(set) var current: URL
    public private(set) var backList: [URL]       // most recent last
    public private(set) var forwardList: [URL]    // next first

    /// Clears forwardList; ignores visiting current.
    public mutating func visit(_ url: URL) {
        guard Self.key(url) != Self.key(current) else { return }
        pushBack(current)
        current = url
        forwardList.removeAll()
    }

    public mutating func goBack() -> URL? {
        jump(toBackIndex: backList.count - 1)
    }

    public mutating func goForward() -> URL? {
        jump(toForwardIndex: 0)
    }

    /// `index` into `backList` (0 = oldest). Entries after it move to the front of `forwardList`.
    public mutating func jump(toBackIndex index: Int) -> URL? {
        guard backList.indices.contains(index) else { return nil }
        let target = backList[index]
        forwardList = Array(backList[(index + 1)...]) + [current] + forwardList
        backList.removeSubrange(index...)
        current = target
        return target
    }

    /// `index` into `forwardList` (0 = next). Entries before it move onto `backList`.
    public mutating func jump(toForwardIndex index: Int) -> URL? {
        guard forwardList.indices.contains(index) else { return nil }
        let target = forwardList[index]
        pushBack(current)
        for url in forwardList[..<index] { pushBack(url) }
        forwardList.removeSubrange(...index)
        current = target
        return target
    }

    public var canGoBack: Bool { !backList.isEmpty }
    public var canGoForward: Bool { !forwardList.isEmpty }

    private mutating func pushBack(_ url: URL) {
        backList.append(url)
        if backList.count > Self.limit { backList.removeFirst(backList.count - Self.limit) }
    }

    private static func key(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
