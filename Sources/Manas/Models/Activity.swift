import Foundation

/// Where observed activity came from.
enum WorkSource: String, Codable, Hashable, Sendable, CaseIterable {
    case claude
    case codex
    case granola
    case arc
    case screenTime = "screen_time"
    case messages

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .granola: "Granola"
        case .arc: "Arc"
        case .screenTime: "Screen Time"
        case .messages: "Messages"
        }
    }

    var systemImage: String {
        switch self {
        case .claude, .codex: "terminal"
        case .granola: "person.2"
        case .arc: "globe"
        case .screenTime: "hourglass"
        case .messages: "message"
        }
    }
}

/// What happened when one local activity source was checked. These values are
/// transient: only the source-derived verdict/discovery is persisted, never
/// raw browser or message content.
struct ActivitySourceStatus: Identifiable, Hashable, Sendable {
    enum State: String, Hashable, Sendable {
        case waiting
        case syncing
        case ready
        case permissionRequired
        case unavailable
        case failed
    }

    var source: WorkSource
    var state: State
    var activityCount: Int
    var detail: String?

    var id: WorkSource { source }

    static func waiting(_ source: WorkSource) -> ActivitySourceStatus {
        ActivitySourceStatus(source: source, state: .waiting, activityCount: 0)
    }
}

/// A typed source failure lets the aggregator distinguish a privacy grant
/// from a missing optional app or a genuinely malformed database.
enum ActivitySourceFailure: Error, LocalizedError, Sendable {
    case permissionRequired(String)
    case unavailable(String)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionRequired(let detail), .unavailable(let detail), .readFailed(let detail): detail
        }
    }

    var statusState: ActivitySourceStatus.State {
        switch self {
        case .permissionRequired: .permissionRequired
        case .unavailable: .unavailable
        case .readFailed: .failed
        }
    }
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
    /// Automatic project/theme cluster from the judge, inherited by the todo
    /// if the user adds this discovery to their list. nil stays ungrouped.
    var group: String?

    var isAdded: Bool { resolution == .added }
    var isDismissed: Bool { resolution == .dismissed }

    init(
        id: UUID = UUID(),
        title: String,
        evidence: String,
        source: WorkSource,
        resolution: Resolution = .pending,
        group: String? = nil
    ) {
        self.id = id
        self.title = title
        self.evidence = evidence
        self.source = source
        self.resolution = resolution
        self.group = TodoGroupName.normalized(group)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, evidence, source, resolution, group
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        evidence = try container.decode(String.self, forKey: .evidence)
        source = try container.decode(WorkSource.self, forKey: .source)
        resolution = try container.decode(Resolution.self, forKey: .resolution)
        group = TodoGroupName.normalized(
            try container.decodeIfPresent(String.self, forKey: .group)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(source, forKey: .source)
        try container.encode(resolution, forKey: .resolution)
        try container.encodeIfPresent(group, forKey: .group)
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
