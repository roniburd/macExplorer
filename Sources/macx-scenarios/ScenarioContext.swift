import Core
import Darwin
import Foundation
import MacxFS

@MainActor final class OutcomeBox { var value: JobOutcome? }

@MainActor
final class ScenarioContext {
    let name: String
    let sandbox: SandboxHandle
    let env: CoreEnvironment
    /// Fixtures live here, so CoreEnvironment.sandboxed's root/.trash and root/state never show up in listings.
    let work: URL
    let helperExecutable: URL?
    private var images: [ImageHandle] = []
    private var models: [FolderModel] = []
    private var tokens: [ObserverToken] = []
    private var queues: [FileOpQueue] = []
    private var helpers: [Process] = []

    init(name: String, sandbox: SandboxHandle, helperExecutable: URL?) {
        self.name = name
        self.sandbox = sandbox
        self.helperExecutable = helperExecutable
        self.env = CoreEnvironment.sandboxed(root: sandbox.root)
        self.work = sandbox.dir("work")
    }

    // MARK: fixtures (writes only through the sandbox or on sandbox-derived paths)

    func path(_ rel: String) -> URL { sandbox.url("work/\(rel)") }
    @discardableResult func file(_ rel: String, _ text: String = "x") -> URL { sandbox.file("work/\(rel)", Data(text.utf8)) }
    @discardableResult func file(_ rel: String, bytes: Int) -> URL { sandbox.file("work/\(rel)", Data(count: bytes)) }
    @discardableResult func file(at url: URL, _ text: String = "x") -> URL { sandbox.file(sandbox.relative(url), Data(text.utf8)) }
    @discardableResult func dir(_ rel: String) -> URL { sandbox.dir("work/\(rel)") }
    @discardableResult func dir(at url: URL) -> URL { sandbox.dir(sandbox.relative(url)) }
    @discardableResult func flat(_ rel: String, count: Int) -> URL { sandbox.flat("work/\(rel)", count: count) }

    private func guarded(_ url: URL) -> String {
        precondition(sandbox.contains(url), "outside sandbox: \(url.path)")
        return url.path
    }

