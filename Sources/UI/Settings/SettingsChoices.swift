import SwiftUI
import Core

/// The four §7 sections, in tab order.
enum SettingsSection: String, CaseIterable, Hashable {
    case general, view, sidebar, advanced

    var title: String {
        switch self {
        case .general: L10n.string("General")
        case .view: L10n.string("View")
        case .sidebar: L10n.string("Sidebar")
        case .advanced: L10n.string("Advanced")
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .view: "eye"
        case .sidebar: "sidebar.left"
        case .advanced: "slider.horizontal.3"
        }
    }
}

/// The Startup folder popup's three entries (`StartupFolder.custom` carries its URL; the popup only needs the case).
enum StartupFolderChoice: String, CaseIterable, Hashable {
    case home, lastLocation, custom

    init(_ folder: StartupFolder) {
        switch folder {
        case .home: self = .home
        case .lastLocation: self = .lastLocation
        case .custom: self = .custom
        }
    }

    var title: String {
        switch self {
        case .home: L10n.string("Home")
        case .lastLocation: L10n.string("Last location")
        case .custom: L10n.string("Custom…")
        }
    }
}

/// Open panels the Settings window runs (tests pass a stub; nothing in a test opens a panel).
@MainActor protocol SettingsPanels: AnyObject {
    func chooseFolder() -> URL?
    func chooseApplication() -> URL?
}

/// Settings edits the SwiftUI sections bind to. Pure over `Settings`; panels come in as closures.
@MainActor enum SettingsChoices {
    // MARK: startup folder

    /// Home and Last location apply directly. Custom keeps an existing custom folder, else asks for one; a cancelled
    /// panel leaves the setting as it was.
    static func select(_ choice: StartupFolderChoice, in settings: Core.Settings, chooseFolder: () -> URL?) {
        switch choice {
        case .home: settings.startupFolder = .home
        case .lastLocation: settings.startupFolder = .lastLocation
        case .custom:
            if case .custom = settings.startupFolder { return }
            if let url = chooseFolder() { settings.startupFolder = .custom(url) }
        }
    }

    /// "Choose…" next to a custom startup folder.
    static func chooseCustomFolder(in settings: Core.Settings, chooseFolder: () -> URL?) {
        if let url = chooseFolder() { settings.startupFolder = .custom(url) }
    }

    static func customFolderName(_ settings: Core.Settings) -> String? {
        guard case .custom(let url) = settings.startupFolder else { return nil }
        return url.lastPathComponent
    }

    static func startupBinding(in settings: Core.Settings, chooseFolder: @escaping @MainActor () -> URL?) -> Binding<StartupFolderChoice> {
        Binding(get: { StartupFolderChoice(settings.startupFolder) },
                set: { select($0, in: settings, chooseFolder: chooseFolder) })
    }

    // MARK: terminal app

    /// nil = Terminal.app (§3.9 default).
    static func terminalAppName(_ settings: Core.Settings) -> String {
        guard let app = settings.terminalApp else { return L10n.string("Terminal") }
        return app.deletingPathExtension().lastPathComponent
    }

    static func chooseTerminalApp(in settings: Core.Settings, chooseApp: () -> URL?) {
        if let app = chooseApp() { settings.terminalApp = app }
    }

    static func resetTerminalApp(in settings: Core.Settings) { settings.terminalApp = nil }

    // MARK: sidebar

    static func isVisible(_ favorite: DefaultFavorite, in settings: Core.Settings) -> Bool {
        !settings.hiddenDefaultFavorites.contains(favorite)
    }

    static func setVisible(_ visible: Bool, _ favorite: DefaultFavorite, in settings: Core.Settings) {
        if visible { settings.hiddenDefaultFavorites.remove(favorite) } else { settings.hiddenDefaultFavorites.insert(favorite) }
    }

    static func visibilityBinding(_ favorite: DefaultFavorite, in settings: Core.Settings) -> Binding<Bool> {
        Binding(get: { isVisible(favorite, in: settings) }, set: { setVisible($0, favorite, in: settings) })
    }

    // MARK: titles

    static func title(for favorite: DefaultFavorite) -> String {
        switch favorite {
        case .home: L10n.string("Home")
        case .desktop: L10n.string("Desktop")
        case .documents: L10n.string("Documents")
        case .downloads: L10n.string("Downloads")
        case .applications: L10n.string("Applications")
        }
    }

    static func title(for density: Density) -> String {
        switch density {
        case .compact: L10n.string("Compact")
        case .regular: L10n.string("Regular")
        case .comfortable: L10n.string("Comfortable")
        }
    }

    static func title(for style: DateStyle) -> String {
        switch style {
        case .relative: L10n.string("Relative")
        case .absolute: L10n.string("Absolute")
        }
    }

    static func title(for openIn: OpenFoldersIn) -> String {
        switch openIn {
        case .sameWindow: L10n.string("In the same window")
        case .newWindow: L10n.string("In a new window")
        }
    }

    static func title(for behavior: ReturnKeyBehavior) -> String {
        switch behavior {
        case .open: L10n.string("Open")
        case .rename: L10n.string("Rename")
        }
    }
}
