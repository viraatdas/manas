import Foundation
import Observation
import os
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Owns the cloud session and keeps `AppStore.todos` and the server table
/// converged. Sync is an overlay: signed out, the app is exactly the local
/// app it always was. Signed in, every local change pushes shortly after it
/// happens and remote changes fold in on a steady cadence.
@MainActor
@Observable
final class SyncController {
    enum Phase: Equatable {
        case signedOut
        case idle
        case syncing
        case error(String)
    }

    private(set) var isSignedIn: Bool
    private(set) var phoneNumber: String?
    private(set) var phase: Phase = .signedOut
    private(set) var lastSyncedAt: Date?
    /// Rows the server refused on the most recent pass, by id, with what it
    /// said. Not persisted: a relaunch retries them, and a later edit to the
    /// row retries it at once. Surfaced so "it didn't sync" has a number on
    /// it instead of being indistinguishable from "it synced".
    private(set) var rejectedRows: [UUID: String] = [:]

    @ObservationIgnored private let auth: any SyncAuth
    @ObservationIgnored private let api = SupabaseTodoAPI()
    @ObservationIgnored private let shareAPI = SupabaseShareAPI()
    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSync: Task<Void, Never>?
    @ObservationIgnored private var isApplyingMerge = false
    @ObservationIgnored private var isObservingStore = false
    @ObservationIgnored private var syncInFlight = false
    /// The lost-list check below runs once per process. `start` is called
    /// again whenever the root view re-appears, and `loadedFromDisk` stays
    /// false for the whole life of a fresh-install process, so without this
    /// latch every re-show of the window after the first sync would throw the
    /// snapshot away and let the next pull resurrect what had just been
    /// deleted.
    @ObservationIgnored private var hasCheckedForLostList = false
    /// Set when a pass is asked for while one is running, so the request is
    /// honoured as soon as the running pass ends instead of being dropped
    /// until the next minute tick.
    @ObservationIgnored private var needsAnotherPass = false
    /// What each refused row looked like when it was refused, and why. The
    /// row is left out of later batches while it still looks like that —
    /// sending the same rejected row every minute helps nobody — and goes
    /// straight back in the moment it changes.
    private struct Rejection {
        var content: String
        var reason: String
    }
    @ObservationIgnored private var rejections: [UUID: Rejection] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "Manas", category: "Sync")

    /// On-disk sync bookkeeping, next to the state file.
    private struct SyncState: Codable {
        var watermark: Date?
        var snapshot: [UUID: TodoRecord]
    }

    @ObservationIgnored private var watermark: Date?
    @ObservationIgnored private var snapshot: [UUID: TodoRecord] = [:]

    /// - Parameters:
    ///   - auth: the phone-auth backend. Both platforms default to the same
    ///     Stytch-backed flow so either device can be the first one signed in.
    ///   - stateURL: where to persist the watermark + snapshot; defaults to
    ///     `sync-state.json` beside the app's state file.
    init(auth: (any SyncAuth)? = nil, stateURL: URL? = nil) {
        // Constructed before anything else touches auth: the real backend
        // reads the keychain from its initializer, on the main thread, before
        // the window exists — so the seam has to stand in for the backend
        // rather than merely ignore it.
        self.auth = auth ?? (Self.isDisabledByEnvironment ? SignedOutSyncAuth() : StytchSyncAuth())
        self.stateURL = stateURL
            ?? AppStore.defaultStateURL.deletingLastPathComponent().appendingPathComponent("sync-state.json")
        isSignedIn = self.auth.isSignedIn
        phoneNumber = self.auth.phone
        if isSignedIn { phase = .idle }
        if let data = try? Data(contentsOf: self.stateURL),
           let saved = try? TodoRecord.makeDecoder().decode(SyncState.self, from: data) {
            watermark = saved.watermark
            snapshot = saved.snapshot
        }
    }

    /// Dev/verification seam, alongside `MANAS_STATE_FILE` and
    /// `MANAS_DISABLE_AUTO_CHECKS`: a locally built copy of the app reads the
    /// same login keychain as the installed one (the keychain service name is
    /// fixed, not scoped by bundle id), so launching one to check a UI change
    /// otherwise signs in as the real user and pushes scratch todos to their
    /// live account. Setting this keeps the build permanently signed out.
    static var isDisabledByEnvironment: Bool {
        let value = ProcessInfo.processInfo.environment["MANAS_DISABLE_SYNC"] ?? ""
        return !value.isEmpty && value != "0"
    }

    // MARK: - Sign in / out

    /// Re-reads a session restored from the shared keychain after the UI is up.
    func refreshAuthState() {
        guard !Self.isDisabledByEnvironment else { return }
        isSignedIn = auth.isSignedIn
        phoneNumber = auth.phone
        publishIdentity()
        if isSignedIn, phase == .signedOut { phase = .idle }
    }

    func requestCode(phone: String) async throws {
        try await auth.requestCode(phone: phone)
    }

    func verifyCode(phone: String, code: String) async throws {
        try await auth.verifyCode(phone: phone, code: code)
        isSignedIn = auth.isSignedIn
        phoneNumber = auth.phone
        publishIdentity()
        phase = .idle
        scheduleSync(after: .zero)
    }

    /// Tells the store who is signed in. That number is the identity behind
    /// shared groups — the author stamped onto new todos, and the member the
    /// UI draws as "you".
    private func publishIdentity() {
        store?.currentPhone = isSignedIn ? PhoneIdentity.normalized(phoneNumber) : nil
    }

    func signOut() {
        stop()
        auth.signOut()
        isSignedIn = false
        phoneNumber = nil
        store?.currentPhone = nil
        phase = .signedOut
        forgetSyncState()
    }

    /// Deletes the authenticated server account, then removes every local
    /// trace only after the server confirms success. A transient network error
    /// therefore never strands the user with local data gone but an account
    /// still active.
    func deleteAccount() async throws {
        stop()
        do {
            try await auth.deleteAccount()
        } catch {
            if isSignedIn { startLoopIfPossible() }
            throw error
        }

        store?.resetUserData()
        store?.saveNow()
        UsageAnalytics.shared.resetAfterAccountDeletion()
        isSignedIn = false
        phoneNumber = nil
        phase = .signedOut
        forgetSyncState()
    }

    private func forgetSyncState() {
        watermark = nil
        snapshot = [:]
        lastSyncedAt = nil
        rejectedRows = [:]
        rejections = [:]
        try? FileManager.default.removeItem(at: stateURL)
    }

    // MARK: - Sync loop

    /// Binds to the store and starts the cadence: an immediate, user-visible
    /// priority pass, a pass ~2s after any local change, and a steady pull
    /// every minute. `syncNow()` suspends at network calls, so this never
    /// delays the first frame of the feed.
    func start(store: AppStore) {
        self.store = store
        // Identity is published even with sync disabled: a verification run
        // signed in through `MANAS_PROBE_SIGNED_IN_AS` needs the store to know
        // its own number, which is what an invite's missing country code is
        // resolved against. The loop below is what actually talks to the
        // network, and it stays off.
        publishIdentity()
        // A snapshot with no state file behind it is a device that has lost
        // its list — a state.json that failed to decode, or was removed —
        // not a device whose user deleted every todo. Syncing from that pair
        // would tombstone every row the snapshot remembers, on every other
        // device too. Start over as a fresh device instead: the server's rows
        // come back down, nothing goes up.
        if !hasCheckedForLostList {
            hasCheckedForLostList = true
            if !store.loadedFromDisk, !snapshot.isEmpty {
                logger.error("State file missing but \(self.snapshot.count) rows in the sync snapshot; resetting sync state rather than deleting them everywhere")
                watermark = nil
                snapshot = [:]
                persistSyncState()
            }
        }
        guard !Self.isDisabledByEnvironment else { return }
        startLoopIfPossible()
    }

    private func startLoopIfPossible() {
        guard loopTask == nil, !Self.isDisabledByEnvironment else { return }
        observeStore()
        loopTask = Task(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        pendingSync?.cancel()
        pendingSync = nil
    }

    /// Pull promptly when the app returns to the foreground or the Mac wakes.
    /// The in-flight guard in `syncNow()` coalesces this with a launch or
    /// periodic pass, so duplicate lifecycle notifications cannot create
    /// competing database updates.
    func refreshInBackground() {
        guard !Self.isDisabledByEnvironment, isSignedIn else { return }
        Task(priority: .userInitiated) { [weak self] in
            await self?.syncNow()
        }
    }

    /// Arms observation of the synced state, once; every change (except our
    /// own merge application) schedules a short-debounce push. Share rows are
    /// watched alongside the todos so inviting someone reaches them in seconds
    /// rather than at the next minute tick.
    private func observeStore() {
        guard !isObservingStore else { return }
        isObservingStore = true
        observeStoreOnce()
    }

    private func observeStoreOnce() {
        guard let store else { return }
        withObservationTracking {
            _ = store.todos
            _ = store.sharedGroupRecords
            _ = store.sharedMemberRecords
        } onChange: { [weak self] in
            // Read the flag *now*, on the mutating actor: the merge sets it,
            // assigns, and clears it in one synchronous stretch, so by the
            // time a hop to the main actor runs the flag is already false and
            // every applied merge used to schedule a needless pass.
            let isOurOwnWrite = Thread.isMainThread
                ? MainActor.assumeIsolated { self?.isApplyingMerge ?? false }
                : false
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !isOurOwnWrite {
                    self.scheduleSync(after: .seconds(2))
                }
                self.observeStoreOnce()
            }
        }
    }

    private func scheduleSync(after delay: Duration) {
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// One full pass: refresh the token if needed, pull, merge, apply, push.
    /// A request that arrives mid-pass runs another pass straight after.
    func syncNow() async {
        // The offline seam is absolute: `MANAS_PROBE_SIGNED_IN_AS` makes
        // `isSignedIn` true so the sharing UI is drivable, and this is what
        // keeps that identity from ever reaching the network.
        guard !Self.isDisabledByEnvironment else { return }
        guard SupabaseConfig.isConfigured, isSignedIn, let store else { return }
        guard !syncInFlight else {
            needsAnotherPass = true
            return
        }
        syncInFlight = true
        defer { syncInFlight = false }
        repeat {
            needsAnotherPass = false
            await runPass(store: store)
        } while needsAnotherPass && isSignedIn
    }

    private func runPass(store: AppStore) async {
        phase = .syncing
        do {
            let token = try await auth.bearerToken()
            // Shares go first, and their push lands before any todo does: a
            // todo carries its share id as a foreign key, so the group has to
            // exist on the server before a row can point at it.
            try await syncShares(store: store, token: token)
            let remote = try await api.changes(since: watermark, accessToken: token)
            let outcome = SyncMerge.merge(
                local: store.todos,
                snapshot: snapshot,
                remote: remote,
                previousWatermark: watermark,
                currentPhone: PhoneIdentity.normalized(phoneNumber),
                liveShareIDs: Set(store.sharedGroups.map(\.id))
            )
            // What the server said is applied before anything is sent back.
            // Applying only after a successful push meant a push the server
            // kept refusing also kept every remote change off the screen —
            // the list looked frozen, with nothing anywhere saying why.
            apply(outcome.todos, to: store)
            watermark = outcome.watermark

            let previousSnapshot = snapshot
            // A row the server refused last time, unchanged since, sits the
            // batch out; anything else the merge wants sent goes.
            let batch = outcome.toPush.filter { rejections[$0.id]?.content != $0.contentKey }
            let pushed: PushOutcome
            do {
                pushed = try await api.push(batch, accessToken: token)
            } catch {
                // Nothing landed. Keep every pushed row dirty against its old
                // baseline so the next pass sends it again, but keep what
                // was pulled: that part of the pass did happen.
                snapshot = Self.reconcile(
                    outcome.snapshot, pushed: .nothing, attempted: outcome.toPush, previous: previousSnapshot
                )
                persistSyncState()
                throw error
            }
            snapshot = Self.reconcile(
                outcome.snapshot, pushed: pushed, attempted: outcome.toPush, previous: previousSnapshot
            )
            for record in batch {
                if let reason = pushed.rejected[record.id] {
                    rejections[record.id] = Rejection(content: record.contentKey, reason: reason)
                    logger.error("Server refused todo \(record.id.uuidString): \(reason)")
                } else if pushed.accepted.contains(record.id) {
                    rejections[record.id] = nil
                }
            }
            // A refusal is only worth remembering while the merge still
            // wants that row sent.
            let stillOffered = Set(outcome.toPush.map(\.id))
            rejections = rejections.filter { stillOffered.contains($0.key) }
            rejectedRows = rejections.mapValues(\.reason)
            persistSyncState()
            lastSyncedAt = Date()
            phase = .idle
            reloadWidgets()
        } catch {
            logger.error("Sync failed: \(error.localizedDescription)")
            phase = .error(error.localizedDescription)
        }
    }

    private func apply(_ todos: [Todo], to store: AppStore) {
        guard todos != store.todos else { return }
        isApplyingMerge = true
        store.todos = todos
        isApplyingMerge = false
    }

    /// The snapshot after a push that may not have taken every row: accepted
    /// rows move to their pushed state, refused or unsent ones stay at the
    /// baseline the merge saw, so they remain dirty and are tried again.
    static func reconcile(
        _ next: [UUID: TodoRecord],
        pushed: PushOutcome,
        attempted: [TodoRecord],
        previous: [UUID: TodoRecord]
    ) -> [UUID: TodoRecord] {
        var snapshot = next
        for record in attempted where !pushed.accepted.contains(record.id) {
            snapshot[record.id] = previous[record.id]
        }
        return snapshot
    }

    /// One pass over the share tables. They are small enough to pull whole,
    /// which is also what makes a revoked share disappear: the row simply
    /// stops coming back, and `applyShareMerge` releases its todos.
    private func syncShares(store: AppStore, token: String) async throws {
        let remoteGroups = try await shareAPI.groups(accessToken: token)
        let remoteMembers = try await shareAPI.members(accessToken: token)
        let groups = ShareMerge.merge(local: store.sharedGroupRecords, remote: remoteGroups)
        let members = ShareMerge.merge(local: store.sharedMemberRecords, remote: remoteMembers)

        // Only push what this device is allowed to write. The todo push has
        // carried this guard from the start; the share push did not, and the
        // consequence was worse than a lost edit: a member's client would send
        // back the group row it had just pulled, the server would reject it
        // with a 403 (only the owner may write that row), the throw would
        // abort syncShares — and because shares are pushed *before* todos are
        // fetched, that member never received a single shared todo again. It
        // looked exactly like an empty group, on every launch, forever.
        let pushable = ShareMerge.pushable(
            groups: groups.toPush,
            members: members.toPush,
            knownGroups: store.sharedGroupRecords,
            currentPhone: store.currentPhone
        )
        // A refused roster row is logged and left behind, not thrown: the
        // todos behind it still have to sync. The guard above is what keeps
        // this path rare; this is what keeps it harmless.
        let groupPush = try await shareAPI.pushGroups(pushable.groups, accessToken: token)
        let memberPush = try await shareAPI.pushMembers(pushable.members, accessToken: token)
        for (id, reason) in groupPush.rejected {
            logger.error("Server refused shared group \(id.uuidString): \(reason)")
        }
        for (id, reason) in memberPush.rejected {
            logger.error("Server refused membership \(id.uuidString): \(reason)")
        }
        isApplyingMerge = true
        store.applyShareMerge(groups: groups.records, members: members.records)
        isApplyingMerge = false
    }

    private func persistSyncState() {
        let state = SyncState(watermark: watermark, snapshot: snapshot)
        if let data = try? TodoRecord.makeEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    /// The widget renders from the shared state file; nudge it after changes.
    private func reloadWidgets() {
        #if os(iOS) && canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
