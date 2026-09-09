import XCTest
@testable import Manas

/// The merge engine is pure, so every conflict shape gets pinned down here:
/// fresh devices, concurrent edits, deletions, tombstones, and ordering.
final class SyncMergeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(
        _ todo: Todo,
        position: Double,
        updatedAt: Date,
        deleted: Bool = false
    ) -> TodoRecord {
        TodoRecord(todo: todo, position: position, updatedAt: updatedAt, deleted: deleted)
    }

    func testFirstSyncPushesEverythingAndSetsSnapshot() {
        let a = Todo(text: "Water the plants")
        let b = Todo(text: "Ship the widget", group: "Work")
        let outcome = SyncMerge.merge(
            local: [a, b],
            snapshot: [:],
            remote: [],
            previousWatermark: nil,
            now: now
        )
        XCTAssertEqual(outcome.todos.map(\.id), [a.id, b.id])
        XCTAssertEqual(Set(outcome.toPush.map(\.id)), [a.id, b.id])
        XCTAssertEqual(outcome.toPush.map(\.updatedAt), [now, now])
        XCTAssertEqual(outcome.snapshot.count, 2)
        XCTAssertNil(outcome.watermark, "our own pushes never move the watermark; only what the server hands back does")
    }

    func testRemoteNewRowsArriveAndNothingEchoesBack() {
        let remoteTodo = Todo(text: "From the desktop", group: "Work")
        let remoteRecord = record(remoteTodo, position: 0, updatedAt: now.addingTimeInterval(-10))
        let outcome = SyncMerge.merge(
            local: [],
            snapshot: [:],
            remote: [remoteRecord],
            previousWatermark: nil,
            now: now
        )
        XCTAssertEqual(outcome.todos.map(\.id), [remoteTodo.id])
        XCTAssertEqual(outcome.todos.first?.group, "Work")
        XCTAssertTrue(outcome.toPush.isEmpty, "a pulled row must not bounce straight back")
        XCTAssertEqual(outcome.watermark, now.addingTimeInterval(-10))
    }

    func testCleanRoundTripIsQuiescent() {
        let todo = Todo(text: "Stay put")
        let first = SyncMerge.merge(
            local: [todo], snapshot: [:], remote: [], previousWatermark: nil, now: now
        )
        let second = SyncMerge.merge(
            local: first.todos,
            snapshot: first.snapshot,
            remote: [],
            previousWatermark: first.watermark,
            now: now.addingTimeInterval(60)
        )
        XCTAssertTrue(second.toPush.isEmpty, "an unchanged store must sync to a no-op")
        XCTAssertEqual(second.todos.map(\.id), [todo.id])
    }

    func testLocalEditBeatsConcurrentRemoteEdit() {
        var base = Todo(text: "Original")
        let synced = record(base, position: 0, updatedAt: now.addingTimeInterval(-100))
        base.text = "Edited here"
        var remoteVersion = synced
        remoteVersion.text = "Edited elsewhere"
        remoteVersion.updatedAt = now.addingTimeInterval(-5)

        let outcome = SyncMerge.merge(
            local: [base],
            snapshot: [base.id: synced],
            remote: [remoteVersion],
            previousWatermark: now.addingTimeInterval(-100),
            now: now
        )
        XCTAssertEqual(outcome.todos.first?.text, "Edited here")
        XCTAssertEqual(outcome.toPush.first?.text, "Edited here")
    }

    func testRemoteEditAppliesWhenLocalIsClean() {
        let base = Todo(text: "Original", group: "Work")
        let synced = record(base, position: 0, updatedAt: now.addingTimeInterval(-100))
        var remoteVersion = synced
        remoteVersion.isDone = true
        remoteVersion.updatedAt = now.addingTimeInterval(-5)

        let outcome = SyncMerge.merge(
            local: [base],
            snapshot: [base.id: synced],
            remote: [remoteVersion],
            previousWatermark: now.addingTimeInterval(-100),
            now: now
        )
        XCTAssertEqual(outcome.todos.first?.isDone, true)
        XCTAssertTrue(outcome.toPush.isEmpty)
    }

    func testLocalDeletionBecomesTombstone() {
        let gone = Todo(text: "Delete me")
        let synced = record(gone, position: 0, updatedAt: now.addingTimeInterval(-100))
        let outcome = SyncMerge.merge(
            local: [],
            snapshot: [gone.id: synced],
            remote: [],
            previousWatermark: now.addingTimeInterval(-100),
            now: now
        )
        XCTAssertTrue(outcome.todos.isEmpty)
        XCTAssertEqual(outcome.toPush.count, 1)
        XCTAssertEqual(outcome.toPush.first?.deleted, true)
        XCTAssertEqual(outcome.toPush.first?.updatedAt, now)
    }

    func testRemoteTombstoneRemovesCleanLocal() {
        let doomed = Todo(text: "Removed on desktop")
        let synced = record(doomed, position: 0, updatedAt: now.addingTimeInterval(-100))
        var tombstone = synced
        tombstone.deleted = true
        tombstone.updatedAt = now.addingTimeInterval(-5)

        let outcome = SyncMerge.merge(
            local: [doomed],
            snapshot: [doomed.id: synced],
            remote: [tombstone],
            previousWatermark: now.addingTimeInterval(-100),
            now: now
        )
        XCTAssertTrue(outcome.todos.isEmpty)
        XCTAssertTrue(outcome.toPush.isEmpty)
    }

    func testRemoteTombstoneDoesNotResurrectViaSnapshot() {
        let doomed = Todo(text: "Deleted everywhere")
        let synced = record(doomed, position: 0, updatedAt: now.addingTimeInterval(-100))
        var tombstone = synced
        tombstone.deleted = true
        tombstone.updatedAt = now.addingTimeInterval(-5)

        // Locally already gone AND remotely tombstoned: nothing comes back.
        let outcome = SyncMerge.merge(
            local: [],
            snapshot: [doomed.id: synced],
            remote: [tombstone],
            previousWatermark: now.addingTimeInterval(-100),
            now: now
        )
        XCTAssertTrue(outcome.todos.isEmpty)
        XCTAssertTrue(outcome.toPush.isEmpty)
    }

    func testLocalDeletionWinsOverConcurrentRemoteEdit() {
        let contested = Todo(text: "Edited there, deleted here")
        let synced = record(contested, position: 0, updatedAt: now.addingTimeInterval(-100))
        var remoteVersion = synced
        remoteVersion.text = "Edited there"
        remoteVersion.updatedAt = now.addingTimeInterval(-5)

        let outcome = SyncMerge.merge(
            local: [],
            snapshot: [contested.id: synced],
            remote: [remoteVersion],
            previousWatermark: now.addingTimeInterval(-100),
            now: now
        )
        XCTAssertTrue(outcome.todos.isEmpty, "deleting is the deliberate act; an edit elsewhere does not bring it back")
        XCTAssertEqual(outcome.toPush.map(\.deleted), [true])
    }

    func testRemoteTombstoneWinsOverALocalEdit() {
        // The Mac's judge writes a verdict on a todo every hour. That used to
        // count as "a local edit in hand", and it resurrected todos the phone
        // had deleted minutes earlier.
        var judged = Todo(text: "Deleted on the phone")
        let synced = record(judged, position: 0, updatedAt: now.addingTimeInterval(-100))
        judged.verdict = Verdict(status: .inProgress, evidence: "Seen in a session", judgedAt: now)
        var tombstone = synced
        tombstone.deleted = true
        tombstone.updatedAt = now.addingTimeInterval(-5)

        let outcome = SyncMerge.merge(
            local: [judged],
            snapshot: [judged.id: synced],
            remote: [tombstone],
            previousWatermark: now.addingTimeInterval(-100),
            now: now
        )
        XCTAssertTrue(outcome.todos.isEmpty)
        XCTAssertTrue(outcome.toPush.isEmpty)
        XCTAssertNil(outcome.snapshot[judged.id])
    }

    func testARowBroughtBackAfterOurTombstoneLandedComesBack() {
        // Our deletion reached the server (the snapshot holds the tombstone)
        // and the server now shows a live row: somebody re-created it on
        // purpose, so it is theirs to keep.
        let revived = Todo(text: "Back by request")
        var ourTombstone = record(revived, position: 0, updatedAt: now.addingTimeInterval(-50))
        ourTombstone.deleted = true
        let theirs = record(revived, position: 0, updatedAt: now.addingTimeInterval(-5))

        let outcome = SyncMerge.merge(
            local: [],
            snapshot: [revived.id: ourTombstone],
            remote: [theirs],
            previousWatermark: now.addingTimeInterval(-100),
            now: now
        )
        XCTAssertEqual(outcome.todos.map(\.text), ["Back by request"])
        XCTAssertTrue(outcome.toPush.isEmpty)
    }

    func testBothSidesEditingDifferentFieldsKeepsBoth() {
        // The phone ticks the box while the Mac writes a verdict. Neither
        // device should lose its change to the other.
        var local = Todo(text: "Ship it", group: "Work")
        let synced = record(local, position: 0, updatedAt: now.addingTimeInterval(-100))
        local.verdict = Verdict(status: .done, evidence: "Shipped in the 2 PM session", judgedAt: now)
        var remoteVersion = synced
        remoteVersion.isDone = true
        remoteVersion.updatedAt = now.addingTimeInterval(-5)

        let outcome = SyncMerge.merge(
            local: [local],
            snapshot: [local.id: synced],
            remote: [remoteVersion],
            previousWatermark: now.addingTimeInterval(-100),
            now: now
        )
        let merged = outcome.todos.first
        XCTAssertEqual(merged?.isDone, true, "the phone's completion survives")
        XCTAssertEqual(merged?.verdict?.status, .done, "and so does the Mac's verdict")
        XCTAssertEqual(outcome.toPush.count, 1, "the combined row goes back up")
        XCTAssertEqual(outcome.toPush.first?.isDone, true)
        XCTAssertEqual(outcome.toPush.first?.verdict?.status, .done)
    }

    func testBothSidesEditingTheSameFieldGoesToThisDevice() {
        var local = Todo(text: "Original")
        let synced = record(local, position: 0, updatedAt: now.addingTimeInterval(-100))
        local.text = "Edited here"
        var remoteVersion = synced
        remoteVersion.text = "Edited there"
        remoteVersion.isDone = true
        remoteVersion.updatedAt = now.addingTimeInterval(-5)

        let outcome = SyncMerge.merge(
            local: [local],
            snapshot: [local.id: synced],
            remote: [remoteVersion],
            previousWatermark: now.addingTimeInterval(-100),
            now: now
        )
        XCTAssertEqual(outcome.todos.first?.text, "Edited here", "a tie goes to the edit the person can still see")
        XCTAssertEqual(outcome.todos.first?.isDone, true, "while the field only they touched still lands")
    }

    func testARowThisDeviceHasNoMemoryOfTakesTheServersCopy() {
        // A Mac signed out and back in, or a lost sync-state.json: the disk
        // still holds an old copy of a row the server has since moved on
        // from. Pushing the old copy would undo a completion made elsewhere.
        let stale = Todo(text: "Stale on disk")
        var current = record(stale, position: 0, updatedAt: now.addingTimeInterval(-5))
        current.isDone = true

        let outcome = SyncMerge.merge(
            local: [stale],
            snapshot: [:],
            remote: [current],
            previousWatermark: nil,
            now: now
        )
        XCTAssertEqual(outcome.todos.first?.isDone, true)
        XCTAssertTrue(outcome.toPush.isEmpty, "nothing on this device outranks the server for a row it never synced")
    }

    func testARowThisDeviceHasNoMemoryOfDoesNotResurrectATombstone() {
        let gone = Todo(text: "Deleted while signed out elsewhere")
        var tombstone = record(gone, position: 0, updatedAt: now.addingTimeInterval(-5))
        tombstone.deleted = true

        let outcome = SyncMerge.merge(
            local: [gone],
            snapshot: [:],
            remote: [tombstone],
            previousWatermark: nil,
            now: now
        )
        XCTAssertTrue(outcome.todos.isEmpty)
        XCTAssertTrue(outcome.toPush.isEmpty)
    }

    func testReReadingTheOverlapWindowIsANoOp() {
        // Every pull starts ten minutes behind the watermark, so rows this
        // device already applied come back on every pass. They must merge
        // to nothing — no push, no change.
        let todo = Todo(text: "Seen before")
        let remoteRecord = record(todo, position: 0, updatedAt: now.addingTimeInterval(-30))
        let first = SyncMerge.merge(
            local: [], snapshot: [:], remote: [remoteRecord], previousWatermark: nil, now: now
        )
        let second = SyncMerge.merge(
            local: first.todos,
            snapshot: first.snapshot,
            remote: [remoteRecord],
            previousWatermark: first.watermark,
            now: now.addingTimeInterval(60)
        )
        XCTAssertTrue(second.toPush.isEmpty)
        XCTAssertEqual(second.todos, first.todos)
        XCTAssertEqual(second.watermark, first.watermark)
    }

    func testWatermarkNeverRunsAheadOfThisDevicesClock() {
        // A device whose clock runs fast stamps rows in the future. Taking
        // that stamp as the watermark would skip every other device's rows
        // until the future arrived; instead the stamp is clamped and the row
        // is simply re-read until then.
        let todo = Todo(text: "From a fast clock")
        let ahead = record(todo, position: 0, updatedAt: now.addingTimeInterval(3600))
        let outcome = SyncMerge.merge(
            local: [], snapshot: [:], remote: [ahead], previousWatermark: nil, now: now
        )
        XCTAssertEqual(outcome.watermark, now)
        XCTAssertEqual(SyncMerge.pullFloor(for: now), now.addingTimeInterval(-SyncMerge.pullOverlap))
        XCTAssertNil(SyncMerge.pullFloor(for: nil))
    }

    func testVerdictSurvivesTheWireModel() {
        let verdict = Verdict(
            status: .inProgress,
            evidence: "Seen in the 2 PM session",
            judgedAt: now.addingTimeInterval(-500),
            accepted: true
        )
        let todo = Todo(text: "Judged work", group: "Work", verdict: verdict)
        let wire = record(todo, position: 0, updatedAt: now)
        let decoded = wire.todo
        XCTAssertEqual(decoded.verdict?.status, .inProgress)
        XCTAssertEqual(decoded.verdict?.evidence, "Seen in the 2 PM session")
        XCTAssertEqual(decoded.verdict?.accepted, true)
        XCTAssertEqual(decoded.group, "Work")
        XCTAssertEqual(decoded.day, todo.day)
    }

    func testRecordJSONRoundTripsThroughPostgRESTTimestampFormat() throws {
        // Whole-second createdAt: the wire format carries milliseconds, so a
        // microsecond-precision Date() would differ after one round trip.
        let todo = Todo(text: "Wire format", createdAt: now, group: "Personal")
        let original = record(todo, position: 2, updatedAt: now)
        let data = try TodoRecord.makeEncoder().encode([original])
        let decoded = try TodoRecord.makeDecoder().decode([TodoRecord].self, from: data)
        XCTAssertEqual(decoded, [original])

        // And the fractional-seconds shape Postgres actually returns.
        let postgresPayload = """
        [{"id":"\(todo.id.uuidString.lowercased())","text":"Wire format","day":"2026-07-23",
        "group_name":null,"is_done":false,"verdict":null,"position":0,
        "created_at":"2026-07-23T12:00:00.123456+00:00",
        "updated_at":"2026-07-23T12:00:00.123456+00:00","deleted":false}]
        """
        let parsed = try TodoRecord.makeDecoder().decode(
            [TodoRecord].self,
            from: Data(postgresPayload.utf8)
        )
        XCTAssertEqual(parsed.first?.day, "2026-07-23")
    }

    func testBulkRecordJSONKeepsIdenticalKeysForNullableColumns() throws {
        let grouped = record(
            Todo(
                text: "Grouped",
                group: "Manas",
                verdict: Verdict(status: .done, evidence: "Shipped")
            ),
            position: 0,
            updatedAt: now
        )
        let ungrouped = record(
            Todo(text: "Ungrouped"),
            position: 1,
            updatedAt: now
        )

        let data = try TodoRecord.makeEncoder().encode([grouped, ungrouped])
        let objects = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )

        XCTAssertEqual(Set(objects[0].keys), Set(objects[1].keys))
        XCTAssertTrue(objects[1]["group_name"] is NSNull)
        XCTAssertTrue(objects[1]["verdict"] is NSNull)
    }

    func testMergedDayOrderFollowsRemotePositions() {
        let day = Calendar.current.startOfDay(for: now)
        let first = Todo(text: "Top", day: day)
        let second = Todo(text: "Bottom", day: day)
        let outcome = SyncMerge.merge(
            local: [],
            snapshot: [:],
            remote: [
                record(second, position: 1, updatedAt: now.addingTimeInterval(-9)),
                record(first, position: 0, updatedAt: now.addingTimeInterval(-8)),
            ],
            previousWatermark: nil,
            now: now
        )
        XCTAssertEqual(outcome.todos.map(\.text), ["Top", "Bottom"])
    }
}
