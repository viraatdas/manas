import XCTest
@testable import Manas

/// Exercises the real Process layer with tiny system binaries — fast, no
/// network, no claude involved.
final class ProcessCommandRunnerTests: XCTestCase {
    private let runner = ProcessCommandRunner()

    func testCapturesStdoutAndExitStatus() async throws {
        let output = try await runner.run(executablePath: "/bin/echo", arguments: ["hello"], timeout: 10)
        XCTAssertEqual(output.exitStatus, 0)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "hello\n")
        XCTAssertTrue(output.stderr.isEmpty)
    }

    func testCapturesStderrAndNonZeroExit() async throws {
        let output = try await runner.run(
            executablePath: "/bin/sh",
            arguments: ["-c", "echo oops >&2; exit 3"],
            timeout: 10
        )
        XCTAssertEqual(output.exitStatus, 3)
        XCTAssertEqual(String(decoding: output.stderr, as: UTF8.self), "oops\n")
    }

    func testTimeoutKillsProcess() async {
        let started = Date()
        do {
            _ = try await runner.run(executablePath: "/bin/sleep", arguments: ["30"], timeout: 0.3)
            XCTFail("Expected timedOut")
        } catch let error as CommandError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("Expected CommandError.timedOut, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "Timeout must not wait for the full sleep")
    }

    func testLaunchFailureForMissingBinary() async {
        do {
            _ = try await runner.run(executablePath: "/no/such/binary", arguments: [], timeout: 5)
            XCTFail("Expected launchFailed")
        } catch let error as CommandError {
            guard case .launchFailed = error else {
                return XCTFail("Expected launchFailed, got \(error)")
            }
        } catch {
            XCTFail("Expected CommandError, got \(error)")
        }
    }

    func testCancellationStopsTheProcess() async {
        let runner = self.runner
        let task = Task {
            try await runner.run(executablePath: "/bin/sleep", arguments: ["30"], timeout: 60)
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let started = Date()
        _ = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "Cancellation must not wait for the full sleep")
    }

    func testAugmentedPATHPrependsKnownInstallDirs() {
        let environment = ProcessCommandRunner.environmentWithAugmentedPATH(
            base: ["PATH": "/usr/bin:/bin"],
            homeDirectory: "/fake/home"
        )
        let parts = environment["PATH"]!.components(separatedBy: ":")
        XCTAssertEqual(Array(parts.prefix(4)), [
            "/fake/home/.claude/local",
            "/fake/home/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ])
        XCTAssertTrue(parts.contains("/usr/bin"))
    }

    func testAugmentedPATHDoesNotDuplicateExistingDirs() {
        let environment = ProcessCommandRunner.environmentWithAugmentedPATH(
            base: ["PATH": "/opt/homebrew/bin:/usr/bin"],
            homeDirectory: "/fake/home"
        )
        let parts = environment["PATH"]!.components(separatedBy: ":")
        XCTAssertEqual(parts.filter { $0 == "/opt/homebrew/bin" }.count, 1)
    }
}
