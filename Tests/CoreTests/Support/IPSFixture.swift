import Foundation

enum IPSFixture {
    static func make(bundleID: String = "com.macexplorer.app", timestamp: String = "2026-11-04 10:11:12.00 -0800",
                     bugType: String = "309", appVersion: String = "0.4.0", build: String = "812",
                     home: String = "/Users/tester", frameCount: Int = 30) -> String {
        let header: [String: Any] = [
            "app_name": "macExplorer", "timestamp": timestamp, "app_version": appVersion, "build_version": build,
            "bundleID": bundleID, "bug_type": bugType, "os_version": "macOS 26.1 (25B78)", "name": "macExplorer",
        ]
        let frames: [[String: Any]] = (0..<frameCount).map { i in
            i % 3 == 2 ? ["imageOffset": 4096 + i, "imageIndex": 1]
                       : ["imageOffset": 1000 + i, "symbol": "Core.Thing.method\(i)()", "symbolLocation": i, "imageIndex": 0]
        }
        let body: [String: Any] = [
            "procPath": "\(home)/Applications/MacExplorer.app/Contents/MacOS/macExplorer",
            "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "subtype": "KERN_INVALID_ADDRESS at 0x0"],
            "termination": ["indicator": "Segmentation fault: 11", "namespace": "SIGNAL", "code": 11],
            "faultingThread": 1,
            "threads": [["frames": [["imageOffset": 1, "imageIndex": 0]]], ["triggered": true, "frames": frames]],
            "usedImages": [
                ["name": "macExplorer", "path": "\(home)/Applications/MacExplorer.app/Contents/MacOS/macExplorer"],
                ["name": "libsystem_kernel.dylib", "path": "/usr/lib/system/libsystem_kernel.dylib"],
            ],
        ]
        func json(_ o: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), encoding: .utf8)! }
        return json(header) + "\n" + json(body)
    }
}
