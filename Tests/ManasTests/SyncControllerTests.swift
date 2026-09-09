import XCTest
@testable import Manas

/// The parts of the sync loop that decide what survives a bad pass — pinned
/// down without a network, because each of them was learned from one.
@MainActor
final class SyncControllerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManasSyncTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func record(_ todo: Todo, deleted: Bool = false) -> TodoRecord {
        TodoRecord(todo: todo, position: 0, updatedAt: now, deleted: deleted)
    }

    // MARK: - A push the server only partly took

    func testRowsTheServerRefusedStayDirty() {
        let accepted = Todo(text: "Taken")
        let refused = Todo(text: "Refused")
        let previousBaseline = record(refused)
        let pushedAccepted = record(accepted)
        var pushedRefused = previousBaseline
        pushedRefused.text = "Refused, edited"

        let next = SyncController.reconcile(
            [accepted.id: pushedAccepted, refused.id: pushedRefused],
            pushed: PushOutcome(accepted: [accepted.id], rejected: [refused.id: "403"]),
            attempted: [pushedAccepted, pushedRefused],
            previous: [refused.id: previousBaseline]
        )
        XCTAssertEqual(next[accepted.id], pushedAccepted, "what landed is the new baseline")
        XCTAssertEqual(next[refused.id], previousBaseline, "what did not stays dirty against the old one")
    }

    func testANewRowTheServerRefusedIsForgottenFromTheSnapshot() {
        let brandNew = Todo(text: "Never landed")
        let next = SyncController.reconcile(
            [brandNew.id: record(brandNew)],
            pushed: .nothing,
            attempted: [record(brandNew)],
            previous: [:]
        )
        XCTAssertNil(next[brandNew.id], "no baseline means the next pass treats it as never synced, and tries again")
    }

    func testOnlyClientRefusalsAreIsolated() {
        XCTAssertTrue(PostgRESTClient.APIError.server(403, "policy").isRejection)
        XCTAssertTrue(PostgRESTClient.APIError.server(409, "unique").isRejection)
        XCTAssertTrue(PostgRESTClient.APIError.server(400, "bad column").isRejection)
        XCTAssertFalse(PostgRESTClient.APIError.server(401, "expired").isRejection, "a stale token is retried whole")
        XCTAssertFalse(PostgRESTClient.APIError.server(429, "slow down").isRejection)
        XCTAssertFalse(PostgRESTClient.APIError.server(500, "boom").isRejection)
        XCTAssertFalse(PostgRESTClient.APIError.server(0, "no response").isRejection)
    }

    // MARK: - A device that lost its list

    private struct SyncState: Codable {
        var watermark: Date?
        var snapshot: [UUID: TodoRecord]
    }

    func testAMissingStateFileWithARememberedSnapshotStartsOverInsteadOfDeletingEverything() throws {
        // state.json is gone (or failed to decode) but sync-state.json still
        // remembers forty rows. Syncing from that pair would tombstone all
        // forty on the server, and every other device would follow.
        let directory = tempDirectory()
        let stateURL = directory.appendingPathComponent("state.json")
        let syncStateURL = directory.appendingPathComponent("sync-state.json")
        let remembered = (0..<40).map { record(Todo(text: "Row \($0)")) }
        let saved = SyncState(
            watermark: now,
            snapshot: Dictionary(uniqueKeysWithValues: remembered.map { ($0.id, $0) })
        )
        try TodoRecord.makeEncoder().encode(saved).write(to: syncStateURL)

        let store = AppStore(fileURL: stateURL)
        XCTAssertFalse(store.loadedFromDisk)
        let sync = SyncController(auth: SignedOutSyncAuth(), stateURL: syncStateURL)
        sync.start(store: store)

        let after = try TodoRecord.makeDecoder().decode(
            SyncState.self, from: Data(contentsOf: syncStateURL)
        )
        XCTAssertTrue(after.snapshot.isEmpty, "the snapshot is dropped, so the server's rows come back down instead of being deleted")
        XCTAssertNil(after.watermark, "and the next pull is a full one")
    }

    func testAnEmptyListReadFromDiskKeepsItsSnapshot() throws {
        // The user really did delete their last todo: the state file exists
        // and says so. That deletion must still reach the server.
        let directory = tempDirectory()
        let stateURL = directory.appendingPathComponent("state.json")
        let syncStateURL = directory.appendingPathComponent("sync-state.json")
        let lastOne = record(Todo(text: "The last one"))
        try TodoRecord.makeEncoder().encode(
            SyncState(watermark: now, snapshot: [lastOne.id: lastOne])
        ).write(to: syncStateURL)
        AppStore(fileURL: stateURL).saveNow()

        let store = AppStore(fileURL: stateURL)
        XCTAssertTrue(store.loadedFromDisk)
        SyncController(auth: SignedOutSyncAuth(), stateURL: syncStateURL).start(store: store)

        let after = try TodoRecord.makeDecoder().decode(
            SyncState.self, from: Data(contentsOf: syncStateURL)
        )
        XCTAssertEqual(after.snapshot.count, 1)
    }

    // MARK: - Pulling in pages

    /// A fake table: rows ordered by (updated_at, id), served in pages the
    /// way PostgREST would answer the queries `pageQuery` builds.
    private func serve(_ rows: [TodoRecord], pageSize: Int, query: String) -> [TodoRecord] {
        let ordered = rows.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
        }
        guard let range = query.range(of: "id.gt.") else {
            return Array(ordered.prefix(pageSize))
        }
        let cursorID = String(query[range.upperBound...].prefix(36))
        let stampStart = query.range(of: "updated_at.gt.")!.upperBound
        let stampEnd = query[stampStart...].firstIndex(of: ",")!
        let stamp = String(query[stampStart..<stampEnd]).removingPercentEncoding!
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let cursorStamp = formatter.date(from: stamp)!
        let after = ordered.filter {
            $0.updatedAt > cursorStamp
                || ($0.updatedAt >= cursorStamp && $0.id.uuidString.lowercased() > cursorID)
        }
        return Array(after.prefix(pageSize))
    }

    func testPagingReadsEveryRowAcrossPagesAndStampTies() async throws {
        // 25 rows, and every fifth shares one stamp with its neighbours —
        // the shape a batch push leaves behind.
        let rows = (0..<25).map { i in
            TodoRecord(
                todo: Todo(text: "Row \(i)"),
                position: Double(i),
                updatedAt: now.addingTimeInterval(Double(i / 5) * 60)
            )
        }
        let pulled = try await SupabaseTodoAPI.paginate(pageSize: 4, floor: nil) { query in
            self.serve(rows, pageSize: 4, query: query)
        }
        XCTAssertEqual(Set(pulled.map(\.id)), Set(rows.map(\.id)), "no row is skipped")
    }

    func testPagingSurvivesARowMovingBetweenPages() async throws {
        // A row on page one is edited elsewhere between fetches, so it moves
        // to the end of the ordering. Offset paging would have skipped the row
        // that shifted into its old slot; keyset paging does not.
        var rows = (0..<10).map { i in
            TodoRecord(todo: Todo(text: "Row \(i)"), position: Double(i), updatedAt: now.addingTimeInterval(Double(i)))
        }
        var fetches = 0
        let pulled = try await SupabaseTodoAPI.paginate(pageSize: 4, floor: nil) { query in
            fetches += 1
            if fetches == 2 {
                rows[1].text = "Edited elsewhere"
                rows[1].updatedAt = now.addingTimeInterval(100)
            }
            return self.serve(rows, pageSize: 4, query: query)
        }
        XCTAssertEqual(Set(pulled.map(\.id)), Set(rows.map(\.id)))
        XCTAssertEqual(
            pulled.last(where: { $0.id == rows[1].id })?.text, "Edited elsewhere",
            "and the moved row's newer content is the one that lands"
        )
    }

    func testTheFirstPageStartsAtTheFloorAndLaterPagesAtTheCursor() {
        let floor = now
        XCTAssertTrue(SupabaseTodoAPI.pageQuery(after: nil, floor: floor, pageSize: 1000)
            .contains("updated_at=gt."))
        let cursor = TodoRecord(todo: Todo(text: "Last on the page"), position: 0, updatedAt: now)
        let next = SupabaseTodoAPI.pageQuery(after: cursor, floor: floor, pageSize: 1000)
        XCTAssertTrue(next.contains("or=(updated_at.gt."))
        XCTAssertTrue(next.contains("id.gt.\(cursor.id.uuidString.lowercased())"))
        XCTAssertFalse(next.contains("updated_at=gt."), "the cursor supersedes the floor")
    }

    func testLostListCheckRunsOncePerProcess() throws {
        // `start` re-runs whenever the root view re-appears, and on a fresh
        // install `loadedFromDisk` stays false for the whole process. The
        // reset must not fire again once the first sync has filled the
        // snapshot, or every re-show of the window would discard it.
        let directory = tempDirectory()
        let stateURL = directory.appendingPathComponent("state.json")
        let syncStateURL = directory.appendingPathComponent("sync-state.json")
        let store = AppStore(fileURL: stateURL)
        let sync = SyncController(auth: SignedOutSyncAuth(), stateURL: syncStateURL)
        sync.start(store: store)

        // The first pass would have written a snapshot; stand in for it.
        let row = record(Todo(text: "Synced after install"))
        try TodoRecord.makeEncoder().encode(
            SyncState(watermark: now, snapshot: [row.id: row])
        ).write(to: syncStateURL)
        let reopened = SyncController(auth: SignedOutSyncAuth(), stateURL: syncStateURL)
        reopened.start(store: store)   // first start of this controller: may reset
        try TodoRecord.makeEncoder().encode(
            SyncState(watermark: now, snapshot: [row.id: row])
        ).write(to: syncStateURL)
        reopened.start(store: store)   // the window re-shown: must not
        let after = try TodoRecord.makeDecoder().decode(SyncState.self, from: Data(contentsOf: syncStateURL))
        XCTAssertEqual(after.snapshot.count, 1)
    }
}
