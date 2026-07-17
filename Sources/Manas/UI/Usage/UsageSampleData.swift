import Foundation

/// Seeded multi-day sample data for the usage previews. Uses a throwaway
/// state file so previews never touch the real Application Support state.
@MainActor
enum UsageSampleData {
    static func store(now: Date = Date()) -> AppStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManasPreview-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json")
        let store = AppStore(fileURL: url)
        store.dailyTokenBudget = 10_000
        store.usageRecords = sampleRecords(now: now)
        store.lastCheckedAt = store.usageRecords.last?.timestamp
        store.syncedSourceCount = 3
        store.codingSessionsToday = sampleCodingSessions(now: now)
        return store
    }

    /// Today's observed coding sessions for the "Coding sessions today" card,
    /// ranked busiest first the way the check-in flow ranks them.
    static func sampleCodingSessions(now: Date = Date()) -> [CodingSessionSummary] {
        let calendar = Calendar.current
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        }
        return [
            CodingSessionSummary(
                source: .claude, title: "manas",
                startedAt: at(8, 5), endedAt: at(12, 40), totalTokens: 2_412_000
            ),
            CodingSessionSummary(
                source: .codex, title: "exla-infra",
                startedAt: at(13, 10), endedAt: at(14, 2), totalTokens: 486_000
            ),
            CodingSessionSummary(
                source: .claude, title: "dotfiles",
                startedAt: at(15, 30), endedAt: at(15, 48), totalTokens: 74_500
            ),
        ]
    }

    /// Seven days of check-ins: one empty day, a mid-week spike, and a today
    /// that matches the design mock (2,140 tokens · $0.03 · 4 checks).
    static func sampleRecords(now: Date = Date()) -> [UsageRecord] {
        let calendar = Calendar.current
        func record(
            daysAgo: Int, hour: Int, minute: Int,
            model: JudgeModel, tokensIn: Int, tokensOut: Int,
            costUSD: Double, summary: String
        ) -> UsageRecord {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            let timestamp = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
            return UsageRecord(
                timestamp: timestamp,
                model: model.rawValue,
                tokensIn: tokensIn,
                tokensOut: tokensOut,
                costUSD: costUSD,
                summary: summary
            )
        }
        return [
            // Six days ago is intentionally empty — the sparkline should
            // render gaps gracefully.
            record(daysAgo: 5, hour: 15, minute: 20, model: .haiku, tokensIn: 980, tokensOut: 170,
                   costUSD: 0.011, summary: "First check-in, 2 todos judged"),
            record(daysAgo: 4, hour: 9, minute: 45, model: .haiku, tokensIn: 1_240, tokensOut: 260,
                   costUSD: 0.014, summary: "3 todos judged"),
            record(daysAgo: 4, hour: 16, minute: 10, model: .haiku, tokensIn: 1_620, tokensOut: 300,
                   costUSD: 0.018, summary: "4 todos judged, 1 discovered"),
            record(daysAgo: 3, hour: 13, minute: 5, model: .haiku, tokensIn: 730, tokensOut: 160,
                   costUSD: 0.009, summary: "2 todos judged"),
            record(daysAgo: 2, hour: 10, minute: 30, model: .sonnet, tokensIn: 2_480, tokensOut: 540,
                   costUSD: 0.052, summary: "5 todos judged, 2 discovered"),
            record(daysAgo: 2, hour: 17, minute: 55, model: .haiku, tokensIn: 1_710, tokensOut: 330,
                   costUSD: 0.019, summary: "4 todos judged"),
            record(daysAgo: 1, hour: 11, minute: 15, model: .haiku, tokensIn: 2_190, tokensOut: 420,
                   costUSD: 0.024, summary: "5 todos judged, 1 discovered"),
            // Today: 2,140 tokens, $0.03, four checks.
            record(daysAgo: 0, hour: 8, minute: 5, model: .haiku, tokensIn: 320, tokensOut: 60,
                   costUSD: 0.006, summary: "2 todos judged"),
            record(daysAgo: 0, hour: 10, minute: 41, model: .haiku, tokensIn: 410, tokensOut: 75,
                   costUSD: 0.007, summary: "3 todos judged"),
            record(daysAgo: 0, hour: 12, minute: 58, model: .sonnet, tokensIn: 460, tokensOut: 90,
                   costUSD: 0.008, summary: "3 todos judged, 1 discovered"),
            record(daysAgo: 0, hour: 14, minute: 14, model: .haiku, tokensIn: 585, tokensOut: 140,
                   costUSD: 0.009, summary: "4 todos judged, 2 discovered"),
        ]
    }
}
