import AppKit

/// The app's NSApplication (main.swift instantiates it; Info.plist NSPrincipalClass = MacxApplication).
/// Only in UI scenario runs does ScenarioDriver set `scenarioKeyWindow`. AppKit then resolves nil-targeted
/// actions and menu validation through that window even when macOS refused to activate the process
/// (cooperative activation; verified 2026-11-02). With it nil, which is always the case outside
/// `--scenario`, the window overrides defer to AppKit.
@objc(MacxApplication)
public final class MacxApplication: NSApplication {
    @MainActor static var scenarioKeyWindow: NSWindow?
    public override var keyWindow: NSWindow? { MacxApplication.scenarioKeyWindow ?? super.keyWindow }
    public override var mainWindow: NSWindow? { MacxApplication.scenarioKeyWindow ?? super.mainWindow }
    public override var isActive: Bool { MacxApplication.scenarioKeyWindow != nil || super.isActive }

    /// §5.6 routing 1–3: colliding primaries reach the field editor being edited (FieldEditorKeyRouting); bound extra mouse buttons run their command (MouseRouter).
    public override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, FieldEditorKeyRouting.route(event, in: keyWindow) { return }
        if event.type == .otherMouseDown, MouseRouter.handle(event, in: event.window ?? keyWindow) { return }
        if let pinned = MacxApplication.scenarioKeyWindow, event.type == .keyDown || event.type == .keyUp,
           super.keyWindow !== pinned {
            // Scenario runs only: AppKit routes keys to its own key window, which can be nil or another window
            // (after a sheet ends, or when activation was refused). Deliver them to the pinned window instead.
            MacxApplication.deliver(event, toPinned: pinned, menu: mainMenu)
            return
        }
        super.sendEvent(event)
    }

    /// What NSApplication does with a key event for its key window: key equivalents (window, then menu) first,
    /// then the first responder's keyDown/keyUp (unhandled keys travel up its responder chain to the window).
    /// NSWindow.sendEvent is not used: it drops key events while the window is not key.
    static func deliver(_ event: NSEvent, toPinned window: NSWindow, menu: NSMenu?) {
        let responder: NSResponder = window.firstResponder ?? window
        switch event.type {
        case .keyDown:
            if window.performKeyEquivalent(with: event) || (menu?.performKeyEquivalent(with: event) ?? false) { return }
            responder.keyDown(with: event)
        case .keyUp:
            responder.keyUp(with: event)
        default:
            window.sendEvent(event)
        }
    }
}
