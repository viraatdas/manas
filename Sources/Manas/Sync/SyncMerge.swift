import Foundation

/// The pure heart of sync: given the local todos, the last-synced snapshot,
/// and the rows changed remotely since the watermark, produce the merged list,
/// the rows to push, and the next snapshot.
///
/// The rules, in the order they decide a row:
///
/// 1. **A deletion wins.** A tombstone from the server removes the row here
///    even if this device has an unpushed edit in hand, and a row deleted here
///    is tombstoned even if the server has a newer edit. Deleting is the most
///    deliberate thing a person does to a todo; an hourly verdict written by
///    the Mac's judge is not, and it used to bring deleted todos back.
/// 2. **No memory means the server is right.** A row this device has never
///    synced (no snapshot entry) but which already exists on the server —
///    a Mac signed out and back in, a lost `sync-state.json` — takes the
///    server's version rather than overwriting it with whatever stale copy
///    happens to be on disk. Rows the server has never seen are pushed.
/// 3. **Both sides edited: merge by field.** A local change to a field beats
///    the server's; a field this device did not touch takes the server's.
///    So the phone's check-off and the Mac's verdict on the same todo both
///    survive, instead of whichever device synced last clobbering the other.
/// 4. **Order belongs to the writer.** A row somebody else wrote in a shared
///    group keeps the position the server holds for it; only its content is
///    ever pushed back.
///
/// The watermark only ever comes from stamps the server handed back, never
/// from this device's own pushes, and every pull starts `pullOverlap` behind
/// it. Rows are stamped with the pushing device's clock, so a row another
/// device committed a moment before this one's push carried a stamp *below*
/// the old watermark and was never pulled. Re-reading a window is cheap —
/// everything in it merges to a no-op — and it is what makes the two devices
/// actually converge.
enum SyncMerge {
    struct Outcome: Sendable {
        /// The merged list in display order (per-day position ascending).
        var todos: [Todo]
        /// Dirty rows to upsert, tombstones included.
        var toPush: [TodoRecord]
        /// Per-id server state once `toPush` has landed.
        var snapshot: [UUID: TodoRecord]
        /// The newest server stamp seen; the next pull starts here (minus the
        /// overlap).
        var watermark: Date?
    }

    /// How far behind the watermark each pull begins. Wide enough to cover a
    /// whole sync pass on the other device plus any ordinary clock skew.
    static let pullOverlap: TimeInterval = 10 * 60

