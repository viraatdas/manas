import XCTest
@testable import Manas

@MainActor
final class AppStoreTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_752_000_000)

    private func tempStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ManasTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    func testFreshStoreHasDefaults() {
        let store = AppStore(fileURL: tempStateURL())
        XCTAssertTrue(store.todos.isEmpty)
        XCTAssertTrue(store.discoveredActivities.isEmpty)
        XCTAssertTrue(store.usageRecords.isEmpty)
        XCTAssertEqual(store.selectedModel, .sonnet, "the judge model is a constant — always sonnet")
        XCTAssertEqual(store.dailyTokenBudget, 10_000)
        XCTAssertNil(store.lastCheckedAt)
        XCTAssertEqual(store.syncedSourceCount, 0)
    }

    func testSaveLoadRoundTrip() {
        let url = tempStateURL()
        let store = AppStore(fileURL: url)
        let todo = Todo(
            text: "Ship the sparkline",
            createdAt: date,
            verdict: Verdict(status: .inProgress, evidence: "Session touched Charts", judgedAt: date)
        )
        store.todos = [todo]
        store.discoveredActivities = [
            DiscoveredActivity(title: "Reviewed PR #42", evidence: "claude session", source: .claude)
        ]
        store.usageRecords = [
            UsageRecord(timestamp: date, model: "haiku", tokensIn: 1800, tokensOut: 340, costUSD: 0.03, summary: "3 todos judged, 1 discovered")
        ]
        store.dailyTokenBudget = 25_000
        store.lastCheckedAt = date
        store.syncedSourceCount = 3
        store.saveNow()

        let reloaded = AppStore(fileURL: url)
        XCTAssertEqual(reloaded.todos, store.todos)
        XCTAssertEqual(reloaded.discoveredActivities, store.discoveredActivities)
        XCTAssertEqual(reloaded.usageRecords, store.usageRecords)
        XCTAssertEqual(reloaded.dailyTokenBudget, 25_000)
        XCTAssertEqual(reloaded.lastCheckedAt, date)
        XCTAssertEqual(reloaded.syncedSourceCount, 3)
    }

    func testCorruptFileFallsBackToDefaults() throws {
        let url = tempStateURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = AppStore(fileURL: url)
        XCTAssertTrue(store.todos.isEmpty)
        XCTAssertEqual(store.dailyTokenBudget, 10_000)
    }

    /// state.json written before the model dial was removed carries a
    /// `selectedModel` key — it must still load, not be treated as corrupt.
    func testLegacyStateWithSelectedModelKeyStillLoads() throws {
        let url = tempStateURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacyJSON = #"""
        {
          "todos": [{"id": "6F1E9C6A-2C3B-4E5D-8F9A-0B1C2D3E4F5A", "text": "Ship the sparkline", "createdAt": "2025-07-08T18:40:00Z", "isDone": false}],
          "discoveredActivities": [],
          "usageRecords": [],
          "selectedModel": "haiku",
          "dailyTokenBudget": 25000,
          "syncedSourceCount": 2
        }
        """#
        try Data(legacyJSON.utf8).write(to: url)
        let store = AppStore(fileURL: url)
        XCTAssertEqual(store.todos.map(\.text), ["Ship the sparkline"])
        XCTAssertEqual(store.dailyTokenBudget, 25_000)
        XCTAssertEqual(store.syncedSourceCount, 2)
        XCTAssertEqual(store.selectedModel, .sonnet, "the old haiku choice is ignored — the judge always runs sonnet")
    }

    func testMutationTriggersDebouncedSave() async throws {
        let url = tempStateURL()
        let store = AppStore(fileURL: url, saveDebounce: .milliseconds(50))
        store.addTodo("Water the plants")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "save should be debounced, not synchronous")

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let reloaded = AppStore(fileURL: url)
        XCTAssertEqual(reloaded.todos.map(\.text), ["Water the plants"])
    }

    func testTodoHelpers() {
        let store = AppStore(fileURL: tempStateURL())
        XCTAssertNil(store.addTodo("   "), "blank todos are rejected")
        store.addTodo("First")
        store.addTodo("Second")
        XCTAssertEqual(store.todos.map(\.text), ["Second", "First"], "new todos go on top")

        let id = store.todos[0].id
        store.toggleDone(id)
        XCTAssertTrue(store.todos[0].isDone)
        store.removeTodo(id)
        XCTAssertEqual(store.todos.map(\.text), ["First"])
    }

    func testApplyJudgeResult() {
        let store = AppStore(fileURL: tempStateURL())
        store.addTodo("Write the judge prompt")
        let id = store.todos[0].id

        let verdict = Verdict(status: .done, evidence: "Prompt landed in the 2:01 PM session", judgedAt: date)
        let usage = UsageRecord(timestamp: date, model: "haiku", tokensIn: 2000, tokensOut: 140, costUSD: 0.03, summary: "1 todo judged, 1 discovered")
        let discovered = DiscoveredActivity(title: "Debugged flaky CI", evidence: "codex session", source: .codex)
        store.applyJudgeResult(JudgeResult(verdicts: [id: verdict], discovered: [discovered], usage: usage))

        XCTAssertEqual(store.todos[0].verdict, verdict)
        XCTAssertEqual(store.discoveredActivities, [discovered])
        XCTAssertEqual(store.usageRecords, [usage])
        XCTAssertEqual(store.lastCheckedAt, date)

        // A repeat discovery with the same title (any case) is not re-added,
        // so dismissed suggestions stay dismissed.
        store.dismissDiscovered(discovered.id)
        let repeatUsage = UsageRecord(timestamp: date.addingTimeInterval(600), model: "haiku", tokensIn: 500, tokensOut: 50, costUSD: 0.01, summary: "1 todo judged")
        let repeated = DiscoveredActivity(title: "debugged flaky ci", evidence: "again", source: .claude)
        store.applyJudgeResult(JudgeResult(discovered: [repeated], usage: repeatUsage))
        XCTAssertEqual(store.discoveredActivities.count, 1)
        XCTAssertTrue(store.discoveredActivities[0].isDismissed)
        XCTAssertEqual(store.usageRecords.count, 2)
    }

    func testDiscoveredDeduplication() {
        let store = AppStore(fileURL: tempStateURL())
        store.addTodo("Ship the sparkline")
        let usage = UsageRecord(timestamp: date, model: "haiku", tokensIn: 100, tokensOut: 10, costUSD: 0.001, summary: "judged")

        store.applyJudgeResult(JudgeResult(discovered: [
            DiscoveredActivity(title: "  ship the Sparkline ", evidence: "already a todo", source: .claude),
            DiscoveredActivity(title: "Fixed flaky CI", evidence: "codex session", source: .codex),
            DiscoveredActivity(title: "fixed flaky ci", evidence: "same pass repeat", source: .claude),
            DiscoveredActivity(title: "   ", evidence: "blank title", source: .claude),
        ], usage: usage))

        XCTAssertEqual(
            store.discoveredActivities.map(\.title), ["Fixed flaky CI"],
            "existing todos, same-pass repeats, and blank titles are all filtered"
        )
    }

    func testRepeatedChecksRefreshRatherThanPileUpDiscoveries() {
        let store = AppStore(fileURL: tempStateURL())
        let usage = UsageRecord(timestamp: date, model: "haiku", tokensIn: 100, tokensOut: 10, costUSD: 0.001, summary: "judged")

        store.applyJudgeResult(JudgeResult(discovered: [
            DiscoveredActivity(title: "Refactored the transcript reader", evidence: "first pass", source: .claude),
            DiscoveredActivity(title: "Reviewed PR #42", evidence: "first pass", source: .claude),
        ], usage: usage))
        store.dismissDiscovered(store.discoveredActivities[1].id)

        // An hour later the judge re-observes the same day and rephrases the
        // same work: the pending suggestion is replaced, not duplicated.
        store.applyJudgeResult(JudgeResult(discovered: [
            DiscoveredActivity(title: "Refactored transcript parsing", evidence: "second pass", source: .claude),
            DiscoveredActivity(title: "reviewed pr #42", evidence: "second pass", source: .claude),
        ], usage: usage))

        let pending = store.discoveredActivities.filter { $0.resolution == .pending }
        XCTAssertEqual(pending.map(\.title), ["Refactored transcript parsing"], "pending items come from the latest pass only")
        XCTAssertEqual(
            store.discoveredActivities.filter(\.isDismissed).map(\.title), ["Reviewed PR #42"],
            "a dismissed suggestion stays dismissed and never returns"
        )
    }

    func testReJudgingPreservesAcceptanceWhenStatusIsUnchanged() {
        let store = AppStore(fileURL: tempStateURL())
        store.addTodo("Ship it")
        let id = store.todos[0].id
        let usage = UsageRecord(timestamp: date, model: "haiku", tokensIn: 100, tokensOut: 10, costUSD: 0.001, summary: "judged")

        store.applyJudgeResult(JudgeResult(
            verdicts: [id: Verdict(status: .inProgress, evidence: "First pass", judgedAt: date)],
            usage: usage
        ))
        store.setVerdictAccepted(id, accepted: true)

        // Same status on the next auto-check: stays settled, evidence refreshes.
        store.applyJudgeResult(JudgeResult(
            verdicts: [id: Verdict(status: .inProgress, evidence: "Second pass", judgedAt: date.addingTimeInterval(3600))],
            usage: usage
        ))
        XCTAssertEqual(store.todos[0].verdict?.accepted, true)
        XCTAssertEqual(store.todos[0].verdict?.evidence, "Second pass")

        // Changed status: new information, surface it for review again.
        store.applyJudgeResult(JudgeResult(
            verdicts: [id: Verdict(status: .done, evidence: "Merged", judgedAt: date.addingTimeInterval(7200))],
            usage: usage
        ))
        XCTAssertNil(store.todos[0].verdict?.accepted)
    }

    func testAcceptingDoneVerdictChecksOffTodo() {
        let store = AppStore(fileURL: tempStateURL())
        store.addTodo("Ship it")
        let id = store.todos[0].id
        store.applyJudgeResult(JudgeResult(
            verdicts: [id: Verdict(status: .done, evidence: "Merged", judgedAt: date)],
            usage: UsageRecord(timestamp: date, model: "haiku", tokensIn: 100, tokensOut: 10, costUSD: 0.001, summary: "1 todo judged")
        ))
        XCTAssertFalse(store.todos[0].isDone)

        store.setVerdictAccepted(id, accepted: true)
        XCTAssertEqual(store.todos[0].verdict?.accepted, true)
        XCTAssertTrue(store.todos[0].isDone)
    }

    func testAddDiscoveredToTodos() {
        let store = AppStore(fileURL: tempStateURL())
        let discovered = DiscoveredActivity(title: "Reviewed PR #42", evidence: "claude session", source: .claude)
        store.discoveredActivities = [discovered]

        let todo = store.addDiscoveredToTodos(discovered.id)
        XCTAssertEqual(todo?.text, "Reviewed PR #42")
        XCTAssertEqual(todo?.isDone, true)
        XCTAssertEqual(todo?.verdict?.status, .done)
        XCTAssertTrue(store.discoveredActivities[0].isAdded)
        XCTAssertNil(store.addDiscoveredToTodos(discovered.id), "already-added items can't be added twice")
    }

    func testUsageAggregates() {
        let store = AppStore(fileURL: tempStateURL())
        let previousDay = date.addingTimeInterval(-86_400 * 2)
        store.usageRecords = [
            UsageRecord(timestamp: date, model: "haiku", tokensIn: 1000, tokensOut: 200, costUSD: 0.02, summary: "3 todos judged"),
            UsageRecord(timestamp: date.addingTimeInterval(3600), model: "haiku", tokensIn: 800, tokensOut: 140, costUSD: 0.01, summary: "2 todos judged"),
            UsageRecord(timestamp: previousDay, model: "sonnet", tokensIn: 5000, tokensOut: 900, costUSD: 0.09, summary: "5 todos judged"),
        ]

        XCTAssertEqual(store.records(on: date).count, 2)
        XCTAssertEqual(store.records(on: date).reduce(0) { $0 + $1.totalTokens }, 2140)
        XCTAssertEqual(store.checkInDays.count, 2)
        XCTAssertEqual(store.checkInDays.first?.totalTokens, 5900)

        let week = store.recentDays(7, endingOn: date)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.last?.records.count, 2)
        XCTAssertEqual(week[4].records.count, 1, "record from two days ago lands in the right slot")
        XCTAssertEqual(week.filter { $0.records.isEmpty }.count, 5, "empty days are filled in for the sparkline")
    }
}
