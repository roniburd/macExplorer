// Sources/UI/Properties/ACLEditorModel.swift
import Foundation
import Core
import MacxFS

/// The Access column: which preset an entry's permissions match.
enum ACLPermissionSummary: Hashable, CaseIterable {
    case readOnly, readWrite, fullControl, custom

    static func summary(_ p: ACLPermissions) -> ACLPermissionSummary {
        switch p {
        case .readOnlyPreset: .readOnly
        case .readWritePreset: .readWrite
        case .fullControlPreset: .fullControl
        default: .custom
        }
    }

    /// The preset's permissions; nil for Custom.
    var permissions: ACLPermissions? {
        switch self {
        case .readOnly: .readOnlyPreset
        case .readWrite: .readWritePreset
        case .fullControl: .fullControlPreset
        case .custom: nil
        }
    }

    var title: String {
        switch self {
        case .readOnly: L10n.string("Read only")
        case .readWrite: L10n.string("Read & Write")
        case .fullControl: L10n.string("Full Control")
        case .custom: L10n.string("acl.access.custom")
        }
    }
}

/// The Applies To column for folders (Explorer's wording).
enum ACLAppliesTo {
    static func text(_ inheritance: ACLInheritance) -> String {
        let files = inheritance.contains(.fileInherit), folders = inheritance.contains(.directoryInherit)
        let base: String = switch (inheritance.contains(.onlyInherit), files, folders) {
        case (false, false, false): L10n.string("This folder only")
        case (false, true, true): L10n.string("This folder, subfolders and files")
        case (false, false, true): L10n.string("This folder and subfolders")
        case (false, true, false): L10n.string("This folder and files")
        case (true, true, true): L10n.string("Subfolders and files only")
        case (true, false, true): L10n.string("Subfolders only")
        case (true, true, false): L10n.string("Files only")
        case (true, false, false): L10n.string("Nothing")
        }
        return inheritance.contains(.limitInherit) ? String(format: L10n.string("%@ (one level)"), base) : base
    }
}

/// The entry sheet's editable state: principal, Allow/Deny, a preset or the 13 checkboxes, and inheritance.
struct ACLEntryDraft: Equatable {
    struct PermissionRow: Hashable {
        let permission: ACLPermissions
        let title: String
    }
    struct InheritanceRow: Hashable {
        let flag: ACLInheritance
        let title: String
    }

    var entry: ACLEntry
    /// The user picked Custom… while the checkboxes still match a preset.
    private var customChosen = false

    init(_ entry: ACLEntry) {
        self.entry = entry
        customChosen = false
    }

    var preset: ACLPermissionSummary {
        get { customChosen ? .custom : ACLPermissionSummary.summary(entry.permissions) }
        set {
            if let permissions = newValue.permissions {
                entry.permissions = permissions
                customChosen = false
            } else {
                customChosen = true
            }
        }
    }

    mutating func set(_ permission: ACLPermissions, _ on: Bool) {
        if on { entry.permissions.insert(permission) } else { entry.permissions.remove(permission) }
    }

    mutating func set(_ flag: ACLInheritance, _ on: Bool) {
        if on { entry.inheritance.insert(flag) } else { entry.inheritance.remove(flag) }
    }

    static var permissionRows: [PermissionRow] {
        [
            PermissionRow(permission: .readData, title: L10n.string("Read data / List folder")),
            PermissionRow(permission: .writeData, title: L10n.string("Write data / Create files")),
            PermissionRow(permission: .appendData, title: L10n.string("Append data / Create folders")),
            PermissionRow(permission: .execute, title: L10n.string("Execute / Traverse folder")),
            PermissionRow(permission: .delete, title: L10n.string("Delete")),
            PermissionRow(permission: .deleteChild, title: L10n.string("Delete subfolders and files")),
            PermissionRow(permission: .readAttributes, title: L10n.string("Read attributes")),
            PermissionRow(permission: .writeAttributes, title: L10n.string("Write attributes")),
            PermissionRow(permission: .readExtAttributes, title: L10n.string("Read extended attributes")),
            PermissionRow(permission: .writeExtAttributes, title: L10n.string("Write extended attributes")),
            PermissionRow(permission: .readSecurity, title: L10n.string("Read permissions")),
            PermissionRow(permission: .writeSecurity, title: L10n.string("acl.permission.changePermissions")),
            PermissionRow(permission: .changeOwner, title: L10n.string("Take ownership")),
        ]
    }

