import Foundation

/// Sharing a group with a phone number.
///
/// The whole feature rests on one idea: identity is a phone number. You share
/// a group with a number, the person signed in as that number sees the same
/// bucket, and every todo carries whoever wrote it. Nothing here talks to the
/// network — these calls edit the local records, and `SyncController` carries
/// them both ways on its normal cadence, which is what makes sharing work
/// offline and survive a failed request.
extension AppStore {
    // MARK: - Reading

    /// Every share this device is actually in: tombstones dropped, members
    /// attached in join order with the owner first.
    ///
    /// Membership is re-checked here rather than assumed, so a group you left
    /// (or were removed from) disappears the moment its row says so, instead
    /// of lingering until the next pull confirms what is already known.
    var sharedGroups: [SharedGroup] {
        let membersByShare = Dictionary(grouping: sharedMemberRecords.filter { !$0.deleted }) {
            $0.shareID
        }
        let me = PhoneIdentity.normalized(currentPhone)
        return sharedGroupRecords
            .filter { !$0.deleted }
            .filter { record in
                // Signed out there is no "me" to check against, so show what
                // is in hand rather than blanking every shared bucket.
                guard let me else { return true }
                return record.ownerID == me
                    || (membersByShare[record.id] ?? []).contains { $0.phone == me }
            }
            .map { record in
                let members = (membersByShare[record.id] ?? [])
                    .sorted { lhs, rhs in
                        // The owner leads; everyone else in the order they
                        // were invited.
                        if (lhs.phone == record.ownerID) != (rhs.phone == record.ownerID) {
                            return lhs.phone == record.ownerID
                        }
                        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                        return lhs.id.uuidString < rhs.id.uuidString
                    }
                    .map {
                        SharedGroupMember(
                            id: $0.id,
                            phone: $0.phone,
                            displayName: $0.displayName,
                            joinedAt: $0.createdAt
                        )
                    }
                return SharedGroup(
                    id: record.id,
                    name: record.name,
                    emoji: record.emoji,
                    ownerPhone: record.ownerID,
                    members: members,
                    createdAt: record.createdAt
                )
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func sharedGroup(id: UUID) -> SharedGroup? {
        sharedGroups.first { $0.id == id }
    }

    /// The share a todo belongs to, if it is in one.
    func sharedGroup(for todo: Todo) -> SharedGroup? {
        todo.shareID.flatMap { sharedGroup(id: $0) }
    }

    /// True when the signed-in user created the share, and so may invite,
    /// remove, and stop sharing.
    func isOwner(of share: SharedGroup) -> Bool {
        share.isOwned(by: currentPhone)
    }

    /// How a phone number reads in the UI: their name if the group knows one,
    /// "You" for yourself, otherwise the number.
    func memberLabel(_ member: SharedGroupMember) -> String {
        if PhoneIdentity.matches(member.phone, currentPhone) {
            return member.displayName.map { "\($0) (you)" } ?? "You"
        }
        return member.displayName ?? PhoneIdentity.display(member.phone)
    }

    /// True unless the todo is a shared one somebody else wrote. Anything with
    /// no author — every todo written before sharing existed, and everything
    /// added while signed out — is this user's.
    func isAuthoredByCurrentUser(_ todo: Todo) -> Bool {
        guard todo.shareID != nil, let author = todo.authorPhone else { return true }
        return PhoneIdentity.matches(author, currentPhone)
    }

    /// The member who wrote a todo, when it is in a shared group and the author
    /// is still in it. A todo in a private group has no badge to show, and a
    /// row written by someone since removed shows none either.
    func author(of todo: Todo) -> SharedGroupMember? {
        guard let phone = todo.authorPhone, let share = sharedGroup(for: todo) else { return nil }
        return share.member(withPhone: phone)
    }

    // MARK: - Writing

    /// Opens a group up to a phone number, creating the share the first time.
    ///
    /// The group's existing todos join the share, which is what "share this
    /// group" plainly means — otherwise the other person would arrive at an
    /// empty bucket with the same name. Returns nil when the number isn't
    /// usable, when it's the user's own, or when they're already in the group.
    @discardableResult
    func shareGroup(
        _ label: String,
        withPhone rawPhone: String,
        memberName: String? = nil,
        now: Date = Date()
    ) -> SharedGroup? {
        guard let group = canonicalTodoGroup(label),
              let owner = PhoneIdentity.normalized(currentPhone),
              let invitee = PhoneIdentity.normalized(rawPhone),
              invitee != owner
        else { return nil }

        let share = existingShare(named: group) ?? createShare(named: group, owner: owner, now: now)
        guard share.isOwned(by: owner) else { return nil }
        guard addMember(to: share.id, phone: invitee, name: memberName, now: now) != nil else {
            return nil
        }
        adoptTodos(labelled: group, into: share.id)
        UsageAnalytics.shared.capture(.groupShared(
            memberCount: sharedGroup(id: share.id)?.members.count ?? 2
        ))
        return sharedGroup(id: share.id)
    }

    /// Adds one more phone number to an existing share. Returns nil if the
    /// caller doesn't own it, the number is unusable, or they're already in.
    @discardableResult
    func addMember(
        to shareID: UUID,
        phone rawPhone: String,
        name: String? = nil,
        now: Date = Date()
    ) -> SharedGroupMember? {
        guard let share = sharedGroup(id: shareID), isOwner(of: share),
              let phone = PhoneIdentity.normalized(rawPhone),
              share.member(withPhone: phone) == nil
        else { return nil }
        let record = SharedGroupMemberRecord(
            id: UUID(),
            shareID: shareID,
            phone: phone,
            displayName: Self.normalizedName(name),
            createdAt: now,
            updatedAt: now,
            deleted: false
        )
        // A member removed earlier still has a tombstoned row; re-inviting the
        // same number would otherwise trip the (share, phone) uniqueness the
        // server enforces, so revive that row rather than writing a second one.
        if let index = sharedMemberRecords.firstIndex(where: {
            $0.shareID == shareID && $0.phone == phone
        }) {
            sharedMemberRecords[index].deleted = false
            sharedMemberRecords[index].displayName = record.displayName
            sharedMemberRecords[index].updatedAt = now
            let revived = sharedMemberRecords[index]
            return SharedGroupMember(
                id: revived.id,
                phone: revived.phone,
                displayName: revived.displayName,
                joinedAt: revived.createdAt
            )
        }
        sharedMemberRecords.append(record)
        return SharedGroupMember(
            id: record.id,
            phone: record.phone,
            displayName: record.displayName,
            joinedAt: record.createdAt
        )
    }

    /// Removes someone from a share. Their todos stay — the group keeps its
    /// history — they simply stop seeing it. The owner cannot be removed;
    /// stopping the share is the way to end it.
    func removeMember(_ memberID: UUID, from shareID: UUID, now: Date = Date()) {
        guard let share = sharedGroup(id: shareID), isOwner(of: share),
              let index = sharedMemberRecords.firstIndex(where: { $0.id == memberID }),
              sharedMemberRecords[index].shareID == shareID,
              sharedMemberRecords[index].phone != share.ownerPhone
        else { return }
        sharedMemberRecords[index].deleted = true
        sharedMemberRecords[index].updatedAt = now
    }

    /// Steps out of a group somebody else shared. The server lets a member
    /// tombstone their own row, so this is the invitee's counterpart to the
    /// owner's "stop sharing": the group's todos stay behind as a private
    /// group of the same name.
    func leaveSharedGroup(_ shareID: UUID, now: Date = Date()) {
        guard let share = sharedGroup(id: shareID), !isOwner(of: share),
              let phone = PhoneIdentity.normalized(currentPhone),
              let index = sharedMemberRecords.firstIndex(where: {
                  $0.shareID == shareID && $0.phone == phone
              })
        else { return }
        sharedMemberRecords[index].deleted = true
        sharedMemberRecords[index].updatedAt = now
        releaseTodosOfEndedShares()
        UsageAnalytics.shared.capture(.groupUnshared)
    }

    /// Ends a share. The bucket stays in the owner's own list as an ordinary
    /// private group carrying the same todos — sharing was an addition, so
    /// undoing it should take nothing away.
    func stopSharing(_ shareID: UUID, now: Date = Date()) {
        guard let share = sharedGroup(id: shareID), isOwner(of: share) else { return }
        for index in sharedGroupRecords.indices where sharedGroupRecords[index].id == shareID {
            sharedGroupRecords[index].deleted = true
            sharedGroupRecords[index].updatedAt = now
        }
        for index in sharedMemberRecords.indices where sharedMemberRecords[index].shareID == shareID {
            sharedMemberRecords[index].deleted = true
            sharedMemberRecords[index].updatedAt = now
        }
        releaseTodosOfEndedShares()
        UsageAnalytics.shared.capture(.groupUnshared)
    }

    /// Renames the badge on a shared group. Owner-only, and it travels: the
    /// icon is part of the share, not a local preference.
    func setSharedGroupEmoji(_ shareID: UUID, emoji: String?, now: Date = Date()) {
        guard let share = sharedGroup(id: shareID), isOwner(of: share),
              let index = sharedGroupRecords.firstIndex(where: { $0.id == shareID })
        else { return }
        sharedGroupRecords[index].emoji = TodoGroupName.normalizedEmoji(emoji)
        sharedGroupRecords[index].updatedAt = now
    }

    /// Sets the name this user appears under, and writes it onto every
    /// membership row of theirs so the other side sees it too.
    func setMyDisplayName(_ name: String?, now: Date = Date()) {
        let normalized = Self.normalizedName(name)
        myDisplayName = normalized
        guard let phone = PhoneIdentity.normalized(currentPhone) else { return }
        for index in sharedMemberRecords.indices
        where sharedMemberRecords[index].phone == phone
            && sharedMemberRecords[index].displayName != normalized {
            sharedMemberRecords[index].displayName = normalized
            sharedMemberRecords[index].updatedAt = now
        }
    }

    /// Folds a freshly pulled server state into the local records. Called by
    /// `SyncController`; kept here so every mutation of the share tables goes
    /// through one file.
    func applyShareMerge(
        groups: [SharedGroupRecord],
        members: [SharedGroupMemberRecord]
    ) {
        if sharedGroupRecords != groups { sharedGroupRecords = groups }
        if sharedMemberRecords != members { sharedMemberRecords = members }
        releaseTodosOfEndedShares()
    }

    /// What happens to the todos of a share that has ended — revoked by its
    /// owner, or left. The user's own work stays, as an ordinary private group
    /// of the same name: sharing was an addition, and undoing it shouldn't
    /// delete anything they wrote. The other members' todos go, because they
    /// were never this user's to keep and the server has already stopped
    /// accepting writes to them.
    private func releaseTodosOfEndedShares() {
        let live = Set(sharedGroups.map(\.id))
        let ended = todos.filter { todo in
            guard let shareID = todo.shareID else { return false }
            return !live.contains(shareID)
        }
        guard !ended.isEmpty else { return }
        let discarded = Set(ended.filter { !isAuthoredByCurrentUser($0) }.map(\.id))
        todos.removeAll { discarded.contains($0.id) }
        // The share row survives as a tombstone, so its name is still on hand
        // to label the private group the survivors land in.
        let names = Dictionary(
            sharedGroupRecords.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        for index in todos.indices {
            guard let shareID = todos[index].shareID, !live.contains(shareID) else { continue }
            todos[index].shareID = nil
            if todos[index].group == nil { todos[index].group = names[shareID] }
        }
    }

    // MARK: - Internals

    private func existingShare(named group: String) -> SharedGroup? {
        let key = TodoGroupName.key(for: group)
        return sharedGroups.first { TodoGroupName.key(for: $0.name) == key }
    }

    private func createShare(named group: String, owner: String, now: Date) -> SharedGroup {
        let shareID = UUID()
        sharedGroupRecords.append(SharedGroupRecord(
            id: shareID,
            name: group,
            emoji: emoji(forGroup: group),
            ownerID: owner,
            createdAt: now,
            updatedAt: now,
            deleted: false
        ))
        // The owner is a member like anyone else, so "can this number see the
        // group?" is one question with one answer, on the client and in the
        // server's row-level security alike.
        sharedMemberRecords.append(SharedGroupMemberRecord(
            id: UUID(),
            shareID: shareID,
            phone: owner,
            displayName: myDisplayName,
            createdAt: now,
            updatedAt: now,
            deleted: false
        ))
        return sharedGroup(id: shareID) ?? SharedGroup(
            id: shareID,
            name: group,
            emoji: nil,
            ownerPhone: owner,
            members: [],
            createdAt: now
        )
    }

    /// Moves every private todo carrying `label` into the share.
    private func adoptTodos(labelled label: String, into shareID: UUID) {
        let key = TodoGroupName.key(for: label)
        for index in todos.indices
        where todos[index].shareID == nil
            && todos[index].group.map({ TodoGroupName.key(for: $0) }) == key {
            todos[index].shareID = shareID
            if todos[index].authorPhone == nil { todos[index].authorPhone = currentPhone }
        }
    }

    private static func normalizedName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return String(trimmed.prefix(40))
    }
}

extension AppStore {
    /// Names a member so their avatar shows initials instead of digits.
    ///
    /// Avatars fall back to the last two digits of a number when nobody has a
    /// name, which reads like a serial number rather than a person. Invites
    /// made from the contact picker carry a name across on their own; this is
    /// for the ones that predate it, and for correcting a name that came
    /// through wrong. The owner may name anyone in the group; everyone else
    /// only themselves — which is exactly what row-level security allows, so
    /// the write never bounces.
    @discardableResult
    func setMemberName(
        _ rawName: String?,
        forMemberWithPhone rawPhone: String,
        in shareID: UUID,
        now: Date = Date()
    ) -> Bool {
        guard let share = sharedGroup(id: shareID),
              let phone = PhoneIdentity.normalized(rawPhone),
              isOwner(of: share) || PhoneIdentity.matches(phone, currentPhone),
              let index = sharedMemberRecords.firstIndex(where: {
                  $0.shareID == shareID && $0.phone == phone && !$0.deleted
              })
        else { return false }

        let name = Self.normalizedName(rawName)
        guard sharedMemberRecords[index].displayName != name else { return true }
        sharedMemberRecords[index].displayName = name
        sharedMemberRecords[index].updatedAt = now
        return true
    }
}
