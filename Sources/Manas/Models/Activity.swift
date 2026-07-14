import Foundation

/// Where observed activity came from.
enum WorkSource: String, Codable, Hashable, Sendable, CaseIterable {
    case claude
    case codex
    case granola
}

/// Something the sources saw the user doing that wasn't on the todo list
/// ("You might have also done this").
struct DiscoveredActivity: Identifiable, Codable, Hashable, Sendable {
    /// What the user did with the suggestion. A single enum (rather than two
    /// bools) so an item can't be both added and dismissed.
    enum Resolution: String, Codable, Hashable, Sendable {
        case pending
        case added
        case dismissed
    }

    var id: UUID
    var title: String
    var evidence: String
    var source: WorkSource
    var resolution: Resolution

    var isAdded: Bool { resolution == .added }
    var isDismissed: Bool { resolution == .dismissed }

    init(
        id: UUID = UUID(),
        title: String,
        evidence: String,
        source: WorkSource,
        resolution: Resolution = .pending
    ) {
        self.id = id
        self.title = title
        self.evidence = evidence
        self.source = source
        self.resolution = resolution
    }
}

/// A chunk of observed work fetched from one source — a coding session, a meeting.
struct WorkActivity: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var source: WorkSource
    /// Repo or project the session ran in; nil for meetings.
    var projectPath: String?
    var summary: String
    /// Features or topics worked on, e.g. ["token usage strip", "7-day sparkline"].
    var features: [String]
    var startedAt: Date
    /// nil while a session is still open.
    var endedAt: Date?
    var tokensUsed: Int?

    init(
        id: UUID = UUID(),
        source: WorkSource,
        projectPath: String? = nil,
        summary: String,
        features: [String] = [],
        startedAt: Date,
        endedAt: Date? = nil,
        tokensUsed: Int? = nil
    ) {
        self.id = id
        self.source = source
        self.projectPath = projectPath
        self.summary = summary
        self.features = features
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.tokensUsed = tokensUsed
    }
}
