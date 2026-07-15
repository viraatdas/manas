import XCTest
@testable import Manas

/// Smoke test against the real claude CLI. Opt-in only — it spends real
/// tokens — via: MANAS_CLAUDE_INTEGRATION=1 swift test --filter Integration
final class ClaudeCLIJudgeIntegrationTests: XCTestCase {
    func testRealCLIJudgesASmallDay() async throws {
        guard ProcessInfo.processInfo.environment["MANAS_CLAUDE_INTEGRATION"] == "1" else {
            throw XCTSkip("Set MANAS_CLAUDE_INTEGRATION=1 to run the real claude CLI smoke test.")
        }
        let judge = ClaudeCLIJudge(timeout: 120)
        let todos = [
            Todo(text: "Build the judge engine for Manas"),
            Todo(text: "Book a dentist appointment"),
        ]
        let activities = [
            WorkActivity(
                source: .claude,
                projectPath: "/Users/me/code/manas",
                summary: "Implemented ClaudeCLIJudge: CLI locator, JSON envelope parsing, verdict parsing, usage accounting, and tests",
                features: ["judge engine", "usage accounting"],
                startedAt: Date().addingTimeInterval(-3600),
                endedAt: Date()
            ),
        ]

        let result = try await judge.judge(todos: todos, activities: activities, model: "haiku")

        XCTAssertFalse(result.verdicts.isEmpty, "Expected at least one verdict from the real CLI")
        // Whether the session counts as "done" or "in_progress" is the
        // model's judgment call — only require that it saw the work.
        let judgeTodoStatus = result.verdicts[todos[0].id]?.status
        XCTAssertTrue(
            judgeTodoStatus == .done || judgeTodoStatus == .inProgress,
            "Expected the judge-engine todo to be recognized as worked on, got \(String(describing: judgeTodoStatus))"
        )
        XCTAssertEqual(result.verdicts[todos[0].id]?.evidence.isEmpty, false)
        XCTAssertGreaterThan(result.usage.tokensIn, 0)
        XCTAssertGreaterThan(result.usage.tokensOut, 0)
        // Recent CLIs report the full model id they ran; older ones leave
        // the requested alias in place.
        XCTAssertTrue(result.usage.model.lowercased().contains("haiku"), "Unexpected model: \(result.usage.model)")
        XCTAssertTrue(result.usage.summary.contains("judged"))
    }
}
