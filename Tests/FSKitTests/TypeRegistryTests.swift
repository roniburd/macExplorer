import Foundation
import MacxFS
import XCTest

final class TypeRegistryTests: XCTestCase {
    func testFixedIndices() {
        let r = TypeRegistry()
        XCTAssertEqual(r.type(at: TypeRegistry.folderIndex), .folder)
        XCTAssertEqual(r.type(at: TypeRegistry.dataIndex), .data)
        XCTAssertEqual(r.type(at: TypeRegistry.symlinkIndex), .symbolicLink)
        XCTAssertEqual(r.index(forExtension: "", isDirectory: false), TypeRegistry.dataIndex)
        XCTAssertEqual(r.index(forExtension: "", isDirectory: true), TypeRegistry.folderIndex)
    }

    func testInterningIsCaseInsensitiveAndStable() {
        let r = TypeRegistry()
        let a = r.index(forExtension: "txt", isDirectory: false)
        XCTAssertEqual(r.index(forExtension: "TXT", isDirectory: false), a)
        XCTAssertEqual(r.type(at: a), .plainText)
        let v = r.version
        _ = r.index(forExtension: "txt", isDirectory: false)
        XCTAssertEqual(r.version, v)
    }

    func testPackagesAndApplications() {
        let r = TypeRegistry()
        let app = r.index(forExtension: "app", isDirectory: true)
        XCTAssertTrue(r.isPackage(app))
        XCTAssertTrue(r.isApplication(app))
        let rtfd = r.index(forExtension: "rtfd", isDirectory: true)
        XCTAssertTrue(r.isPackage(rtfd))
        XCTAssertFalse(r.isApplication(rtfd))
        XCTAssertEqual(r.index(forExtension: "2", isDirectory: true), TypeRegistry.folderIndex, "v1.2 is a folder")
        XCTAssertFalse(r.isPackage(r.index(forExtension: "app", isDirectory: false)), "a file named x.app is not a package")
    }

    func testUnknownExtensionGetsDynamicType() {
        let r = TypeRegistry()
        let i = r.index(forExtension: "macxunknownext", isDirectory: false)
        XCTAssertNotEqual(i, TypeRegistry.dataIndex)
        XCTAssertTrue(r.type(at: i).identifier.hasPrefix("dyn."))
    }

    func testKindRanksFollowLocalizedDescriptionAndRecomputeOnGrowth() {
        let r = TypeRegistry()
        let txt = r.index(forExtension: "txt", isDirectory: false)
        let pdf = r.index(forExtension: "pdf", isDirectory: false)
        let first = r.kindRanks()
        XCTAssertEqual(first.version, r.version)
        let byRank = (0..<UInt16(first.ranks.count)).sorted { first.ranks[Int($0)] < first.ranks[Int($1)] }
        let descriptions = byRank.map { r.localizedDescription($0) }
        XCTAssertEqual(descriptions, descriptions.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertNotEqual(first.ranks[Int(txt)], first.ranks[Int(pdf)])
        _ = r.index(forExtension: "png", isDirectory: false)
        XCTAssertEqual(r.kindRanks().ranks.count, first.ranks.count + 1)
    }

    func testConcurrentInterningIsConsistent() {
        let r = TypeRegistry()
        let exts = ["txt", "pdf", "png", "jpg", "swift", "md", "zip", "json"]
        let results = Recorder<[UInt16]>()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            results.append(exts.map { r.index(forExtension: Substring($0), isDirectory: false) })
        }
        XCTAssertEqual(Set(results.values).count, 1)
    }
}