    func setFlags(_ url: URL, _ flags: UInt32) throws {
        guard chflags(guarded(url), flags) == 0 else { throw ScenarioFailure("chflags \(url.lastPathComponent): errno \(errno)") }
    }
    func setMode(_ url: URL, _ mode: mode_t) throws {
        guard chmod(guarded(url), mode) == 0 else { throw ScenarioFailure("chmod \(url.lastPathComponent): errno \(errno)") }
    }
    func setModificationDate(_ url: URL, _ date: Date) throws {
        let t = timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0)
        var times = [t, t]
        guard utimensat(AT_FDCWD, guarded(url), &times, AT_SYMLINK_NOFOLLOW) == 0 else { throw ScenarioFailure("utimensat: errno \(errno)") }
    }
    func setXattr(_ url: URL, _ name: String, _ value: String) throws {
        let path = guarded(url)
        let r = value.withCString { setxattr(path, name, $0, strlen($0), 0, XATTR_NOFOLLOW) }
        guard r == 0 else { throw ScenarioFailure("setxattr: errno \(errno)") }
    }
    func symlink(_ rel: String, to target: String) throws {
        guard Darwin.symlink(target, guarded(path(rel))) == 0 else { throw ScenarioFailure("symlink: errno \(errno)") }
    }
    func renameRaw(_ from: URL, to: URL) throws {
        guard Darwin.rename(guarded(from), guarded(to)) == 0 else { throw ScenarioFailure("rename: errno \(errno)") }
    }
    func removeRaw(_ url: URL) throws {
        guard unlink(guarded(url)) == 0 else { throw ScenarioFailure("unlink: errno \(errno)") }
    }
    func removeTreeRaw(_ url: URL) throws {
        _ = guarded(url)
        try FileManager.default.removeItem(at: url)
    }
    func background(_ work: @escaping @Sendable () -> Void) async { await Task.detached(operation: work).value }

    // MARK: reads (harness-side, read-only)

    private func lstatOf(_ url: URL) -> stat? {
        var st = stat()
        return lstat(url.path, &st) == 0 ? st : nil
    }
    func exists(_ url: URL) -> Bool { lstatOf(url) != nil }
    func size(_ url: URL) -> Int64? { lstatOf(url).map { Int64($0.st_size) } }
    func isDirectory(_ url: URL) -> Bool { lstatOf(url).map { ($0.st_mode & 0o170000) == 0o040000 } ?? false }
    func mode(_ url: URL) -> mode_t? { lstatOf(url).map { $0.st_mode & 0o7777 } }
    func flags(_ url: URL) -> UInt32 { lstatOf(url)?.st_flags ?? 0 }
    func inode(_ url: URL) -> UInt64? { lstatOf(url).map { UInt64($0.st_ino) } }
    func mtimeSeconds(_ url: URL) -> Int? { lstatOf(url).map { $0.st_mtimespec.tv_sec } }
    func readLink(_ url: URL) -> String? {
        var buffer = [CChar](repeating: 0, count: 1_024)
        let n = readlink(url.path, &buffer, buffer.count - 1)
        guard n >= 0 else { return nil }
        return String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    func xattr(_ url: URL, _ name: String) -> String? {
        let n = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard n >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: n)
        guard getxattr(url.path, name, &buffer, n, 0, XATTR_NOFOLLOW) == n else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }
    func entries(_ dir: URL) -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []) }
    func isAliasFile(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true }
    func resolveAlias(_ url: URL) -> URL? { try? URL(resolvingAliasFileAt: url) }

    static func isMounted(_ path: String) -> Bool {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return false }
        let mountedOn = withUnsafeBytes(of: s.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return mountedOn == URL(filePath: path).resolvingSymlinksInPath().path
    }

    // MARK: models

    func track(_ model: FolderModel) { models.append(model) }
    func keep(_ token: ObserverToken) { tokens.append(token) }
    func names(_ model: FolderModel) -> [String] { (0..<model.rowCount).map { model.name(atRow: $0) } }

    /// Ceiling of a condition wait. Polling returns as soon as the condition holds, so it only matters when FSEvents
    /// delivery or a lane read is slow: a CPU-starved CI runner (or `swift test --parallel`) took more than 5 s.
    nonisolated static let defaultWait: Duration = .seconds(30)

    func open(_ dir: URL, query: ViewQuery = ViewQuery(), timeout: Duration = ScenarioContext.defaultWait) async throws -> FolderModel {
        let model = env.makeFolderModel(dir, query: query)
        track(model)
        model.start()
        try await waitUntil("\(dir.lastPathComponent) finishes loading", timeout: timeout) {
            model.state != .loading && model.state != .partial
        }
        return model
    }

    func waitUntil(_ what: String, timeout: Duration = ScenarioContext.defaultWait, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline { throw ScenarioFailure("timed out after \(timeout) waiting for: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func waitUntilAsync(_ what: String, timeout: Duration = ScenarioContext.defaultWait, _ condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()) {
            if clock.now >= deadline { throw ScenarioFailure("timed out after \(timeout) waiting for: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: jobs

    func setInteraction(_ interaction: ScriptedInteraction) { env.interaction.setTarget(interaction) }
    func perform(_ kind: JobKind) async -> JobOutcome { await env.operations.perform(JobRequest(kind)) }

    func undo() async throws -> JobOutcome {
        try expect(env.undo.canUndo, "nothing to undo")
        return try await nextFinished { self.env.undo.undoManager.undo() }
    }

    func redo() async throws -> JobOutcome {
        try expect(env.undo.canRedo, "nothing to redo")
        return try await nextFinished { self.env.undo.undoManager.redo() }
    }

    private func nextFinished(_ trigger: () -> Void) async throws -> JobOutcome {
        let box = OutcomeBox()
        let token = env.operations.onFinished { _, outcome in
            if box.value == nil { box.value = outcome }
        }
        defer { token.cancel() }
        trigger()
        try await waitUntil("the undo/redo job finishes", timeout: .seconds(20)) { box.value != nil }
        return try unwrap(box.value, "undo/redo outcome")
    }

    /// A queue of our own (custom trash/tuning) for disk-image scenarios; journal inside the sandbox.
    func makeQueue(trash: URL, interaction: any FileOpInteraction, tuning: FileOpTuning = FileOpTuning()) -> FileOpQueue {
        let journal = Journal(fileURL: sandbox.dir("queue-state").appending(path: "\(UUID().uuidString).json"))
        let queue = FileOpQueue(lanes: env.lanes, trash: SandboxTrash(directory: trash), journal: journal,
                                interaction: interaction, tuning: tuning)
        queues.append(queue)
        return queue
    }

    func run(_ queue: FileOpQueue, _ kind: JobKind) async -> JobOutcome {
        let id = await queue.enqueue(JobRequest(kind, registersUndo: false))
        return await queue.outcome(of: id)
    }

    // MARK: images and helper processes

    func image(_ name: String, _ format: ImageFormat, sizeMB: Int, readOnly: Bool = false) async throws -> ImageHandle {
        guard SandboxHandle.imagesAvailable else { throw ScenarioSkip("hdiutil is not available") }
        let image = try sandbox.image(name, format, sizeMB: sizeMB, readOnly: readOnly)
        images.append(image)
        await env.volumes.refresh()
        return image
    }

    func requireHelper() throws -> URL {
        guard let helper = helperExecutable, FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ScenarioSkip("the macx-scenarios executable is not available as a crash helper")
        }
        return helper
    }

    func launchHelper(_ executable: URL, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        helpers.append(process)
        return process
    }

    // MARK: assertions

    func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String,
                file: StaticString = #fileID, line: UInt = #line) throws {
        if !condition() { throw ScenarioFailure("\(message()) (\(file):\(line))") }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ what: String, file: StaticString = #fileID, line: UInt = #line) throws {
        if actual != expected { throw ScenarioFailure("\(what): expected \(expected), got \(actual) (\(file):\(line))") }
    }

    func unwrap<T>(_ value: T?, _ what: String, file: StaticString = #fileID, line: UInt = #line) throws -> T {
        guard let value else { throw ScenarioFailure("\(what) is nil (\(file):\(line))") }
        return value
    }

    // MARK: teardown

    func closeAll() {
        for model in models { model.close() }
        models.removeAll()
        for token in tokens { token.cancel() }
        tokens.removeAll()
    }

    /// Closes models, cancels every job, kills helpers, detaches images, clears protections, deletes the sandbox.
    /// Returns true if the sandbox root no longer exists.
    func cleanup() async -> Bool {
        closeAll()
        let main = env.fileOps
        _ = await Deadline.run(.seconds(10)) { await main.cancelAll() }
        for queue in queues { _ = await Deadline.run(.seconds(10)) { await queue.cancelAll() } }
        queues.removeAll()
        for process in helpers where process.isRunning { kill(process.processIdentifier, SIGKILL) }
        helpers.removeAll()
        for image in images.reversed() {
            do { try image.detach() } catch {
                try? await Task.sleep(for: .milliseconds(500))
                try? image.detach()
            }
        }
        images.removeAll()
        sandbox.makeWritable()
        sandbox.destroy()
        return !FileManager.default.fileExists(atPath: sandbox.root.path)
    }
}
