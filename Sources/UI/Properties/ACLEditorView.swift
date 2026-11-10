// Sources/UI/Properties/ACLEditorView.swift
import SwiftUI
import Core

/// One table row: its index in `ACLEditorModel.entries` is the identity (the table reloads after every edit).
private struct ACLRow: Identifiable {
    let id: Int
    let entry: ACLEntry
}

/// Which entry the sheet edits: nil index = a new entry.
private struct ACLSheetRequest: Identifiable {
    let id = UUID()
    let index: Int?
    let draft: ACLEntryDraft
}

/// Properties › Permissions › Access Control (P4-18): Name, Type, Access and (folders) Applies To, with +/− and
/// double-click to edit. Inherited rows are secondary and can't be edited. Read-only when the user can't change it.
struct ACLEditorView: View {
    @Bindable var model: ACLEditorModel
    @State private var selection: Int?
    @State private var sheet: ACLSheetRequest?

    private var rows: [ACLRow] { model.entries.enumerated().map { ACLRow(id: $0.offset, entry: $0.element) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: L10n.string("Access Control")).font(.headline)
            table
                .frame(height: 130)
                .overlay {
                    if let readError = model.readError {
                        Text(verbatim: readError).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(8)
                    } else if model.isLoaded && model.entries.isEmpty {
                        Text(verbatim: L10n.string("No access control entries")).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier(AXID.propertiesACLTable)
            HStack(spacing: 4) {
                Button { openNew() } label: { Image(systemName: "plus") }
                    .accessibilityLabel(L10n.string("Add Entry"))
                    .accessibilityIdentifier(AXID.propertiesACLAdd)
                    .disabled(!model.canAdd)
                Button {
                    guard let selection else { return }
                    Task { await model.remove(at: selection) }
                    self.selection = nil
                } label: { Image(systemName: "minus") }
                    .accessibilityLabel(L10n.string("Remove Entry"))
                    .accessibilityIdentifier(AXID.propertiesACLRemove)
                    .disabled(selection.map { !model.canEdit(row: $0) } ?? true || model.isApplying)
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if let error = model.error {
                Text(verbatim: error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $sheet) { request in
            ACLEntrySheet(editor: model, draft: request.draft, isNew: request.index == nil) { entry in
                sheet = nil
                Task {
                    if let index = request.index { await model.replace(at: index, with: entry) } else { await model.add(entry) }
                }
            } onCancel: { sheet = nil }
        }
    }

    @ViewBuilder private var table: some View {
        let base = Table(rows, selection: $selection) {
            TableColumn(L10n.string("Name")) { row in
                let name = row.entry.isInherited ? String(format: L10n.string("%@ (inherited)"), row.entry.principal.name)
                                                 : row.entry.principal.name
                Text(verbatim: name).foregroundStyle(row.entry.isInherited ? .secondary : .primary)
            }
            TableColumn(L10n.string("acl.type")) { row in
                Text(verbatim: row.entry.kind == .allow ? L10n.string("Allow") : L10n.string("Deny"))
                    .foregroundStyle(row.entry.isInherited ? .secondary : .primary)
            }
            .width(min: 40, ideal: 50)
            TableColumn(L10n.string("Access")) { row in
                Text(verbatim: ACLPermissionSummary.summary(row.entry.permissions).title)
                    .foregroundStyle(row.entry.isInherited ? .secondary : .primary)
            }
            if model.isDirectory {
                TableColumn(L10n.string("Applies To")) { row in
                    Text(verbatim: ACLAppliesTo.text(row.entry.inheritance))
                        .foregroundStyle(row.entry.isInherited ? .secondary : .primary)
                        .help(ACLAppliesTo.text(row.entry.inheritance))
                }
            }
        }
        base.contextMenu(forSelectionType: Int.self) { indices in
            if let index = indices.first, model.canEdit(row: index) {
                Button(L10n.string("acl.editEntry")) { openEdit(index) }
                Button(L10n.string("Remove Entry")) { Task { await model.remove(at: index) } }
            }
        } primaryAction: { indices in
            if let index = indices.first, model.canEdit(row: index) { openEdit(index) }
        }
    }

    private func openNew() {
        guard model.canAdd else { return }
        sheet = ACLSheetRequest(index: nil, draft: ACLEntryDraft(ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone,
                                                                           permissions: .readOnlyPreset)))
    }

    private func openEdit(_ index: Int) {
        guard model.canEdit(row: index), !model.isApplying else { return }
        sheet = ACLSheetRequest(index: index, draft: ACLEntryDraft(model.entries[index]))
    }
}

/// Adds or edits one entry: a searchable principal list (loaded on a lane when the sheet opens), Allow/Deny, an
/// access preset with a Custom… disclosure of the 13 permissions, and for folders the inheritance flags.
private struct ACLEntrySheet: View {
    let editor: ACLEditorModel
    @State var draft: ACLEntryDraft
    let isNew: Bool
    let onSave: (ACLEntry) -> Void
    let onCancel: () -> Void
    @State private var search = ""
    @State private var showsCustom = false
    /// The draft is a deny entry that would lock the user out of this list: warned about, and Add/OK disabled.
    @State private var locksOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: isNew ? L10n.string("Add Entry") : L10n.string("Edit Entry")).font(.headline)
            TextField(L10n.string("Search users and groups"), text: $search)
            List(ACLEditorModel.filter(principals, search), id: \.self, selection: principalBinding) { principal in
                Label {
                    Text(verbatim: principal.name)
                } icon: {
                    Image(systemName: { if case .group = principal { "person.2" } else { "person" } }())
                }
            }
            .frame(height: 120)
            Form {
                Picker(L10n.string("acl.type"), selection: $draft.entry.kind) {
                    Text(verbatim: L10n.string("Allow")).tag(ACLEntry.Kind.allow)
                    Text(verbatim: L10n.string("Deny")).tag(ACLEntry.Kind.deny)
                }
                .pickerStyle(.segmented)
                Picker(L10n.string("Access"), selection: presetBinding) {
                    ForEach(ACLPermissionSummary.allCases, id: \.self) { preset in
                        Text(verbatim: preset.title).tag(preset)
                    }
                }
            }
            .formStyle(.columns)
            DisclosureGroup(L10n.string("Custom…"), isExpanded: $showsCustom) {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 2) {
                    ForEach(ACLEntryDraft.permissionRows, id: \.self) { row in
                        Toggle(row.title, isOn: Binding(get: { draft.entry.permissions.contains(row.permission) },
                                                        set: { draft.set(row.permission, $0) }))
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                    }
                }
            }
            if editor.isDirectory {
                Text(verbatim: L10n.string("Applies to items inside:")).font(.subheadline)
                HStack {
                    ForEach(ACLEntryDraft.inheritanceRows, id: \.self) { row in
                        Toggle(row.title, isOn: Binding(get: { draft.entry.inheritance.contains(row.flag) },
                                                        set: { draft.set(row.flag, $0) }))
                            .toggleStyle(.checkbox)
                    }
                }
            }
            if locksOut {
                Label {
                    Text(verbatim: ACLEditorModel.lockoutMessage(editor.url.lastPathComponent))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
                .font(.caption)
            }
            HStack {
                Spacer()
                Button(L10n.string("Cancel"), role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? L10n.string("Add") : L10n.string("OK")) { onSave(draft.entry) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.entry.permissions.isEmpty || locksOut)
            }
        }
        .padding(16)
        .frame(width: 420)
        .accessibilityIdentifier(AXID.propertiesACLSheet)
        .task { await editor.loadPrincipals() }
        .task(id: draft.entry) { locksOut = await editor.wouldLockOut(draft.entry) }
    }

    /// The picker always lists the entry's own principal, even one the directory doesn't return (an orphaned UUID).
    private var principals: [ACLPrincipal] {
        editor.principals.contains(draft.entry.principal) ? editor.principals : [draft.entry.principal] + editor.principals
    }

    private var principalBinding: Binding<ACLPrincipal?> {
        Binding(get: { draft.entry.principal }, set: { if let p = $0 { draft.entry.principal = p } })
    }

    private var presetBinding: Binding<ACLPermissionSummary> {
        Binding(get: { draft.preset }, set: { draft.preset = $0; if $0 == .custom { showsCustom = true } })
    }
}
