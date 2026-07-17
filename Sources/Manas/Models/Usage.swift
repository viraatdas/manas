import Foundation

/// The cost of one "Ask Claude" check-in.
struct UsageRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var timestamp: Date
    /// Model the judge used — a `JudgeModel` raw value or a full API model id.
    var model: String
    var tokensIn: Int
    var tokensOut: Int
    var costUSD: Double
    /// One-line log entry, e.g. "3 todos judged, 1 discovered".
    var summary: String

    var totalTokens: Int { tokensIn + tokensOut }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        model: String,
        tokensIn: Int,
        tokensOut: Int,
        costUSD: Double,
        summary: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.model = model
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.costUSD = costUSD
        self.summary = summary
    }
}

/// All check-ins for one calendar day, for the usage panel and 7-day sparkline.
struct CheckInDay: Identifiable, Codable, Hashable, Sendable {
    /// Start of the calendar day.
    var date: Date
    var records: [UsageRecord]

    var id: Date { date }
    var totalTokens: Int { records.reduce(0) { $0 + $1.totalTokens } }
    var totalCostUSD: Double { records.reduce(0) { $0 + $1.costUSD } }

    init(date: Date, records: [UsageRecord] = []) {
        self.date = date
        self.records = records
    }
}

/// One coding agent's contribution to today, summarized for the usage panel's
/// "Coding sessions today" card. Derived from observed `WorkActivity`;
/// transient (never persisted) and refreshed on every check-in. These tokens
/// are the coding agent's own subscription usage and are kept separate from
/// Manas's own judge check-in cost, budget dots, and sparkline.
struct CodingSessionSummary: Identifiable, Hashable, Sendable {
    var id: UUID
    /// Always `.claude` or `.codex`.
    var source: WorkSource
    /// Project name when known, otherwise a short summary of the work.
    var title: String
    var startedAt: Date
    /// nil while a session is still open.
    var endedAt: Date?
    var totalTokens: Int

    init(
        id: UUID = UUID(),
        source: WorkSource,
        title: String,
        startedAt: Date,
        endedAt: Date? = nil,
        totalTokens: Int
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.totalTokens = totalTokens
    }

    /// Folds one observed coding `WorkActivity` into a panel row, or nil for
    /// non-coding sources (Arc, Screen Time, Messages carry no token cost).
    init?(activity: WorkActivity) {
        guard activity.source == .claude || activity.source == .codex else { return nil }
        let projectName = activity.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        self.init(
            id: activity.id,
            source: activity.source,
            title: projectName ?? activity.summary,
            startedAt: activity.startedAt,
            endedAt: activity.endedAt,
            totalTokens: activity.tokensUsed ?? 0
        )
    }
}

/// Known model families, kept for mapping stored usage records (old raw
/// values or full API model ids) to friendly names in the usage table. The
/// judge itself always runs Sonnet — there is no user-facing model choice.
enum JudgeModel: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case haiku
    case sonnet

    var id: String { rawValue }

    /// Sentence-case name for the usage table.
    var displayName: String {
        switch self {
        case .haiku: "Haiku"
        case .sonnet: "Sonnet"
        }
    }
}
