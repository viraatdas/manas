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

/// The user's model dial: cheap and fast by default, better judgment on demand.
enum JudgeModel: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case haiku
    case sonnet

    var id: String { rawValue }

    /// Sentence-case name for the model picker.
    var displayName: String {
        switch self {
        case .haiku: "Haiku"
        case .sonnet: "Sonnet"
        }
    }

    var detail: String {
        switch self {
        case .haiku: "Fast and cheap"
        case .sonnet: "Better judgment, costlier"
        }
    }
}
