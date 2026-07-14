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
            isDone: false,
            verdict: Verdict(status: .inProgress, evidence: "Session touched Charts", judgedAt: date, accepted: true)
        )
        XCTAssertEqual(try roundTrip(todo), todo)
    }

    func testTodoWithoutVerdictRoundTrip() throws {
        let todo = Todo(text: "Water the plants", createdAt: date)
        XCTAssertEqual(try roundTrip(todo), todo)
    }

    func testDiscoveredActivityRoundTrip() throws {
        let activity = DiscoveredActivity(
            title: "Reviewed PR #42",
            evidence: "45 minutes in the manas repo",
            source: .codex,
            resolution: .dismissed
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
            discovered: [DiscoveredActivity(title: "Debugged flaky CI", evidence: "codex session", source: .codex)],
            usage: UsageRecord(timestamp: date, model: "haiku", tokensIn: 2000, tokensOut: 140, costUSD: 0.03, summary: "1 todo judged, 1 discovered")
        )
        XCTAssertEqual(try roundTrip(result), result)
    }

    /// Raw values are the on-disk format — guard them against accidental renames.
    func testStableRawValues() {
        XCTAssertEqual(Verdict.Status.allCases.map(\.rawValue), ["done", "inProgress", "notStarted", "unknown"])
        XCTAssertEqual(WorkSource.allCases.map(\.rawValue), ["claude", "codex", "granola"])
        XCTAssertEqual(JudgeModel.allCases.map(\.rawValue), ["haiku", "sonnet"])
    }
}
