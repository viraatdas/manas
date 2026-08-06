import Foundation

/// What carrying forward needs to know about sync: whether it is running at
/// all, and whether it has converged even once since launch.
@MainActor
protocol SyncConvergence {
    /// False when signed out or disabled — nothing will ever arrive, so there
    /// is nothing to wait for.
    var carriesRemoteState: Bool { get }
    /// True once a sync pass has completed since launch.
    var hasSyncedSinceLaunch: Bool { get }
}

extension SyncController: SyncConvergence {
    var carriesRemoteState: Bool { isSignedIn && !Self.isDisabledByEnvironment }
    var hasSyncedSinceLaunch: Bool { lastSyncedAt != nil }
}

@MainActor
extension AppStore {
    /// Rolls yesterday's unfinished todos onto today — but not before this
    /// device has heard from the server.
    ///
    /// Carrying forward reads local state and *writes* to it, which is what
    /// made doing it at launch harmful. A device that has been shut since
    /// yesterday still believes yesterday's todos are unfinished. Rolling them
    /// forward from that stale picture moves a todo somebody already crossed
    /// off on another device, and because moving it is a local edit, the merge
    /// treats this device as the one with news: the stale copy wins, and a
    /// finished todo comes back uncrossed at the top of today.
    ///
    /// So when sync is live, wait for the first pass to land. The wait is
    /// bounded because an offline or failing launch must still roll over —
    /// arriving late is a nuisance, never rolling over loses the day.
    @discardableResult
    func carryForwardOverdueTodos(
        awaiting sync: some SyncConvergence,
        timeout: Duration = .seconds(10),
        pollInterval: Duration = .milliseconds(100),
        now: Date = Date()
    ) async -> Int {
        if sync.carriesRemoteState {
            await waitForFirstSync(sync, timeout: timeout, pollInterval: pollInterval)
        }
        return carryForwardOverdueTodos(now: now)
    }

    private func waitForFirstSync(
        _ sync: some SyncConvergence,
        timeout: Duration,
        pollInterval: Duration
    ) async {
        guard !sync.hasSyncedSinceLaunch else { return }
        let deadline = ContinuousClock.now + timeout
        while !sync.hasSyncedSinceLaunch, ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return // Cancelled: the view went away, so nothing to roll.
            }
        }
    }
}
