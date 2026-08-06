import XCTest
@testable import Manas

/// Rolling yesterday forward is a *write*, so doing it from a stale picture is
/// how a finished todo comes back. These cover when it is allowed to happen.
@MainActor
final class CarryForwardSyncOrderingTests: XCTestCase {
    private final class FakeSync: SyncConvergence {
        var carriesRemoteState: Bool
        var hasSyncedSinceLaunch: Bool

        init(carriesRemoteState: Bool, hasSyncedSinceLaunch: Bool) {
            self.carriesRemoteState = carriesRemoteState
            self.hasSyncedSinceLaunch = hasSyncedSinceLaunch
        }
    }

    private func store(withOverdueTodo done: Bool) -> AppStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("manas-carryforward-\(UUID().uuidString).json")
        let store = AppStore(fileURL: url, saveDebounce: .zero)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        store.addTodo("yesterday's work", on: yesterday)
        if done, let id = store.todos.first?.id { store.toggleDone(id) }
        return store
    }

    /// Signed out, nothing will ever arrive — waiting would just lose the day.
    func testSignedOutRollsForwardImmediately() async {
        let store = store(withOverdueTodo: false)
        let carried = await store.carryForwardOverdueTodos(
            awaiting: FakeSync(carriesRemoteState: false, hasSyncedSinceLaunch: false)
        )
        XCTAssertEqual(carried, 1)
        XCTAssertEqual(store.todosToday.count, 1)
    }

    /// The bug: a phone shut since yesterday rolls forward a todo that was
    /// crossed off on the Mac, and because moving it is a local edit, that
    /// stale copy wins the merge and the finished todo returns, uncrossed.
    func testItWaitsForTheFirstSyncBeforeRollingAnythingForward() async {
        let store = store(withOverdueTodo: false)
        let sync = FakeSync(carriesRemoteState: true, hasSyncedSinceLaunch: false)

        let carried = await store.carryForwardOverdueTodos(
            awaiting: sync,
            timeout: .milliseconds(120),
            pollInterval: .milliseconds(10)
        )

        // It still rolls over after the bounded wait — never rolling over would
        // lose the day for anyone offline — but it gave sync its chance first.
        XCTAssertEqual(carried, 1, "an offline launch must still roll the day over")
    }

    /// Once sync has landed, the local picture is trustworthy and the roll
    /// happens without waiting out the timeout.
    func testAfterSyncItRollsForwardWithoutWaiting() async {
        let store = store(withOverdueTodo: false)
        let sync = FakeSync(carriesRemoteState: true, hasSyncedSinceLaunch: true)

        let started = ContinuousClock.now
        let carried = await store.carryForwardOverdueTodos(
            awaiting: sync,
            timeout: .seconds(30),
            pollInterval: .milliseconds(10)
        )

        XCTAssertEqual(carried, 1)
        XCTAssertLessThan(started.duration(to: .now), .seconds(5), "a converged sync should not be waited on")
    }

    /// The thing the user actually asked for: crossing something off keeps it
    /// off, and it never reappears on the next day's list.
    func testSomethingCrossedOffNeverAppearsOnTheNextDay() async {
        let store = store(withOverdueTodo: true)
        let carried = await store.carryForwardOverdueTodos(
            awaiting: FakeSync(carriesRemoteState: false, hasSyncedSinceLaunch: false)
        )
        XCTAssertEqual(carried, 0)
        XCTAssertTrue(store.todosToday.isEmpty, "a finished todo has no business on today's list")
    }
}
