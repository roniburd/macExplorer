import SwiftUI
import AppKit
import Core

/// Settings › Shortcuts (key-bindings spec §5): every command with its menu shortcut, extra keys and mouse buttons.
/// Click a shortcut to record a new one (Esc cancels, ⌫ clears); [+] records an extra key or mouse button.
struct ShortcutsSettingsView: View {
    @Bindable var settings: Core.Settings
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

    private var model: ShortcutsModel { ShortcutsModel(settings: settings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L10n.string("Search commands…"), text: $query)
                .textFieldStyle(.roundedBorder)
            List {
                ForEach(model.groups(matching: query)) { group in
                    Section(group.title) {
                        ForEach(group.commands, id: \.self) { command in row(command) }
                    }
                }
            }
            .frame(height: 420)
            .accessibilityIdentifier(AXID.shortcutsList)
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
            Button(L10n.string("Restore All Defaults"), role: .destructive) { model.resetAll(); notice = nil }
            Button(L10n.string("Cancel"), role: .cancel) {}
        }
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
