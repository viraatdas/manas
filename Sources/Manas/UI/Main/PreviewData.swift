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
        store.syncedSourceCount = 2
        return store
    }

    /// A judged day that also surfaced work the user never wrote down.
    static var previewWithDiscovered: AppStore {
        let store = previewJudged
        store.discoveredActivities = sampleDiscoveredActivities()
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
        Todo(
            text: "Ship the usage strip",
            verdict: Verdict(
                status: .done,
                evidence: "Built UsageStripView in the 2:01 pm Claude session",
                judgedAt: todayAt(14, 14)
            )
        ),
        Todo(
            text: "Wire up the session parser",
            verdict: Verdict(
                status: .inProgress,
                evidence: "Codex session touched Sources/Manas/Ingest at 11:32 am",
                judgedAt: todayAt(14, 14)
            )
        ),
        Todo(
            text: "Write the launch blog post",
            verdict: Verdict(
                status: .notStarted,
                evidence: "No session touched any writing today",
                judgedAt: todayAt(14, 14)
            )
        ),
        Todo(text: "Book a dentist appointment"),
        Todo(text: "Morning standup", isDone: true),
    ]
}

private func sampleDiscoveredActivities() -> [DiscoveredActivity] {
    [
        DiscoveredActivity(
            title: "Refactored the transcript reader",
            evidence: "45 min in manas/ingest across the 10:05 am Claude session",
            source: .claude
        ),
        DiscoveredActivity(
            title: "Q3 roadmap sync",
            evidence: "Granola: 30 min with the product team at 1:00 pm",
            source: .granola
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
