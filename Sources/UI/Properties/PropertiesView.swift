// Sources/UI/Properties/PropertiesView.swift
import SwiftUI
import AppKit
import Core
import MacxFS

/// Window-level actions the view can't do itself.
struct PropertiesActions {
    var reveal: @MainActor (URL) -> Void
    var changeDefaultApp: @MainActor (_ allOfType: Bool) -> Void
    var eject: @MainActor () -> Void
    /// Copy/Paste of the icon well (P4-08); nil = no clipboard.
    var pasteboard: @MainActor () -> NSPasteboard? = { nil }
}

/// §5.8 layout: tabs for one item, a single form for several items or a volume. Error text sits under the content.
struct PropertiesView: View {
    @Bindable var model: PropertiesViewModel
    let actions: PropertiesActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.content {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            case .failed(let text):
                Text(verbatim: text).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            case .item(let item):
                ItemTabs(model: model, item: item, actions: actions)
            case .items(let multi):
                MultiItemsForm(model: model, multi: multi, actions: actions)
            case .volume(let volume):
                VolumeForm(volume: volume, actions: actions)
            }
            if let error = model.inlineError {
                Text(verbatim: error)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("macx.properties.error")
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}

struct GeneralTab: View {
    @Bindable var model: PropertiesViewModel
    let item: ItemProperties
    let actions: PropertiesActions

