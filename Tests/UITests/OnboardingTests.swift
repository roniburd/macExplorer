import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

/// §5.9 first-launch sheet: Full Disk Access and fn-key notes with System Settings deep links (recorded, never opened,
/// in sandboxed runs), shown once.
@MainActor
final class OnboardingTests: XCTestCase {
    override func setUp() async throws {
        RecordingURLOpener.shared.reset()
    }

    func testShownOnlyOnFirstLaunchAndNotWithSkipOnboarding() {
        let settings = Settings(storage: InMemorySettingsStorage())
        var options = LaunchOptions()
        XCTAssertTrue(OnboardingSheet.shouldShow(settings: settings, options: options))
        options.skipOnboarding = true
        XCTAssertFalse(OnboardingSheet.shouldShow(settings: settings, options: options))
        options.skipOnboarding = false
        settings.onboardingCompleted = true
        XCTAssertFalse(OnboardingSheet.shouldShow(settings: settings, options: options))
    }

    func testSandboxedRunsRecordExternalURLsInsteadOfOpeningThem() {
        var options = LaunchOptions()
        options.stateDirectory = URL(filePath: "/tmp/macx-tests-x/state", directoryHint: .isDirectory)
        XCTAssertTrue(ExternalOpeners.opener(for: options) === RecordingURLOpener.shared)
        options = LaunchOptions()
        options.fakeLaunchServices = true
        XCTAssertTrue(ExternalOpeners.opener(for: options) === RecordingURLOpener.shared)
        XCTAssertTrue(ExternalOpeners.opener(for: LaunchOptions()) is WorkspaceURLOpener)
    }

    func testDeepLinksAreTheSystemSettingsPanes() {
        XCTAssertEqual(SystemSettingsLinks.privacyAllFiles.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        XCTAssertEqual(OnboardingLinks.keyboard.absoluteString, "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    func testButtonsOpenTheirSettingsPaneWithoutFinishing() {
        let settings = Settings(storage: InMemorySettingsStorage())
        var finished = 0
        let flow = OnboardingFlow(settings: settings, opener: RecordingURLOpener.shared) { finished += 1 }
        flow.openPrivacySettings()
        flow.openKeyboardSettings()
        XCTAssertEqual(RecordingURLOpener.shared.opened, [SystemSettingsLinks.privacyAllFiles, OnboardingLinks.keyboard])
        XCTAssertEqual(finished, 0, "the sheet stays up so the other note can still be read")
        XCTAssertFalse(settings.onboardingCompleted)
    }

    func testContinueMarksOnboardingCompletedOnce() {
        let settings = Settings(storage: InMemorySettingsStorage())
        var finished = 0
        let flow = OnboardingFlow(settings: settings, opener: RecordingURLOpener.shared) { finished += 1 }
        flow.finish()
        flow.finish()
        XCTAssertTrue(settings.onboardingCompleted)
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(RecordingURLOpener.shared.opened, [])
    }

    func testTextsNameFullDiskAccessAndFnKeys() {
        XCTAssertTrue(OnboardingTexts.fnKeys.contains("Hold fn"))
        XCTAssertTrue(OnboardingTexts.fnKeys.contains("Use F1, F2, etc. keys as standard function keys"))
        XCTAssertTrue(OnboardingTexts.fullDiskAccessTitle.contains("Full Disk Access"))
        XCTAssertEqual(OnboardingTexts.openPrivacy, "Open Privacy & Security")
        XCTAssertEqual(OnboardingTexts.continueWithout, "Continue Without Full Disk Access")
    }

    func testPresentAttachesASheetThatContinueDismisses() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        let window = try XCTUnwrap(controller.window)
        let flow = OnboardingSheet.present(on: window, context: h.context)
        try await h.waitUntil("sheet attached") { window.attachedSheet != nil }
        XCTAssertEqual(window.attachedSheet?.accessibilityIdentifier(), AXID.onboardingSheet)
        flow.openPrivacySettings()
        XCTAssertEqual(RecordingURLOpener.shared.opened, [SystemSettingsLinks.privacyAllFiles], "sandboxed: recorded, never opened")
        XCTAssertNotNil(window.attachedSheet)
        flow.finish()
        try await h.waitUntil("sheet gone") { window.attachedSheet == nil }
        XCTAssertTrue(h.environment.settings.onboardingCompleted)
    }
}
