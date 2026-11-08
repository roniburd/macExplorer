import Foundation
import Observation
import Core

/// The Install Previous Version window's state (install-previous-version spec).
@MainActor @Observable
final class RollbackModel {
    enum Phase: Equatable {
        case loading
        case list
        case empty
        case preparing(AppcastItem, fraction: Double?)
        /// Verified and armed: the swap happens when MacExplorer quits (a cancelled quit lands here).
        case ready(AppcastItem)
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var items: [AppcastItem] = []
    var selection: AppcastItem.ID?
    private let service: any RollbackServicing

    init(service: any RollbackServicing) { self.service = service }

    var installedVersion: String { service.installedVersion }
    var selectedItem: AppcastItem? { items.first { $0.id == selection } }
    var isBusy: Bool {
        if case .preparing = phase { true } else { false }
    }

    func load() async {
        phase = .loading
        if let blocked = service.preflight() { phase = .failed(blocked.message); return }
        do {
            items = try await service.candidates()
            selection = items.first?.id
            phase = items.isEmpty ? .empty : .list
        } catch {
            phase = .failed(error.message)
        }
    }

    /// After the user confirmed: download, verify, arm, quit.
    func install(_ item: AppcastItem) async {
        guard !isBusy else { return }
        phase = .preparing(item, fraction: nil)
        do {
            let staged = try await service.prepare(item) { [weak self] fraction in
                guard let self, case .preparing(let current, _) = self.phase, current == item else { return }
                self.phase = .preparing(item, fraction: fraction)
            }
            service.arm(staged)
            phase = .ready(item)
            service.quit()
        } catch {
            phase = .failed(error.message)
        }
    }

    func quitNow() {
        guard case .ready = phase else { return }
        service.quit()
    }

    /// Cancel Install / closing the window: nothing is swapped at quit.
    func cancelInstall() {
        service.disarm()
        if case .ready = phase { phase = items.isEmpty ? .empty : .list }
    }

    func backToList() {
        guard case .failed = phase else { return }
        Task { await load() }
    }
}
