import XCTest
@testable import Manas

/// The full "Ask Claude" integration path — ingest → judge → store — driven
/// with stubbed sources and judges so it runs without the claude CLI.
@MainActor
final class JudgeTodayFlowTests: XCTestCase {
    private func tempStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ManasTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    private struct StubSource: ActivitySource {
        var name = "stub"
        var activities: [WorkActivity] = []
        var shouldThrow = false

        func fetchActivities(for date: Date) async throws -> [WorkActivity] {
            if shouldThrow { throw CocoaError(.fileReadUnknown) }
            return activities
        }
    }

    /// Scripts a JudgeResult from whatever it receives, so tests can assert
    /// on the exact todos/activities/model the flow handed over.
    private struct StubJudge: TodoJudge {
        var delay: Duration?
        var makeResult: @Sendable ([Todo], [WorkActivity], String) throws -> JudgeResult

        init(
            delay: Duration? = nil,
            makeResult: @escaping @Sendable ([Todo], [WorkActivity], String) throws -> JudgeResult
        ) {
            self.delay = delay
            self.makeResult = makeResult
        }

        func judge(todos: [Todo], activities: [WorkActivity], model: String) async throws -> JudgeResult {
            if let delay {
                try await Task.sleep(for: delay)
            }
            return try makeResult(todos, activities, model)
        }
    }

    private struct NeverFinishingJudge: TodoJudge {
        func judge(todos: [Todo], activities: [WorkActivity], model: String) async throws -> JudgeResult {
            try await Task.sleep(for: .seconds(60))
            XCTFail("judge should have been cancelled")
            throw CancellationError()
        }
    }

    func testJudgeTodayWiresIngestionThroughJudgeIntoStore() async throws {
        let store = AppStore(fileURL: tempStateURL())
        store.selectedModel = .sonnet
        store.addTodo("Ship the sparkline")
        let todoID = store.todos[0].id

        let activity = WorkActivity(source: .claude, summary: "Worked on Manas", startedAt: Date())
        let aggregator = ActivityAggregator(sources: [
            StubSource(name: "claude", activities: [activity]),
            StubSource(name: "codex"),
        ])
        let judge = StubJudge { todos, activities, model in
            JudgeResult(
                verdicts: Dictionary(uniqueKeysWithValues: todos.map {
                    ($0.id, Verdict(status: .inProgress, evidence: "Session touched Charts"))
                }),
                discovered: [DiscoveredActivity(title: "Fixed flaky CI", evidence: "codex session", source: .codex)],
                usage: UsageRecord(
                    model: model,
                    tokensIn: activities.count * 100,
                    tokensOut: 40,
                    costUSD: 0.01,
                    summary: "1 todo judged, 1 discovered"
                )
            )
        }

        try await store.judgeToday(aggregator: aggregator, judge: judge)

        XCTAssertEqual(store.todos[0].verdict?.status, .inProgress)
        XCTAssertEqual(store.discoveredActivities.map(\.title), ["Fixed flaky CI"])
        XCTAssertEqual(store.usageRecords.count, 1)
        XCTAssertEqual(store.usageRecords[0].model, "sonnet", "the store's model dial reaches the judge")
        XCTAssertEqual(store.usageRecords[0].tokensIn, 100, "aggregated activities reach the judge")
        XCTAssertEqual(store.lastCheckedAt, store.usageRecords[0].timestamp)
        XCTAssertEqual(store.syncedSourceCount, 2)
        XCTAssertEqual(todoID, store.todos[0].id)
    }

    func testFailedSourceStillCountsTheOthers() async throws {
        let store = AppStore(fileURL: tempStateURL())
        store.addTodo("Anything")
        let aggregator = ActivityAggregator(sources: [
            StubSource(name: "claude"),
            StubSource(name: "codex", shouldThrow: true),
        ])
        let judge = StubJudge { _, _, model in
            JudgeResult(usage: UsageRecord(model: model, tokensIn: 10, tokensOut: 5, costUSD: 0, summary: "1 todo judged"))
        }

        try await store.judgeToday(aggregator: aggregator, judge: judge)
        XCTAssertEqual(store.syncedSourceCount, 1)
        XCTAssertEqual(store.usageRecords.count, 1)
    }

    func testEmptyDaySkipsTheCLIEntirely() async throws {
        let store = AppStore(fileURL: tempStateURL())
        let judge = StubJudge { _, _, _ in
            XCTFail("the judge must not be called when there is nothing to judge")
            throw JudgeError.cliNotFound
        }

        try await store.judgeToday(aggregator: ActivityAggregator(sources: [StubSource()]), judge: judge)

        XCTAssertTrue(store.usageRecords.isEmpty, "an empty day records no zero-token check-ins")
        XCTAssertNotNil(store.lastCheckedAt, "the check still counts as having looked")
        XCTAssertEqual(store.syncedSourceCount, 1)
    }

    // MARK: - Check-in coordination

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                return XCTFail("timed out waiting for condition")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testCheckInNowRunsOnePassAndClearsTheFlag() async throws {
        let store = AppStore(fileURL: tempStateURL())
        store.addTodo("Anything")
        let judge = StubJudge { _, _, model in
            JudgeResult(usage: UsageRecord(model: model, tokensIn: 10, tokensOut: 5, costUSD: 0, summary: "1 todo judged"))
        }

        store.checkInNow(aggregator: ActivityAggregator(sources: [StubSource()]), judge: judge)
        XCTAssertTrue(store.isCheckingIn)

        try await waitUntil { !store.isCheckingIn }
        XCTAssertEqual(store.usageRecords.count, 1)
        XCTAssertNil(store.lastCheckInError)
    }

