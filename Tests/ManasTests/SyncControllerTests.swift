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
        XCTAssertTrue(PostgRESTClient.APIError.server(401, "JWT expired").isUnauthorized, "a 401 is the token, and buys a refresh")
        XCTAssertFalse(PostgRESTClient.APIError.server(403, "policy").isUnauthorized)
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

    // MARK: - A session the server ended

    /// The refresh refusals that mean the session is gone, as opposed to a
    /// moment's trouble the next attempt clears.
    func testOnlyARefusedRefreshTokenEndsTheSession() {
        for code in ["refresh_token_not_found", "refresh_token_already_used", "session_not_found", "user_not_found"] {
            XCTAssertTrue(SupabaseAuthClient.endsSession(code: code), code)
        }
        // A retired API key answers 401 with no error_code at all; a rate
        // limit or a proxy says something else. None of those is the session.
        for code in [nil, "over_request_rate_limit", "unexpected_failure", "validation_failed"] {
            XCTAssertFalse(SupabaseAuthClient.endsSession(code: code), code ?? "nil")
        }
    }

    private struct OwnedSyncState: Codable {
        var watermark: Date?
        var snapshot: [UUID: TodoRecord]
        var owner: String?
        var ownerAccount: String?
    }

    /// A device holding a session the server has deleted — exactly where the
    /// iPhone and the Mac sat from 2026-09-11, retrying a dead refresh token
    /// every minute under "Invalid Refresh Token: Refresh Token Not Found".
    func testARefusedRefreshSignsOutButKeepsWhatThisDeviceHasNotSent() async throws {
        let directory = tempDirectory()
        let stateURL = directory.appendingPathComponent("state.json")
        let syncStateURL = directory.appendingPathComponent("sync-state.json")
        var edited = Todo(text: "Synced before the session died")
        let row = record(edited)
        try TodoRecord.makeEncoder().encode(
            SyncState(watermark: now, snapshot: [row.id: row])
        ).write(to: syncStateURL)
        edited.isDone = true   // a change the server never saw
        let earlier = AppStore(fileURL: stateURL)
        earlier.todos = [edited]
        earlier.saveNow()
        let store = AppStore(fileURL: stateURL)
        XCTAssertTrue(store.loadedFromDisk)

        let auth = StubAuth(signedInAs: "+13042164370")
        auth.refreshEnds = true
        let sync = SyncController(auth: auth, stateURL: syncStateURL)
        sync.start(store: store)
        await sync.syncNow()

        XCTAssertFalse(sync.isSignedIn, "a dead session reads as signed out, so the app asks to sign in")
        XCTAssertEqual(sync.phase, .signedOut, "not an error repeated every minute")
        XCTAssertEqual(sync.endedSessionPhone, "+13042164370")
        XCTAssertTrue(auth.didSignOut, "the dead session is dropped from the keychain")
        let kept = try TodoRecord.makeDecoder().decode(OwnedSyncState.self, from: Data(contentsOf: syncStateURL))
        XCTAssertEqual(kept.snapshot[row.id]?.isDone, false, "the baseline survives, so the tick still reads as a change")
        XCTAssertEqual(kept.watermark, now)
        XCTAssertEqual(kept.owner, "13042164370")
        XCTAssertEqual(store.todos.first?.isDone, true, "and nothing on the device was touched")

        // Relaunched later, still signed out: the app still knows why.
        let relaunched = SyncController(auth: StubAuth(signedInAs: nil), stateURL: syncStateURL)
        XCTAssertEqual(relaunched.endedSessionPhone, "+13042164370")
    }

    func testAPassOutlivedByASignOutWritesNothing() async throws {
        // A pass waiting on the network when the person signs out used to
        // carry on and write its snapshot back — with no owner, so the next
        // number to sign in inherited it.
        let directory = tempDirectory()
        let stateURL = directory.appendingPathComponent("state.json")
        let syncStateURL = directory.appendingPathComponent("sync-state.json")
        let row = record(Todo(text: "Synced"))
        try TodoRecord.makeEncoder().encode(
            SyncState(watermark: now, snapshot: [row.id: row])
        ).write(to: syncStateURL)
        AppStore(fileURL: stateURL).saveNow()
        let store = AppStore(fileURL: stateURL)

        let auth = StubAuth(signedInAs: "+13042164370")
        auth.slowToken = true
        let sync = SyncController(auth: auth, stateURL: syncStateURL)
        sync.start(store: store)          // its first pass is now waiting on the token
        try await Task.sleep(for: .milliseconds(50))
        sync.signOut()
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(sync.phase, .signedOut, "the stale pass does not report over the sign-out")
        XCTAssertFalse(FileManager.default.fileExists(atPath: syncStateURL.path), "nor write its snapshot back")
    }

    func testSigningBackInWithTheSameNumberResumesFromTheKeptSnapshot() async throws {
        let syncStateURL = tempDirectory().appendingPathComponent("sync-state.json")
        let row = record(Todo(text: "Kept"))
        try TodoRecord.makeEncoder().encode(
            OwnedSyncState(watermark: now, snapshot: [row.id: row], owner: "13042164370", ownerAccount: "account-1")
        ).write(to: syncStateURL)

        let auth = StubAuth(signedInAs: nil)
        let sync = SyncController(auth: auth, stateURL: syncStateURL)
        XCTAssertEqual(sync.endedSessionPhone, "+13042164370")
        try await sync.verifyCode(phone: "+13042164370", code: "123456")
        sync.stop()

        XCTAssertNil(sync.endedSessionPhone)
        let after = try TodoRecord.makeDecoder().decode(OwnedSyncState.self, from: Data(contentsOf: syncStateURL))
        XCTAssertEqual(Array(after.snapshot.keys), [row.id], "the same account picks up where it stopped")
        XCTAssertEqual(after.watermark, now)
    }

    func testStateFromBeforeOwnersExistedIsKeptAtSignIn() async throws {
        // Every sync-state.json written before 1.0.3 has no owner. Signing in
        // used to keep it; throwing it away would trade this device's unsent
        // edits for the server's copies.
        let syncStateURL = tempDirectory().appendingPathComponent("sync-state.json")
        let row = record(Todo(text: "Legacy"))
        try TodoRecord.makeEncoder().encode(
            SyncState(watermark: now, snapshot: [row.id: row])
        ).write(to: syncStateURL)

        let sync = SyncController(auth: StubAuth(signedInAs: nil), stateURL: syncStateURL)
        try await sync.verifyCode(phone: "+13042164370", code: "123456")
        sync.stop()

        let after = try TodoRecord.makeDecoder().decode(OwnedSyncState.self, from: Data(contentsOf: syncStateURL))
        XCTAssertEqual(Array(after.snapshot.keys), [row.id])
        XCTAssertEqual(after.owner, "13042164370", "and from now on it has one")
    }

    func testTheSameNumberWithARecreatedAccountStartsClean() async throws {
        // The account was deleted on the other device and this number signed
        // up again. The new account has none of the rows the snapshot says
        // the server holds, so resuming would never push them.
        let syncStateURL = tempDirectory().appendingPathComponent("sync-state.json")
        let row = record(Todo(text: "Only on this device now"))
        try TodoRecord.makeEncoder().encode(
            OwnedSyncState(watermark: now, snapshot: [row.id: row], owner: "13042164370", ownerAccount: "account-1")
        ).write(to: syncStateURL)

        let auth = StubAuth(signedInAs: nil)
        auth.nextAccountID = "account-2"
        let sync = SyncController(auth: auth, stateURL: syncStateURL)
        try await sync.verifyCode(phone: "+13042164370", code: "123456")
        sync.stop()

        let after = try TodoRecord.makeDecoder().decode(OwnedSyncState.self, from: Data(contentsOf: syncStateURL))
        XCTAssertTrue(after.snapshot.isEmpty, "every row goes up to the new account")
        XCTAssertEqual(after.ownerAccount, "account-2")
    }

    func testADifferentNumberSigningInStartsClean() async throws {
        let syncStateURL = tempDirectory().appendingPathComponent("sync-state.json")
        let row = record(Todo(text: "Somebody else's history"))
        try TodoRecord.makeEncoder().encode(
            OwnedSyncState(watermark: now, snapshot: [row.id: row], owner: "13042164370", ownerAccount: "account-1")
        ).write(to: syncStateURL)

        let sync = SyncController(auth: StubAuth(signedInAs: nil), stateURL: syncStateURL)
        try await sync.verifyCode(phone: "+14155550137", code: "123456")
        sync.stop()

        let after = try TodoRecord.makeDecoder().decode(OwnedSyncState.self, from: Data(contentsOf: syncStateURL))
        XCTAssertTrue(after.snapshot.isEmpty, "one account's rows are never another's history")
        XCTAssertNil(after.watermark)
        XCTAssertEqual(after.owner, "14155550137")
    }
}