    static var inheritanceRows: [InheritanceRow] {
        [
            InheritanceRow(flag: .fileInherit, title: L10n.string("Files")),
            InheritanceRow(flag: .directoryInherit, title: L10n.string("Folders")),
            InheritanceRow(flag: .onlyInherit, title: L10n.string("Only children")),
            InheritanceRow(flag: .limitInherit, title: L10n.string("Don't propagate")),
        ]
    }
}

/// The Access Control table of one item (P4-18). Reads run on a lane; every edit is one undoable
/// `.setAttributes([url], .acl(explicit))` job ("Undo Change Access"), after which the table reloads from disk.
/// Inherited entries are shown but never edited (`ACLIO.write` keeps them). Without the privileged helper (Phase 6)
/// an item the user doesn't own is read-only (`isEditable == false`).
@MainActor @Observable
final class ACLEditorModel {
    let url: URL
    let isDirectory: Bool
    let isEditable: Bool
    private(set) var entries: [ACLEntry] = []
    private(set) var isLoaded = false
    private(set) var isApplying = false
    private(set) var error: String?
    private(set) var principals: [ACLPrincipal] = []

    @ObservationIgnored private let environment: CoreEnvironment
    /// The Properties window's origin, read when a job starts (the window sets it after the model exists).
    @ObservationIgnored var origin: @MainActor () -> OriginID? = { nil }
    @ObservationIgnored var perform: @MainActor (JobRequest) async -> JobOutcome
    @ObservationIgnored private var principalsTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration = 0

    init(url: URL, isDirectory: Bool, isEditable: Bool, environment: CoreEnvironment) {
        self.url = url
        self.isDirectory = isDirectory
        self.isEditable = isEditable
        self.environment = environment
        let operations = environment.operations
        perform = { request in await operations.perform(request) }
    }

    var canAdd: Bool { isEditable && isLoaded && !isApplying }

    /// Explicit rows of an editable item; inherited rows never.
    func canEdit(row: Int) -> Bool {
        isEditable && entries.indices.contains(row) && !entries[row].isInherited
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        let url = url
        let volume = environment.volumes.volume(for: url)?.id ?? .unknown
        let read = try? await environment.lanes.perform(on: volume) { _ in try ACLIO.read(url) }
        guard generation == loadGeneration else { return }       // a newer load won
        entries = read ?? []
        isLoaded = true
    }

    /// Users and groups for the entry sheet's picker, loaded on a lane once.
    func loadPrincipals() async {
        if principalsTask == nil {
            let lanes = environment.lanes
            principalsTask = Task { [weak self] in
                let all = await PrincipalDirectory.all(lanes: lanes)
                self?.principals = all
            }
        }
        await principalsTask?.value
    }

    static func filter(_ principals: [ACLPrincipal], _ search: String) -> [ACLPrincipal] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return principals }
        return principals.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func add(_ entry: ACLEntry) async {
        guard isEditable, isLoaded else { return }
        var entry = entry
        entry.isInherited = false
        await apply(explicit + [entry])
    }

    func remove(at index: Int) async {
        guard canEdit(row: index) else { return }
        var list = entries
        list.remove(at: index)
        await apply(list.filter { !$0.isInherited })
    }

    func replace(at index: Int, with entry: ACLEntry) async {
        guard canEdit(row: index) else { return }
        var list = entries
        var entry = entry
        entry.isInherited = false
        list[index] = entry
        await apply(list.filter { !$0.isInherited })
    }

    func request(for list: [ACLEntry]) -> JobRequest {
        JobRequest(.setAttributes([url], .acl(list)), origin: origin())
    }

    func close() {
        principalsTask?.cancel()
        principalsTask = nil
    }

    // MARK: private

    private var explicit: [ACLEntry] { entries.filter { !$0.isInherited } }

    /// One job; a skipped item with a reason (the router answers Properties errors with Skip, P1-38) becomes the
    /// inline error. The table reloads from disk either way.
    private func apply(_ list: [ACLEntry]) async {
        isApplying = true
        error = nil
        defer { isApplying = false }
        let outcome = await perform(request(for: list))
        if let failed = outcome.skipped.first(where: { $0.reason != nil }), let reason = failed.reason {
            error = ErrorText.jobError(reason, name: failed.url.lastPathComponent, verb: outcome.record.verb)
        }
        await load()
    }
}
