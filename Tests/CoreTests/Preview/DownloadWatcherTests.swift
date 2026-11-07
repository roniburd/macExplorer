import XCTest
@testable import Core

final class DownloadWatcherTests: XCTestCase {
    let url = URL(filePath: "/tmp/macx-tests-none/cloud.txt")   // never touched: the fake downloader has no file access

    func states(_ d: FakeUbiquitousDownloader, timeout: Duration = .seconds(5)) async -> [DownloadState] {
        var out: [DownloadState] = []
        for await s in DownloadWatcher.download(url, using: d, pollInterval: .milliseconds(10), timeout: timeout) { out.append(s) }
        return out
    }

    func testDownloadsThenDone() async {
        let fake = FakeUbiquitousDownloader(datalessPolls: 2)
        let result = await states(fake)
        XCTAssertEqual(result, [.downloading, .done])
        XCTAssertEqual(fake.started(), [url])
    }

    func testStartFailure() async {
        let result = await states(FakeUbiquitousDownloader(failStart: true))
        XCTAssertEqual(result, [.downloading, .failed])
    }

    func testTimeout() async {
        let result = await states(FakeUbiquitousDownloader(datalessPolls: .max), timeout: .milliseconds(60))
        XCTAssertEqual(result, [.downloading, .timedOut])
    }
}
