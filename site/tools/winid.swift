// Prints the on-screen window IDs of an app (default: macExplorer) for `screencapture -l <id>`.
//   swiftc -O site/tools/winid.swift -o /tmp/winid && /tmp/winid macExplorer
import CoreGraphics

let owner = CommandLine.arguments.dropFirst().first ?? "macExplorer"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == owner
    && (w[kCGWindowLayer as String] as? Int) == 0 {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(w[kCGWindowNumber as String] ?? "", "pid", w[kCGWindowOwnerPID as String] ?? "",
          "\(b["Width"] ?? "")x\(b["Height"] ?? "")", w[kCGWindowName as String] ?? "")
}
