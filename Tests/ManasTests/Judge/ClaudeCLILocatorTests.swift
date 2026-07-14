import XCTest
@testable import Manas

final class ClaudeCLILocatorTests: XCTestCase {
    private func makeLocator(
        runner: MockCommandRunner,
        executables: Set<String>
    ) -> ClaudeCLILocator {
        ClaudeCLILocator(
            runner: runner,
            homeDirectory: "/fake/home",
            shellPath: "/bin/fakesh",
            isExecutableFile: { executables.contains($0) }
        )
    }

    func testFindsFirstCandidateWithoutShellingOut() async {
        let runner = MockCommandRunner()
        let locator = makeLocator(runner: runner, executables: ["/fake/home/.claude/local/claude"])
        let path = await locator.locate()
        XCTAssertEqual(path, "/fake/home/.claude/local/claude")
        XCTAssertTrue(runner.calls.isEmpty, "Direct candidate hits must not spawn a shell")
    }

    func testCandidateOrderPrefersClaudeLocal() async {
        let runner = MockCommandRunner()
        let all: Set<String> = [
            "/fake/home/.claude/local/claude",
            "/fake/home/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        let locator = makeLocator(runner: runner, executables: all)
        let path = await locator.locate()
        XCTAssertEqual(path, "/fake/home/.claude/local/claude")
    }

    func testFallsBackToLoginShell() async {
        let runner = MockCommandRunner(results: [
            .success(CommandOutput(exitStatus: 0, stdout: Data("/via/shell/claude\n".utf8))),
        ])
        let locator = makeLocator(runner: runner, executables: ["/via/shell/claude"])
        let path = await locator.locate()
        XCTAssertEqual(path, "/via/shell/claude")
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls[0].executablePath, "/bin/fakesh")
        XCTAssertEqual(runner.calls[0].arguments, ["-l", "-c", "command -v claude"])
    }

    func testLoginShellSkipsBannerLines() async {
        let runner = MockCommandRunner(results: [
            .success(CommandOutput(exitStatus: 0, stdout: Data("Welcome back!\nsome motd noise\n/via/shell/claude\n".utf8))),
        ])
        let locator = makeLocator(runner: runner, executables: ["/via/shell/claude"])
        let path = await locator.locate()
        XCTAssertEqual(path, "/via/shell/claude")
    }

    func testReturnsNilWhenShellFindsNothing() async {
        let runner = MockCommandRunner(results: [
            .success(CommandOutput(exitStatus: 127)),
        ])
        let locator = makeLocator(runner: runner, executables: [])
        let path = await locator.locate()
        XCTAssertNil(path)
    }

    func testReturnsNilWhenShellResultIsNotExecutable() async {
        let runner = MockCommandRunner(results: [
            .success(CommandOutput(exitStatus: 0, stdout: Data("/stale/claude\n".utf8))),
        ])
        let locator = makeLocator(runner: runner, executables: [])
        let path = await locator.locate()
        XCTAssertNil(path)
    }

    func testReturnsNilWhenShellItselfFails() async {
        let runner = MockCommandRunner(results: [
            .failure(CommandError.launchFailed("no such shell")),
        ])
        let locator = makeLocator(runner: runner, executables: [])
        let path = await locator.locate()
        XCTAssertNil(path)
    }
}
