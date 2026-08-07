import Foundation

/// Everything that can go wrong during a check-in, typed so the UI can show a
/// sensible message for each case.
enum JudgeError: Error, Equatable, LocalizedError {
    /// No claude CLI on this machine (or not anywhere we know to look).
    case cliNotFound
    case launchFailed(String)
    case nonZeroExit(code: Int32, stderr: String)
    case timedOut(seconds: TimeInterval)
    /// The CLI ran but printed something that isn't its JSON envelope.
    case malformedCLIOutput(String)
    /// The model's reply wasn't the strict JSON we asked for, even after a retry.
    case malformedModelOutput(String)
    /// The CLI's envelope says the run itself failed (is_error / non-success subtype).
    case cliReportedError(String)

    /// A coarse category for analytics. Deliberately a fixed vocabulary with no
    /// interpolated payload: `stderr`, CLI output, and model output all quote
    /// the user's own todos and messages, and none of that may leave the
    /// machine. Whoever adds a case here adds a constant, never a `\(value)`.
    var analyticsReason: String {
        switch self {
        case .cliNotFound: "cli_not_found"
        case .launchFailed: "launch_failed"
        case .nonZeroExit: "non_zero_exit"
        case .timedOut: "timed_out"
        case .malformedCLIOutput: "malformed_cli_output"
        case .malformedModelOutput: "malformed_model_output"
        case .cliReportedError: "cli_reported_error"
        }
    }

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "Claude CLI not found. Install Claude Code, then try again."
        case .launchFailed(let message):
            "Could not launch the claude CLI: \(message)"
        case .nonZeroExit(let code, let stderr):
            stderr.isEmpty
                ? "The claude CLI exited with code \(code)."
                : "The claude CLI exited with code \(code): \(stderr)"
        case .timedOut(let seconds):
            "The check-in timed out after \(Int(seconds)) seconds."
        case .malformedCLIOutput:
            "Could not read the claude CLI's response."
        case .malformedModelOutput:
            "Claude's reply was not the expected JSON, even after a retry."
        case .cliReportedError(let message):
            "The claude CLI reported an error: \(message)"
        }
    }
}
