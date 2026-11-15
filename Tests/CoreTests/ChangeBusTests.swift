import Core
import Foundation
import MacxFS
import XCTest

/// LocalChange routing by directory (S3 Contract note 16).
@MainActor
final class ChangeBusTests: XCTestCase {
    private let dir = URL(filePath: "/var/folders/xy/T/macx-tests-1/files/dst")

    func testRoutesToObserversOfThatDirectoryOnly() {
        let bus = ChangeBus()
        var got: [String] = [], other: [String] = []
        let a = bus.observe(directory: dir) { got.append(contentsOf: $0.added) }
        let b = bus.observe(directory: dir.appending(path: "sub")) { other.append(contentsOf: $0.added) }
        bus.post([LocalChange(directory: dir, added: ["x"]), LocalChange(directory: dir.deletingLastPathComponent(), added: ["y"])])
        XCTAssertEqual(got, ["x"])
        XCTAssertEqual(other, [])
        _ = (a, b)
    }

    func testTrailingSlashAndStandardizationMatch() {
        let bus = ChangeBus()
        var got: [String] = []
        let token = bus.observe(directory: dir) { got.append(contentsOf: $0.added) }
        bus.post([LocalChange(directory: URL(filePath: dir.path, directoryHint: .isDirectory), added: ["slash"])])
        bus.post([LocalChange(directory: URL(filePath: dir.path + "/../dst/./"), added: ["dots"])])
        XCTAssertEqual(got, ["slash", "dots"])
        _ = token
    }

    func testPrivateVarMatchesVarBothWays() {
        let bus = ChangeBus()
        var got: [String] = []
        let token = bus.observe(directory: dir) { got.append(contentsOf: $0.added) }
        bus.post([LocalChange(directory: URL(filePath: "/private" + dir.path, directoryHint: .isDirectory), added: ["p"])])
        let tmp = bus.observe(directory: URL(filePath: "/private/tmp/macx-x")) { got.append(contentsOf: $0.added) }
        bus.post([LocalChange(directory: URL(filePath: "/tmp/macx-x/"), added: ["t"])])
        XCTAssertEqual(got, ["p", "t"])
        XCTAssertEqual(ChangeBus.key(for: URL(filePath: "/private/var")), "/var")
        XCTAssertEqual(ChangeBus.key(for: URL(filePath: "/")), "/")
        XCTAssertEqual(ChangeBus.key(for: URL(filePath: "/private/varx/a")), "/private/varx/a")
        _ = (token, tmp)
    }

    func testMultipleObserversAndCancel() {
        let bus = ChangeBus()
        var log: [String] = []
        let a = bus.observe(directory: dir) { _ in log.append("a") }
        let b = bus.observe(directory: dir) { _ in log.append("b") }
        bus.post([LocalChange(directory: dir)])
        a.cancel()
        bus.post([LocalChange(directory: dir)])
        XCTAssertEqual(log, ["a", "b", "b"])
        _ = b
    }

    /// Tokens unsubscribe at once when cancelled on the main thread, and via a main-actor hop from any other thread;
    /// observeAll tokens the same way.
    func testTokensCancelOnMainAtOnceAndFromOtherThreadsLater() async {
        let bus = ChangeBus()
        var log: [String] = []
        let a = bus.observe(directory: dir) { _ in log.append("a") }
        let all = bus.observeAll { _ in log.append("all") }
        let b = bus.observe(directory: dir) { _ in log.append("b") }
        let allB = bus.observeAll { _ in log.append("allB") }
        a.cancel(); all.cancel()
        bus.post([LocalChange(directory: dir)])
        XCTAssertEqual(log, ["b", "allB"])
        await Task.detached { b.cancel(); allB.cancel() }.value
        for _ in 0..<100 {   // the removals are main-actor tasks: let them run
            log = []
            bus.post([LocalChange(directory: dir)])
            if log.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(log, [], "off-main cancels land on the main actor")
    }
}
