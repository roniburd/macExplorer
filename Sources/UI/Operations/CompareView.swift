import AppKit
import SwiftUI
import Core

/// §6.4 Compare: per-item "keep source" / "keep destination" checkboxes, as in Explorer. Both → Keep Both; source
/// only → Replace (Merge for folder pairs); destination only → Skip.
struct CompareSelection: Equatable {
    struct Row: Equatable, Identifiable {
        let pair: ConflictPair
        var keepSource = false
        var keepDestination = false

        var id: URL { pair.source.url }
        var isFolderPair: Bool { pair.source.isDirectory && pair.destination.isDirectory }
        var action: ConflictAction? {
            CompareSelection.action(keepSource: keepSource, keepDestination: keepDestination, isFolderPair: isFolderPair)
        }
    }

    var rows: [Row]

    /// The current pair first, then the other known top-level conflicts, without duplicates.
    init(_ info: ConflictInfo) {
        var seen = Set<URL>()
        rows = ([info.pair] + info.pendingPairs).compactMap { pair in
            seen.insert(pair.source.url).inserted ? Row(pair: pair) : nil
        }
    }

    static func action(keepSource: Bool, keepDestination: Bool, isFolderPair: Bool) -> ConflictAction? {
        switch (keepSource, keepDestination) {
        case (true, true): .keepBoth
        case (true, false): isFolderPair ? .merge : .replace
        case (false, true): .skip
        case (false, false): nil
        }
    }

    var canContinue: Bool { rows.allSatisfy { $0.action != nil } }
    var allSources: Tri { Self.tri(rows.map(\.keepSource)) }
    var allDestinations: Tri { Self.tri(rows.map(\.keepDestination)) }

    mutating func setAllSources(_ on: Bool) {
        for index in rows.indices { rows[index].keepSource = on }
    }

    mutating func setAllDestinations(_ on: Bool) {
        for index in rows.indices { rows[index].keepDestination = on }
    }

    /// One action per source URL (rows without a choice skip; Continue is disabled until there are none).
    var resolution: ConflictResolution {
        .perItem(Dictionary(rows.map { ($0.pair.source.url, $0.action ?? .skip) }, uniquingKeysWith: { first, _ in first }))
    }

    private static func tri(_ values: [Bool]) -> Tri {
        values.allSatisfy { $0 } ? .on : values.contains(true) ? .mixed : .off
    }
}

struct CompareView: View {
    @Binding var selection: CompareSelection
    let icon: @MainActor (ItemSummary) -> NSImage?
    let onContinue: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: L10n.string("Which items do you want to keep?")).font(.headline)
            Text(verbatim: L10n.string("If you keep both, the copied item gets a number added to its name."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TriCheckbox(title: L10n.string("From source"), state: selection.allSources) { selection.setAllSources($0) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                TriCheckbox(title: L10n.string("At destination"), state: selection.allDestinations) { selection.setAllDestinations($0) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($selection.rows) { $row in
                        HStack(alignment: .top, spacing: 12) {
                            CompareSide(item: row.pair.source, icon: icon(row.pair.source), isOn: $row.keepSource)
                            CompareSide(item: row.pair.destination, icon: icon(row.pair.destination), isOn: $row.keepDestination)
                        }
                        Divider()
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 320)
            HStack {
                Button(L10n.string("Back"), action: onBack)
                Spacer()
                Button(L10n.string("Continue"), action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!selection.canContinue)
            }
        }
        .padding(20)
        .frame(width: 600)
    }
}

/// One side of a Compare row: checkbox, icon, name, size, modified date and folder path.
private struct CompareSide: View {
    let item: ItemSummary
    let icon: NSImage?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: 8) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 32, height: 32) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: item.isDirectory ? L10n.string("Folder") : Formatters.bytes(item.size)).font(.caption)
                    Text(verbatim: Formatters.date(item.modified, style: .absolute)).font(.caption)
                    Text(verbatim: item.url.deletingLastPathComponent().path)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
