import XCTest
@testable import Manas

/// Temporary diagnostic: dumps today's real judge prompt to a file so the CLI
/// call can be reproduced by hand. MANAS_PROMPT_DUMP=<path> to enable.
final class PromptDumpTests: XCTestCase {
    func testDumpTodaysPrompt() async throws {
        guard let path = ProcessInfo.processInfo.environment["MANAS_PROMPT_DUMP"] else {
            throw XCTSkip("Set MANAS_PROMPT_DUMP=<path> to dump the prompt.")
        }
        let aggregated = await ActivityAggregator.standard.fetchActivities(for: Date())
        let todos = [
            Todo(text: "Wire the sources and judge into the Manas UI"),
            Todo(text: "Water the plants"),
        ]
        let prompt = JudgePromptBuilder.build(todos: todos, activities: aggregated.activities)
        try Data(prompt.utf8).write(to: URL(fileURLWithPath: path))
        print("prompt bytes: \(prompt.utf8.count), activities: \(aggregated.activities.count)")
    }

    func testRunnerRoundTrip() async throws {
        guard let promptPath = ProcessInfo.processInfo.environment["MANAS_RUNNER_PROMPT"] else {
            throw XCTSkip("Set MANAS_RUNNER_PROMPT=<prompt file> to exercise ProcessCommandRunner against the real CLI.")
        }
        let prompt = try String(contentsOf: URL(fileURLWithPath: promptPath), encoding: .utf8)
        let runner = ProcessCommandRunner()
        let locator = ClaudeCLILocator(runner: runner)
        let cli = await locator.locate()!
        let output = try await runner.run(
            executablePath: cli,
            arguments: ["-p", prompt, "--output-format", "json", "--model", "haiku"],
            timeout: 300
        )
        print("exit=\(output.exitStatus) stdout=\(output.stdout.count)B stderr=\(output.stderr.count)B")
        let dump = URL(fileURLWithPath: promptPath).deletingLastPathComponent()
            .appendingPathComponent("runner-out-\(UUID().uuidString.prefix(8)).json")
        try output.stdout.write(to: dump)
        print("stdout saved: \(dump.path)")
        do {
            let reply = try ClaudeCLIResponseParser.parse(output.stdout)
            print("PARSED OK tokensIn=\(reply.tokensIn) tokensOut=\(reply.tokensOut)")
        } catch {
            print("PARSE FAILED: \(error)")
            throw error
        }
    }

    func testParseCapturedCLIOutput() throws {
        guard let path = ProcessInfo.processInfo.environment["MANAS_PARSE_FILE"] else {
            throw XCTSkip("Set MANAS_PARSE_FILE=<path> to parse a captured CLI output file.")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        do {
            let reply = try ClaudeCLIResponseParser.parse(data)
            print("PARSED OK: tokensIn=\(reply.tokensIn) tokensOut=\(reply.tokensOut) isError=\(reply.isError)")
            print("REPLY TEXT: \(reply.text.prefix(400))")
        } catch {
            print("PARSE FAILED: \(error)")
            throw error
        }
    }
}
