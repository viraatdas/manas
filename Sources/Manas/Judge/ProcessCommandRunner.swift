import Foundation

/// Process-backed CommandRunning: async, cancellable, kills on timeout, and
/// never blocks the main thread (pipes are drained with async reads).
struct ProcessCommandRunner: CommandRunning {
    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // GUI apps inherit a minimal PATH; extend it so wrapper scripts (the
        // claude launcher shells out to its runtime) resolve wherever the
        // user installed them.
        process.environment = Self.environmentWithAugmentedPATH()

        let supervisor = ProcessSupervisor(process)
        process.terminationHandler = { _ in supervisor.processDidTerminate() }

        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed(error.localizedDescription)
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: CommandOutput.self) { group in
                group.addTask {
                    async let stdout = Self.readToEnd(stdoutHandle)
                    async let stderr = Self.readToEnd(stderrHandle)
                    let (out, err) = try await (stdout, stderr)
                    await supervisor.waitForTermination()
                    if supervisor.didTimeOut { throw CommandError.timedOut }
                    try Task.checkCancellation()
                    return CommandOutput(exitStatus: supervisor.exitStatus, stdout: out, stderr: err)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    supervisor.timeOut()
                    throw CommandError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } onCancel: {
            supervisor.terminate()
        }
    }

    private static func readToEnd(_ handle: FileHandle) async throws -> Data {
        var data = Data()
        for try await byte in handle.bytes {
            data.append(byte)
        }
        return data
    }

    static func environmentWithAugmentedPATH(
        base: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> [String: String] {
        var environment = base
        let preferred = [
            "\(homeDirectory)/.claude/local",
            "\(homeDirectory)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        var parts = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .components(separatedBy: ":")
        for directory in preferred.reversed() where !parts.contains(directory) {
            parts.insert(directory, at: 0)
        }
        environment["PATH"] = parts.joined(separator: ":")
        return environment
    }
}

/// Tracks one child process across the reader, timeout, and cancellation
/// tasks. @unchecked Sendable: mutable state is guarded by `lock`, and the
/// Process only receives thread-safe signal/status calls.
private final class ProcessSupervisor: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var timedOut = false
    private var terminated = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(_ process: Process) {
        self.process = process
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    /// Only valid after the process has terminated.
    var exitStatus: Int32 { process.terminationStatus }

    func processDidTerminate() {
        lock.lock()
        terminated = true
        let waiting = continuations
        continuations = []
        lock.unlock()
        waiting.forEach { $0.resume() }
    }

    func waitForTermination() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if terminated {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }

    func timeOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
        terminate()
    }

    /// SIGTERM now, SIGKILL two seconds later if the process ignored the hint.
    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}
