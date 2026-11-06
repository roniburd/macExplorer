import os

/// Shared signposter for the §9 intervals: navigate → firstBatch → firstPaint, enumerate, sort, iconFill, group, thumbnail.
public enum PerfSignposts {
    public static let signposter = OSSignposter(subsystem: "com.macexplorer.app", category: "perf")
    public static let navigate: StaticString = "navigate"
    public static let enumerate: StaticString = "enumerate"
    public static let firstBatch: StaticString = "firstBatch"
    public static let firstPaint: StaticString = "firstPaint"
    public static let sort: StaticString = "sort"
    public static let iconFill: StaticString = "iconFill"
    public static let group: StaticString = "group"          // Group by partition (P2-09)
    public static let thumbnail: StaticString = "thumbnail"  // one Icons-view thumbnail request (P2-17)
}
