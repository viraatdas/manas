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
}