    var body: some View {
        Form {
            HStack(alignment: .top, spacing: 12) {
                IconWellColumn(model: model, actions: actions)
                VStack(alignment: .leading, spacing: 4) {
                    TextField(L10n.string("Name"), text: $model.nameDraft)
                        .onSubmit { Task { await model.commitName() } }
                        .onExitCommand { model.revertName() }
                        .accessibilityIdentifier("macx.properties.name")
                    if let problem = model.nameProblem {
                        Text(verbatim: problem).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            LabeledContent(L10n.string("Kind"), value: item.kindDescription)
            LabeledContent(L10n.string("Location")) {
                HStack {
                    Text(verbatim: item.url.deletingLastPathComponent().path)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    Button(L10n.string("Reveal")) { actions.reveal(item.url) }
                }
            }
            if item.kind == .directory {
                LabeledContent(L10n.string("Size"), value: PropertiesFormat.countedSize(model.folderCount))
                LabeledContent(L10n.string("Contains"), value: model.folderCount.map { PropertiesFormat.contains($0) }
                               ?? L10n.string("Counting…"))
            } else if item.kind == .package {
                // A package is one item to the user: its contents' size, no Contains line (QA round 2).
                LabeledContent(L10n.string("Size"), value: PropertiesFormat.countedSize(model.folderCount))
                LabeledContent(L10n.string("Size on disk"), value: PropertiesFormat.countedDiskSize(model.folderCount))
            } else {
                LabeledContent(L10n.string("Size"), value: PropertiesFormat.size(item.logicalSize))
                LabeledContent(L10n.string("Size on disk"), value: PropertiesFormat.size(item.physicalSize))
            }
            LabeledContent(L10n.string("Created"), value: PropertiesFormat.date(item.created))
            LabeledContent(L10n.string("Modified"), value: PropertiesFormat.date(item.modified))
            LabeledContent(L10n.string("Last opened"), value: PropertiesFormat.date(item.lastOpened))
            LabeledContent(L10n.string("Attributes")) {
                VStack(alignment: .leading, spacing: 4) {
                    TriCheckbox(title: L10n.string("Read-only (Locked)"), state: Tri(item.isLocked)) { on in Task { await model.setLocked(on) } }
                    TriCheckbox(title: L10n.string("Hidden"), state: Tri(item.isHidden)) { on in Task { await model.setHidden(on) } }
                    TriCheckbox(title: L10n.string("Hide extension"), state: Tri(item.isExtensionHidden)) { on in
                        Task { await model.setExtensionHidden(on) }
                    }
                }
            }
        }
        .formStyle(.columns)
        .padding(8)
    }
}

struct PermissionsTab: View {
    let model: PropertiesViewModel
    let item: ItemProperties

    var body: some View {
        Form {
            ForEach(PermissionClass.allCases, id: \.self) { who in
                Picker(PropertiesFormat.who(who, owner: item.ownerName, group: item.groupName), selection: Binding(
                    get: { PermissionModel.access(item.mode, who) },
                    set: { access in Task { await model.setAccess(access, for: who) } })) {
                    ForEach(PermissionAccess.allCases, id: \.self) { access in
                        Text(verbatim: PropertiesFormat.access(access)).tag(access)
                    }
                }
                .disabled(!model.canEditPermissions)
            }
            if item.kind == .file {
                LabeledContent(L10n.string("Executable"),
                               value: PermissionModel.isExecutable(item.mode) ? L10n.string("Yes") : L10n.string("No"))
            }
            if let note = PropertiesViewModel.permissionsNote(isOwner: item.isOwnedByCurrentUser) {
                Text(verbatim: note).font(.caption).foregroundStyle(.secondary)
            }
            if item.kind == .directory {
                Button(L10n.string("Apply to enclosed items…")) { Task { await model.applyPermissionsToEnclosed() } }
                    .disabled(!model.canEditPermissions)
            }
            if !item.aclEntries.isEmpty {
                Section(L10n.string("Access control list")) {
                    ForEach(item.aclEntries, id: \.self) { entry in
                        Text(verbatim: entry).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.columns)
        .padding(8)
    }
}

struct OpensWithTab: View {
    let model: PropertiesViewModel
    let actions: PropertiesActions

    var body: some View {
        Form {
            LabeledContent(L10n.string("Opens with"), value: model.defaultApp?.name ?? L10n.string("No default app"))
            HStack {
                Button(L10n.string("Change…")) { actions.changeDefaultApp(false) }
                Button(L10n.string("Change All…")) { actions.changeDefaultApp(true) }
            }
        }
        .formStyle(.columns)
        .padding(8)
    }
}

struct DetailsTab: View {
    let model: PropertiesViewModel
    let item: ItemProperties

    var body: some View {
        Form {
            LabeledContent(L10n.string("Type identifier"), value: item.typeIdentifier)
            LabeledContent(L10n.string("Path")) { Text(verbatim: item.url.path).textSelection(.enabled).lineLimit(3) }
            LabeledContent(L10n.string("Inode"), value: String(item.inode))
            LabeledContent(L10n.string("Volume"), value: item.volumeName)
            if !item.whereFroms.isEmpty {
                LabeledContent(L10n.string("Where from")) {
                    VStack(alignment: .leading) {
                        ForEach(item.whereFroms, id: \.self) { url in
                            Text(verbatim: url).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                }
            }
            if let quarantine = item.quarantine {
                LabeledContent(L10n.string("Quarantine")) {
                    HStack {
                        Text(verbatim: PropertiesFormat.quarantine(agent: quarantine.agentName, date: quarantine.date))
                        Button(L10n.string("Remove")) { Task { await model.removeQuarantine() } }
                    }
                }
            }
            if !item.xattrs.isEmpty {
                LabeledContent(L10n.string("Extended attributes")) {
                    VStack(alignment: .leading) {
                        ForEach(item.xattrs, id: \.name) { xattr in
                            Text(verbatim: "\(xattr.name) (\(Formatters.bytes(Int64(xattr.size))))").font(.caption.monospaced())
                        }
                    }
                }
            }
        }
        .formStyle(.columns)
        .padding(8)
    }
}

/// The icon well (drop or paste an image to set a custom icon, P4-08) and "Remove Custom Icon" under it. Items whose
/// icon can't be changed show the plain icon.
private struct IconWellColumn: View {
    let model: PropertiesViewModel
    let actions: PropertiesActions

    var body: some View {
        VStack(spacing: 4) {
            if model.canEditIcon {
                IconWellView(image: model.icon, isEnabled: !model.isApplying, showsRemove: model.hasCustomIcon,
                             lanes: model.environment.lanes, pasteboard: actions.pasteboard,
                             onDropImage: { data in Task { await model.setCustomIcon(data) } },
                             onRemove: { Task { await model.setCustomIcon(nil) } })
                    .frame(width: 64, height: 64)
                    .help(L10n.string("Drop or paste an image to use it as the icon."))
                if model.hasCustomIcon {
                    Button(L10n.string("Remove Custom Icon")) { Task { await model.setCustomIcon(nil) } }
                        .controlSize(.small)
                        .disabled(model.isApplying)
                        .accessibilityIdentifier(AXID.propertiesRemoveCustomIcon)
                }
            } else if let icon = model.icon {
                Image(decorative: icon, scale: 2).resizable().frame(width: 64, height: 64)
            }
        }
    }
}

private struct MultiItemsForm: View {
    let model: PropertiesViewModel
    let multi: MultiProperties
    let actions: PropertiesActions

    var body: some View {
        Form {
            LabeledContent(L10n.string("Selection"), value: PropertiesFormat.items(count: multi.count, files: multi.files, folders: multi.folders))
            LabeledContent(L10n.string("Total size"), value: PropertiesFormat.size(multi.totalSize))
            if model.canEditIcon {
                LabeledContent(L10n.string("Icon")) { IconWellColumn(model: model, actions: actions) }
            }
            LabeledContent(L10n.string("Attributes")) {
                VStack(alignment: .leading, spacing: 4) {
                    TriCheckbox(title: L10n.string("Read-only (Locked)"), state: multi.locked) { on in Task { await model.setLocked(on) } }
                    TriCheckbox(title: L10n.string("Hidden"), state: multi.hidden) { on in Task { await model.setHidden(on) } }
                    TriCheckbox(title: L10n.string("Hide extension"), state: multi.extensionHidden) { on in
                        Task { await model.setExtensionHidden(on) }
                    }
                }
            }
        }
        .formStyle(.columns)
    }
}

private struct VolumeForm: View {
    let volume: VolumeProperties
    let actions: PropertiesActions

    var body: some View {
        Form {
            LabeledContent(L10n.string("Format"), value: volume.volume.format)
            LabeledContent(L10n.string("Capacity"), value: PropertiesFormat.size(volume.capacity))
            LabeledContent(L10n.string("Used"), value: PropertiesFormat.size(volume.used))
            LabeledContent(L10n.string("Free"), value: PropertiesFormat.size(volume.available))
            if let usage = PropertiesFormat.usage(capacity: volume.capacity, available: volume.available) {
                ProgressView(value: usage).accessibilityLabel(L10n.string("Used space"))
            }
            LabeledContent(L10n.string("Mount point")) { Text(verbatim: volume.volume.mountPoint.path).textSelection(.enabled) }
            if volume.volume.isEjectable {
                Button(L10n.string("Eject")) { actions.eject() }
            }
        }
        .formStyle(.columns)
    }
}
