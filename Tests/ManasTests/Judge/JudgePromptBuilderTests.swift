import XCTest
@testable import Manas

final class JudgePromptBuilderTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_752_000_000)

    func testPromptContainsTodoIDsAndText() {
        let todos = [
            Todo(text: "Ship the sparkline", createdAt: date, group: "Manas"),
            Todo(text: "Review the ingestion PR", createdAt: date),
        ]
        let prompt = JudgePromptBuilder.build(todos: todos, activities: [])
        for todo in todos {
            XCTAssertTrue(prompt.contains(todo.id.uuidString), "Prompt should carry the todo id verbatim")
            XCTAssertTrue(prompt.contains(todo.text))
        }
    }

    func testPromptAsksForGroupsAndOffersTheOnesInUse() {
        let prompt = JudgePromptBuilder.build(
            todos: [
                Todo(text: "Ship the sparkline", createdAt: date, group: "Manas"),
                Todo(text: "Fix the parser", createdAt: date),
            ],
            activities: []
        )
        // Existing labels are offered verbatim so a re-check clusters into them
        // rather than coining a synonym that splits the theme in two.
        XCTAssertTrue(prompt.contains("Groups already in use"))
        XCTAssertTrue(prompt.contains("- Manas"))
        XCTAssertTrue(prompt.contains("  group: Manas"), "a todo's current group is echoed back")
        XCTAssertTrue(prompt.contains("\"group\": \"<short label>\" | null"))
        // The standing buckets are always on offer, even when nothing uses them.
        XCTAssertTrue(prompt.contains("- Work"))
        XCTAssertTrue(prompt.contains("- Personal"))
        // Discoveries can still be tagged as a time sink for the built-in section.
        XCTAssertTrue(prompt.contains("Waste of time"))
        XCTAssertTrue(prompt.contains("time sink"))
    }

    func testWasteOfTimeIsNotOfferedAsATodoGroup() {
        let prompt = JudgePromptBuilder.build(
            todos: [Todo(text: "Scrolled X", createdAt: date, group: TodoGroupName.wasteOfTime)],
            activities: []
        )
        let offered = prompt
            .components(separatedBy: "## Groups already in use")[1]
            .components(separatedBy: "##")[0]
        XCTAssertFalse(
            offered.contains(TodoGroupName.wasteOfTime),
            "the time-sink label is never offered as somewhere a todo could be filed"
        )
        XCTAssertTrue(prompt.contains("Never put a todo in \"Waste of time\""))
    }

    func testPromptAsksForCommitmentsFoundInConversations() {
        let prompt = JudgePromptBuilder.build(todos: [], activities: [])
        XCTAssertTrue(prompt.contains("commitments"))
        XCTAssertTrue(prompt.contains("[messages] conversations"))
        // Commitments are ordinary discoveries, so they reach the list through
        // the same add-to-todos path as unlisted work — not a new section.
        XCTAssertTrue(prompt.contains("\"source\" to \"messages\""))
        // A commitment is only worth surfacing while it is still outstanding.
        XCTAssertTrue(prompt.contains("still needs doing"))
    }

    func testPromptKeepsMessageEvidenceAnonymous() {
        let activity = WorkActivity(
            source: .messages,
            summary: "Messages conversation · 4 messages",
            features: ["Reply: can you book the table?", "You: yeah I'll do it tonight"],
            startedAt: date
        )
        let prompt = JudgePromptBuilder.build(todos: [], activities: [activity])
        XCTAssertTrue(prompt.contains("[messages]"))
        XCTAssertTrue(prompt.contains("can you book the table?"))
        XCTAssertTrue(prompt.contains("never name or describe the other person"))
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
        XCTAssertTrue(prompt.contains("\"browser\""))
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
