import Foundation

struct ScenarioResult: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case passed, failed, skipped }
    var name: String
    var status: Status
    var message: String?
    var durationMs: Int
    var sandbox: String
    var sandboxRemoved: Bool
}

struct RunReport: Codable, Equatable, Sendable {
    var results: [ScenarioResult]
    var passed: Int
    var failed: Int
    var skipped: Int
}

enum ScenarioOutcome: Sendable, Equatable { case passed, skipped(String), failed(String) }

@MainActor
enum ScenarioRunner {
    /// Called with each scenario sandbox root right after it is created (the CLI's --manifest).
    static var onSandboxCreated: ((URL) -> Void)?

    static func runOne(_ scenario: CoreScenario, helper: URL?, requireImages: Bool, keepSandbox: Bool) async -> ScenarioResult {
        let clock = ContinuousClock()
        let start = clock.now
        let sandbox: SandboxHandle
        do { sandbox = try SandboxHandle.make(prefix: "macx-scenario") } catch {
            return ScenarioResult(name: scenario.name, status: .failed, message: "cannot create sandbox: \(error)",
                                  durationMs: 0, sandbox: "", sandboxRemoved: true)
        }
        onSandboxCreated?(sandbox.root)
        let ctx = ScenarioContext(name: scenario.name, sandbox: sandbox, helperExecutable: helper)
        _ = await ctx.env.start()

        let task = Task { @MainActor () -> ScenarioOutcome in
            do {
                try await scenario.body(ctx)
                return .passed
            } catch let skip as ScenarioSkip {
                return .skipped(skip.reason)
            } catch {
                return .failed(String(describing: error))
            }
        }
        var outcome = await Deadline.wait(for: task, timeout: scenario.timeout)
        var stopped = true
        if outcome == nil {
            task.cancel()
            let queue = ctx.env.fileOps
            _ = await Deadline.run(.seconds(10)) { await queue.cancelAll() }
            stopped = await Deadline.wait(for: task, timeout: .seconds(5)) != nil
            outcome = .failed("timed out after \(scenario.timeout)"
                              + (stopped ? "" : "; the scenario did not stop, sandbox kept at \(sandbox.root.path)"))
        }

        var removed = false
        if stopped && !keepSandbox { removed = await ctx.cleanup() } else { ctx.closeAll() }

        let elapsed = (clock.now - start).components
        let ms = Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
        let (status, message): (ScenarioResult.Status, String?) = switch outcome ?? .failed("no outcome") {
        case .passed: (.passed, nil)
        case .skipped(let reason): requireImages ? (.failed, "required but skipped: \(reason)") : (.skipped, reason)
        case .failed(let message): (.failed, message)
        }
        return ScenarioResult(name: scenario.name, status: status, message: message, durationMs: ms,
                              sandbox: sandbox.root.path, sandboxRemoved: removed)
    }

    static func run(_ scenarios: [CoreScenario], helper: URL?, requireImages: Bool, keepSandbox: Bool,
                    log: (String) -> Void) async -> RunReport {
        var results: [ScenarioResult] = []
        for scenario in scenarios {
            let r = await runOne(scenario, helper: helper, requireImages: requireImages, keepSandbox: keepSandbox)
            results.append(r)
            switch r.status {
            case .passed: log("PASS \(r.name) (\(r.durationMs) ms)")
            case .skipped: log("SKIP \(r.name): \(r.message ?? "")")
            case .failed: log("FAIL \(r.name): \(r.message ?? "")")
            }
            log(r.sandboxRemoved ? "  sandbox \(r.sandbox) removed" : "  sandbox \(r.sandbox) KEPT")
            if r.status == .failed && !r.sandboxRemoved && !keepSandbox {
                log("ABORT: \(r.name) left its sandbox in use; not running further scenarios")
                break
            }
        }
        return RunReport(results: results,
                         passed: results.filter { $0.status == .passed }.count,
                         failed: results.filter { $0.status == .failed }.count,
                         skipped: results.filter { $0.status == .skipped }.count)
    }
}