    func testCheckInErrorSurfacesInline() async throws {
        let store = AppStore(fileURL: tempStateURL())
        store.addTodo("Anything")
        let judge = StubJudge { _, _, _ in throw JudgeError.cliNotFound }

        store.checkInNow(aggregator: ActivityAggregator(sources: [StubSource()]), judge: judge)
        try await waitUntil { !store.isCheckingIn }

        XCTAssertEqual(store.lastCheckInError, JudgeError.cliNotFound.errorDescription)
        XCTAssertTrue(store.usageRecords.isEmpty)
    }

    func testOverlappingChecksAreCoalesced() async throws {
        let store = AppStore(fileURL: tempStateURL())
        store.addTodo("Anything")
        let judge = StubJudge(delay: .milliseconds(150)) { _, _, model in
            JudgeResult(usage: UsageRecord(model: model, tokensIn: 10, tokensOut: 5, costUSD: 0, summary: "1 todo judged"))
        }

        let aggregator = ActivityAggregator(sources: [StubSource()])
        store.checkInNow(aggregator: aggregator, judge: judge)
        store.checkInNow(aggregator: aggregator, judge: judge)
        store.checkInNow(aggregator: aggregator, judge: judge)

        try await waitUntil { !store.isCheckingIn }
        XCTAssertEqual(store.usageRecords.count, 1, "clicks during a running check must not stack passes")
    }

    func testAutoCheckInsRepeatUntilStopped() async throws {
        let store = AppStore(fileURL: tempStateURL())
        store.addTodo("Anything")
        let judge = StubJudge { _, _, model in
            JudgeResult(usage: UsageRecord(model: model, tokensIn: 10, tokensOut: 5, costUSD: 0, summary: "1 todo judged"))
        }

        store.startAutoCheckIns(
            every: .milliseconds(40),
            aggregator: ActivityAggregator(sources: [StubSource()]),
            judge: judge
        )
        try await waitUntil { store.usageRecords.count >= 2 }
        store.stopAutoCheckIns()

        let countWhenStopped = store.usageRecords.count
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.usageRecords.count, countWhenStopped, "stopping must halt the cadence")
    }

    func testJudgeErrorPropagatesWithoutRecordingUsage() async {
        let store = AppStore(fileURL: tempStateURL())
        store.addTodo("Anything")
        let aggregator = ActivityAggregator(sources: [StubSource()])
        let judge = StubJudge { _, _, _ in throw JudgeError.cliNotFound }

        do {
            try await store.judgeToday(aggregator: aggregator, judge: judge)
            XCTFail("expected JudgeError.cliNotFound")
        } catch let error as JudgeError {
            XCTAssertEqual(error, .cliNotFound)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(store.usageRecords.isEmpty)
        XCTAssertNil(store.lastCheckedAt)
        XCTAssertNil(store.todos[0].verdict)
        XCTAssertEqual(store.syncedSourceCount, 1, "ingestion succeeded even though judging failed")
    }

    func testJudgeTodayIsCancellable() async {
        let store = AppStore(fileURL: tempStateURL())
        store.addTodo("Anything")
        let aggregator = ActivityAggregator(sources: [StubSource()])

        let task = Task { try await store.judgeToday(aggregator: aggregator, judge: NeverFinishingJudge()) }
        task.cancel()

        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
        XCTAssertTrue(store.usageRecords.isEmpty)
        XCTAssertNil(store.lastCheckedAt)
    }

    func testJudgedDaySurvivesRelaunch() async throws {
        let url = tempStateURL()
        let store = AppStore(fileURL: url)
        store.addTodo("Ship the sparkline")

        let judge = StubJudge { todos, _, model in
            JudgeResult(
                verdicts: Dictionary(uniqueKeysWithValues: todos.map {
                    ($0.id, Verdict(status: .done, evidence: "Merged this morning"))
                }),
                discovered: [DiscoveredActivity(title: "Reviewed PR #42", evidence: "claude session", source: .claude)],
                usage: UsageRecord(model: model, tokensIn: 1800, tokensOut: 340, costUSD: 0.03, summary: "1 todo judged, 1 discovered")
            )
        }
        try await store.judgeToday(aggregator: ActivityAggregator(sources: [StubSource()]), judge: judge)
        store.saveNow()

        // ISO 8601 persistence keeps whole seconds only, so compare ids and
        // fields rather than whole structs carrying fractional-second dates.
        let relaunched = AppStore(fileURL: url)
        XCTAssertEqual(relaunched.todos.map(\.id), store.todos.map(\.id))
        XCTAssertEqual(relaunched.todos[0].verdict?.status, .done)
        XCTAssertEqual(relaunched.todos[0].verdict?.evidence, "Merged this morning")
        XCTAssertEqual(relaunched.discoveredActivities.map(\.title), ["Reviewed PR #42"])
        XCTAssertEqual(relaunched.usageRecords.map(\.id), store.usageRecords.map(\.id), "usage history feeds the sparkline after relaunch")
        XCTAssertEqual(relaunched.usageRecords.first?.totalTokens, 2140)
        XCTAssertEqual(relaunched.usageRecords.first?.costUSD, 0.03)
        XCTAssertEqual(
            relaunched.lastCheckedAt?.timeIntervalSince1970 ?? -1,
            store.lastCheckedAt?.timeIntervalSince1970 ?? -2,
            accuracy: 1
        )
        XCTAssertEqual(relaunched.syncedSourceCount, 1)
    }
}
