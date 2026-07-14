import Foundation

/// A provider of observed work: Claude Code sessions, Codex sessions, Granola
/// meetings. Source workers implement this; the sync pipeline fans out over
/// every registered source for the selected day.
protocol ActivitySource: Sendable {
    var name: String { get }
    func fetchActivities(for date: Date) async throws -> [WorkActivity]
}

/// Judges the day's todos against observed activities and reports what the
/// check-in cost.
protocol TodoJudge: Sendable {
    /// `model` is a `JudgeModel` raw value ("haiku"/"sonnet") or a full API
    /// model id — pass `store.selectedModel.rawValue`.
    func judge(todos: [Todo], activities: [WorkActivity], model: String) async throws -> JudgeResult
}

/// Everything one judge pass produces.
struct JudgeResult: Codable, Hashable, Sendable {
    /// Verdicts keyed by `Todo.id`.
    var verdicts: [UUID: Verdict]
    var discovered: [DiscoveredActivity]
    var usage: UsageRecord

    init(verdicts: [UUID: Verdict] = [:], discovered: [DiscoveredActivity] = [], usage: UsageRecord) {
        self.verdicts = verdicts
        self.discovered = discovered
        self.usage = usage
    }
}
