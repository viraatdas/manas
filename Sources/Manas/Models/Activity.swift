import Foundation

/// Where observed activity came from.
enum WorkSource: String, Codable, Hashable, Sendable, CaseIterable {
    case claude
    case codex
    case granola
    case browser
    case screenTime = "screen_time"
    case messages

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .granola: "Granola"
        case .browser: "Browser"
        case .screenTime: "Screen Time"
        case .messages: "Messages"
        }
    }

    /// `arc` was this case's raw value while the browser reader only knew how
    /// to read Arc. Stored discoveries and judge output still carry it, so it
    /// decodes as `.browser` instead of failing the whole state file.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let known = WorkSource(rawValue: raw) {
            self = known
        } else if raw == "arc" {
            self = .browser
        } else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unrecognized work source \"\(raw)\""
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var systemImage: String {
        switch self {
        case .claude, .codex: "terminal"
        case .granola: "person.2"
        case .browser: "globe"
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

    /// Whether this is work the sources saw the user finish, or something the
    /// user still owes. Messages produce both — "shipped the release notes" is
    /// done, "I'll send the invite" is not — and they cannot share a landing
    /// spot: adding a `done` discovery files a checked-off todo, which would
    /// quietly mark an outstanding commitment complete the moment it appeared.
    enum Kind: String, Codable, Hashable, Sendable {
        case done
        case owed
    }

    var id: UUID
    var title: String
    var evidence: String
    var source: WorkSource
    var resolution: Resolution
    var kind: Kind
    /// Automatic project/theme cluster from the judge, inherited by the todo
    /// if the user adds this discovery to their list. nil stays ungrouped.
    var group: String?
    /// The observed duration for a time-sink discovery. Only Waste of time
    /// uses this; it is intentionally absent for ordinary work discoveries.
    var estimatedMinutes: Int?

    var isAdded: Bool { resolution == .added }
    var isDismissed: Bool { resolution == .dismissed }

    init(
        id: UUID = UUID(),
        title: String,
        evidence: String,
        source: WorkSource,
        resolution: Resolution = .pending,
        kind: Kind = .done,
        group: String? = nil,
        estimatedMinutes: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.evidence = evidence
        self.source = source
        self.resolution = resolution
        self.kind = kind
        self.group = TodoGroupName.normalized(group)
        self.estimatedMinutes = estimatedMinutes.map { min(max($0, 0), 24 * 60) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, evidence, source, resolution, kind, group, estimatedMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        evidence = try container.decode(String.self, forKey: .evidence)
        source = try container.decode(WorkSource.self, forKey: .source)
        resolution = try container.decode(Resolution.self, forKey: .resolution)
        // Absent in state.json files written before commitments existed; those
        // discoveries were all observed work.
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .done
        group = TodoGroupName.normalized(
            try container.decodeIfPresent(String.self, forKey: .group)
        )
        estimatedMinutes = try container.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(source, forKey: .source)
        try container.encode(resolution, forKey: .resolution)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(group, forKey: .group)
        try container.encodeIfPresent(estimatedMinutes, forKey: .estimatedMinutes)
    }
}

/// A locally stored observation that contributes to the Waste of time total.
/// It contains only a generic discovery title and duration, never the raw
/// browsing or Screen Time data it was derived from.
struct WastedTimeEntry: Codable, Hashable, Sendable {
    var day: Date
    var title: String
    var minutes: Int

    init(day: Date, title: String, minutes: Int) {
        self.day = Calendar.current.startOfDay(for: day)
        self.title = title
        self.minutes = min(max(minutes, 0), 24 * 60)
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
