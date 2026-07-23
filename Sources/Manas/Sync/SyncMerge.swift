import Foundation

/// The pure heart of sync: given the local todos, the last-synced snapshot,
/// and the rows changed remotely since the watermark, produce the merged list,
/// the rows to push, and the next snapshot. Last write wins per todo; a local
/// edit in hand always beats a concurrent remote edit (it pushes and
/// overwrites), and deletions travel as tombstones so they never resurrect.
enum SyncMerge {
    struct Outcome: Sendable {
        /// The merged list in display order (per-day position ascending).
        var todos: [Todo]
        /// Dirty rows to upsert, tombstones included.
        var toPush: [TodoRecord]
        /// Per-id server state after the push completes.
        var snapshot: [UUID: TodoRecord]
        /// The newest change stamp seen or written; the next pull starts here.
        var watermark: Date?
    }

    static func merge(
        local: [Todo],
        snapshot: [UUID: TodoRecord],
        remote: [TodoRecord],
        previousWatermark: Date?,
        now: Date = Date()
    ) -> Outcome {
        // Page is sorted oldest-first, so keeping the last occurrence per id
        // resolves any in-page double edit.
        var remoteByID: [UUID: TodoRecord] = [:]
        for record in remote {
            remoteByID[record.id] = record
        }

        // A local todo is content-dirty when it never synced or differs from
        // what the server last saw. Position is judged later, after merge
        // decides the final order.
        func isContentDirty(_ todo: Todo) -> Bool {
            guard let synced = snapshot[todo.id] else { return true }
            let localRecord = TodoRecord(todo: todo, position: synced.position, updatedAt: synced.updatedAt)
            return localRecord.contentKey != synced.contentKey || synced.deleted
        }

        // Phase 1 — decide each todo's surviving content.
        var merged: [Todo] = []
        var appliedRemote: [UUID: TodoRecord] = [:]
        var localIDs = Set<UUID>()

        for todo in local {
            localIDs.insert(todo.id)
            if let record = remoteByID[todo.id], !isContentDirty(todo) {
                // Remote changed and we didn't: remote wins, including removal.
                if !record.deleted {
                    merged.append(record.todo)
                    appliedRemote[todo.id] = record
                }
            } else {
                merged.append(todo)
            }
        }

        // Rows that are new to this device.
        for record in remote where !localIDs.contains(record.id) && snapshot[record.id] == nil {
            guard !record.deleted else { continue }
            merged.append(record.todo)
            appliedRemote[record.id] = record
        }

        // Ids the server knew that are gone locally: a concurrent remote edit
        // resurrects (no data loss); otherwise the deletion propagates.
        var tombstones: [TodoRecord] = []
        for (id, synced) in snapshot where !localIDs.contains(id) {
            if let record = remoteByID[id] {
                if !record.deleted {
                    merged.append(record.todo)
                    appliedRemote[id] = record
                }
            } else if !synced.deleted {
                var tombstone = synced
                tombstone.deleted = true
                tombstone.updatedAt = now
                tombstones.append(tombstone)
            }
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
            positionInDay[todo.id] = appliedRemote[todo.id]?.position ?? localPosition
        }
        merged.sort { a, b in
            if a.day != b.day { return a.day < b.day }
            let pa = positionInDay[a.id] ?? 0
            let pb = positionInDay[b.id] ?? 0
            if pa != pb { return pa < pb }
            return a.createdAt < b.createdAt
        }

        // Phase 3 — final records: recompute positions from the settled order,
        // then push everything whose stored server state differs.
        var finalCounters: [String: Double] = [:]
        var toPush = tombstones
        var nextSnapshot: [UUID: TodoRecord] = [:]
        for todo in merged {
            let key = TodoRecord.dayString(from: todo.day)
            let position = finalCounters[key, default: 0]
            finalCounters[key] = position + 1

            let baseline = snapshot[todo.id]
            let candidate = TodoRecord(
                todo: todo,
                position: position,
                updatedAt: baseline?.updatedAt ?? now
            )
            if let applied = appliedRemote[todo.id], applied.contentKey == candidate.contentKey {
                // Freshly pulled and unchanged — the server already has it.
                nextSnapshot[todo.id] = applied
            } else if let baseline, baseline.contentKey == candidate.contentKey, !baseline.deleted {
                nextSnapshot[todo.id] = baseline
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

        let stamps = [previousWatermark].compactMap { $0 }
            + remote.map(\.updatedAt)
            + toPush.map(\.updatedAt)
        return Outcome(
            todos: merged,
            toPush: toPush,
            snapshot: nextSnapshot,
            watermark: stamps.max()
        )
    }
}
