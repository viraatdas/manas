import Foundation

/// Normalization for the automatic group labels the judge assigns (a short
/// project or theme name such as "Manas" or "Exla infra"). Groups are never
/// managed by hand; this only trims, collapses whitespace, and clips length so
/// the judge's labels stay tidy, plus a case/diacritic-insensitive key so the
/// same theme with different capitalization clusters together.
enum TodoGroupName {
    static let maximumLength = 30

    /// Built-in groups offered in the picker before the user makes their own.
    /// "Waste of time" is the judge's home for detected time-sink activity.
    static let suggestions = ["Work", "Personal", "Waste of time"]

    /// The exact label the judge tags detected time-wasting activity with.
    static let wasteOfTime = "Waste of time"

    /// A calm palette to pick a group's emoji from at creation time.
    static let emojiPalette = ["💼", "🏠", "🕳️", "🚀", "🧠", "💡", "🎯", "🛠️", "🌱", "📓", "📦", "✈️"]

    /// The default badge for a group when the user hasn't chosen one; the
    /// built-ins get a fitting emoji, everything else falls back to a folder.
    static let fallbackEmoji = "📁"
    static let defaultEmoji: [String: String] = [
        key(for: "Work"): "💼",
        key(for: "Personal"): "🏠",
        key(for: "Waste of time"): "🕳️",
    ]

    static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let collapsed = rawValue
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumLength))
    }

    static func key(for value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// First grapheme of a typed emoji, or nil if it's blank.
    static func normalizedEmoji(_ raw: String?) -> String? {
        guard let first = raw?.trimmingCharacters(in: .whitespaces).first else { return nil }
        return String(first)
    }
}

/// A user todo, optionally annotated with the judge's latest verdict and the
/// project/theme group the judge clustered it into.
struct Todo: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var text: String
    var createdAt: Date
    /// The calendar day (start of day) this todo belongs to. Past days are
    /// frozen history, future days are plans; only today's todos get judged.
    var day: Date
    /// Automatic project/theme cluster assigned by the judge (e.g. "Manas").
    /// nil until the judge groups it; ungrouped todos render first, unlabeled.
    var group: String?
    var isDone: Bool
    var verdict: Verdict?

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        day: Date? = nil,
        group: String? = nil,
        isDone: Bool = false,
        verdict: Verdict? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.day = Calendar.current.startOfDay(for: day ?? createdAt)
        self.group = TodoGroupName.normalized(group)
        self.isDone = isDone
        self.verdict = verdict
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, createdAt, day, group, section, isDone, verdict
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        // state.json files written before todos were day-scoped have no
        // `day` key; those todos belong to the day they were created. Every
        // decoded day is re-normalized so `day` is start-of-day no matter
        // which build — or which timezone — wrote the file.
        day = Calendar.current.startOfDay(
            for: try container.decodeIfPresent(Date.self, forKey: .day) ?? createdAt
        )
        // `group` supersedes the earlier manual `section` field; if only the
        // legacy key is present its value seeds the group so existing
        // organization survives the migration.
        let decodedGroup = try container.decodeIfPresent(String.self, forKey: .group)
        let legacySection = try container.decodeIfPresent(String.self, forKey: .section)
        group = TodoGroupName.normalized(decodedGroup ?? legacySection)
        isDone = try container.decode(Bool.self, forKey: .isDone)
        verdict = try container.decodeIfPresent(Verdict.self, forKey: .verdict)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(day, forKey: .day)
        try container.encodeIfPresent(group, forKey: .group)
        try container.encode(isDone, forKey: .isDone)
        try container.encodeIfPresent(verdict, forKey: .verdict)
    }
}

/// One project/theme group of a single day, in the order the UI renders it.
/// A nil `group` is the leading unlabeled cluster of ungrouped todos.
struct TodoGroup: Identifiable, Hashable, Sendable {
    var group: String?
    var todos: [Todo]

    var id: String { group.map { TodoGroupName.key(for: $0) } ?? "__ungrouped__" }
}

/// One calendar day's todos, as rendered by the day-grouped lists.
struct DayGroup: Identifiable, Hashable, Sendable {
    /// Start of the calendar day.
    var day: Date
    var todos: [Todo]

    var id: Date { day }
}

/// The judge's assessment of a single todo against observed activity.
struct Verdict: Codable, Hashable, Sendable {
    enum Status: String, Codable, Hashable, Sendable, CaseIterable {
        case done
        case inProgress
        case notStarted
        case unknown
    }

    var status: Status
    /// One-line justification shown under the todo, e.g.
    /// "Shipped in the 2:01 PM claude session".
    var evidence: String
    var judgedAt: Date
    /// nil until the user accepts or dismisses the verdict.
    var accepted: Bool?

    init(status: Status, evidence: String, judgedAt: Date = Date(), accepted: Bool? = nil) {
        self.status = status
        self.evidence = evidence
        self.judgedAt = judgedAt
        self.accepted = accepted
    }
}
