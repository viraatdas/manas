import Foundation

/// One row of `public.shared_groups`: a group the owner opened up to other
/// phone numbers.
///
/// Unlike todos, share rows are both the wire format *and* the local store —
/// `AppStore` persists these records directly and assembles `SharedGroup` for
/// the UI. Keeping the tombstone and the stamp on the same object is what
/// makes revoking a share survive being offline: the row stays in hand, marked
/// deleted, until a sync manages to push it.
struct SharedGroupRecord: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var emoji: String?
    /// Digits of the owner. The server defaults this to the caller's phone
    /// claim and only the owner may write the row, so it can't be forged.
    var ownerID: String
    var createdAt: Date
    var updatedAt: Date
    var deleted: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, emoji, deleted
        case ownerID = "owner_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// PostgREST rejects a bulk upsert whose objects don't all carry the same
    /// keys, and Swift's synthesized encoder drops nil optionals — so nullable
    /// columns are written explicitly as JSON null. Same reason as `TodoRecord`.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(emoji, forKey: .emoji)
        try container.encode(ownerID, forKey: .ownerID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(deleted, forKey: .deleted)
    }

    /// What makes two versions of a row "the same"; `updatedAt` is excluded
    /// because it records when a change happened, it isn't itself a change.
    var contentKey: String {
        "\(name)|\(emoji ?? "-")|\(ownerID)|\(deleted)"
    }
}

/// One row of `public.shared_group_members`: a phone number that can see and
/// add to a shared group. The owner gets one of these too, so membership is a
/// single question everywhere ("is this number in the group?").
struct SharedGroupMemberRecord: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var shareID: UUID
    /// Digits, matching the server's `current_phone_id()`.
    var phone: String
    var displayName: String?
    var createdAt: Date
    var updatedAt: Date
    var deleted: Bool

    enum CodingKeys: String, CodingKey {
        case id, phone, deleted
        case shareID = "share_id"
        case displayName = "display_name"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(shareID, forKey: .shareID)
        try container.encode(phone, forKey: .phone)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(deleted, forKey: .deleted)
    }

    var contentKey: String {
        "\(shareID.uuidString)|\(phone)|\(displayName ?? "-")|\(deleted)"
    }
}

/// Converges the local share rows with the server's.
///
/// Much simpler than `SyncMerge`: share rows are few, and everything except a
/// member renaming themselves is written by the owner alone, so plain
/// last-write-wins on `updatedAt` settles every realistic conflict. The rows
/// the server hasn't seen — or has an older copy of — come back as the push.
enum ShareMerge {
    struct Outcome<Record: Identifiable & Sendable>: Sendable where Record.ID == UUID {
        var records: [Record]
        var toPush: [Record]
    }

    static func merge(
        local: [SharedGroupRecord],
        remote: [SharedGroupRecord]
    ) -> Outcome<SharedGroupRecord> {
        merge(
            local: local,
            remote: remote,
            updatedAt: \.updatedAt,
            contentKey: \.contentKey,
            deleted: \.deleted
        )
    }

    static func merge(
        local: [SharedGroupMemberRecord],
        remote: [SharedGroupMemberRecord]
    ) -> Outcome<SharedGroupMemberRecord> {
        merge(
            local: local,
            remote: remote,
            updatedAt: \.updatedAt,
            contentKey: \.contentKey,
            deleted: \.deleted
        )
    }

    private static func merge<Record: Identifiable & Sendable>(
        local: [Record],
        remote: [Record],
        updatedAt: (Record) -> Date,
        contentKey: (Record) -> String,
        deleted: (Record) -> Bool
    ) -> Outcome<Record> where Record.ID == UUID {
        var remoteByID: [UUID: Record] = [:]
        for record in remote { remoteByID[record.id] = record }

        var merged: [Record] = []
        var toPush: [Record] = []
        var seen = Set<UUID>()

        for record in local {
            seen.insert(record.id)
            guard let server = remoteByID[record.id] else {
                // A tombstone the server didn't hand back is finished
                // business: either it never reached the server, or the server
                // has stopped showing it to us — which is what happens the
                // moment we leave a group. Pushing it again would be a write
                // we no longer have the right to make, and one rejection
                // fails the whole pass, so it is dropped instead.
                guard !deleted(record) else { continue }
                // Otherwise the server has never heard of it — a share made
                // offline, or one whose push hasn't landed yet.
                merged.append(record)
                toPush.append(record)
                continue
            }
            if updatedAt(record) > updatedAt(server), contentKey(record) != contentKey(server) {
                merged.append(record)
                toPush.append(record)
            } else {
                merged.append(server)
            }
        }
        // Rows this device has never seen: a group somebody shared *with* us,
        // or a member the owner added from their other device.
        for record in remote where !seen.contains(record.id) {
            merged.append(record)
        }
        return Outcome(records: merged, toPush: toPush)
    }
}
