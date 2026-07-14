import Foundation

/// A user todo, optionally annotated with the judge's latest verdict.
struct Todo: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var text: String
    var createdAt: Date
    var isDone: Bool
    var verdict: Verdict?

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        isDone: Bool = false,
        verdict: Verdict? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.isDone = isDone
        self.verdict = verdict
    }
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
