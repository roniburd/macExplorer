import AppKit

extension NSWindow {
    /// Close Window (⌘W) for windows without a browser pane (Settings, Properties, the Operations panel). Browser
    /// windows' panes implement it first in the responder chain.
    @objc func macx_closeWindow(_ sender: Any?) { performClose(sender) }
}
