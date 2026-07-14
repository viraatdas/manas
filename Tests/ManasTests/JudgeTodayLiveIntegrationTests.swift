import XCTest
@testable import Manas

/// The real end-to-end "Ask Claude" pass — real transcript ingestion, the
/// real claude CLI, a real (temp-file) store — exactly the code path behind
/// the button. Opt-in only, it spends real tokens:
/// MANAS_CLAUDE_INTEGRATION=1 swift test --filter JudgeTodayLive
@MainActor
final class JudgeTodayLiveIntegrationTests: XCTestCase {
    func testFullAskClaudePassAgainstRealSourcesAndCLI() async throws {
        guard ProcessInfo.processInfo.environment["MANAS_CLAUDE_INTEGRATION"] == "1" else {
            throw XCTSkip("Set MANAS_CLAUDE_INTEGRATION=1 to run the live end-to-end pass.")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManasLive-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json")
        let store = AppStore(fileURL: url)
        store.addTodo("Wire the Manas judge into the UI")
        store.addTodo("Water the plants")

        try await store.judgeToday(judge: ClaudeCLIJudge(timeout: 180))

        XCTAssertGreaterThanOrEqual(store.syncedSourceCount, 1, "at least one transcript source should sync")
        XCTAssertEqual(store.usageRecords.count, 1)
        XCTAssertGreaterThan(store.usageRecords[0].tokensIn, 0)
        XCTAssertGreaterThan(store.usageRecords[0].tokensOut, 0)
        XCTAssertNotNil(store.lastCheckedAt)
        XCTAssertTrue(
            store.todos.contains { $0.verdict != nil },
            "the judge should verdict at least one todo against today's real sessions"
        )

        store.saveNow()
        let relaunched = AppStore(fileURL: url)
        XCTAssertEqual(relaunched.usageRecords.map(\.id), store.usageRecords.map(\.id), "usage survives relaunch")
        XCTAssertEqual(relaunched.todos.map(\.id), store.todos.map(\.id))
    }
}
