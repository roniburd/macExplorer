import Foundation
import Core

/// The launch notice after LaunchRecovery cleaned up an interrupted session (§3.14 launch obligations, §6.7).
struct RecoveryNotice: Equatable {
    var message: String
    var details: String

    /// nil when there is nothing to tell.
    @MainActor init?(_ report: RecoveryReport) {
        guard !report.isEmpty else { return nil }
        func line(_ count: Int, one: String, many: String) -> String? {
            switch count {
            case 0: nil
            case 1: one
            default: String(format: many, count)
            }
        }
        message = L10n.string("MacExplorer cleaned up after operations that were interrupted")
        details = [
            line(report.incompleteJobs.count, one: L10n.string("1 operation didn't finish."), many: L10n.string("%ld operations didn't finish.")),
            line(report.removedPartials.count, one: L10n.string("Removed 1 incomplete copy."), many: L10n.string("Removed %ld incomplete copies.")),
            line(report.restoredDestinations.count, one: L10n.string("Put back 1 item that was being replaced."),
                 many: L10n.string("Put back %ld items that were being replaced.")),
            line(report.restoredRenames.count, one: L10n.string("Restored the original name of 1 item."),
                 many: L10n.string("Restored the original names of %ld items.")),
        ].compactMap { $0 }.joined(separator: "\n")
    }
}
