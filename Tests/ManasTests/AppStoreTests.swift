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
            group: "Manas",
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

    /// state.json written before todos were day-scoped has no `day` key on
    /// any todo — it must load without data loss, each todo backfilled to
    /// its created-at calendar day.
    func testLegacyStateWithoutDayKeysBackfillsFromCreatedAt() throws {
        let url = tempStateURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacyJSON = #"""
        {
          "todos": [
            {"id": "6F1E9C6A-2C3B-4E5D-8F9A-0B1C2D3E4F5A", "text": "Ship the sparkline", "createdAt": "2025-07-08T18:40:00Z", "isDone": false,
             "verdict": {"status": "inProgress", "evidence": "Session touched Charts", "judgedAt": "2025-07-08T19:00:00Z"}},
            {"id": "0A1B2C3D-4E5F-6789-ABCD-EF0123456789", "text": "Water the plants", "createdAt": "2025-07-07T09:05:00Z", "isDone": true}
          ],
          "discoveredActivities": [],
          "usageRecords": [],
          "dailyTokenBudget": 25000,
          "syncedSourceCount": 2
        }
        """#
        try Data(legacyJSON.utf8).write(to: url)

        let store = AppStore(fileURL: url)
        XCTAssertEqual(store.todos.map(\.text), ["Ship the sparkline", "Water the plants"], "no todo is lost")
        for todo in store.todos {
            XCTAssertEqual(todo.day, Calendar.current.startOfDay(for: todo.createdAt))
        }
        XCTAssertEqual(store.todos[0].verdict?.status, .inProgress, "verdicts survive the migration")
        XCTAssertTrue(store.todos[1].isDone)
    }

    func testAddTodoOnFutureDayAndDayGroups() {
        let store = AppStore(fileURL: tempStateURL())
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let lastWeek = calendar.date(byAdding: .day, value: -6, to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let nextWeek = calendar.date(byAdding: .day, value: 6, to: today)!

        store.addTodo("Old chore", on: lastWeek)
        store.addTodo("Yesterday's task", on: yesterday)
        store.addTodo("Today first", on: Date())
        store.addTodo("Today second")
        store.addTodo("Plan far ahead", on: nextWeek)
        store.addTodo("Plan tomorrow", on: tomorrow)

        XCTAssertEqual(store.todos(on: yesterday).map(\.text), ["Yesterday's task"])
        XCTAssertEqual(
            store.todosToday.map(\.text), ["Today second", "Today first"],
            "new todos go on top of their own day's group"
        )
        XCTAssertEqual(store.todos(on: tomorrow).map(\.text), ["Plan tomorrow"])

        XCTAssertEqual(store.pastDays.map(\.day), [yesterday, lastWeek], "past days come newest first")
        XCTAssertEqual(store.pastDays.map { $0.todos.map(\.text) }, [["Yesterday's task"], ["Old chore"]])
        XCTAssertEqual(store.upcomingDays.map(\.day), [tomorrow, nextWeek], "upcoming days come soonest first")
        XCTAssertEqual(store.upcomingDays.map { $0.todos.map(\.text) }, [["Plan tomorrow"], ["Plan far ahead"]])
        XCTAssertFalse(
            store.pastDays.contains { calendar.isDate($0.day, inSameDayAs: today) }
                || store.upcomingDays.contains { calendar.isDate($0.day, inSameDayAs: today) },
            "today belongs to neither group"
        )
    }

    func testMoveToTodayRedatesUnfinishedPastTodoAndClearsVerdict() {
        let store = AppStore(fileURL: tempStateURL())
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        store.addTodo("Already here")
        store.addTodo("Carry me over", on: yesterday)
        let id = store.todos(on: yesterday)[0].id
        store.todos[store.todos.firstIndex { $0.id == id }!].verdict =
            Verdict(status: .notStarted, evidence: "Yesterday showed no related work", judgedAt: date)

        store.moveToToday(id)

        XCTAssertEqual(
            store.todosToday.map(\.text), ["Carry me over", "Already here"],
            "the carried-over todo lands on top of today"
        )
        XCTAssertTrue(store.pastDays.isEmpty)
        let moved = store.todosToday[0]
        XCTAssertEqual(moved.id, id)
        XCTAssertEqual(moved.day, today)
        XCTAssertNil(moved.verdict, "the stale verdict is cleared for a fresh judgment")
    }

    func testMoveToTodayIgnoresFinishedTodayAndFutureTodos() {
        let store = AppStore(fileURL: tempStateURL())
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        store.addTodo("Finished yesterday", on: yesterday)
        store.toggleDone(store.todos(on: yesterday)[0].id)
        store.addTodo("Today already", on: Date())
        store.addTodo("Planned ahead", on: tomorrow)

        for todo in store.todos {
            store.moveToToday(todo.id)
        }

        XCTAssertEqual(store.todos(on: yesterday).map(\.text), ["Finished yesterday"], "done past todos stay put")
        XCTAssertEqual(store.todosToday.map(\.text), ["Today already"])
        XCTAssertEqual(store.todos(on: tomorrow).map(\.text), ["Planned ahead"], "future todos never move")
    }

    func testApplyJudgeResultNeverTouchesPastOrFutureTodos() {
        let store = AppStore(fileURL: tempStateURL())
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        store.addTodo("Frozen history", on: yesterday)
        let frozenVerdict = Verdict(status: .done, evidence: "Settled yesterday", judgedAt: date, accepted: true)
        store.todos[0].verdict = frozenVerdict
        store.addTodo("Today's work")
        store.addTodo("Future plan", on: tomorrow)

        let pastID = store.todos(on: yesterday)[0].id
        let todayID = store.todosToday[0].id
        let futureID = store.todos(on: tomorrow)[0].id

        // A confused judge echoes verdicts for every id it has ever seen.
        store.applyJudgeResult(JudgeResult(
            verdicts: [
                pastID: Verdict(status: .notStarted, evidence: "Stale re-judgment", judgedAt: date),
                todayID: Verdict(status: .inProgress, evidence: "Session touched it", judgedAt: date),
                futureID: Verdict(status: .done, evidence: "Impossible foresight", judgedAt: date),
            ],
            usage: UsageRecord(timestamp: date, model: "sonnet", tokensIn: 100, tokensOut: 10, costUSD: 0.001, summary: "judged")
        ))

        XCTAssertEqual(
            store.todos(on: yesterday)[0].verdict, frozenVerdict,
            "a past day's verdict is frozen — even a direct id match cannot change it"
        )
        XCTAssertEqual(store.todosToday[0].verdict?.status, .inProgress)
        XCTAssertNil(store.todos(on: tomorrow)[0].verdict, "future todos are immune to verdicts")
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

    func testTodoGroupsClusterUngroupedFirstThenByFirstAppearance() {
        let store = AppStore(fileURL: tempStateURL())
        let today = Calendar.current.startOfDay(for: Date())
        store.todos = [
            Todo(text: "Ship release", day: today, group: "Manas"),
            Todo(text: "Loose task", day: today),
            Todo(text: "Fix parser", day: today, group: "Manas"),
            Todo(text: "Rotate keys", day: today, group: "Exla infra"),
            Todo(text: "Reply to Sam", day: today),
        ]

        let groups = store.todoGroups(on: Date())
        XCTAssertEqual(
            groups.map(\.group), [nil, "Manas", "Exla infra"],
            "the ungrouped cluster leads, then each label in first-appearance order"
        )
        XCTAssertEqual(groups[0].todos.map(\.text), ["Loose task", "Reply to Sam"])
        XCTAssertEqual(groups[1].todos.map(\.text), ["Ship release", "Fix parser"])
        XCTAssertEqual(groups[2].todos.map(\.text), ["Rotate keys"])
    }

    func testCreatedGroupBecomesAStandingBucketBeforeAnyTodo() {
        let store = AppStore(fileURL: tempStateURL())
        let group = store.createGroup("Vancouver trip", emoji: "✈️")

        XCTAssertEqual(group, "Vancouver trip")
        XCTAssertTrue(store.standingGroups.contains("Vancouver trip"), "a created group shows even while empty")
        XCTAssertEqual(store.availableTodoGroups, ["Work", "Personal", "Vancouver trip"])
        XCTAssertEqual(store.emoji(forGroup: "Vancouver trip"), "✈️")
        // Creating the same name again does not duplicate it.
        store.createGroup("vancouver trip")
        XCTAssertEqual(store.customGroups, ["Vancouver trip"])
    }

    func testDeleteGroupClearsItFromTodosAndRemovesTheBucket() {
        let store = AppStore(fileURL: tempStateURL())
        store.createGroup("Errands", emoji: "🧾")
        store.addTodo("Buy milk", group: "Errands")
        XCTAssertEqual(store.todosToday.first?.group, "Errands")

        store.deleteGroup("Errands")
        XCTAssertNil(store.todosToday.first?.group, "deleting a group ungroups its todos")
        XCTAssertFalse(store.standingGroups.contains("Errands"))
        XCTAssertEqual(store.emoji(forGroup: "Errands"), "📁", "the custom emoji is dropped with the group")
    }

    func testCustomGroupsSurviveRelaunch() {
        let url = tempStateURL()
        let store = AppStore(fileURL: url)
        store.createGroup("Reading", emoji: "📓")
        store.saveNow()

        let reloaded = AppStore(fileURL: url)
        XCTAssertTrue(reloaded.standingGroups.contains("Reading"))
        XCTAssertEqual(reloaded.emoji(forGroup: "Reading"), "📓")
    }

    func testBuiltInGroupsLeadAndEmojisResolveWithDefaults() {
        let store = AppStore(fileURL: tempStateURL())
        store.addTodo("Rotate the keys", group: "Exla infra")

        XCTAssertEqual(
            store.availableTodoGroups, ["Work", "Personal", "Exla infra"],
            "built-in Work and Personal lead, then custom groups in use"
        )
        XCTAssertEqual(store.emoji(forGroup: "Work"), "💼")
        XCTAssertEqual(store.emoji(forGroup: "Personal"), "🏠")
        XCTAssertEqual(store.emoji(forGroup: "Exla infra"), "📁", "custom groups fall back to a folder")

        store.setGroupEmoji("Exla infra", emoji: "🚀")
        XCTAssertEqual(store.emoji(forGroup: "EXLA INFRA"), "🚀", "emoji resolves by case-folded group key")
    }

    func testGroupEmojiSurvivesRelaunch() {
        let url = tempStateURL()
        let store = AppStore(fileURL: url)
        store.addTodo("Ship it", group: "Manas")
        store.setGroupEmoji("Manas", emoji: "🚀")
        store.saveNow()

        let reloaded = AppStore(fileURL: url)
        XCTAssertEqual(reloaded.emoji(forGroup: "Manas"), "🚀")
    }

    func testManualGroupOnAddAndMoveCanonicalizes() {
        let store = AppStore(fileURL: tempStateURL())
        store.addTodo("Ship the panel", group: "Manas")
        store.addTodo("Loose task")
        // A second, differently-cased label reuses the existing spelling.
        store.addTodo("Fix the sparkline", group: " manas ")

        XCTAssertEqual(store.todosToday.first { $0.text == "Ship the panel" }?.group, "Manas")
        XCTAssertEqual(store.todosToday.first { $0.text == "Fix the sparkline" }?.group, "Manas")
        XCTAssertNil(store.todosToday.first { $0.text == "Loose task" }?.group)
        XCTAssertEqual(store.availableTodoGroups, ["Work", "Personal", "Manas"])

        // Moving reassigns, and clearing sends it back to the ungrouped cluster.
        let looseID = store.todosToday.first { $0.text == "Loose task" }!.id
        store.setTodoGroup(looseID, group: "Manas")
        XCTAssertEqual(store.todosToday.first { $0.id == looseID }?.group, "Manas")
        store.setTodoGroup(looseID, group: nil)
        XCTAssertNil(store.todosToday.first { $0.id == looseID }?.group)
    }

    func testJudgeDoesNotAssignGroupsGroupingIsManual() {
        let store = AppStore(fileURL: tempStateURL())
        store.addTodo("Baggage for Vancouver", group: "Personal")
        store.addTodo("Wire the judge")
        let manualID = store.todosToday.first { $0.text == "Baggage for Vancouver" }!.id
        let looseID = store.todosToday.first { $0.text == "Wire the judge" }!.id
        let usage = UsageRecord(model: "sonnet", tokensIn: 1, tokensOut: 1, costUSD: 0, summary: "judged")

        // Even if a JudgeResult carries group suggestions, they are not applied:
        // grouping is manual (Work / Personal, dragged by the user).
        store.applyJudgeResult(JudgeResult(
            groups: [manualID: "Vancouver", looseID: "Manas"], usage: usage
        ))

        XCTAssertEqual(store.todosToday.first { $0.id == manualID }?.group, "Personal")
        XCTAssertNil(
            store.todosToday.first { $0.id == looseID }?.group,
            "the judge never auto-groups a loose todo"
        )
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
        let discovered = DiscoveredActivity(
            title: "Reviewed PR #42", evidence: "claude session", source: .claude, group: "Manas"
        )
        store.discoveredActivities = [discovered]

        let todo = store.addDiscoveredToTodos(discovered.id)
        XCTAssertEqual(todo?.text, "Reviewed PR #42")
        XCTAssertEqual(todo?.isDone, true)
        XCTAssertEqual(todo?.verdict?.status, .done)
        XCTAssertEqual(todo?.group, "Manas", "a promoted discovery inherits the judge's group")
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
