import Foundation
import Core
import MacxFS

/// Subfolders of one folder for the breadcrumb's › menus (§5.2). Reads through the folder's volume's
/// `DirectoryReader` (directories only, no materialization), so it runs on an I/O lane, never on main.
enum SubfolderLister {
    static let limit = 1_000

    /// Folder names (not packages), sorted like Finder; hidden ones only with `showHidden`. [] when unreadable.
    static func list(_ directory: URL, readers: DirectoryReaders, showHidden: Bool) async -> [String] {
        var options = ReadOptions()
        options.directoriesOnly = true
        options.noMaterialization = true
        let stream = await readers.reader(for: directory).read(directory, generation: .initial, options: options)
        var names: [String] = []
        loop: for await event in stream {
            switch event {
            case .batch(let batch):
                for index in 0..<batch.count {
                    let entry = batch.entries[index]
                    guard entry.kind == .directory, showHidden || !entry.flags.isHidden else { continue }
                    names.append(batch.name(at: index))
                }
                if names.count >= limit { break loop }
            case .completed, .failed, .stalled:
                break loop
            case .waitingForPermission, .resumed:
                continue
            }
        }
        names.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return Array(names.prefix(limit))
    }
}
