import XCTest
@testable import Manas

/// The share tables' own merge: last write wins, and a tombstone the server
/// no longer shows us is finished business rather than something to retry.
final class ShareMergeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func group(
        _ id: UUID,
        name: String,
        owner: String = "14155550137",
        updatedAt: Date,
        deleted: Bool = false
    ) -> SharedGroupRecord {
        SharedGroupRecord(
            id: id, name: name, emoji: nil, ownerID: owner,
            createdAt: now, updatedAt: updatedAt, deleted: deleted
        )
    }

    func testALocallyMadeShareIsPushed() {
        let id = UUID()
        let outcome = ShareMerge.merge(local: [group(id, name: "Manas", updatedAt: now)], remote: [])
        XCTAssertEqual(outcome.toPush.map(\.id), [id])
        XCTAssertEqual(outcome.records.map(\.id), [id])
    }

    func testAShareSomebodyElseMadeArrivesWithoutEchoing() {
        let id = UUID()
        let remote = group(id, name: "Their list", owner: "15555550100", updatedAt: now)
        let outcome = ShareMerge.merge(local: [], remote: [remote])
        XCTAssertEqual(outcome.records.map(\.name), ["Their list"])
        XCTAssertTrue(outcome.toPush.isEmpty)
    }

    func testTheNewerSideWins() {
        let id = UUID()
        let stale = group(id, name: "Old name", updatedAt: now)
        let fresh = group(id, name: "New name", updatedAt: now.addingTimeInterval(60))

        let localWins = ShareMerge.merge(local: [fresh], remote: [stale])
        XCTAssertEqual(localWins.records.map(\.name), ["New name"])
        XCTAssertEqual(localWins.toPush.map(\.name), ["New name"])

        let remoteWins = ShareMerge.merge(local: [stale], remote: [fresh])
        XCTAssertEqual(remoteWins.records.map(\.name), ["New name"])
        XCTAssertTrue(remoteWins.toPush.isEmpty)
    }

    func testATombstoneTheServerNoLongerShowsIsDroppedRatherThanRetriedForever() {
        // What leaving a group looks like on the next pass: our own tombstoned
        // membership row, and a server that has stopped showing us the share.
        // Pushing it again would be a write we no longer have the right to
        // make, and one rejection fails the entire sync pass.
        let member = SharedGroupMemberRecord(
            id: UUID(), shareID: UUID(), phone: "14155550137", displayName: nil,
            createdAt: now, updatedAt: now, deleted: true
        )
        let outcome = ShareMerge.merge(local: [member], remote: [])
        XCTAssertTrue(outcome.toPush.isEmpty)
        XCTAssertTrue(outcome.records.isEmpty)
    }
}

