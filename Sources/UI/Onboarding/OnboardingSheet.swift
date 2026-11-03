import AppKit
import SwiftUI
import Core

/// System Settings › Keyboard (spec §5.9: "Use F1, F2, etc. keys as standard function keys").
enum OnboardingLinks {
    static let keyboard = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
}

/// The sheet's text (§5.9).
@MainActor enum OnboardingTexts {
    static var title: String { L10n.string("Welcome to macExplorer") }
    static var fullDiskAccessTitle: String { L10n.string("Full Disk Access") }
    static var fullDiskAccess: String {
        L10n.string("macOS asks before an app reads Desktop, Documents, Downloads, other apps' data and external disks. With Full Disk Access, macExplorer can browse and search everywhere without a prompt for each folder. You can grant it in Privacy & Security at any time.")
    }
    static var openPrivacy: String { L10n.string("Open Privacy & Security") }
    static var continueWithout: String { L10n.string("Continue Without Full Disk Access") }
    static var fnKeysTitle: String { L10n.string("Function keys") }
    static var fnKeys: String {
        L10n.string("Using F2 or F5? Hold fn, or turn on 'Use F1, F2, etc. keys as standard function keys'.")
    }
    static var openKeyboard: String { L10n.string("Open Keyboard Settings") }
}

/// What the sheet's buttons do. The deep links go through `ExternalURLOpening` (recorded in sandboxed runs); finishing
/// marks onboarding as done, once.
@MainActor
final class OnboardingFlow {
    private let settings: Core.Settings
    private let opener: any ExternalURLOpening
    private var onFinish: (() -> Void)?

    init(settings: Core.Settings, opener: any ExternalURLOpening, onFinish: @escaping () -> Void) {
        self.settings = settings
        self.opener = opener
        self.onFinish = onFinish
    }

    func openPrivacySettings() { opener.open(SystemSettingsLinks.privacyAllFiles) }
    func openKeyboardSettings() { opener.open(OnboardingLinks.keyboard) }

    func finish() {
        guard let onFinish else { return }
        self.onFinish = nil
        settings.onboardingCompleted = true
        onFinish()
    }
}

struct OnboardingView: View {
    let flow: OnboardingFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(OnboardingTexts.title).font(.title2).bold()
            VStack(alignment: .leading, spacing: 6) {
                Label(OnboardingTexts.fullDiskAccessTitle, systemImage: "lock.shield").font(.headline)
                Text(OnboardingTexts.fullDiskAccess).fixedSize(horizontal: false, vertical: true)
                Button(OnboardingTexts.openPrivacy) { flow.openPrivacySettings() }
            }
            VStack(alignment: .leading, spacing: 6) {
                Label(OnboardingTexts.fnKeysTitle, systemImage: "keyboard").font(.headline)
                Text(OnboardingTexts.fnKeys).fixedSize(horizontal: false, vertical: true)
                Button(OnboardingTexts.openKeyboard) { flow.openKeyboardSettings() }
            }
            HStack {
                Spacer()
                Button(OnboardingTexts.continueWithout) { flow.finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// First-launch sheet (§5.9) on the first browser window: Full Disk Access and fn-key notes. Shown until "Continue"
/// once; `--skip-onboarding` (scenario and smoke runs) never shows it.
@MainActor enum OnboardingSheet {
    static func shouldShow(settings: Core.Settings, options: LaunchOptions) -> Bool {
        !options.skipOnboarding && !settings.onboardingCompleted
    }

    @discardableResult
    static func present(on window: NSWindow, context: UIContext, opener: (any ExternalURLOpening)? = nil) -> OnboardingFlow {
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        sheet.setAccessibilityIdentifier(AXID.onboardingSheet)
        let flow = OnboardingFlow(settings: context.environment.settings,
                                  opener: opener ?? ExternalOpeners.opener(for: context.options)) { [weak window, weak sheet] in
            guard let sheet else { return }
            if let window, window.attachedSheet === sheet || window.sheets.contains(sheet) {
                window.endSheet(sheet)
            } else {
                sheet.orderOut(nil)
            }
        }
        let host = NSHostingController(rootView: OnboardingView(flow: flow))
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        window.beginSheet(sheet)
        return flow
    }
}
