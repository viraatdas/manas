import Foundation

/// Finds the user's installed claude CLI. GUI apps don't inherit the shell's
/// PATH, so the common install locations are probed directly first, then the
/// user's login shell is asked as a last resort.
struct ClaudeCLILocator: Sendable {
    var candidatePaths: [String]
    var shellPath: String
    var runner: any CommandRunning
    var isExecutableFile: @Sendable (String) -> Bool

    init(
        runner: any CommandRunning = ProcessCommandRunner(),
        homeDirectory: String = NSHomeDirectory(),
        shellPath: String? = nil,
        isExecutableFile: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.candidatePaths = [
            "\(homeDirectory)/.claude/local/claude",
            "\(homeDirectory)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        self.shellPath = shellPath ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        self.runner = runner
        self.isExecutableFile = isExecutableFile
    }

    func locate() async -> String? {
        for path in candidatePaths where isExecutableFile(path) {
            return path
        }
        return await locateViaLoginShell()
    }

    private func locateViaLoginShell() async -> String? {
        guard
            let output = try? await runner.run(
                executablePath: shellPath,
                arguments: ["-l", "-c", "command -v claude"],
                timeout: 10
            ),
            output.exitStatus == 0
        else { return nil }
        // Login shells can print banners; the path is the last non-empty line.
        let lines = String(decoding: output.stdout, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let path = lines.last, path.hasPrefix("/"), isExecutableFile(path) else { return nil }
        return path
    }
}
