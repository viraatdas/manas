import Foundation

// Seeded AppStore instances for #Preview blocks. Every store is backed by a
// throwaway temp file so previews never read or write the real state on disk.

@MainActor
extension AppStore {
    /// Fresh install: no todos, no discoveries, never checked.
    static var previewEmpty: AppStore { scratchStore() }

    /// A judged day: verdicts in every state, one settled item, one todo the
    /// judge hasn't seen yet.
    static var previewJudged: AppStore {
        let store = scratchStore()
        store.todos = sampleJudgedTodos()
        store.usageRecords = sampleUsageRecords()
        store.lastCheckedAt = todayAt(14, 14)
        store.syncedSourceCount = 5
        store.sourceStatuses = [
            ActivitySourceStatus(source: .claude, state: .ready, activityCount: 2),
            ActivitySourceStatus(source: .codex, state: .ready, activityCount: 1),
            ActivitySourceStatus(source: .arc, state: .ready, activityCount: 12),
            ActivitySourceStatus(source: .screenTime, state: .ready, activityCount: 8),
            ActivitySourceStatus(source: .messages, state: .ready, activityCount: 3),
        ]
        return store
    }

    /// A judged day that also surfaced work the user never wrote down.
    static var previewWithDiscovered: AppStore {
        let store = previewJudged
        store.discoveredActivities = sampleDiscoveredActivities()
        return store
    }

    /// The full timeline: three past days of frozen history, the judged
    /// today with discoveries, and two planned days ahead.
    static var previewTimeline: AppStore {
        let store = previewWithDiscovered
        store.todos += samplePastTodos() + sampleUpcomingTodos()
        return store
    }

    private static func scratchStore() -> AppStore {
        AppStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("manas-preview-\(UUID().uuidString).json")
        )
    }
}

private func sampleJudgedTodos() -> [Todo] {
    [
        // Two ungrouped one-offs lead as the unlabeled cluster, then the
        // judge's "Manas" and "Launch" clusters follow.
        Todo(text: "Book a dentist appointment"),
        Todo(text: "Morning standup", isDone: true),
        Todo(
            text: "Ship the usage strip",
            group: "Manas",
            verdict: Verdict(
                status: .done,
                evidence: "Built UsageStripView in the 2:01 pm Claude session",
                judgedAt: todayAt(14, 14)
            )
        ),
        Todo(
            text: "Wire up the session parser",
            group: "Manas",
            verdict: Verdict(
                status: .inProgress,
                evidence: "Codex session touched Sources/Manas/Ingest at 11:32 am",
                judgedAt: todayAt(14, 14)
            )
        ),
        Todo(
            text: "Write the launch blog post",
            group: "Launch",
            verdict: Verdict(
                status: .notStarted,
                evidence: "No session touched any writing today",
                judgedAt: todayAt(14, 14)
            )
        ),
    ]
}

private func samplePastTodos() -> [Todo] {
    [
        Todo(
            text: "Review the ingestion PR",
            day: day(-1),
            group: "Manas",
            isDone: true
        ),
        Todo(
            text: "Draft the launch email",
            day: day(-1),
            group: "Launch",
            verdict: Verdict(
                status: .notStarted,
                evidence: "No session touched any writing that day",
                judgedAt: day(-1)
            )
        ),
        Todo(
            text: "Refactor the judge prompt",
            day: day(-2),
            group: "Manas",
            isDone: true
        ),
        Todo(text: "Call the accountant", day: day(-2)),
        Todo(
            text: "Clean up the test fixtures",
            day: day(-4),
            group: "Manas",
            isDone: true
        ),
    ]
}

private func sampleUpcomingTodos() -> [Todo] {
    // Future days stay flat and ungrouped; the judge never touches them.
    [
        Todo(text: "Prep the demo script", day: day(1)),
        Todo(text: "Book flights for the offsite", day: day(1)),
        Todo(text: "Pack for the offsite", day: day(2)),
    ]
}

private func sampleDiscoveredActivities() -> [DiscoveredActivity] {
    [
        DiscoveredActivity(
            title: "Refactored the transcript reader",
            evidence: "45 min in manas/ingest across the 10:05 am Claude session",
            source: .claude,
            group: "Manas"
        ),
        DiscoveredActivity(
            title: "Confirmed the offsite dinner",
            evidence: "A Messages conversation confirmed the reservation at 1:00 pm",
            source: .messages
        ),
    ]
}

private func sampleUsageRecords() -> [UsageRecord] {
    [
        UsageRecord(
            timestamp: todayAt(9, 30),
            model: JudgeModel.haiku.rawValue,
            tokensIn: 640,
            tokensOut: 180,
            costUSD: 0.008,
            summary: "2 todos judged"
        ),
        UsageRecord(
            timestamp: todayAt(14, 14),
            model: JudgeModel.haiku.rawValue,
            tokensIn: 980,
            tokensOut: 340,
            costUSD: 0.012,
            summary: "3 todos judged, 1 discovered"
        ),
    ]
}

private func todayAt(_ hour: Int, _ minute: Int) -> Date {
    Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
}

/// Start of the day `offset` days from today.
private func day(_ offset: Int) -> Date {
    let calendar = Calendar.current
    return calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date())) ?? Date()
}
