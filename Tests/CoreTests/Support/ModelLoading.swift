@testable import Core
import Foundation
import MacxFS

enum ModelLoadingError: Error { case timeout(URL, FolderState) }

/// Opens `directory` with the environment's real readers and watcher and waits until the listing completes.
/// The caller closes the model (tests register `addTeardownBlock`).
@MainActor
func loadedModel(_ directory: URL, env: CoreEnvironment, query: ViewQuery? = nil,
                 timeout: Duration = .seconds(30)) async throws -> FolderModel {
    let model = env.makeFolderModel(directory, query: query)
    model.start()
    let deadline = ContinuousClock.now + timeout
    while model.state != .complete {
        guard ContinuousClock.now < deadline else { model.close(); throw ModelLoadingError.timeout(directory, model.state) }
        try await Task.sleep(for: .milliseconds(10))
    }
    return model
}
