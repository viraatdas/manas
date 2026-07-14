import Foundation

/// One finished run of an external command.
struct CommandOutput: Hashable, Sendable {
    var exitStatus: Int32
    var stdout: Data
    var stderr: Data

    init(exitStatus: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Failures launching or supervising an external command.
enum CommandError: Error, Equatable {
    case launchFailed(String)
    case timedOut
}

/// Seam over Process so the judge can be tested without spawning real binaries.
protocol CommandRunning: Sendable {
    /// Runs `executablePath` with `arguments`, killing the process after
    /// `timeout` seconds (throwing `CommandError.timedOut`).
    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> CommandOutput
}
