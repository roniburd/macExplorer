import Core

struct ShortcutGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let commands: [Command]
}

enum ShortcutApply: Equatable {
    case saved
    case rejected(BindingRejection)
    case conflict([KeyBindings.Use])
}

/// Settings › Shortcuts logic: groups, search, and edits written straight to `settings.keyBindingOverrides`.
@MainActor struct ShortcutsModel {
    let settings: Core.Settings

    /// Main-menu order. Every Command appears exactly once.
    static let groups: [ShortcutGroup] = [
        ShortcutGroup(id: "open", title: L10n.string("Open"),
                      commands: [.open, .openInNewWindow, .showPackageContents, .openInTerminal, .revealInFinder]),
        ShortcutGroup(id: "edit", title: L10n.string("Edit"),
                      commands: [.undo, .redo, .cut, .copy, .paste, .moveItemHere, .copyAsPath]),
        ShortcutGroup(id: "selection", title: L10n.string("Selection"), commands: [.selectAll, .selectNone, .invertSelection]),
        ShortcutGroup(id: "file", title: L10n.string("File"),
                      commands: [.newFolder, .newTextFile, .newEmptyFile, .rename, .duplicate, .makeAlias, .makeSymlink,
                                 .moveToTrash, .deletePermanently, .share, .properties]),
        ShortcutGroup(id: "navigation", title: L10n.string("Navigation"),
                      commands: [.back, .forward, .up, .focusAddressBar, .focusSearch, .refresh,
                                 .cycleFocusForward, .cycleFocusBackward, .cancelOperation]),
        ShortcutGroup(id: "window", title: L10n.string("Window"), commands: [.newWindow, .closeWindow, .showOperations]),
        ShortcutGroup(id: "view", title: L10n.string("View"),
                      commands: [.viewAsDetails, .viewAsIcons, .iconSizeSmall, .iconSizeMedium, .iconSizeLarge,
                                 .densityCompact, .densityRegular, .densityComfortable, .toggleHidden, .toggleCommandBar,
                                 .useViewAsDefault, .resetFolderView]),
        ShortcutGroup(id: "sort", title: L10n.string("Sort"),
                      commands: [.sortByName, .sortByDateModified, .sortBySize, .sortByKind, .sortByDateCreated,
                                 .sortAscending, .sortDescending]),
        ShortcutGroup(id: "sidebar", title: L10n.string("Sidebar"), commands: [.eject, .removeFromFavorites]),
    ]

    var bindings: KeyBindings { settings.keyBindings }

    func title(_ command: Command) -> String { MainMenuTitles.title(command) }

    /// Groups with only the commands matching `query` (title, glyphs "⌘[", text form "cmd+[", or "mouse 4"); empty groups dropped.
    func groups(matching query: String) -> [ShortcutGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Self.groups }
        let b = bindings
        return Self.groups.compactMap { group in
            let commands = group.commands.filter { command in
                let chords = [b.primary(command)].compactMap { $0 } + b.alternates(command)
                let haystack = [title(command)] + chords.flatMap { [$0.displayString, $0.description] }
                    + b.mouse(command).flatMap { [$0.displayName, $0.description] }
                return haystack.contains { $0.lowercased().contains(q) }
            }
            return commands.isEmpty ? nil : ShortcutGroup(id: group.id, title: group.title, commands: commands)
        }
    }

    /// Spec §6: each trigger `command` holds that another command also holds (only possible through hand-edited or
    /// older stored data), with those other uses. Shown on every row involved.
    func conflicts(for command: Command) -> [Trigger: [KeyBindings.Use]] {
        let b = bindings
        let triggers = [b.primary(command)].compactMap { $0 }.map(Trigger.key)
            + b.alternates(command).map(Trigger.key) + b.mouse(command).map(Trigger.mouse)
        var result: [Trigger: [KeyBindings.Use]] = [:]
        for trigger in triggers {
            let others = b.uses(of: trigger).filter { $0.command != command }
            if !others.isEmpty { result[trigger] = others }
        }
        return result
    }

    func isModified(_ command: Command) -> Bool { settings.keyBindingOverrides.commands[command] != nil }
    func isFixed(_ command: Command) -> Bool { KeyBindings.fixedCommands.contains(command) }

    /// Validates, then saves unless another slot holds `trigger` and `reassigning` is false.
    func apply(_ trigger: Trigger, to command: Command, as slot: KeyBindings.Slot, reassigning: Bool) -> ShortcutApply {
        if let rejection = KeyBindings.validate(trigger, as: slot) { return .rejected(rejection) }
        let others = bindings.uses(of: trigger).filter { $0 != KeyBindings.Use(command: command, slot: slot) }
        if !others.isEmpty, !reassigning { return .conflict(others) }
        settings.keyBindingOverrides.reassign(trigger, to: command, as: slot)
        return .saved
    }

    func clearPrimary(_ command: Command) { settings.keyBindingOverrides.setPrimary(nil, for: command) }

    func remove(_ trigger: Trigger, from command: Command) {
        switch trigger {
        case .key(let chord): settings.keyBindingOverrides.removeAlternate(chord, from: command)
        case .mouse(let button): settings.keyBindingOverrides.removeMouse(button, from: command)
        }
    }

    func reset(_ command: Command) { settings.keyBindingOverrides.reset(command) }
    func resetAll() { settings.keyBindingOverrides = .empty }

    static func message(_ rejection: BindingRejection) -> String {
        switch rejection {
        case .reserved: L10n.string("Reserved by macOS or MacExplorer.")
        case .editsTextAsPrimary: L10n.string("Menu shortcuts need ⌘ or ⌃, or an F key. ⌥ alone works only with keys that don't type.")
        case .wrongSlot: L10n.string("Mouse buttons can only be added as extras.")
        }
    }

    func conflictMessage(_ trigger: Trigger, _ uses: [KeyBindings.Use]) -> String {
        let names = uses.map { title($0.command) }.joined(separator: ", ")
        return String(format: L10n.string("%@ is used by %@."), trigger.displayString, names)
    }
}
