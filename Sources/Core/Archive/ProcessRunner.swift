import Foundation
import Darwin
import MacxFS

/// Where a tool's standard output goes. `.file` creates the file exclusively (never replaces one).
public enum ProcessOutput: Sendable, Equatable { case discard, capture, file(URL) }

public struct ProcessResult: Sendable, Equatable {
    /// The exit status, or 128 + the signal number for a tool killed by a signal.
    public var status: Int32
    /// Captured standard output (`.capture` only; at most `ProcessRunner.captureLimit` bytes).
    public var stdout: Data
    /// The last 4 KiB of standard error.
    public var stderrTail: String
}

/// The tool couldn't be started (`posix_spawn` errno, e.g. ENOENT) or its output file couldn't be created (EEXIST).
public struct ProcessRunnerError: Error, Sendable, Equatable, ErrnoCarrying {
    public var code: Int32
    public init(code: Int32) { self.code = code }
    var errnoCode: Int32 { code }
}

/// Runs a system tool (ditto, aa, tar) on a lane: `posix_spawn` with a fixed environment and only stdin/stdout/stderr
/// inherited, heartbeats while it runs, SIGSTOP/SIGCONT for pause, SIGTERM (SIGKILL after 2 s) for cancel. Standard
/// error is delivered line by line (the tools' verbose progress) and its tail is kept for error messages.
public enum ProcessRunner {
    static let captureLimit = 64 << 20
    static let tailLimit = 4096
    static let pollMilliseconds: Int32 = 50
    static let killDelay: Duration = .seconds(2)

    /// Cancelled when the awaiting Task is (`LaneContext.isCancelled`): throws `LaneError.cancelled` once the tool ended.
    public static func run(_ tool: String, _ arguments: [String], output: ProcessOutput = .discard, context: LaneContext,
                           isPaused: @escaping @Sendable () -> Bool,
                           onStderrLine: @escaping @Sendable (String) -> Void) throws -> ProcessResult {
        try run(tool, arguments, output: output, context: context, isPaused: isPaused, isCancelled: { false },
                onStderrLine: onStderrLine)
    }

    /// Jobs pass `isCancelled: { control.isCancelled }`: a job's cancel goes through JobControl, not through the
    /// awaiting Task. `onStarted` runs on the lane right after the tool was spawned.
    static func run(_ tool: String, _ arguments: [String], output: ProcessOutput = .discard, context: LaneContext,
                    isPaused: @escaping @Sendable () -> Bool, isCancelled: @escaping @Sendable () -> Bool,
                    onStarted: (() -> Void)? = nil,
                    onStderrLine: @escaping @Sendable (String) -> Void) throws -> ProcessResult {
        assertOffMain()
        // Child ends: stdout (the output file, a pipe or /dev/null) and stderr (a pipe).
        var outRead: Int32 = -1, outWrite: Int32 = -1
        switch output {
        case .discard:
            outWrite = open("/dev/null", O_WRONLY | O_CLOEXEC)
        case .capture:
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else { throw ProcessRunnerError(code: errno) }
            outRead = fds[0]; outWrite = fds[1]
        case .file(let url):
            outWrite = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        }
        guard outWrite >= 0 else {
            let code = errno
            if outRead >= 0 { close(outRead) }
            throw ProcessRunnerError(code: code)
        }
        var errFDs: [Int32] = [-1, -1]
        guard pipe(&errFDs) == 0 else {
            let code = errno
            close(outWrite); if outRead >= 0 { close(outRead) }
            throw ProcessRunnerError(code: code)
        }
        let errRead = errFDs[0], errWrite = errFDs[1]
        for fd in [outRead, errRead] where fd >= 0 {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        _ = fcntl(errWrite, F_SETFD, FD_CLOEXEC)

        let pid: pid_t
        do {
            pid = try spawn(tool, arguments, stdout: outWrite, stderr: errWrite)
        } catch {
            close(outWrite); close(errWrite); close(errRead); if outRead >= 0 { close(outRead) }
            throw error
        }
        close(outWrite); close(errWrite)       // the child holds its own copies
        defer { close(errRead); if outRead >= 0 { close(outRead) } }
        onStarted?()

        var captured = Data()
        var tail = Data()
        var pending = Data()
        var openFDs = [errRead] + (outRead >= 0 ? [outRead] : [])
        var buffer = [UInt8](repeating: 0, count: 64 << 10)

        func deliverLines() {
            while let nl = pending.firstIndex(of: 0x0A) {
                onStderrLine(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...nl)
            }
        }
        /// Reads what is available on `fd`; false at EOF or on an error other than EAGAIN/EINTR.
        func drain(_ fd: Int32) -> Bool {
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    let chunk = Data(buffer[0..<n])
                    if fd == errRead {
                        tail.append(chunk)
                        if tail.count > tailLimit { tail = tail.suffix(tailLimit) }
                        pending.append(chunk)
                        deliverLines()
                    } else if captured.count < captureLimit {
                        captured.append(chunk.prefix(captureLimit - captured.count))
                    }
                    continue
                }
                if n == 0 { return false }
                if errno == EINTR { continue }
                return errno == EAGAIN
            }
        }
        func pollOnce() {
            var fds = openFDs.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            guard !fds.isEmpty else { usleep(UInt32(pollMilliseconds) * 1000); return }
            guard poll(&fds, nfds_t(fds.count), pollMilliseconds) > 0 else { return }
            for p in fds where p.revents != 0 {
                if !drain(p.fd) { openFDs.removeAll { $0 == p.fd } }
            }
        }

