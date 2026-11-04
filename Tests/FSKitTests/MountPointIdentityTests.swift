import Foundation
import MacxFixtures
import MacxFS
import XCTest

/// QA round 1: folders that are mount points report their volume's root ID (2 on every APFS/HFS+ volume), so two
/// of them in one folder used to share an identity and one row replaced the other. All writes stay in a sandbox;
/// the images are created, mounted -nobrowse inside it and detached by these tests.
final class MountPointIdentityTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
    }

    private func identities(_ entries: [(String, Entry)]) -> [String: RowID] {
        var store = EntryStore(identityMode: .objectID)
        var batch = Batch(generation: .initial)
        for (name, entry) in entries { Array(name.utf8).withUnsafeBufferPointer { batch.append(entry, nameBytes: $0) } }
        store.append(batch)
        return Dictionary(uniqueKeysWithValues: (0..<store.count).map { (store.name(UInt32($0)), store.identity(UInt32($0))) })
    }

    func testTwoMountPointsInOneFolderKeepDistinctIdentities() async throws {
        try XCTSkipUnless(DiskImage.isAvailable, "hdiutil not available")
        let one = try DiskImage.create(in: sandbox, format: .hfsPlus, sizeMB: 8)
        defer { try? one.detach() }
        let two = try DiskImage.create(in: sandbox, format: .apfs, sizeMB: 16)
        defer { try? two.detach() }
        try sandbox.createFile("plain.txt")
        let names = [one.relativeMountPath, two.relativeMountPath, "plain.txt"]
        let root = sandbox.root

        let items = try await LanePool().perform(on: .unknown) { ctx in
            try ItemReader.read(names: names, in: root, generation: .initial, types: .shared, context: ctx)
        }
        XCTAssertEqual(items.batch.count, 3, "\(items.errors) \(items.missing)")
        let patched = identities((0..<items.batch.count).map { (items.batch.name(at: $0), items.batch.entries[$0]) })
        XCTAssertEqual(Set(patched.values).count, 3, "item reads: every row has its own identity \(patched)")

        let listed = try await readAll(root)
        let fresh = identities(listed.entries.filter { names.contains($0.key) }.map { ($0.key, $0.value.0) })
        XCTAssertEqual(Set(fresh.values).count, 3, "bulk listing: every row has its own identity \(fresh)")
        XCTAssertEqual(fresh, patched, "a watcher patch keeps the identity the listing gave the row")

        var fallback = ReadOptions()
        fallback.forceFallback = true
        let slow = try await readAll(root, options: fallback)
        let slowIDs = identities(slow.entries.filter { names.contains($0.key) }.map { ($0.key, $0.value.0) })
        XCTAssertEqual(slowIDs, fresh, "the fallback reader agrees")
    }
}
