import SwiftUI
import AppKit
import Core
import MacxFS

/// Settings › Shortcuts (key-bindings spec §5): every command with its menu shortcut, extra keys and mouse buttons.
/// Click a shortcut to record a new one (Esc cancels, ⌫ clears); [+] records an extra key or mouse button.
/// P4-02: a preset picker (Explorer, Finder; Custom once edited), and Import…/Export… of a keymap file with a report
/// of what an import skipped or why it was rejected.
struct ShortcutsSettingsView: View {
    @Bindable var settings: Core.Settings
    /// The keymap file panels; nil disables Import… and Export….
    let panels: (any SettingsPanels)?
    let lanes: LanePool
    @State private var pendingPreset: KeymapPreset?
    @State private var keymapStatus: KeymapStatus?
    @State private var query = ""
    @State private var recording: Recording?
    @State private var notice: Notice?
    @State private var confirmReset = false
    @State private var recorder = ShortcutRecorder()

    struct Recording: Equatable {
        let command: Command
        let slot: KeyBindings.Slot      // .primary = the Shortcut cell; .alternate = [+] (key → alternate, mouse → mouse)
    }

    struct Notice: Equatable {
        let command: Command
        let text: String
        /// Set for a conflict: what Reassign would save.
        let pending: (trigger: Trigger, slot: KeyBindings.Slot)?
        static func == (a: Notice, b: Notice) -> Bool { a.command == b.command && a.text == b.text }
    }

    /// The outcome of the last import or export, shown under the list until the next one or a preset change.
    struct KeymapStatus: Equatable {
        enum Tone { case info, warning, error }
        let tone: Tone
        let summary: String
        let details: [String]
    }

