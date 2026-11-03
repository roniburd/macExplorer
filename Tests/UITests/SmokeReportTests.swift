import XCTest
@testable import UI

final class SmokeReportTests: XCTestCase {
    func testRoundTripsThroughFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "macx-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }

        let report = SmokeReport(windowTitles: ["files"], root: "/tmp/macx-tests-x/files/", processID: 42)
        let file = tmp.appending(path: SmokeReport.fileName)
        try report.write(to: file)
        XCTAssertEqual(try SmokeReport.read(from: file), report)
    }

    func testFileNameAndJSONKeys() throws {
        XCTAssertEqual(SmokeReport.fileName, "smoke.json")
        let data = try JSONEncoder().encode(SmokeReport(windowTitles: ["a"], root: nil, processID: 1))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["windowTitles", "processID"], "nil root is omitted")
    }
}
