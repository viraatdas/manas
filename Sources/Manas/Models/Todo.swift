import Foundation

/// A user todo, optionally annotated with the judge's latest verdict.
struct Todo: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var text: String
    var createdAt: Date
    /// The calendar day (start of day) this todo belongs to. Past days are
    /// frozen history, future days are plans; only today's todos get judged.
    var day: Date
    var isDone: Bool
    var verdict: Verdict?

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        day: Date? = nil,
        isDone: Bool = false,
        verdict: Verdict? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.day = Calendar.current.startOfDay(for: day ?? createdAt)
        self.isDone = isDone
        self.verdict = verdict
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, createdAt, day, isDone, verdict
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
        isDone = try container.decode(Bool.self, forKey: .isDone)
        verdict = try container.decodeIfPresent(Verdict.self, forKey: .verdict)
    }
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
