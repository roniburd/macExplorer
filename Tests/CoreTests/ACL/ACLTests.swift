import XCTest
import Darwin
import Darwin.membership
@testable import Core
import MacxFS
import MacxFixtures

/// ACL model, read/write and the undoable `.acl` attribute edit (P4-14). Every file is inside the test's sandbox.
final class ACLTests: FileOpsTestCase {
    private var me: ACLPrincipal { PrincipalDirectory.resolve(user: NSUserName())! }
    private func onLane<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await LanePool().perform(on: .unknown) { _ in try body() }
    }

    func testPermissionBitsAndPresets() {
        XCTAssertEqual(ACLPermissions.readData.rawValue, 1)
        XCTAssertEqual(ACLPermissions.changeOwner.rawValue, 1 << 12)
        XCTAssertEqual(ACLPermissions.all.count, 13)
        XCTAssertEqual(ACLPermissions.fullControlPreset.rawValue, (1 << 13) - 1)
        XCTAssertEqual(ACLPermissions.readOnlyPreset, [.readData, .execute, .readAttributes, .readExtAttributes, .readSecurity])
        XCTAssertTrue(ACLPermissions.readWritePreset.isSuperset(of: .readOnlyPreset))
        XCTAssertTrue(ACLPermissions.readWritePreset.isSuperset(of: [.writeData, .appendData, .writeAttributes, .writeExtAttributes, .delete, .deleteChild]))
        XCTAssertFalse(ACLPermissions.readWritePreset.contains(.writeSecurity))
        XCTAssertEqual(ACLInheritance.all.count, 4)
        let entry = ACLEntry(kind: .deny, principal: PrincipalDirectory.everyone, permissions: [.delete], inheritance: [.fileInherit])
        XCTAssertEqual(try JSONDecoder().decode(ACLEntry.self, from: JSONEncoder().encode(entry)), entry)
    }

    func testPrincipalResolution() throws {
        guard case .user(let name, let uuid) = me else { return XCTFail() }
        XCTAssertEqual(name, NSUserName())
        var uid: uid_t = 0; var type: Int32 = 0
        var u = uuid.uuid
        XCTAssertEqual(withUnsafeBytes(of: &u) { mbr_uuid_to_id($0.bindMemory(to: UInt8.self).baseAddress!, &uid, &type) }, 0)
        XCTAssertEqual(uid, getuid())
        XCTAssertEqual(PrincipalDirectory.everyone, .group(name: "everyone", uuid: UUID(uuidString: "ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C")!))
        XCTAssertNil(PrincipalDirectory.resolve(user: "macx-no-such-user-\(UUID().uuidString.prefix(6))"))
        XCTAssertNotNil(PrincipalDirectory.resolve(group: "staff"))
        XCTAssertEqual(PrincipalDirectory.principal(for: uuid), me)
        let orphan = UUID()
        XCTAssertEqual(PrincipalDirectory.principal(for: orphan).uuid, orphan)
    }

    func testWriteReadAndCanonicalOrder() async throws {
        let a = try file("a.txt")
        let me = self.me
        let allow = ACLEntry(kind: .allow, principal: me, permissions: .readWritePreset)
        let deny = ACLEntry(kind: .deny, principal: PrincipalDirectory.everyone, permissions: [.delete])
        try await onLane { try ACLIO.write(explicit: [allow, deny], to: a) }
        let read = try await onLane { try ACLIO.read(a) }
        XCTAssertEqual(read, [deny, allow])                                  // explicit deny before allow
        XCTAssertEqual(ACLIO.canonicalOrder([allow, deny]), [deny, allow])
        let text = try await onLane { try ACLIO.text(a) }
        XCTAssertTrue(text.contains("everyone") && text.contains("deny"))
        try await onLane { try ACLIO.restore(text: "", to: a) }
        let check1 = try await onLane { try ACLIO.read(a) }
        XCTAssertEqual(check1, [])
        let check2 = try await onLane { try ACLIO.text(a) }
        XCTAssertEqual(check2, "")
        try await onLane { try ACLIO.restore(text: text, to: a) }
        let check3 = try await onLane { try ACLIO.read(a) }
        XCTAssertEqual(check3, [deny, allow])
    }

    func testReadMissingItemThrowsENOENT() async throws {
        let missing = url("missing.txt")
        do {
            _ = try await onLane { try ACLIO.read(missing) }
            XCTFail("expected ENOENT")
        } catch let e as ACLIOError {
            XCTAssertEqual(e.code, ENOENT)
        }
    }

    func testInheritedEntriesArePreservedOnWrite() async throws {
        let d = try dir("d")
        let me = self.me
        let inheritable = ACLEntry(kind: .allow, principal: me, permissions: .readOnlyPreset, inheritance: [.fileInherit])
        try await onLane { try ACLIO.write(explicit: [inheritable], to: d) }
        let child = try file("d/child.txt")                    // created after: inherits
        let inherited = try await onLane { try ACLIO.read(child) }
        XCTAssertEqual(inherited.count, 1); XCTAssertTrue(inherited.first?.isInherited ?? false)
        let explicit = ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: [.readData])
        try await onLane { try ACLIO.write(explicit: [explicit], to: child) }
        let after = try await onLane { try ACLIO.read(child) }
        XCTAssertEqual(after.map(\.isInherited), [false, true])
    }

    func testAttributeJobAndUndo() async throws {
        let a = try file("a.txt")
        let entry = ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: .readOnlyPreset)
        let (queue, _) = makeQueue()
        let outcome = try await run(.setAttributes([a], .acl([entry])), on: queue)
        let check4 = try await onLane { try ACLIO.read(a) }
        XCTAssertEqual(check4, [entry])
        guard case .attributesChanged(_, let old, let new)? = outcome.record.actions.first else { return XCTFail() }
        XCTAssertEqual(old.acl, ""); XCTAssertNotNil(new.acl); XCTAssertNotEqual(new.acl, "")
        _ = try await run(.undo(outcome.record), on: queue)
        let check5 = try await onLane { try ACLIO.read(a) }
        XCTAssertEqual(check5, [])
    }

    func testUnchangedACLRecordsNothing() async throws {
        let a = try file("a.txt")
        let (queue, _) = makeQueue()
        let outcome = try await run(.setAttributes([a], .acl([])), on: queue)
        XCTAssertEqual(outcome.record.actions, [])
    }

    func testUndoSkipsWhenACLChangedSince() async throws {
        let a = try file("a.txt")
        let (queue, _) = makeQueue()
        let outcome = try await run(.setAttributes([a], .acl([ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: [.readData])])), on: queue)
        let me = self.me
        try await onLane { try ACLIO.write(explicit: [ACLEntry(kind: .deny, principal: me, permissions: [.delete])], to: a) }
        let undo = try await run(.undo(outcome.record), on: queue)
        XCTAssertEqual(undo.skipped.map(\.reason), [.changedDuringMove])
        let check6 = try await onLane { try ACLIO.read(a) }
        XCTAssertEqual(check6, [ACLEntry(kind: .deny, principal: me, permissions: [.delete])])
    }

    func testLockedItemIsAsked() async throws {
        let a = try file("a.txt")
        try sandbox.setFlags("a.txt", UInt32(UF_IMMUTABLE))
        let interaction = ScriptedInteraction(errors: [.skip])
        let (queue, _) = makeQueue(interaction: interaction)
        _ = try await run(.setAttributes([a], .acl([ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: [.readData])])), on: queue)
        XCTAssertEqual(interaction.askedErrors().map(\.kind), [.locked])
    }

    // MARK: lockout (review finding: "deny everyone read" hid the ACL from its owner and broke undo)

    func testLockoutDetection() async throws {
        let me = self.me
        let staff = try XCTUnwrap(PrincipalDirectory.resolve(group: "staff"))
        let results = try await onLane { () -> [Bool] in
            [
                ACLEntry(kind: .deny, principal: PrincipalDirectory.everyone, permissions: .readOnlyPreset).locksOutCurrentUser,
                ACLEntry(kind: .deny, principal: me, permissions: [.writeSecurity]).locksOutCurrentUser,
                ACLEntry(kind: .deny, principal: staff, permissions: [.readSecurity]).locksOutCurrentUser,
                ACLEntry(kind: .deny, principal: PrincipalDirectory.everyone, permissions: [.delete]).locksOutCurrentUser,
                ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: .fullControlPreset).locksOutCurrentUser,
                ACLEntry(kind: .deny, principal: .user(name: "orphan", uuid: UUID()), permissions: [.readSecurity]).locksOutCurrentUser,
            ]
        }
        XCTAssertEqual(results, [true, true, true, false, false, false])
    }

    func testUnreadableACLIsNeverSnapshotAsNone() async throws {
        let a = try file("a.txt")
        // Deny the owner readsecurity (and delete, so the sandbox teardown must clear an ACL it can't read).
        let lock = ACLEntry(kind: .deny, principal: PrincipalDirectory.everyone, permissions: [.readSecurity, .delete])
        try await onLane { try ACLIO.write(explicit: [lock], to: a) }
        do {
            _ = try await onLane { try ACLIO.read(a) }
            XCTFail("expected EACCES")
        } catch let e as ACLIOError {
            XCTAssertEqual(e.code, EACCES)
        }
        let snap = try await onLane { AttributeJobs.snapshot(a, for: .acl([])) }
        XCTAssertNil(snap, "an unreadable ACL fails the item, never reads as \"\"")
        let interaction = ScriptedInteraction(errors: [.skip])
        let (queue, _) = makeQueue(interaction: interaction)
        let outcome = try await run(.setAttributes([a], .acl([])), on: queue)
        XCTAssertEqual(outcome.record.actions, [])
        XCTAssertEqual(interaction.askedErrors().count, 1)
    }

    func testEditThatHidesTheACLIsRolledBack() async throws {
        let a = try file("a.txt")
        let interaction = ScriptedInteraction(errors: [.skip])
        let (queue, _) = makeQueue(interaction: interaction)
        let outcome = try await run(.setAttributes([a], .acl([ACLEntry(kind: .deny, principal: PrincipalDirectory.everyone,
                                                                         permissions: .readOnlyPreset)])), on: queue)
        XCTAssertEqual(outcome.record.actions, [], "nothing recorded: the edit was put back")
        XCTAssertEqual(interaction.askedErrors().count, 1)
        let after = try await onLane { try ACLIO.read(a) }
        XCTAssertEqual(after, [], "the previous (empty) ACL is restored and readable")
    }

    func testAllPrincipalsListsCurrentUserAndStaff() async {
        let all = await PrincipalDirectory.all(lanes: LanePool())
        XCTAssertTrue(all.contains(me))
        XCTAssertTrue(all.contains(PrincipalDirectory.everyone))
        XCTAssertTrue(all.contains { if case .group(let n, _) = $0 { n == "staff" } else { false } })
        XCTAssertFalse(all.contains { if case .user(let n, _) = $0 { n == "root" } else { false } })   // uid < 500 excluded
    }
}
