import XCTest
import Darwin
@testable import Core

final class FileOpErrorTests: XCTestCase {
    func testErrnoMapping() {
        XCTAssertEqual(FileOpErrorKind(errno: EACCES, isLockedItem: false), .permissionDenied)
        XCTAssertEqual(FileOpErrorKind(errno: EPERM, isLockedItem: false), .blockedByMacOS)
        XCTAssertEqual(FileOpErrorKind(errno: EPERM, isLockedItem: true), .locked)
        XCTAssertEqual(FileOpErrorKind(errno: EROFS, isLockedItem: false), .readOnlyVolume)
        XCTAssertEqual(FileOpErrorKind(errno: ENOSPC, isLockedItem: false), .noSpace(needed: nil, available: nil))
        XCTAssertEqual(FileOpErrorKind(errno: EBUSY, isLockedItem: false), .inUse)
        XCTAssertEqual(FileOpErrorKind(errno: ETXTBSY, isLockedItem: false), .inUse)
        XCTAssertEqual(FileOpErrorKind(errno: ENAMETOOLONG, isLockedItem: false), .nameTooLong)
        XCTAssertEqual(FileOpErrorKind(errno: ENOENT, isLockedItem: false), .sourceGone)
        guard case .other(let code, let message) = FileOpErrorKind(errno: EIO, isLockedItem: false) else { return XCTFail() }
        XCTAssertEqual(code, EIO)
        XCTAssertFalse(message.isEmpty)
    }

    /// §6.5 table, row by row.
    func testAllowedResolutionsMatchSpecTable() {
        XCTAssertEqual(FileOpErrorKind.permissionDenied.allowedResolutions, [.retry, .skip, .skipAll, .cancel])
        XCTAssertEqual(FileOpErrorKind.blockedByMacOS.allowedResolutions, [.retry, .skip, .cancel])
        XCTAssertEqual(FileOpErrorKind.locked.allowedResolutions, [.unlockAndContinue, .skip, .cancel])
        XCTAssertEqual(FileOpErrorKind.readOnlyVolume.allowedResolutions, [.cancel])
        XCTAssertEqual(FileOpErrorKind.noSpace(needed: 1, available: 0).allowedResolutions, [.retry, .cancel])
        XCTAssertEqual(FileOpErrorKind.inUse.allowedResolutions, [.retry, .skip, .cancel])
        XCTAssertEqual(FileOpErrorKind.nameTooLong.allowedResolutions, [.skip, .cancel])
        XCTAssertEqual(FileOpErrorKind.sourceGone.allowedResolutions, [.skip, .cancel])
        XCTAssertEqual(FileOpErrorKind.intoItself.allowedResolutions, [.skip, .cancel])
        XCTAssertEqual(FileOpErrorKind.changedDuringMove.allowedResolutions, [.retry, .skip, .cancel])
        XCTAssertEqual(FileOpErrorKind.noTrash.allowedResolutions, [.skip, .cancel])
        XCTAssertEqual(FileOpErrorKind.other(code: EIO, message: "x").allowedResolutions, [.retry, .skip, .cancel])
    }

    func testProgressFraction() {
        var p = JobProgress.zero
        XCTAssertNil(p.fraction)
        p.itemsTotal = 4; p.itemsDone = 1
        XCTAssertEqual(p.fraction, 0.25)
        p.bytesTotal = 200; p.bytesDone = 150
        XCTAssertEqual(p.fraction, 0.75)          // bytes win when known
        p.itemsTotal = 0; p.bytesTotal = nil
        XCTAssertEqual(p.fraction, 1)
    }

    func testThroughputMeterKeeps60SamplesAndEstimates() {
        var meter = ThroughputMeter()
        let t0 = ContinuousClock.now
        for i in 0...100 { meter.sample(bytesDone: Int64(i) * 1_000, at: t0 + .milliseconds(100 * i)) }
        XCTAssertEqual(meter.samples.count, 60)
        XCTAssertEqual(meter.samples.last!, 10_000, accuracy: 1)       // 1,000 bytes per 100 ms
        let eta = meter.estimatedRemaining(bytesDone: 100_000, bytesTotal: 150_000)
        XCTAssertEqual(eta!.inSeconds, 5, accuracy: 0.1)
        XCTAssertEqual(meter.estimatedRemaining(bytesDone: 5, bytesTotal: 5), .zero)
    }

    func testPartialNameShapeAndLimit() {
        let job = JobID()
        let name = PartialName.make(for: "report.pdf", job: job)
        XCTAssertEqual(name, ".report.pdf.macx-partial-\(job.short)")
        XCTAssertTrue(PartialName.isPartial(name))
        XCTAssertFalse(PartialName.isPartial("report.pdf"))
        XCTAssertFalse(PartialName.isPartial(".report.pdf.macx-partial-XYZ"))
        let long = PartialName.make(for: String(repeating: "é", count: 127), job: job)   // 254 UTF-8 bytes
        XCTAssertLessThanOrEqual(long.utf8.count, 255)
        XCTAssertTrue(PartialName.isPartial(long))
    }

    func testInteractionProxySuspendsUntilTargetIsSet() async {
        let proxy = InteractionProxy()
        let scripted = ScriptedInteraction(errors: [.retry])
        let snapshot = JobSnapshot.testValue
        let task = Task { await proxy.resolveError(FileOpError(kind: .inUse, url: URL(filePath: "/x")), job: snapshot) }
        try? await Task.sleep(for: .milliseconds(50))
        proxy.setTarget(scripted)
        let answer = await task.value
        XCTAssertEqual(answer, .retry)
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.inUse])
    }

    func testScriptedInteractionDefaults() async {
        let s = ScriptedInteraction()
        let snap = JobSnapshot.testValue
        let pair = ConflictPair(source: .init(url: URL(filePath: "/a"), isDirectory: false, size: 1, modified: .now),
                                destination: .init(url: URL(filePath: "/b"), isDirectory: false, size: 1, modified: .now))
        let info = ConflictInfo(pair: pair, isFolderMerge: false, knownRemaining: 1, pendingPairs: [pair])
        let r = await s.resolveConflict(info, job: snap)
        XCTAssertEqual(r, .one(.skip))
        let e = await s.resolveError(FileOpError(kind: .inUse, url: URL(filePath: "/a")), job: snap)
        XCTAssertEqual(e, .skip)
        let space = await s.confirmInsufficientSpace(SpaceShortfall(needed: 2, available: 1, volumeName: "v"), job: snap)
        XCTAssertFalse(space)
        let noTrash = await s.confirmPermanentDeleteWithoutTrash([URL(filePath: "/a")], job: snap)
        XCTAssertFalse(noTrash)
        XCTAssertEqual(s.askedConflicts().count, 1)
    }

    func testRecordUndoability() {
        let id = FileIdentity(device: 1, inode: 2)
        XCTAssertFalse(JobRecord(id: JobID(), verb: .copying, actions: []).isUndoable)
        XCTAssertTrue(JobRecord(id: JobID(), verb: .copying, actions: [.created(URL(filePath: "/a"), id)]).isUndoable)
        XCTAssertFalse(JobRecord(id: JobID(), verb: .deleting, actions: [.deleted(URL(filePath: "/a"))]).isUndoable)
    }
}

extension JobSnapshot {
    static var testValue: JobSnapshot {
        JobSnapshot(id: JobID(), description: JobDescription(verb: .copying, itemCount: 1, firstItemName: "a",
                                                             sourceFolderName: nil, destinationFolderName: nil),
                    state: .running, progress: .zero, origin: nil, startedAt: .now)
    }
}
