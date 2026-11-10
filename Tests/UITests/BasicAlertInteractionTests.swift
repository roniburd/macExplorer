import XCTest
@testable import UI
import Core

final class BasicAlertInteractionTests: XCTestCase {
    private let url = URL(filePath: "/tmp/macx-tests-x/a.txt")

    private func pair() -> ConflictPair {
        let item = ItemSummary(url: url, isDirectory: false, size: 1, modified: Date(timeIntervalSince1970: 0))
        return ConflictPair(source: item, destination: item)
    }

    func testConflictPromptButtonsAndAnswers() {
        let prompt = BasicAlertInteraction.conflictPrompt(ConflictInfo(pair: pair(), isFolderMerge: false, knownRemaining: 0, pendingPairs: []))
        XCTAssertEqual(prompt.buttons.map(\.title), ["Replace", "Keep Both", "Skip", "Cancel"])
        XCTAssertEqual(prompt.buttons.map(\.answer), [.one(.replace), .one(.keepBoth), .one(.skip), .cancelJob])
        XCTAssertTrue(prompt.message.contains("a.txt"))
        let merge = BasicAlertInteraction.conflictPrompt(ConflictInfo(pair: pair(), isFolderMerge: true, knownRemaining: 0, pendingPairs: []))
        XCTAssertEqual(merge.buttons.map(\.answer), [.one(.merge), .one(.keepBoth), .one(.skip), .cancelJob])
    }

    func testErrorPromptOffersExactlyTheAllowedResolutions() {
        for kind: FileOpErrorKind in [.permissionDenied, .locked, .readOnlyVolume, .sourceGone, .other(code: 5, message: "EIO")] {
            let prompt = BasicAlertInteraction.errorPrompt(FileOpError(kind: kind, url: url))
            XCTAssertEqual(prompt.buttons.map(\.answer), kind.allowedResolutions, "\(kind)")
            XCTAssertFalse(prompt.buttons.contains { $0.title.isEmpty })
            XCTAssertTrue(prompt.message.contains("a.txt"))
        }
    }

    func testSpaceAndNoTrashPrompts() {
        let space = BasicAlertInteraction.spacePrompt(SpaceShortfall(needed: 10, available: 5, volumeName: "Disk"))
        XCTAssertEqual(space.buttons.map(\.answer), [true, false])
        let noTrash = BasicAlertInteraction.noTrashPrompt([url])
        XCTAssertEqual(noTrash.buttons.map(\.answer), [true, false])
        XCTAssertEqual(noTrash.buttons.map(\.title), ["Delete", "Cancel"])
    }

    func testAnswerForResponseFallsBackToTheLastButton() {
        let prompt = BasicAlertInteraction.noTrashPrompt([url])
        XCTAssertEqual(prompt.answer(forButtonIndex: 0), true)
        XCTAssertEqual(prompt.answer(forButtonIndex: 1), false)
        XCTAssertEqual(prompt.answer(forButtonIndex: 7), false, "an unexpected response is the cancel button")
    }
}

final class UndoActionNamesTests: XCTestCase {
    func testEveryVerbHasALocalizedName() {
        let verbs: [JobVerb] = [.copying, .moving, .trashing, .deleting, .duplicating, .creating, .renaming, .makingAlias,
                                .makingSymlink, .changingPermissions, .changingAttributes, .tagging, .undoing, .redoing]
        for verb in verbs {
            let name = UndoActionNames.name(for: JobDescription(verb: verb, itemCount: 1, firstItemName: "a", sourceFolderName: nil,
                                                               destinationFolderName: nil))
            XCTAssertFalse(name.isEmpty)
            XCTAssertNotEqual(name, verb.rawValue, "localized, not the raw verb")
        }
        XCTAssertEqual(UndoActionNames.name(for: JobDescription(verb: .copying, itemCount: 2, firstItemName: nil,
                                                                sourceFolderName: nil, destinationFolderName: nil)), "Copy")
        XCTAssertEqual(UndoActionNames.name(for: JobDescription(verb: .trashing, itemCount: 2, firstItemName: nil,
                                                                sourceFolderName: nil, destinationFolderName: nil)), "Move to Trash")
        XCTAssertEqual(UndoActionNames.name(for: JobDescription(verb: .tagging, itemCount: 2, firstItemName: nil,
                                                                sourceFolderName: nil, destinationFolderName: nil)), "Tag")
    }
}