    private var model: ShortcutsModel { ShortcutsModel(settings: settings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            keymapBar
            TextField(L10n.string("Search commands…"), text: $query)
                .textFieldStyle(.roundedBorder)
            List {
                ForEach(model.groups(matching: query)) { group in
                    Section(group.title) {
                        ForEach(group.commands, id: \.self) { command in row(command) }
                    }
                }
            }
            .frame(height: 400)
            .accessibilityIdentifier(AXID.shortcutsList)
            if let keymapStatus { statusView(keymapStatus) }
            HStack {
                Text(L10n.string("Shortcuts set in System Settings › Keyboard › App Shortcuts take precedence over menu shortcuts."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L10n.string("Restore All Defaults")) { confirmReset = true }
                    .accessibilityIdentifier(AXID.shortcutsRestoreDefaults)
            }
        }
        .padding()
        .onDisappear { recorder.stop(); recording = nil }
        .onChange(of: query) { recorder.stop(); recording = nil }
        .confirmationDialog(L10n.string("Restore all shortcuts to their defaults?"), isPresented: $confirmReset) {
            Button(L10n.string("Restore All Defaults"), role: .destructive) { model.resetAll(); notice = nil; keymapStatus = nil }
            Button(L10n.string("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(pendingPreset.map(presetQuestion) ?? "", isPresented: presetDialogShown) {
            Button(L10n.string("Replace Shortcuts"), role: .destructive) {
                if let pendingPreset { model.applyPreset(pendingPreset) }
                pendingPreset = nil
                notice = nil
                keymapStatus = nil
            }
            Button(L10n.string("Cancel"), role: .cancel) { pendingPreset = nil }
        } message: {
            if pendingPreset?.returnKey == .rename {
                Text(L10n.string("Return will rename the selected item, as in Finder."))
            }
        }
    }

    // MARK: presets, import, export (P4-02)

    private var keymapBar: some View {
        HStack(spacing: 8) {
            Picker(L10n.string("Preset:"), selection: presetSelection) {
                ForEach(ShortcutsModel.presetChoices, id: \.self) { choice in
                    Text(ShortcutsModel.title(choice)).tag(choice)
                        .selectionDisabled(choice == .custom)
                }
            }
            .fixedSize()
            .accessibilityIdentifier(AXID.shortcutsPreset)
            Spacer()
            Button(L10n.string("Import…")) { importKeymap() }
                .disabled(panels == nil)
                .accessibilityIdentifier(AXID.shortcutsImport)
            Button(L10n.string("Export…")) { exportKeymap() }
                .disabled(panels == nil)
                .accessibilityIdentifier(AXID.shortcutsExport)
        }
    }

    /// Shows the current preset (Custom once edited); choosing another one asks first.
    private var presetSelection: Binding<ShortcutsModel.PresetChoice> {
        Binding(get: { model.presetChoice }, set: { choice in
            guard case .preset(let preset) = choice, choice != model.presetChoice else { return }
            recorder.stop()
            recording = nil
            pendingPreset = preset
        })
    }

    private var presetDialogShown: Binding<Bool> {
        Binding(get: { pendingPreset != nil }, set: { if !$0 { pendingPreset = nil } })
    }

    private func presetQuestion(_ preset: KeymapPreset) -> String {
        String(format: L10n.string("Replace your shortcuts with the %@ preset?"), ShortcutsModel.title(.preset(preset)))
    }

    private func importKeymap() {
        recorder.stop()
        recording = nil
        guard let url = panels?.chooseKeymapToImport() else { return }
        let model = model
        Task { @MainActor in
            switch await model.importKeymap(from: url, lanes: lanes) {
            case .imported(let warnings):
                notice = nil
                let name = url.lastPathComponent
                keymapStatus = KeymapStatus(tone: warnings.isEmpty ? .info : .warning,
                                            summary: String(format: L10n.string("Imported “%@”."), name),
                                            details: warnings.map(ShortcutsModel.message))
            case .failed(let failure):
                let report = ShortcutsModel.report(failure)
                keymapStatus = KeymapStatus(tone: .error, summary: report.summary, details: report.details)
            }
        }
    }

    private func exportKeymap() {
        recorder.stop()
        recording = nil
        guard let url = panels?.chooseKeymapExportDestination() else { return }
        let model = model
        Task { @MainActor in
            do {
                try await model.exportKeymap(to: url, lanes: lanes)
                keymapStatus = KeymapStatus(tone: .info, summary: String(format: L10n.string("Exported “%@”."),
                                                                         url.lastPathComponent), details: [])
            } catch {
                keymapStatus = KeymapStatus(tone: .error, summary: L10n.string("The keymap couldn’t be saved."), details: [])
            }
        }
    }

    private func statusView(_ status: KeymapStatus) -> some View {
        let color: Color = switch status.tone {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
        return HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.summary).font(.callout).foregroundStyle(color)
                ForEach(Array(status.details.enumerated()), id: \.offset) { _, line in
                    Text("• " + line).font(.caption).foregroundStyle(color)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { keymapStatus = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .help(L10n.string("Dismiss"))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AXID.shortcutsKeymapStatus)
    }

    // MARK: rows

    @ViewBuilder private func row(_ command: Command) -> some View {
        let b = model.bindings
        let fixed = model.isFixed(command)
        let conflicts = model.conflicts(for: command)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(model.title(command))
                    .fontWeight(model.isModified(command) ? .bold : .regular)
                    .frame(width: 170, alignment: .leading)
                    .lineLimit(1)
                primaryCell(command, chord: b.primary(command), fixed: fixed,
                            conflicted: b.primary(command).map { conflicts[.key($0)] != nil } ?? false)
                    .frame(width: 90, alignment: .leading)
                chips(command, keys: b.alternates(command), mouse: b.mouse(command), fixed: fixed, conflicts: conflicts)
                Spacer(minLength: 0)
                if !conflicts.isEmpty {
                    // Spec §6: a trigger another command also holds is flagged on both rows.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(conflicts.sorted { $0.key.displayString < $1.key.displayString }
                            .map { model.conflictMessage($0.key, $0.value) }.joined(separator: "\n"))
                }
                if !fixed {
                    Button { begin(command, .alternate) } label: {
                        Image(systemName: isRecording(command, .alternate) ? "record.circle" : "plus")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string("Add a key or mouse button"))
                }
                if model.isModified(command) {
                    Button { model.reset(command); notice = nil } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .help(L10n.string("Restore default"))
                }
            }
            if let notice, notice.command == command { noticeView(notice) }
        }
        .opacity(fixed ? 0.6 : 1)
        .help(fixed ? L10n.string("Fixed") : "")
    }

    @ViewBuilder private func primaryCell(_ command: Command, chord: KeyChord?, fixed: Bool, conflicted: Bool) -> some View {
        if isRecording(command, .primary) {
            Text(L10n.string("Type shortcut…")).foregroundStyle(.tint)
        } else if fixed {
            Text(chord?.displayString ?? "—").foregroundStyle(.secondary)
        } else if conflicted {
            Button(chord?.displayString ?? "—") { begin(command, .primary) }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
        } else {
            Button(chord?.displayString ?? "—") { begin(command, .primary) }
                .buttonStyle(.borderless)
        }
    }

    /// `keys` and `mouse` hold no repeats (`KeyBindings` drops them), so `\.self` is a unique id.
    private func chips(_ command: Command, keys: [KeyChord], mouse: [MouseButton], fixed: Bool,
                       conflicts: [Trigger: [KeyBindings.Use]]) -> some View {
        HStack(spacing: 4) {
            ForEach(keys.map(Trigger.key) + mouse.map(Trigger.mouse), id: \.self) { trigger in
                ShortcutChip(text: trigger.displayString, removable: !fixed, conflicted: conflicts[trigger] != nil) {
                    model.remove(trigger, from: command)
                }
            }
            if isRecording(command, .alternate) {
                Text(L10n.string("Type shortcut…")).foregroundStyle(.tint)
            }
        }
    }

    @ViewBuilder private func noticeView(_ notice: Notice) -> some View {
        HStack(spacing: 8) {
            Text(notice.text).font(.caption).foregroundStyle(notice.pending == nil ? .red : .orange)
            if let pending = notice.pending {
                Button(L10n.string("Reassign")) {
                    _ = model.apply(pending.trigger, to: notice.command, as: pending.slot, reassigning: true)
                    self.notice = nil
                }
                Button(L10n.string("Cancel")) { self.notice = nil }
            }
        }
    }

    // MARK: recording

    private func isRecording(_ command: Command, _ slot: KeyBindings.Slot) -> Bool {
        recording == Recording(command: command, slot: slot)
    }

    private func begin(_ command: Command, _ slot: KeyBindings.Slot) {
        notice = nil
        recording = Recording(command: command, slot: slot)
        recorder.start(in: NSApp.keyWindow, acceptsMouse: slot == .alternate, backspaceClears: slot == .primary) { outcome in
            recording = nil
            switch outcome {
            case .cancel: break
            case .clear: model.clearPrimary(command)
            case .trigger(let trigger):
                let target: KeyBindings.Slot
                if case .mouse = trigger { target = .mouse } else { target = slot }
                switch model.apply(trigger, to: command, as: target, reassigning: false) {
                case .saved: break
                case .rejected(let rejection):
                    notice = Notice(command: command, text: ShortcutsModel.message(rejection), pending: nil)
                case .conflict(let uses):
                    notice = Notice(command: command, text: model.conflictMessage(trigger, uses), pending: (trigger, target))
                }
            }
        }
    }
}

/// An extra key or mouse button; hovering shows × to remove it.
private struct ShortcutChip: View {
    let text: String
    let removable: Bool
    let conflicted: Bool
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            Text(text).font(.callout.monospaced())
            if removable, hovering {
                Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help(L10n.string("Remove"))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(conflicted ? Color.orange.opacity(0.3) : Color.secondary.opacity(0.15)))
        .onHover { hovering = $0 }
    }
}
