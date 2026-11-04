// Sources/UI/Properties/PropertiesFormat.swift
import AppKit
import SwiftUI
import Core
import MacxFS

/// Display text for the Properties window (§5.8). Inputs are plain values, so tests need no Core initializers.
@MainActor
enum PropertiesFormat {
    static func grouped(_ value: Int64, locale: Locale = .current) -> String {
        value.formatted(.number.locale(locale))
    }

    /// "1.2 MB (1,234,567 bytes)"; unknown sizes show "--".
    static func size(_ bytes: Int64?, locale: Locale = .current) -> String {
        guard let bytes else { return Formatters.folderSize }
        return String(format: L10n.string("%@ (%@ bytes)"), Formatters.bytes(bytes), grouped(bytes, locale: locale))
    }

    /// "1,204 files, 3 folders", prefixed with "Counting…" until the background count finishes.
    static func contains(files: Int, folders: Int, finished: Bool, locale: Locale = .current) -> String {
        let text = String(format: L10n.string("%@ files, %@ folders"),
                          grouped(Int64(files), locale: locale), grouped(Int64(folders), locale: locale))
        return finished ? text : String(format: L10n.string("Counting… %@"), text)
    }

    /// Multiple selection header: "3 items (2 files, 1 folders)".
    static func items(count: Int, files: Int, folders: Int, locale: Locale = .current) -> String {
        String(format: L10n.string("%@ items (%@ files, %@ folders)"), grouped(Int64(count), locale: locale),
               grouped(Int64(files), locale: locale), grouped(Int64(folders), locale: locale))
    }

    static func date(_ date: Date?) -> String {
        date.map { Formatters.date($0, style: .absolute) } ?? Formatters.folderSize
    }

    static func access(_ access: PermissionAccess) -> String {
        switch access {
        case .readWrite: L10n.string("Read & Write")
        case .readOnly: L10n.string("Read only")
        case .writeOnly: L10n.string("Write only")
        case .noAccess: L10n.string("No access")
        }
    }

    static func who(_ who: PermissionClass, owner: String, group: String) -> String {
        switch who {
        case .owner: String(format: L10n.string("Owner (%@)"), owner)
        case .group: String(format: L10n.string("Group (%@)"), group)
        case .everyone: L10n.string("Everyone")
        }
    }

    /// Used fraction for the volume usage bar; nil when the capacity is unknown.
    static func usage(capacity: Int64?, available: Int64?) -> Double? {
        guard let capacity, capacity > 0, let available else { return nil }
        return min(1, max(0, Double(capacity - available) / Double(capacity)))
    }

    static func quarantine(agent: String?, date: Date?) -> String {
        let parts = [agent, date.map { Formatters.date($0, style: .absolute) }].compactMap { $0 }
        return parts.isEmpty ? L10n.string("Quarantined") : parts.joined(separator: ", ")
    }
}

extension Tri {
    init(_ on: Bool) { self = on ? .on : .off }

    /// A click on an unchecked or mixed box checks it (applies to every item); a click on a checked box unchecks it.
    var afterClick: Bool { self != .on }
}

/// AppKit checkbox with a real mixed state (§5.8 multiple selection; P1-38's Compare headers). The model owns the
/// state: a click reports the new value and the box shows whatever the model says next.
struct TriCheckbox: NSViewRepresentable {
    let title: String
    let state: Tri
    var isEnabled = true
    let onToggle: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToggle: onToggle) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = true
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.onToggle = onToggle
        context.coordinator.state = state
        button.title = title
        button.isEnabled = isEnabled
        button.state = switch state {
        case .on: .on
        case .off: .off
        case .mixed: .mixed
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onToggle: (Bool) -> Void
        var state: Tri = .off

        init(onToggle: @escaping (Bool) -> Void) { self.onToggle = onToggle }

        @objc func clicked(_ sender: NSButton) {
            let on = state.afterClick
            sender.state = on ? .on : .off     // AppKit would cycle into mixed; the model decides instead
            onToggle(on)
        }
    }
}
