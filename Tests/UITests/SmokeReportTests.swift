import XCTest
@testable import UI
import MacxFixtures

final class SmokeReportTests: XCTestCase {
    func testRoundTripsThroughFile() throws {
        let sandbox = try Sandbox()
        addTeardownBlock { sandbox.destroy() }
        let tmp = sandbox.root

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