    /// - Parameters:
    ///   - currentPhone: the signed-in number, used to tell our own rows from
    ///     a shared group's. nil means "everything here is ours", which is
    ///     exactly right for a device with no shared groups.
    ///   - liveShareIDs: the shared groups this device still belongs to. A row
    ///     somebody else wrote in a group that has since ended is no longer
    ///     ours to write, so it must not be pushed.
    static func merge(
        local: [Todo],
        snapshot: [UUID: TodoRecord],
        remote: [TodoRecord],
        previousWatermark: Date?,
        now: Date = Date(),
        currentPhone: String? = nil,
        liveShareIDs: Set<UUID> = []
    ) -> Outcome {
        // Page is sorted oldest-first, so keeping the last occurrence per id
        // resolves any in-page double edit.
        var remoteByID: [UUID: TodoRecord] = [:]
        for record in remote {
            remoteByID[record.id] = record
        }

        // A local todo is content-dirty when it differs from what the server
        // last saw. Position is judged later, after merge decides the order.
        func isContentDirty(_ todo: Todo, against base: TodoRecord) -> Bool {
            let localRecord = TodoRecord(todo: todo, position: base.position, updatedAt: base.updatedAt)
            return localRecord.contentKey != base.contentKey || base.deleted
        }

        // Whether this device may write a row at all. Our own rows always;
        // somebody else's only while we are still in the shared group it
        // belongs to. The server enforces exactly this, and a single rejected
        // row fails the whole batch — so when a share ends, the copies of other
        // people's todos it leaves behind have to fall silent rather than keep
        // being pushed.
        func isWritable(_ record: TodoRecord) -> Bool {
            if record.isAuthored(by: currentPhone) { return true }
            guard let shareID = record.shareID else { return false }
            return liveShareIDs.contains(shareID)
        }

        // Phase 1 — decide each todo's surviving content.
        var merged: [Todo] = []
        /// The server's version of every row we accepted this pass, which is
        /// also where its in-day position comes from.
        var acceptedRemote: [UUID: TodoRecord] = [:]
        var localIDs = Set<UUID>()

        for todo in local {
            localIDs.insert(todo.id)
            guard let record = remoteByID[todo.id] else {
                merged.append(todo)
                continue
            }
            // Rule 1: a tombstone removes the row whatever is in hand.
            guard !record.deleted else { continue }
            guard let base = snapshot[todo.id] else {
                // Rule 2: no memory of syncing this row, so the server's
                // copy is the truth.
                merged.append(record.todo)
                acceptedRemote[todo.id] = record
                continue
            }
            if !isContentDirty(todo, against: base) {
                // Remote changed and we didn't: remote wins.
                merged.append(record.todo)
                acceptedRemote[todo.id] = record
            } else {
                // Rule 3: both sides have news. Fields this device changed
                // beat the server's; the rest take the server's.
                merged.append(threeWay(local: todo, base: base, remote: record))
                acceptedRemote[todo.id] = record
            }
        }

        // Rows that are new to this device.
        for record in remote where !localIDs.contains(record.id) && snapshot[record.id] == nil {
            guard !record.deleted else { continue }
            merged.append(record.todo)
            acceptedRemote[record.id] = record
        }

        // Ids the server knew that are gone locally.
        var tombstones: [TodoRecord] = []
        for (id, base) in snapshot where !localIDs.contains(id) {
            if let record = remoteByID[id] {
                if record.deleted {
                    // Both sides agree it is gone.
                    continue
                }
                if base.deleted {
                    // Our tombstone already landed and the server now shows a
                    // live row: somebody brought it back on purpose.
                    merged.append(record.todo)
                    acceptedRemote[id] = record
                    continue
                }
                // Rule 1 again: our deletion is still in hand and the server
                // edited the row meanwhile. The deletion wins.
            }
            if !base.deleted, isWritable(base) {
                var tombstone = base
                tombstone.deleted = true
                tombstone.updatedAt = now
                tombstones.append(tombstone)
            }
        }

        // A row somebody else wrote in a shared group. Its position belongs to
        // them: the same row sits in two people's days, interleaved with two
        // different sets of private todos, so each device computes a different
        // index for it. If both pushed, the two clients would spend forever
        // rewriting each other's order.
        func isForeign(_ id: UUID) -> Bool {
            guard let record = acceptedRemote[id] ?? snapshot[id], record.shareID != nil else {
                return false
            }
            return !record.isAuthored(by: currentPhone)
        }

        // Phase 2 — settle display order: per-day position ascending, local
        // relative order preserved via stable sort. Days keep ascending order
        // in the flat array; the UI filters per day, so only in-day order shows.
        var positionInDay: [UUID: Double] = [:]
        var dayCounters: [String: Double] = [:]
        for todo in merged {
            let key = TodoRecord.dayString(from: todo.day)
            let localPosition = dayCounters[key, default: 0]
            dayCounters[key] = localPosition + 1
            if isForeign(todo.id), let owned = acceptedRemote[todo.id] ?? snapshot[todo.id] {
                positionInDay[todo.id] = owned.position
            } else {
                positionInDay[todo.id] = acceptedRemote[todo.id]?.position ?? localPosition
            }
        }
        merged.sort { a, b in
            if a.day != b.day { return a.day < b.day }
            let pa = positionInDay[a.id] ?? 0
            let pb = positionInDay[b.id] ?? 0
            if pa != pb { return pa < pb }
            return a.createdAt < b.createdAt
        }

        // Phase 3 — final records: recompute positions from the settled order,
        // then push everything that differs from what the server holds.
        var finalCounters: [String: Double] = [:]
        var toPush = tombstones
        var nextSnapshot: [UUID: TodoRecord] = [:]
        for todo in merged {
            let key = TodoRecord.dayString(from: todo.day)
            let position = finalCounters[key, default: 0]
            finalCounters[key] = position + 1

            // What we believe the server holds right now: the row it just
            // handed back, else the last version we synced.
            let serverCurrent = acceptedRemote[todo.id] ?? remoteByID[todo.id] ?? snapshot[todo.id]
            // Someone else's row keeps the position the server has, so an edit
            // to its text or checkbox travels while its order does not.
            let settledPosition = isForeign(todo.id)
                ? serverCurrent?.position ?? position
                : position
            let candidate = TodoRecord(
                todo: todo,
                position: settledPosition,
                updatedAt: serverCurrent?.updatedAt ?? now
            )
            if let serverCurrent, !serverCurrent.deleted, serverCurrent.contentKey == candidate.contentKey {
                // The server already has exactly this.
                nextSnapshot[todo.id] = serverCurrent
            } else if !isWritable(candidate) {
                // Read-only leftover from a share that ended: keep showing it,
                // stop trying to write it.
                if let serverCurrent { nextSnapshot[todo.id] = serverCurrent }
            } else {
                var pushed = candidate
                pushed.updatedAt = now
                toPush.append(pushed)
                nextSnapshot[todo.id] = pushed
            }
        }
        for tombstone in tombstones {
            nextSnapshot[tombstone.id] = tombstone
        }

        return Outcome(
            todos: merged,
            toPush: toPush,
            snapshot: nextSnapshot,
            watermark: nextWatermark(previous: previousWatermark, remote: remote, now: now)
        )
    }

