import XCTest
@testable import Manas

final class ClaudeCLIJudgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_752_000_000)
    private let cliPath = "/fake/home/.claude/local/claude"

    private func makeJudge(
        runner: MockCommandRunner,
        cliInstalled: Bool = true,
        timeout: TimeInterval = 60
    ) -> ClaudeCLIJudge {
        let expected = cliPath
        let isExecutableFile: @Sendable (String) -> Bool
        if cliInstalled {
            isExecutableFile = { $0 == expected }
        } else {
            isExecutableFile = { _ in false }
        }
        let locator = ClaudeCLILocator(
            runner: runner,
            homeDirectory: "/fake/home",
            shellPath: "/bin/fakesh",
            isExecutableFile: isExecutableFile
        )
        let fixedNow = now
        return ClaudeCLIJudge(runner: runner, locator: locator, timeout: timeout, now: { fixedNow })
    }

    private func makeTodos() -> [Todo] {
        [
            Todo(text: "Ship the sparkline", createdAt: now),
            Todo(text: "Review the ingestion PR", createdAt: now),
        ]
    }

    private func makeActivities() -> [WorkActivity] {
        [
            WorkActivity(
                source: .claude,
                projectPath: "/Users/me/code/manas",
                summary: "Built the 7-day sparkline with Swift Charts",
                features: ["sparkline", "usage panel"],
                startedAt: now.addingTimeInterval(-7200),
                endedAt: now.addingTimeInterval(-3600)
            ),
        ]
    }

    func testSuccessfulJudgePopulatesResult() async throws {
        let todos = makeTodos()
        let reply = JudgeFixtures.modelReplyJSON(
            verdicts: [
                (id: todos[0].id.uuidString, status: "done", evidence: "The claude session in manas built the sparkline"),
                (id: todos[1].id.uuidString, status: "not_started", evidence: "No session touched the ingestion PR"),
            ],
            discovered: [
                (title: "Polished the usage panel", evidence: "The claude session also touched the usage panel", source: "claude"),
            ]
        )
        let runner = MockCommandRunner(results: [
            .success(JudgeFixtures.cliSuccess(result: reply, inputTokens: 1800, outputTokens: 340, cacheCreation: 100, cacheRead: 200, cost: 0.03)),
        ])
        let judge = makeJudge(runner: runner)

        let result = try await judge.judge(todos: todos, activities: makeActivities(), model: "haiku")

        XCTAssertEqual(result.verdicts.count, 2)
        XCTAssertEqual(result.verdicts[todos[0].id]?.status, .done)
        XCTAssertEqual(result.verdicts[todos[0].id]?.evidence, "The claude session in manas built the sparkline")
        XCTAssertEqual(result.verdicts[todos[0].id]?.judgedAt, now)
        XCTAssertNil(result.verdicts[todos[0].id]?.accepted)
        XCTAssertEqual(result.verdicts[todos[1].id]?.status, .notStarted)

        XCTAssertEqual(result.discovered.count, 1)
        XCTAssertEqual(result.discovered[0].title, "Polished the usage panel")
        XCTAssertEqual(result.discovered[0].source, .claude)
        XCTAssertEqual(result.discovered[0].resolution, .pending)

        XCTAssertEqual(result.usage.model, "haiku", "Falls back to the requested alias when the CLI reports no model")
        XCTAssertEqual(result.usage.tokensIn, 1800 + 100 + 200)
        XCTAssertEqual(result.usage.tokensOut, 340)
        XCTAssertEqual(result.usage.costUSD, 0.03, accuracy: 0.000_001)
        XCTAssertEqual(result.usage.timestamp, now)
        XCTAssertEqual(result.usage.summary, "2 todos judged, 1 discovered")
    }

    func testUsageRecordsTheModelTheCLIReportsRan() async throws {
        let todos = makeTodos()
        let reply = JudgeFixtures.modelReplyJSON(verdicts: [
            (id: todos[0].id.uuidString, status: "done", evidence: "Shipped"),
        ])
        let runner = MockCommandRunner(results: [
            .success(JudgeFixtures.cliSuccess(result: reply, modelID: "claude-sonnet-5")),
        ])
        let judge = makeJudge(runner: runner)

        let result = try await judge.judge(todos: todos, activities: makeActivities(), model: "sonnet")

        XCTAssertEqual(result.usage.model, "claude-sonnet-5", "The usage log shows the model that actually ran, not the requested alias")
    }

    func testCLIInvocationArguments() async throws {
        let todos = makeTodos()
        let activities = makeActivities()
        let reply = JudgeFixtures.modelReplyJSON(verdicts: [
            (id: todos[0].id.uuidString, status: "unknown", evidence: "Unclear"),
        ])
        let runner = MockCommandRunner(results: [.success(JudgeFixtures.cliSuccess(result: reply))])
        let judge = makeJudge(runner: runner)

        _ = try await judge.judge(todos: todos, activities: activities, model: "sonnet")

        XCTAssertEqual(runner.calls.count, 1)
        let call = runner.calls[0]
        XCTAssertEqual(call.executablePath, cliPath)
        XCTAssertEqual(call.timeout, 60)
        XCTAssertEqual(call.arguments.count, 6)
        XCTAssertEqual(call.arguments[0], "-p")
        XCTAssertEqual(call.arguments[1], JudgePromptBuilder.build(todos: todos, activities: activities))
        XCTAssertEqual(Array(call.arguments[2...]), ["--output-format", "json", "--model", "sonnet"])
    }

    func testVerdictsForUnknownTodoIDsAreDropped() async throws {
        let todos = makeTodos()
        let reply = JudgeFixtures.modelReplyJSON(verdicts: [
            (id: todos[0].id.uuidString, status: "done", evidence: "Real"),
            (id: UUID().uuidString, status: "done", evidence: "Hallucinated todo"),
            (id: "not-a-uuid", status: "done", evidence: "Broken id"),
        ])
        let runner = MockCommandRunner(results: [.success(JudgeFixtures.cliSuccess(result: reply))])
        let judge = makeJudge(runner: runner)

        let result = try await judge.judge(todos: todos, activities: makeActivities(), model: "haiku")

        XCTAssertEqual(result.verdicts.count, 1)
        XCTAssertEqual(result.usage.summary, "1 todo judged, 0 discovered")
    }

    func testRetryAfterMalformedModelOutputAccumulatesUsage() async throws {
        let todos = makeTodos()
        let goodReply = JudgeFixtures.modelReplyJSON(verdicts: [
            (id: todos[0].id.uuidString, status: "in_progress", evidence: "Session started on it"),
        ])
        let runner = MockCommandRunner(results: [
            .success(JudgeFixtures.cliSuccess(result: "Sure! Let me think about the day first...", inputTokens: 1000, outputTokens: 50, cost: 0.01)),
            .success(JudgeFixtures.cliSuccess(result: goodReply, inputTokens: 1100, outputTokens: 90, cost: 0.02)),
        ])
        let judge = makeJudge(runner: runner)

        let result = try await judge.judge(todos: todos, activities: makeActivities(), model: "haiku")

        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertTrue(runner.calls[1].arguments[1].contains("not valid JSON"), "Retry prompt should carry the JSON-only nudge")
        XCTAssertTrue(runner.calls[1].arguments[1].hasPrefix(JudgePromptBuilder.build(todos: todos, activities: makeActivities())))
        XCTAssertEqual(result.verdicts[todos[0].id]?.status, .inProgress)
        XCTAssertEqual(result.usage.tokensIn, 2100, "Usage must cover both attempts")
        XCTAssertEqual(result.usage.tokensOut, 140)
        XCTAssertEqual(result.usage.costUSD, 0.03, accuracy: 0.000_001)
    }

    func testMalformedTwiceThrowsTypedError() async {
        let runner = MockCommandRunner(results: [
            .success(JudgeFixtures.cliSuccess(result: "prose only")),
            .success(JudgeFixtures.cliSuccess(result: "still prose")),
        ])
        let judge = makeJudge(runner: runner)

        do {
            _ = try await judge.judge(todos: makeTodos(), activities: makeActivities(), model: "haiku")
            XCTFail("Expected malformedModelOutput")
        } catch let error as JudgeError {
            guard case .malformedModelOutput = error else {
                return XCTFail("Expected malformedModelOutput, got \(error)")
            }
        } catch {
            XCTFail("Expected JudgeError, got \(error)")
        }
        XCTAssertEqual(runner.calls.count, 2, "Exactly one retry")
    }

    func testMissingCLIThrowsCliNotFound() async {
        let runner = MockCommandRunner(results: [
            .success(CommandOutput(exitStatus: 127)),  // login-shell fallback finds nothing
        ])
        let judge = makeJudge(runner: runner, cliInstalled: false)

        do {
            _ = try await judge.judge(todos: makeTodos(), activities: makeActivities(), model: "haiku")
            XCTFail("Expected cliNotFound")
        } catch let error as JudgeError {
            XCTAssertEqual(error, .cliNotFound)
        } catch {
            XCTFail("Expected JudgeError, got \(error)")
        }
    }

    func testNonZeroExitThrowsTypedError() async {
        let runner = MockCommandRunner(results: [
            .success(CommandOutput(exitStatus: 1, stderr: Data("Invalid API key\n".utf8))),
        ])
        let judge = makeJudge(runner: runner)

        do {
            _ = try await judge.judge(todos: makeTodos(), activities: makeActivities(), model: "haiku")
            XCTFail("Expected nonZeroExit")
        } catch let error as JudgeError {
            XCTAssertEqual(error, .nonZeroExit(code: 1, stderr: "Invalid API key"))
        } catch {
            XCTFail("Expected JudgeError, got \(error)")
        }
    }

    func testTimeoutMapsToTypedError() async {
        let runner = MockCommandRunner(results: [
            .failure(CommandError.timedOut),
        ])
        let judge = makeJudge(runner: runner, timeout: 60)

        do {
            _ = try await judge.judge(todos: makeTodos(), activities: makeActivities(), model: "haiku")
            XCTFail("Expected timedOut")
        } catch let error as JudgeError {
            XCTAssertEqual(error, .timedOut(seconds: 60))
        } catch {
            XCTFail("Expected JudgeError, got \(error)")
        }
    }

    func testCLIReportedErrorThrowsTypedError() async {
        let runner = MockCommandRunner(results: [
            .success(CommandOutput(
                exitStatus: 0,
                stdout: JudgeFixtures.cliEnvelopeJSON(result: "Execution failed", isError: true, subtype: "error_during_execution")
            )),
        ])
        let judge = makeJudge(runner: runner)

        do {
            _ = try await judge.judge(todos: makeTodos(), activities: makeActivities(), model: "haiku")
            XCTFail("Expected cliReportedError")
        } catch let error as JudgeError {
            XCTAssertEqual(error, .cliReportedError("Execution failed"))
        } catch {
            XCTFail("Expected JudgeError, got \(error)")
        }
    }

    func testMalformedEnvelopeThrowsWithoutRetry() async {
        let runner = MockCommandRunner(results: [
            .success(CommandOutput(exitStatus: 0, stdout: Data("garbage".utf8))),
        ])
        let judge = makeJudge(runner: runner)

        do {
            _ = try await judge.judge(todos: makeTodos(), activities: makeActivities(), model: "haiku")
            XCTFail("Expected malformedCLIOutput")
        } catch let error as JudgeError {
            guard case .malformedCLIOutput = error else {
                return XCTFail("Expected malformedCLIOutput, got \(error)")
            }
        } catch {
            XCTFail("Expected JudgeError, got \(error)")
        }
        XCTAssertEqual(runner.calls.count, 1, "A broken CLI envelope is not the model's fault — no retry")
    }

    func testNothingToJudgeShortCircuits() async throws {
        let runner = MockCommandRunner()
        let judge = makeJudge(runner: runner)

        let result = try await judge.judge(todos: [], activities: [], model: "haiku")

        XCTAssertTrue(runner.calls.isEmpty, "No CLI call when there is nothing to judge")
        XCTAssertTrue(result.verdicts.isEmpty)
        XCTAssertTrue(result.discovered.isEmpty)
        XCTAssertEqual(result.usage.tokensIn, 0)
        XCTAssertEqual(result.usage.tokensOut, 0)
        XCTAssertEqual(result.usage.costUSD, 0)
        XCTAssertEqual(result.usage.summary, "Nothing to judge")
    }

    func testMissingCostDefaultsToZeroOnSubscription() async throws {
        let todos = makeTodos()
        let reply = JudgeFixtures.modelReplyJSON(verdicts: [
            (id: todos[0].id.uuidString, status: "done", evidence: "Done in session"),
        ])
        let runner = MockCommandRunner(results: [
            .success(JudgeFixtures.cliSuccess(result: reply, cost: nil)),
        ])
        let judge = makeJudge(runner: runner)

        let result = try await judge.judge(todos: todos, activities: makeActivities(), model: "haiku")

        XCTAssertEqual(result.usage.costUSD, 0)
    }
}
