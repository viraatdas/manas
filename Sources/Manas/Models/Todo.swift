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

/// Stable identifiers for the foldable sections of a day. Namespaced so a
/// group that happens to be called "discovered" can't collide with the
/// discovered-activities section, and built on the case-folded group key so
/// re-capitalizing a group does not silently unfold it.
///
/// Group keys carry the day they belong to. The feed stacks many days in one
/// scroll view, and most of them own a "Work" and a "Personal" group; a key
/// shared across days folded every one of them at once, so clicking today's
/// header resized the history sitting above the viewport and threw the scroll
/// position somewhere else entirely.
enum SectionKey {
    static func group(_ label: String, on day: Date) -> String {
        "group:\(dayKey(day)):\(TodoGroupName.key(for: label))"
    }

    /// A shared group folds on its share id, not its label: two buckets on the
    /// same day may legitimately share a name, and folding one must not fold
    /// the other.
    static func group(_ destination: TodoDestination, on day: Date) -> String {
        guard destination.shareID != nil else {
            return group(destination.group ?? "", on: day)
        }
        return "group:\(dayKey(day)):\(destination.key)"
    }

    static let discovered = "section:discovered"

    /// `yyyy-MM-dd` in the current calendar. Built from date components rather
    /// than a formatter so it never picks up a locale's numbering system.
    static func dayKey(_ day: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }

    /// The day a group key belongs to, or nil for any other key (the
    /// discovered section, or a `group:work` key written before groups folded
    /// per day). Used to drop keys whose day no longer has any todos.
    static func dayComponent(of key: String) -> String? {
        let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "group" else { return nil }
        return String(parts[1])
    }

    /// True for a key this build no longer understands: a `group:` key without
    /// a day, left behind by an older state.json. Folding is a view
    /// preference, so these are simply dropped rather than migrated onto a day
    /// they were never scoped to.
    static func isStaleGroupKey(_ key: String) -> Bool {
        key.hasPrefix("group:") && dayComponent(of: key) == nil
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
    /// The shared group this todo belongs to, if any. Only ever set by an
    /// explicit user action (adding into a shared bucket, or dragging one
    /// there) — the judge's automatic grouping never sets it, so a check-in
    /// can't push private work into somebody else's list by guessing a label.
    var shareID: UUID?
    /// Digits of whoever wrote it, stamped at creation from the signed-in
    /// number. nil for anything written before sharing existed, or while
    /// signed out; a shared row without an author simply shows no avatar.
    var authorPhone: String?
    var isDone: Bool
    var verdict: Verdict?

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        day: Date? = nil,
        group: String? = nil,
        shareID: UUID? = nil,
        authorPhone: String? = nil,
        isDone: Bool = false,
        verdict: Verdict? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.day = Calendar.current.startOfDay(for: day ?? createdAt)
        self.group = TodoGroupName.normalized(group)
        self.shareID = shareID
        self.authorPhone = PhoneIdentity.normalized(authorPhone)
        self.isDone = isDone
        self.verdict = verdict
    }

    /// Where this todo sits: its label plus the share that owns it.
    var destination: TodoDestination {
        TodoDestination(group: group, shareID: shareID)
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, createdAt, day, group, section, shareID, authorPhone, isDone, verdict
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
        // Both absent from every state.json written before sharing shipped.
        shareID = try container.decodeIfPresent(UUID.self, forKey: .shareID)
        authorPhone = PhoneIdentity.normalized(
            try container.decodeIfPresent(String.self, forKey: .authorPhone)
        )
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
        try container.encodeIfPresent(shareID, forKey: .shareID)
        try container.encodeIfPresent(authorPhone, forKey: .authorPhone)
        try container.encode(isDone, forKey: .isDone)
        try container.encodeIfPresent(verdict, forKey: .verdict)
    }
}

/// One project/theme group of a single day, in the order the UI renders it.
/// A nil `group` is the leading unlabeled cluster of ungrouped todos.
struct TodoGroup: Identifiable, Hashable, Sendable {
    var group: String?
    /// Set when this bucket is a shared group, which is what separates it from
    /// a private group that happens to carry the same label.
    var shareID: UUID?
    var todos: [Todo]

    init(group: String?, shareID: UUID? = nil, todos: [Todo]) {
        self.group = group
        self.shareID = shareID
        self.todos = todos
    }

    var destination: TodoDestination {
        TodoDestination(group: group, shareID: shareID)
    }

    var id: String { destination.key }
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
