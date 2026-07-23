import Foundation

/// One row of the cloud `todos` table — `Todo` plus the sync bookkeeping the
/// server needs: a stable per-day `position` (the flat array's display order),
/// an `updatedAt` for last-write-wins merging, and a `deleted` tombstone so
/// removals propagate instead of resurrecting.
struct TodoRecord: Codable, Hashable, Sendable {
    var id: UUID
    var text: String
    /// The semantic calendar day as "yyyy-MM-dd" — a label, not an instant,
    /// so a todo stays on "July 23" across timezones.
    var day: String
    var groupName: String?
    var isDone: Bool
    var verdict: Verdict?
    var position: Double
    var createdAt: Date
    var updatedAt: Date
    var deleted: Bool

    enum CodingKeys: String, CodingKey {
        case id, text, day, verdict, position, deleted
        case groupName = "group_name"
        case isDone = "is_done"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(todo: Todo, position: Double, updatedAt: Date, deleted: Bool = false) {
        id = todo.id
        text = todo.text
        day = Self.dayString(from: todo.day)
        groupName = todo.group
        isDone = todo.isDone
        verdict = todo.verdict
        self.position = position
        createdAt = todo.createdAt
        self.updatedAt = updatedAt
        self.deleted = deleted
    }

    /// Reconstructs the local model. Rows with unparseable days land on today
    /// rather than vanishing.
    var todo: Todo {
        Todo(
            id: id,
            text: text,
            createdAt: createdAt,
            day: Self.dayDate(from: day) ?? Date(),
            group: groupName,
            isDone: isDone,
            verdict: verdict
        )
    }

    /// The fields that make two records "the same content" for dirty checks.
    /// `updatedAt` is deliberately excluded — it records when a change was
    /// made, it isn't itself a change.
    var contentKey: String {
        let verdictPart = verdict.map {
            "\($0.status.rawValue)|\($0.evidence)|\($0.judgedAt.timeIntervalSince1970)|\(String(describing: $0.accepted))"
        } ?? "-"
        return "\(text)|\(day)|\(groupName ?? "-")|\(isDone)|\(verdictPart)|\(position)|\(deleted)"
    }

    // MARK: - Day formatting

    /// POSIX-locale formatter in the local timezone: the string is the user's
    /// calendar day, and parsing lands on that day's local start. Formatters
    /// are documented thread-safe on every supported OS, hence the unsafe opt-out.
    nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dayString(from date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func dayDate(from string: String) -> Date? {
        dayFormatter.date(from: string).map { Calendar.current.startOfDay(for: $0) }
    }
}

extension TodoRecord {
    /// JSON coding tuned for PostgREST: ISO-8601 with fractional seconds both
    /// ways, since Postgres timestamps come back as "…T12:00:00.123456+00:00"
    /// which the plain `.iso8601` strategy rejects.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(wireDateFormatter.string(from: date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = wireDateFormatter.date(from: string) ?? wireDateFallback.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized timestamp: \(string)"
            )
        }
        return decoder
    }

    nonisolated(unsafe) private static let wireDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let wireDateFallback: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