/// How shared rows behave inside the todo merge.
final class SharedTodoSyncTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let mine = "14155550137"
    private let theirs = "15555550100"

    func testTheirRowKeepsTheirOrderInsteadOfBeingRewrittenEveryPass() {
        // The same shared row sits in two people's days, interleaved with two
        // different sets of private todos, so each device computes a different
        // index for it. If both pushed, they would rewrite each other forever.
        let shareID = UUID()
        let hers = Todo(text: "Her line", group: "Manas", shareID: shareID, authorPhone: theirs)
        let remote = TodoRecord(todo: hers, position: 7, updatedAt: now.addingTimeInterval(-10))

        let first = SyncMerge.merge(
            local: [], snapshot: [:], remote: [remote], previousWatermark: nil,
            now: now, currentPhone: mine, liveShareIDs: [shareID]
        )
        XCTAssertTrue(first.toPush.isEmpty)
        XCTAssertEqual(first.snapshot[hers.id]?.position, 7)

        // A second pass with one of our own todos ahead of it in the day.
        let ours = Todo(text: "Mine", authorPhone: mine)
        let second = SyncMerge.merge(
            local: [ours] + first.todos,
            snapshot: first.snapshot,
            remote: [],
            previousWatermark: first.watermark,
            now: now,
            currentPhone: mine,
            liveShareIDs: [shareID]
        )
        XCTAssertEqual(
            second.toPush.map(\.id), [ours.id],
            "only our own new row is pushed; theirs is not renumbered"
        )
        XCTAssertEqual(second.snapshot[hers.id]?.position, 7)
    }

    func testTickingOffTheirSharedTodoStillTravels() {
        let shareID = UUID()
        var hers = Todo(text: "Her line", group: "Manas", shareID: shareID, authorPhone: theirs)
        let remote = TodoRecord(todo: hers, position: 3, updatedAt: now.addingTimeInterval(-10))
        hers.isDone = true

        let outcome = SyncMerge.merge(
            local: [hers],
            snapshot: [hers.id: remote],
            remote: [],
            previousWatermark: nil,
            now: now,
            currentPhone: mine,
            liveShareIDs: [shareID]
        )
        XCTAssertEqual(outcome.toPush.map(\.id), [hers.id])
        XCTAssertEqual(outcome.toPush.first?.isDone, true)
        XCTAssertEqual(
            outcome.toPush.first?.position, 3,
            "the edit travels; their ordering is left alone"
        )
        XCTAssertEqual(outcome.toPush.first?.authorID, theirs, "and it stays their line")
    }

    func testRowsFromAnEndedShareGoQuietInsteadOfWedgingSync() {
        // After a share ends the server rejects any write to the other
        // members' rows, and one rejection fails the whole batch — so the
        // merge must stop offering them.
        let shareID = UUID()
        var hers = Todo(text: "Her line", group: "Manas", shareID: shareID, authorPhone: theirs)
        let synced = TodoRecord(todo: hers, position: 0, updatedAt: now.addingTimeInterval(-10))
        hers.shareID = nil // what applyShareMerge does when the share disappears

        let stillHeld = SyncMerge.merge(
            local: [hers], snapshot: [hers.id: synced], remote: [], previousWatermark: nil,
            now: now, currentPhone: mine, liveShareIDs: []
        )
        XCTAssertTrue(stillHeld.toPush.isEmpty, "a row we may no longer write is never pushed")

        let removedLocally = SyncMerge.merge(
            local: [], snapshot: [hers.id: synced], remote: [], previousWatermark: nil,
            now: now, currentPhone: mine, liveShareIDs: []
        )
        XCTAssertTrue(
            removedLocally.toPush.isEmpty,
            "and dropping it locally must not try to tombstone it either"
        )
        XCTAssertTrue(removedLocally.snapshot.isEmpty)
    }

    func testOurOwnRowsAreUnaffectedByAllOfThis() {
        let ours = Todo(text: "Mine", authorPhone: mine)
        let legacy = Todo(text: "Written before sharing existed")
        let outcome = SyncMerge.merge(
            local: [ours, legacy], snapshot: [:], remote: [], previousWatermark: nil,
            now: now, currentPhone: mine
        )
        XCTAssertEqual(Set(outcome.toPush.map(\.id)), [ours.id, legacy.id])
    }

    func testTheWireCarriesTheShareAndAuthorAsExplicitNulls() throws {
        let shareID = UUID()
        let shared = TodoRecord(
            todo: Todo(text: "Shared", group: "Manas", shareID: shareID, authorPhone: mine),
            position: 0,
            updatedAt: now
        )
        let private_ = TodoRecord(todo: Todo(text: "Private"), position: 1, updatedAt: now)

        // PostgREST rejects a bulk upsert whose objects don't all carry the
        // same keys, so nil columns have to travel as JSON null.
        let data = try TodoRecord.makeEncoder().encode([shared, private_])
        let objects = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        for object in objects {
            XCTAssertTrue(object.keys.contains("share_id"))
            XCTAssertTrue(object.keys.contains("author_id"))
        }
        XCTAssertTrue(objects[1]["share_id"] is NSNull)

        let decoded = try TodoRecord.makeDecoder().decode([TodoRecord].self, from: data)
        XCTAssertEqual(decoded[0].shareID, shareID)
        XCTAssertEqual(decoded[0].authorID, mine)
        XCTAssertEqual(decoded[0].todo.shareID, shareID)
        XCTAssertNil(decoded[1].shareID)
    }

    func testATodoWrittenByAnOlderBuildStillDecodes() throws {
        // state.json files from before sharing carry neither key.
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "text": "Old todo",
          "createdAt": 728000000,
          "day": 728000000,
          "isDone": false
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let plain = JSONDecoder()
        plain.dateDecodingStrategy = .secondsSince1970
        let todo = try plain.decode(Todo.self, from: Data(json.utf8))
        XCTAssertNil(todo.shareID)
        XCTAssertNil(todo.authorPhone)
        XCTAssertEqual(todo.destination, .ungrouped)
    }
}
