import Foundation

/// A plugin bundle's `NSPrincipalClass` subclasses this. The app creates it once, on the main actor, after checking
/// the bundle's Info.plist `MacxPluginAPIVersion`; `apiVersion` is reported in Settings › Connections only.
@MainActor
open class MacxPlugin: NSObject {
    public required override init() { super.init() }
    open var apiVersion: APIVersion { MacxPluginAPI.version }
    open func makeProviders() -> [any RemoteProvider] { [] }
}