    /// The stamp the next pull starts from. Only what the server handed back
    /// counts — never this device's own pushes — and never past this device's
    /// own clock: a row stamped in the future by a device whose clock runs
    /// fast is simply re-read on every pass until the clock catches up,
    /// instead of moving the watermark somewhere the other devices' rows can
    /// never reach.
    static func nextWatermark(previous: Date?, remote: [TodoRecord], now: Date) -> Date? {
        let stamps = [previous].compactMap { $0 } + remote.map { min($0.updatedAt, now) }
        return stamps.max()
    }

    /// The stamp to ask the server for: the watermark, less the overlap.
    static func pullFloor(for watermark: Date?) -> Date? {
        watermark?.addingTimeInterval(-pullOverlap)
    }

    /// Field-by-field merge of a row both sides edited since `base`. Starts
    /// from the server's copy and lays this device's changes over it, so a
    /// field the user touched here wins and everything else follows the
    /// server. Ties (both changed the same field) go to this device, which is
    /// the one holding an edit the person can still see.
    static func threeWay(local: Todo, base: TodoRecord, remote: TodoRecord) -> Todo {
        let baseTodo = base.todo
        var resolved = remote.todo
        // Identity fields never merge: the id is the row, and creation is a
        // fact about the past.
        resolved.id = local.id
        resolved.createdAt = local.createdAt
        if local.text != baseTodo.text {
            resolved.text = local.text
        }
        if !Calendar.current.isDate(local.day, inSameDayAs: baseTodo.day) {
            resolved.day = local.day
        }
        // The bucket travels as one thing: a label alone means private, a
        // label with a share id means published. Splitting them could file a
        // todo into a share under the wrong name.
        if local.destination != baseTodo.destination {
            resolved.group = local.group
            resolved.shareID = local.shareID
        }
        if local.isDone != baseTodo.isDone {
            resolved.isDone = local.isDone
        }
        if local.verdict != baseTodo.verdict {
            resolved.verdict = local.verdict
        }
        // The author is claimed exactly once, when a todo written before
        // sign-in first enters a shared group.
        if local.authorPhone != baseTodo.authorPhone, resolved.authorPhone == nil {
            resolved.authorPhone = local.authorPhone
        }
        return resolved
    }
}
