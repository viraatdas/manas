import XCTest
@testable import Manas

final class ModelCodingTests: XCTestCase {
    // Whole-second date so ISO 8601 coding round-trips exactly.
    private let date = Date(timeIntervalSince1970: 1_752_000_000)

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try AppStore.makeEncoder().encode(value)
        return try AppStore.makeDecoder().decode(T.self, from: data)
    }

    func testTodoRoundTrip() throws {
        let todo = Todo(
            text: "Ship the sparkline",
            createdAt: date,
            group: "Manas",
            isDone: false,
            verdict: Verdict(status: .inProgress, evidence: "Session touched Charts", judgedAt: date, accepted: true)
        )
        XCTAssertEqual(try roundTrip(todo), todo)
    }

    func testTodoWithoutVerdictRoundTrip() throws {
        let todo = Todo(text: "Water the plants", createdAt: date)
        XCTAssertEqual(try roundTrip(todo), todo)
    }

    func testTodoDayNormalizesToStartOfDay() {
        let midDay = date
        XCTAssertEqual(
            Todo(text: "A", createdAt: midDay).day,
            Calendar.current.startOfDay(for: midDay),
            "day defaults to the created-at calendar day"
        )
        let futureAfternoon = midDay.addingTimeInterval(86_400 * 3 + 5_000)
        XCTAssertEqual(
            Todo(text: "B", createdAt: midDay, day: futureAfternoon).day,
            Calendar.current.startOfDay(for: futureAfternoon),
            "an explicit day is normalized to its start of day"
        )
    }

    /// Todos persisted before day scoping have no `day` key — they must
    /// decode with day backfilled from their created-at calendar day.
    func testTodoWithoutDayKeyBackfillsFromCreatedAt() throws {
        let legacyJSON = #"""
        {
          "id": "6F1E9C6A-2C3B-4E5D-8F9A-0B1C2D3E4F5A",
          "text": "Ship the sparkline",
          "createdAt": "2025-07-08T18:40:00Z",
          "isDone": false
        }
        """#
        let todo = try AppStore.makeDecoder().decode(Todo.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(todo.day, Calendar.current.startOfDay(for: todo.createdAt))
        XCTAssertNil(todo.group, "todos written before grouping remain ungrouped")
    }

    func testTodoGroupNamesNormalizeWhitespaceAndLength() {
        XCTAssertEqual(Todo(text: "A", group: "  Exla   infra ").group, "Exla infra")
        XCTAssertNil(Todo(text: "B", group: "   ").group)
        XCTAssertEqual(
            Todo(text: "C", group: String(repeating: "x", count: 80)).group?.count,
            TodoGroupName.maximumLength
        )
    }

    /// state.json written by the interim manual-sections build carries a
    /// `section` key; its value seeds the group so existing organization is
    /// preserved when the app upgrades to automatic grouping.
    func testLegacySectionKeyMigratesIntoGroup() throws {
        let legacyJSON = #"""
        {
          "id": "6F1E9C6A-2C3B-4E5D-8F9A-0B1C2D3E4F5A",
          "text": "Ship the sparkline",
          "createdAt": "2025-07-08T18:40:00Z",
          "day": "2025-07-08T00:00:00Z",
          "section": "Projects",
          "isDone": false
        }
        """#
        let todo = try AppStore.makeDecoder().decode(Todo.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(todo.group, "Projects", "the legacy section value seeds the new group")
    }

    /// A `day` written mid-day — by a hand-edit, or by a machine in another
    /// timezone — still decodes to start-of-day, so grouping by `day` holds.
    func testTodoDecodesUnnormalizedDayToStartOfDay() throws {
        let json = #"""
        {
          "id": "6F1E9C6A-2C3B-4E5D-8F9A-0B1C2D3E4F5A",
          "text": "Ship the sparkline",
          "createdAt": "2025-07-08T18:40:00Z",
          "day": "2025-07-09T13:37:00Z",
          "isDone": false
        }
        """#
        let todo = try AppStore.makeDecoder().decode(Todo.self, from: Data(json.utf8))
        XCTAssertEqual(todo.day, Calendar.current.startOfDay(for: todo.day))
        XCTAssertNotEqual(todo.day, todo.createdAt)
    }

    func testDiscoveredActivityRoundTrip() throws {
        let activity = DiscoveredActivity(
            title: "Reviewed PR #42",
            evidence: "45 minutes in the manas repo",
            source: .codex,
            resolution: .dismissed,
            group: "Manas"
        )
        XCTAssertEqual(try roundTrip(activity), activity)
    }

    func testWorkActivityRoundTrip() throws {
        let activity = WorkActivity(
            source: .claude,
            projectPath: "/Users/me/code/manas",
            summary: "Built the usage strip",
            features: ["token usage strip", "expandable breakdown"],
            startedAt: date,
            endedAt: date.addingTimeInterval(3600),
            tokensUsed: 2140
        )
        XCTAssertEqual(try roundTrip(activity), activity)
    }

    func testWorkActivityWithNilsRoundTrip() throws {
        let meeting = WorkActivity(source: .granola, summary: "Weekly sync", startedAt: date)
        XCTAssertEqual(try roundTrip(meeting), meeting)
    }

    func testUsageRecordRoundTrip() throws {
        let record = UsageRecord(
            timestamp: date,
            model: "haiku",
            tokensIn: 1800,
            tokensOut: 340,
            costUSD: 0.03,
            summary: "3 todos judged, 1 discovered"
        )
        XCTAssertEqual(try roundTrip(record), record)
    }

    func testCheckInDayRoundTrip() throws {
        let day = CheckInDay(
            date: date,
            records: [
                UsageRecord(timestamp: date, model: "haiku", tokensIn: 100, tokensOut: 20, costUSD: 0.001, summary: "1 todo judged"),
                UsageRecord(timestamp: date.addingTimeInterval(60), model: "sonnet", tokensIn: 900, tokensOut: 150, costUSD: 0.02, summary: "4 todos judged"),
            ]
        )
        let decoded = try roundTrip(day)
        XCTAssertEqual(decoded, day)
        XCTAssertEqual(decoded.totalTokens, 1170)
        XCTAssertEqual(decoded.totalCostUSD, 0.021, accuracy: 0.000_001)
    }

    func testJudgeResultRoundTrip() throws {
        let todoID = UUID()
        let result = JudgeResult(
            verdicts: [todoID: Verdict(status: .done, evidence: "Merged at 2:01 PM", judgedAt: date)],
            groups: [todoID: "Manas"],
            discovered: [DiscoveredActivity(title: "Debugged flaky CI", evidence: "codex session", source: .codex, group: "Manas")],
            usage: UsageRecord(timestamp: date, model: "haiku", tokensIn: 2000, tokensOut: 140, costUSD: 0.03, summary: "1 todo judged, 1 discovered")
        )
        XCTAssertEqual(try roundTrip(result), result)
    }

    /// Raw values are the on-disk format — guard them against accidental renames.
    func testStableRawValues() {
        XCTAssertEqual(Verdict.Status.allCases.map(\.rawValue), ["done", "inProgress", "notStarted", "unknown"])
        XCTAssertEqual(
            WorkSource.allCases.map(\.rawValue),
            ["claude", "codex", "granola", "arc", "screen_time", "messages"]
        )
        XCTAssertEqual(JudgeModel.allCases.map(\.rawValue), ["haiku", "sonnet"])
    }
}
