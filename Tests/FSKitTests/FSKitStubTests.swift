// P1-01 stub: a test target needs at least one test to load. P1-03 deletes this file when it adds real tests.
import XCTest
import MacxFS
import CFSKit

final class FSKitStubTests: XCTestCase {
    func testTargetLoads() {
        XCTAssertNotNil(Bundle.module.url(forResource: "Corpus/sort-allowed-divergences", withExtension: "json"),
                        "the .copy(\"Corpus\") resource is bundled")
    }
}