/// Auth with no keychain and no network. `bearerToken()` never hands out a
/// token — so no pass in these tests can reach the live backend — and either
/// ends the session or fails like a dropped connection.
@MainActor
private final class StubAuth: SyncAuth {
    private(set) var phone: String?
    private(set) var accountID: String?
    /// The account a `verifyCode` signs into.
    var nextAccountID = "account-1"
    var refreshEnds = false
    private(set) var didSignOut = false

    init(signedInAs phone: String?) {
        self.phone = phone
        accountID = phone == nil ? nil : "account-1"
    }

    struct Offline: Error {}

    var isSignedIn: Bool { phone != nil }
    func requestCode(phone: String) async throws {}
    func verifyCode(phone: String, code: String) async throws {
        self.phone = phone
        accountID = nextAccountID
    }
    /// Hands out a token after a pause, so a test can act while a pass waits
    /// on it. The token is never good: the pass must stop before using it.
    var slowToken = false

    func bearerToken() async throws -> String {
        if slowToken {
            try await Task.sleep(for: .milliseconds(200))
            return "never-sent"
        }
        if refreshEnds {
            throw SessionEndedError(reason: "Invalid Refresh Token: Refresh Token Not Found")
        }
        throw Offline()
    }
    func expireAccessToken() {}
    func deleteAccount() async throws {}
    func signOut() {
        phone = nil
        accountID = nil
        didSignOut = true
    }
}
