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
    /// `model` is the model to request — the app always passes
    /// `store.selectedModel.rawValue` ("sonnet").
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
