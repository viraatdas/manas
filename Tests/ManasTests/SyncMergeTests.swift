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
        XCTAssertEqual(outcome.watermark, now)
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

    func testConcurrentRemoteEditResurrectsLocalDeletion() {
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
        XCTAssertEqual(outcome.todos.first?.text, "Edited there", "a concurrent edit outweighs a deletion")
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