        var stopped = false
        var termSentAt: ContinuousClock.Instant?
        var killed = false
        var status: Int32 = 0
        while true {
            context.heartbeat()
            var st: Int32 = 0
            let w = waitpid(pid, &st, WNOHANG)
            if w == pid { status = st; break }
            if w < 0, errno != EINTR { status = 0x7f00; break }   // not our child any more: treat as failed
            if termSentAt == nil, context.isCancelled || isCancelled() {
                kill(pid, SIGTERM)
                if stopped { kill(pid, SIGCONT); stopped = false }
                termSentAt = .now
            }
            if let t = termSentAt, !killed, ContinuousClock.now - t > killDelay { kill(pid, SIGKILL); killed = true }
            if termSentAt == nil {
                let paused = isPaused()
                if paused != stopped { kill(pid, paused ? SIGSTOP : SIGCONT); stopped = paused }
            }
            pollOnce()
        }
        // The tool is gone: whatever it wrote is in the pipes now.
        for fd in openFDs { _ = drain(fd) }
        if !pending.isEmpty {
            onStderrLine(String(decoding: pending, as: UTF8.self))
            pending.removeAll()
        }
        if termSentAt != nil { throw LaneError.cancelled }
        return ProcessResult(status: exitStatus(status), stdout: captured, stderrTail: String(decoding: tail, as: UTF8.self))
    }

    /// waitpid status → exit code, or 128 + signal.
    static func exitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// stdin is /dev/null, stdout/stderr the given descriptors; nothing else is inherited (POSIX_SPAWN_CLOEXEC_DEFAULT).
    /// Signals start at their defaults and unblocked (the app may ignore SIGPIPE). English messages, a fixed PATH.
    private static func spawn(_ tool: String, _ arguments: [String], stdout: Int32, stderr: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attr)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        var noSignals = sigset_t(), allSignals = sigset_t()
        sigemptyset(&noSignals); sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        let argv: [UnsafeMutablePointer<CChar>?] = ([tool] + arguments).map { strdup($0) } + [nil]
        let environment: [String] = ["LANG=en_US.UTF-8", "LC_ALL=en_US.UTF-8", "PATH=/usr/bin:/bin"]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer { for p in argv + envp { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, tool, &actions, &attr, argv, envp)
        guard rc == 0 else { throw ProcessRunnerError(code: rc) }
        return pid
    }
}
