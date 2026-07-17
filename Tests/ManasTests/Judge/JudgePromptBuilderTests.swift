import XCTest
@testable import Manas

final class JudgePromptBuilderTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_752_000_000)

    func testPromptContainsTodoIDsAndText() {
        let todos = [
            Todo(text: "Ship the sparkline", createdAt: date, section: "Work"),
            Todo(text: "Review the ingestion PR", createdAt: date),
        ]
        let prompt = JudgePromptBuilder.build(todos: todos, activities: [])
        for todo in todos {
            XCTAssertTrue(prompt.contains(todo.id.uuidString), "Prompt should carry the todo id verbatim")
            XCTAssertTrue(prompt.contains(todo.text))
        }
        XCTAssertTrue(prompt.contains("section: Work"))
    }

    func testPromptContainsActivityDetails() {
        let activity = WorkActivity(
            source: .codex,
            projectPath: "/Users/me/code/manas",
            summary: "Built the usage strip",
            features: ["token usage strip", "expandable breakdown"],
            startedAt: date,
            endedAt: date.addingTimeInterval(3600)
        )
        let prompt = JudgePromptBuilder.build(todos: [], activities: [activity])
        XCTAssertTrue(prompt.contains("[codex]"))
        XCTAssertTrue(prompt.contains("/Users/me/code/manas"))
        XCTAssertTrue(prompt.contains("Built the usage strip"))
        XCTAssertTrue(prompt.contains("token usage strip, expandable breakdown"))
    }

    func testOpenSessionMarkedStillOpen() {
        let activity = WorkActivity(source: .claude, summary: "Still hacking", startedAt: date)
        let prompt = JudgePromptBuilder.build(todos: [], activities: [activity])
        XCTAssertTrue(prompt.contains("(still open)"))
    }

    func testPromptRequestsStrictJSONShape() {
        let prompt = JudgePromptBuilder.build(todos: [Todo(text: "A", createdAt: date)], activities: [])
        XCTAssertTrue(prompt.contains("strict JSON only"))
        XCTAssertTrue(prompt.contains("\"verdicts\""))
        XCTAssertTrue(prompt.contains("\"todoID\""))
        XCTAssertTrue(prompt.contains("\"in_progress\""))
        XCTAssertTrue(prompt.contains("\"not_started\""))
        XCTAssertTrue(prompt.contains("\"discovered\""))
        XCTAssertTrue(prompt.contains("sentence case"))
        XCTAssertTrue(prompt.contains("\"granola\""))
        XCTAssertTrue(prompt.contains("\"arc\""))
        XCTAssertTrue(prompt.contains("\"screen_time\""))
        XCTAssertTrue(prompt.contains("\"messages\""))
    }

    func testEmptySectionsMarkedNone() {
        let prompt = JudgePromptBuilder.build(todos: [], activities: [])
        XCTAssertTrue(prompt.contains("## Today's todos\n(none)"))
        XCTAssertTrue(prompt.contains("## Observed activity\n(none)"))
    }

    func testNudgeAsksForJSONOnly() {
        XCTAssertTrue(JudgePromptBuilder.jsonOnlyNudge.contains("not valid JSON"))
        XCTAssertTrue(JudgePromptBuilder.jsonOnlyNudge.contains("Return only the JSON object"))
    }
}
